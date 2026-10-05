#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for scripts/check-arm-isolation.sh, which asks Claude Code which
# instruction files a headless arm loads with and without
# `--setting-sources project`. No test starts a real session: CLAUDE_BIN
# points the script at a stand-in that feeds the script's own hook the
# loads each test names, the way Claude Code reports them. The stand-in
# is also first on PATH, and HOME and CLAUDE_CONFIG_DIR are a temporary
# directory, so a script that stopped honoring CLAUDE_BIN would still
# run the stand-in, and a real claude that ran anyway would find no
# real config. Coverage records nothing here: the project measures only
# bin/*.
# Run: ruby test/check_arm_isolation_test.rb

require_relative 'cli_test_case'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

class CheckArmIsolationTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/check-arm-isolation.sh', __dir__)
  USER_FILE = '/config/CLAUDE.md'
  USER_RULE = '/config/rules/style.md'
  PROJECT_FILE = '/work/project/CLAUDE.md'

  # Stands in for claude. It reports each load named in STUB_PLAIN (an
  # arm without the flag) or STUB_FLAGGED through every InstructionsLoaded
  # hook in the settings the script passed with --settings, as JSON or as
  # the path of a file, with every hook open at once and the payload
  # shaped as Claude Code shapes it. A Project load is reported
  # only when the working directory holds a CLAUDE.md to load. It
  # records its arguments, settings, working directory, and process ID
  # for the test to read. Knobs, each also taking an arm-specific form
  # (STUB_PLAIN_EXIT, STUB_FLAGGED_STDERR): STUB_EXIT and STUB_STDERR.
  # STUB_VERSION and STUB_VERSION_EXIT set what --version says, and
  # STUB_NEW_ONLY_IN names the one directory it reports a new build
  # from, the way a launcher that picks a build by directory would.
  # STUB_SPACED puts a space after each colon in the payload, and
  # STUB_SLEEP holds the arm open for that many seconds.
  STUB = <<~'RUBY'
    #!/usr/bin/env ruby
    require 'json'
    if ARGV == ['--version']
      old_outside = ENV['STUB_NEW_ONLY_IN'] && Dir.pwd != ENV['STUB_NEW_ONLY_IN']
      puts old_outside ? '2.0.50 (Claude Code)' : ENV.fetch('STUB_VERSION', '9.9.9 (Claude Code)')
      exit Integer(ENV.fetch('STUB_VERSION_EXIT', '0'))
    end
    given = ARGV[ARGV.index('--settings') + 1]
    settings = JSON.parse(given.start_with?('{') ? given : File.read(given))
    mode = given.start_with?('{') ? nil : File.stat(given).mode & 0o777
    File.open(ENV.fetch('STUB_CALLS'), 'a') do |log|
      log.puts JSON.generate('argv' => ARGV, 'cwd' => Dir.pwd, 'pid' => Process.pid, 'settings' => settings,
                             'settings_mode' => mode,
                             'project_file' => File.exist?('CLAUDE.md'),
                             'auto_memory_off' => ENV['CLAUDE_CODE_DISABLE_AUTO_MEMORY'])
    end
    sleep Integer(ENV['STUB_SLEEP']) if ENV['STUB_SLEEP']
    flagged = ARGV.each_cons(2).any? { |pair| pair == ['--setting-sources', 'project'] }
    arm = flagged ? 'FLAGGED' : 'PLAIN'
    hooks = settings.dig('hooks', 'InstructionsLoaded').flat_map { |entry| entry['hooks'] }
    loads = JSON.parse(ENV.fetch("STUB_#{arm}"))
    loads = loads.reject { |type, _| type == 'Project' } unless File.exist?('CLAUDE.md')
    pipes = loads.flat_map do |type, path|
      payload = { 'session_id' => 'stub', 'transcript_path' => '/stub/transcript.jsonl',
                  'cwd' => Dir.pwd, 'hook_event_name' => 'InstructionsLoaded',
                  'file_path' => path, 'memory_type' => type, 'load_reason' => 'session_start' }
      hooks.map do |hook|
        io = IO.popen(['sh', '-c', hook['command']], 'w')
        io.write(ENV['STUB_SPACED'] ? JSON.generate(payload, space: ' ') : JSON.generate(payload))
        io.flush
        io
      end
    end
    sleep 0.05
    pipes.each(&:close)
    stderr = ENV["STUB_#{arm}_STDERR"] || ENV['STUB_STDERR']
    warn stderr if stderr
    exit Integer(ENV["STUB_#{arm}_EXIT"] || ENV.fetch('STUB_EXIT', '0'))
  RUBY

  def setup
    @tmp = File.realpath(Dir.mktmpdir('check-arm-isolation-test'))
    @stub = File.join(@tmp, 'claude')
    File.write(@stub, STUB)
    File.chmod(0o755, @stub)
    @calls = File.join(@tmp, 'calls')
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def check_env(plain: [['User', USER_FILE], ['Project', PROJECT_FILE]],
                flagged: [['Project', PROJECT_FILE]], **extra)
    { 'HOME' => @tmp, 'CLAUDE_CONFIG_DIR' => @tmp, 'TMPDIR' => @tmp,
      'PATH' => "#{@tmp}:#{ENV.fetch('PATH')}", 'CLAUDE_BIN' => @stub, 'STUB_CALLS' => @calls,
      'STUB_PLAIN' => JSON.generate(plain), 'STUB_FLAGGED' => JSON.generate(flagged) }
      .merge(extra.transform_keys(&:to_s))
  end

  def check(*args, **options)
    Open3.capture3(check_env(**options), 'bash', SCRIPT, *args)
  end

  def calls
    File.readlines(@calls).map { |line| JSON.parse(line) }
  end

  def flagged_call
    calls.find { |call| call['argv'].include?('--setting-sources') }
  end

  def plain_call
    calls.find { |call| !call['argv'].include?('--setting-sources') }
  end

  def scratch_leftovers(dir = @tmp)
    Dir.glob(File.join(dir, 'check-arm-isolation.*'))
  end

  def assert_no_arm_ran
    refute File.exist?(@calls), 'an arm ran'
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # --- the verdict ---

  def test_passes_when_the_flag_keeps_every_user_level_file_out
    out, err, status = check(plain: [['User', USER_FILE], ['User', USER_RULE], ['Project', PROJECT_FILE]])

    assert_equal 0, status.exitstatus, err
    assert_match(/isolates an arm on 9\.9\.9/, out)
    assert_match(/2 user-level/, out)
    assert_empty err
  end

  def test_fails_when_a_user_level_file_loads_under_the_flag
    out, err, status = check(flagged: [['User', USER_FILE], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, out + err
    assert_includes err, USER_FILE
    assert_match(/does not isolate an arm on 9\.9\.9/, err)
    assert_match(/run no batch that relies on the flag/, err)
    assert_includes err, 'CONTRIBUTING.md'
    refute_match(/park/, err)
    assert_empty out
  end

  def test_names_every_user_level_file_that_leaked_and_no_project_file
    _out, err, status = check(flagged: [['User', USER_FILE], ['User', USER_RULE], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, USER_FILE
    assert_includes err, USER_RULE
    refute_includes err, PROJECT_FILE
  end

  def test_a_leak_is_reported_even_when_the_project_file_goes_unreported
    _out, err, status = check(flagged: [['User', USER_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, USER_FILE
  end

  def test_reads_a_report_written_with_spaces_after_its_colons
    _out, err, status = check(flagged: [['User', USER_FILE], ['Project', PROJECT_FILE]], STUB_SPACED: '1')

    assert_equal 1, status.exitstatus, err
    assert_includes err, USER_FILE
  end

  def test_names_a_leaked_file_whose_path_has_a_quote_in_it
    quoted = '/config/rules/say "hi".md'

    _out, err, status = check(flagged: [['User', quoted], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, 'say \"hi\".md'
  end

  def test_writes_a_leaked_file_under_the_home_directory_with_a_tilde
    _out, err, status = check(flagged: [['User', "#{@tmp}/.claude/CLAUDE.md"], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, '  ~/.claude/CLAUDE.md'
    refute_includes err, "#{@tmp}/.claude"
  end

  def test_writes_a_leaked_file_with_a_tilde_when_home_ends_in_a_slash
    _out, err, status = check(HOME: "#{@tmp}/",
                              flagged: [['User', "#{@tmp}/.claude/CLAUDE.md"], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, '  ~/.claude/CLAUDE.md'
    refute_includes err, "#{@tmp}/.claude"
  end

  def test_cannot_tell_when_no_user_level_file_loads_even_without_the_flag
    out, err, status = check(plain: [['Project', PROJECT_FILE]])

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: no user-level instruction file loaded/, err)
    refute_match(/park/, err)
    assert_empty out
  end

  def test_cannot_tell_when_the_flagged_arm_reports_no_project_file
    out, err, status = check(flagged: [])

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: the arm with the flag did not report/, err)
    assert_empty out
  end

  def test_cannot_tell_when_the_unflagged_arm_reports_nothing_at_all
    out, err, status = check(plain: [])

    assert_equal 2, status.exitstatus, out + err
    assert_match(/arm without the flag did not report/, err)
    refute_match(/no user-level instruction file/, err)
  end

  # --- an arm that fails ---

  def test_names_the_unflagged_arm_when_it_alone_fails_and_shows_its_error
    out, err, status = check(STUB_PLAIN_EXIT: '4', STUB_PLAIN_STDERR: "Invalid API key\nPlease sign in",
                             STUB_FLAGGED_STDERR: 'flagged noise')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: the arm without the flag exited 4:/, err)
    assert_includes err, "  Invalid API key\n  Please sign in"
    refute_includes err, 'flagged noise'
    assert_empty out
  end

  def test_names_the_flagged_arm_when_it_alone_fails_and_shows_its_error
    out, err, status = check(STUB_FLAGGED_EXIT: '5', STUB_FLAGGED_STDERR: 'Not logged in',
                             STUB_PLAIN_STDERR: 'plain noise')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: the arm with the flag exited 5:/, err)
    assert_includes err, '  Not logged in'
    refute_includes err, 'plain noise'
    assert_empty out
  end

  def test_an_arm_that_fails_silently_is_reported_as_such
    _out, err, status = check(STUB_EXIT: '3')

    assert_equal 2, status.exitstatus, err
    assert_match(/exited 3:/, err)
    assert_includes err, '  (no error output)'
  end

  # --- how the arms are run ---

  def test_only_one_arm_carries_the_flag
    check

    assert_equal 2, calls.size
    assert flagged_call, 'no arm ran with --setting-sources project'
    assert plain_call, 'no arm ran without the flag'
  end

  def test_both_arms_run_headless_on_haiku
    check

    calls.each do |call|
      assert_includes call['argv'], '-p'
      assert call['argv'].each_cons(2).include?(%w[--model haiku]), 'an arm ran on another model'
    end
  end

  def test_both_arms_run_from_one_scratch_directory_under_tmpdir
    check

    assert_equal plain_call['cwd'], flagged_call['cwd']
    assert plain_call['cwd'].start_with?("#{@tmp}/check-arm-isolation."), plain_call['cwd']
  end

  def test_gives_both_arms_a_project_file_to_report
    check

    calls.each { |call| assert call['project_file'], 'an arm ran in a directory with no CLAUDE.md' }
  end

  def test_both_arms_run_with_session_saving_and_auto_memory_off
    check

    calls.each do |call|
      assert_includes call['argv'], '--no-session-persistence'
      assert_equal '1', call['auto_memory_off']
    end
  end

  # --tools takes any number of values, so the one after its empty
  # value has to be another option.
  def test_neither_arm_is_given_any_tools_or_mcp_servers
    check

    calls.each do |call|
      argv = call['argv']
      tools = argv.index('--tools')
      assert_equal '', argv[tools + 1], 'an arm ran with tools'
      assert argv[tools + 2].start_with?('--'), 'a value follows the empty tool list'
      assert_includes argv, '--strict-mcp-config'
    end
  end

  # --- which claude runs ---

  def test_runs_claude_from_path_when_claude_bin_is_unset
    out, err, status = check(CLAUDE_BIN: nil)

    assert_equal 0, status.exitstatus, out + err
    assert_equal 2, calls.size
  end

  def test_cannot_tell_when_claude_is_not_installed
    out, err, status = check(CLAUDE_BIN: File.join(@tmp, 'no-such-claude'))

    assert_equal 2, status.exitstatus, out + err
    assert_match(/no-such-claude is not installed or not on PATH/, err)
    assert_no_arm_ran
  end

  def test_refuses_a_claude_that_is_not_a_file
    out, err, status = check(CLAUDE_BIN: 'echo')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/not a file/, err)
    assert_no_arm_ran
  end

  def test_works_with_a_relative_path_to_claude
    out, err, status = Dir.chdir(@tmp) { check(CLAUDE_BIN: './claude') }

    assert_equal 0, status.exitstatus, out + err
  end

  # The version guard and the arms must run one binary. PATH is built
  # to hold no real claude, so an arm that looked one up again from the
  # scratch directory finds nothing rather than starting a session.
  def test_runs_the_claude_it_checked_when_path_has_a_relative_entry
    skip 'a real claude sits in /usr/bin or /bin' if %w[/usr/bin /bin].any? { |dir| File.exist?("#{dir}/claude") }
    Dir.mkdir(File.join(@tmp, 'bin'))
    FileUtils.cp(@stub, File.join(@tmp, 'bin', 'claude'))
    Dir.mkdir(File.join(@tmp, 'ruby'))
    File.symlink(RbConfig.ruby, File.join(@tmp, 'ruby', 'ruby'))
    path = ['bin', File.join(@tmp, 'ruby'), '/usr/bin', '/bin'].join(':')

    out, err, status = Dir.chdir(@tmp) { check(CLAUDE_BIN: nil, PATH: path) }

    assert_equal 0, status.exitstatus, out + err
    assert_equal 2, calls.size
  end

  # --- the version guard ---

  def test_starts_no_session_on_a_build_that_deleted_history_under_the_flag
    out, err, status = check(STUB_VERSION: '2.1.100 (Claude Code)')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/Claude Code 2\.1\.100 is older than 2\.1\.101/, err)
    assert_no_arm_ran
  end

  def test_starts_no_session_on_an_older_major_or_minor_whatever_its_patch
    %w[1.0.128 2.0.200].each do |old|
      FileUtils.rm_f(@calls)

      out, err, status = check(STUB_VERSION: "#{old} (Claude Code)")

      assert_equal 2, status.exitstatus, "#{old}: #{out}#{err}"
      assert_match(/older than 2\.1\.101/, err, old)
      refute File.exist?(@calls), "an arm ran on #{old}"
    end
  end

  def test_runs_on_the_first_build_with_the_history_fix
    out, err, status = check(STUB_VERSION: '2.1.101 (Claude Code)')

    assert_equal 0, status.exitstatus, out + err
  end

  def test_runs_on_a_later_minor_or_major_whatever_its_patch
    %w[2.2.0 3.0.0 v2.1.101].each do |newer|
      out, err, status = check(STUB_VERSION: "#{newer} (Claude Code)")

      assert_equal 0, status.exitstatus, "#{newer}: #{out}#{err}"
    end
  end

  def test_starts_no_session_on_a_version_it_cannot_read
    ['2.1', '2.1.100.5', '2.2.0-beta.1', '2.1.1234567', '2.1.99999999999999999999',
     'claude: unknown option'].each do |odd|
      FileUtils.rm_f(@calls)

      out, err, status = check(STUB_VERSION: "#{odd} (Claude Code)")

      assert_equal 2, status.exitstatus, "#{odd}: #{out}#{err}"
      assert_match(/could not read a version/, err, odd)
      assert_includes err, "it printed: #{odd}"
      refute_match(/integer expression/, err, odd)
      refute File.exist?(@calls), "an arm ran on #{odd}"
    end
  end

  def test_starts_no_session_when_asking_for_the_version_fails
    out, err, status = check(STUB_VERSION_EXIT: '1')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/could not read a version/, err)
    assert_no_arm_ran
  end

  def test_reads_the_version_from_the_directory_the_arms_run_in
    out, err, status = Dir.chdir(@tmp) { check(STUB_NEW_ONLY_IN: @tmp) }

    assert_equal 2, status.exitstatus, out + err
    assert_match(/Claude Code 2\.0\.50 is older/, err)
    assert_no_arm_ran
  end

  # --- the scratch directory ---

  def test_removes_its_scratch_directory_after_a_pass
    _out, _err, status = check

    assert_equal 0, status.exitstatus
    assert_empty scratch_leftovers
  end

  def test_removes_its_scratch_directory_when_the_flag_leaks
    _out, _err, status = check(flagged: [['User', USER_FILE]])

    assert_equal 1, status.exitstatus
    assert_empty scratch_leftovers
  end

  def test_removes_its_scratch_directory_when_it_cannot_tell
    _out, _err, status = check(STUB_EXIT: '1')

    assert_equal 2, status.exitstatus
    assert_empty scratch_leftovers
  end

  def test_works_in_a_temporary_directory_with_a_space_in_its_name
    spaced = File.join(@tmp, 'two words')
    Dir.mkdir(spaced)

    out, err, status = check(TMPDIR: spaced)

    assert_equal 0, status.exitstatus, out + err
    assert_empty scratch_leftovers(spaced)
  end

  def test_refuses_a_scratch_path_the_hook_command_cannot_carry
    ["it's", 'say"hi', 'back\\slash'].each do |name|
      odd = File.join(@tmp, name)
      Dir.mkdir(odd)

      out, err, status = check(TMPDIR: odd)

      assert_equal 2, status.exitstatus, "#{name}: #{out}#{err}"
      assert_match(/has a quote or backslash in it/, err, name)
      refute File.exist?(@calls), "an arm ran under #{name}"
      assert_empty scratch_leftovers(odd), name
    end
  end

  def test_refuses_a_scratch_path_with_a_control_character_without_printing_it
    odd = File.join(@tmp, "a\tb")
    Dir.mkdir(odd)

    out, err, status = check(TMPDIR: odd)

    assert_equal 2, status.exitstatus, out + err
    assert_match(/control character/, err)
    refute_includes err, "\t"
    assert_no_arm_ran
    assert_empty scratch_leftovers(odd)
  end

  def test_works_from_a_relative_temporary_directory
    Dir.mkdir(File.join(@tmp, 'rel'))

    out, err, status = Dir.chdir(@tmp) { check(TMPDIR: 'rel') }

    assert_equal 0, status.exitstatus, out + err
    assert_empty scratch_leftovers(File.join(@tmp, 'rel'))
  end

  def test_a_relative_temporary_directory_ignores_cdpath
    Dir.mkdir(File.join(@tmp, 'rel'))

    out, err, status = Dir.chdir(@tmp) { check(TMPDIR: 'rel', CDPATH: @tmp) }

    assert_equal 0, status.exitstatus, out + err
    assert_empty scratch_leftovers(File.join(@tmp, 'rel'))
  end

  def test_works_from_a_temporary_directory_whose_name_starts_with_a_dash
    Dir.mkdir(File.join(@tmp, '-dash'))

    out, err, status = Dir.chdir(@tmp) { check(TMPDIR: '-dash') }

    assert_equal 0, status.exitstatus, out + err
    assert_empty scratch_leftovers(File.join(@tmp, '-dash'))
  end

  # --- being interrupted ---

  def test_a_killed_check_stops_its_arms_and_removes_its_scratch_directory
    script = Process.spawn(check_env(STUB_SLEEP: '30'), 'bash', SCRIPT, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.05 until File.exist?(@calls) && calls.size == 2 }
    arms = calls.map { |call| call['pid'] }

    Process.kill('TERM', script)
    Process.wait(script)
    Timeout.timeout(10) { sleep 0.05 while arms.any? { |pid| alive?(pid) } }

    assert_empty scratch_leftovers
  ensure
    arms&.each { |pid| Process.kill('KILL', pid) if alive?(pid) }
  end

  # --- a settings file for the arm with the flag ---

  def arm_settings(content = { 'apiKeyHelper' => '/opt/sign-in.sh' }, name: 'sign-in.json')
    path = File.join(@tmp, name)
    File.write(path, content.is_a?(String) ? content : JSON.generate(content))
    path
  end

  def test_hands_the_flagged_arm_the_settings_file_it_is_given
    out, err, status = check(ARM_SETTINGS: arm_settings)

    assert_equal 0, status.exitstatus, out + err
    assert_equal '/opt/sign-in.sh', flagged_call['settings']['apiKeyHelper']
  end

  def test_the_arm_without_the_flag_runs_on_user_settings_alone
    out, err, status = check(ARM_SETTINGS: arm_settings)

    assert_equal 0, status.exitstatus, out + err
    refute plain_call['settings'].key?('apiKeyHelper')
  end

  def test_passes_each_arm_one_settings_value_since_a_second_replaces_the_first
    out, err, status = check(ARM_SETTINGS: arm_settings)

    assert_equal 0, status.exitstatus, out + err
    calls.each { |call| assert_equal 1, call['argv'].count('--settings') }
  end

  # A process's arguments show in ps to every user on the machine.
  def test_keeps_what_the_settings_file_holds_off_the_arms_command_line
    out, err, status = check(ARM_SETTINGS: arm_settings({ 'env' => { 'TOKEN' => 'not-for-ps' } }))

    assert_equal 0, status.exitstatus, out + err
    assert_equal 'not-for-ps', flagged_call['settings'].dig('env', 'TOKEN')
    calls.each { |call| refute_includes call['argv'].join(' '), 'not-for-ps' }
  end

  def test_writes_the_flagged_arms_settings_where_only_this_user_can_read_them
    out, err, status = check(ARM_SETTINGS: arm_settings)

    assert_equal 0, status.exitstatus, out + err
    assert_equal 0o600, flagged_call['settings_mode']
  end

  # A version manager picks a ruby by the directory it is run from.
  def test_runs_ruby_from_the_directory_the_check_was_started_in
    shims = File.join(@tmp, 'shims')
    started = File.join(@tmp, 'started-here')
    [shims, started].each { |dir| Dir.mkdir(dir) }
    File.write(File.join(shims, 'ruby'), <<~SH)
      #!/bin/sh
      case " $* " in *" -rjson "*) pwd > "#{@tmp}/ruby-ran-in" ;; esac
      exec "#{RbConfig.ruby}" "$@"
    SH
    File.chmod(0o755, File.join(shims, 'ruby'))

    out, err, status = Dir.chdir(started) do
      check(ARM_SETTINGS: arm_settings, PATH: "#{shims}:#{@tmp}:#{ENV.fetch('PATH')}")
    end

    assert_equal 0, status.exitstatus, out + err
    assert_equal started, File.read(File.join(@tmp, 'ruby-ran-in')).strip
  end

  def test_reads_a_settings_file_with_a_space_in_its_name
    out, err, status = check(ARM_SETTINGS: arm_settings(name: 'sign in.json'))

    assert_equal 0, status.exitstatus, out + err
    assert_equal '/opt/sign-in.sh', flagged_call['settings']['apiKeyHelper']
  end

  def test_still_reports_a_leak_from_an_arm_given_a_settings_file
    _out, err, status = check(ARM_SETTINGS: arm_settings, flagged: [['User', USER_FILE], ['Project', PROJECT_FILE]])

    assert_equal 1, status.exitstatus, err
    assert_includes err, USER_FILE
  end

  def test_keeps_the_hooks_a_settings_file_already_has
    own = { 'type' => 'command', 'command' => 'true' }
    file = arm_settings({ 'hooks' => { 'InstructionsLoaded' => [{ 'hooks' => [own] }],
                                       'SessionStart' => [{ 'hooks' => [own] }] } })

    out, err, status = check(ARM_SETTINGS: file)
    hooks = flagged_call['settings']['hooks']

    assert_equal 0, status.exitstatus, out + err
    assert_equal 2, hooks['InstructionsLoaded'].size
    assert_includes hooks['InstructionsLoaded'], { 'hooks' => [own] }
    assert_equal [{ 'hooks' => [own] }], hooks['SessionStart']
  end

  def test_reads_a_settings_file_named_relative_to_where_the_check_was_run
    arm_settings

    out, err, status = Dir.chdir(@tmp) { check(ARM_SETTINGS: 'sign-in.json') }

    assert_equal 0, status.exitstatus, out + err
    assert_equal '/opt/sign-in.sh', flagged_call['settings']['apiKeyHelper']
  end

  def test_starts_no_session_when_the_settings_file_is_missing
    out, err, status = check(ARM_SETTINGS: File.join(@tmp, 'no-such.json'))

    assert_equal 2, status.exitstatus, out + err
    assert_match(%r{cannot tell: could not read the ARM_SETTINGS file ~/no-such\.json}, err)
    refute_includes err, @tmp
    assert_no_arm_ran
  end

  def test_starts_no_session_when_the_settings_file_is_a_directory
    out, err, status = check(ARM_SETTINGS: @tmp)

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: could not read the ARM_SETTINGS file/, err)
    assert_no_arm_ran
  end

  def test_starts_no_session_when_the_settings_file_is_not_a_json_object
    ['{"apiKeyHelper": ', '["apiKeyHelper"]', '{"hooks": []}', '{"hooks": null}',
     "{\"apiKeyHelper\": \"\xFF\"}".b].each do |content|
      out, err, status = check(ARM_SETTINGS: arm_settings(content))
      shape = content.inspect

      assert_equal 2, status.exitstatus, "#{shape}: #{out}#{err}"
      assert_match(%r{cannot tell: the ARM_SETTINGS file ~/sign-in\.json cannot be used}, err, shape)
      refute_includes err, @tmp, shape
      refute_match(/\.rb:\d+|from -e/, err, shape)
      refute File.exist?(@calls), "an arm ran with #{shape}"
      assert_empty scratch_leftovers, shape
    end
  end

  # The guard runs before anything else is looked up, so a PATH with
  # nothing on it reaches it.
  def test_starts_no_session_when_a_settings_file_is_given_and_ruby_is_missing
    empty = File.join(@tmp, 'empty')
    Dir.mkdir(empty)

    out, err, status = Open3.capture3(check_env(ARM_SETTINGS: arm_settings, PATH: empty), '/bin/bash', SCRIPT)

    assert_equal 2, status.exitstatus, out + err
    assert_match(/ARM_SETTINGS needs ruby/, err)
    assert_no_arm_ran
    assert_empty scratch_leftovers
  end

  # A version manager's shim can be on PATH and still refuse to run.
  def test_tells_a_ruby_that_will_not_run_from_a_settings_file_that_is_wrong
    shims = File.join(@tmp, 'shims')
    Dir.mkdir(shims)
    File.write(File.join(shims, 'ruby'), <<~SH)
      #!/bin/sh
      case " $* " in *" -rjson "*) echo "shim: no version is set" >&2; exit 126 ;; esac
      exec "#{RbConfig.ruby}" "$@"
    SH
    File.chmod(0o755, File.join(shims, 'ruby'))

    out, err, status = check(ARM_SETTINGS: arm_settings, PATH: "#{shims}:#{@tmp}:#{ENV.fetch('PATH')}")

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: ruby could not merge the ARM_SETTINGS file/, err)
    assert_includes err, '  shim: no version is set'
    refute_match(/cannot be used/, err)
    assert_no_arm_ran
    assert_empty scratch_leftovers
  end

  def test_points_at_arm_settings_when_the_flagged_arm_alone_fails_without_it
    _out, err, status = check(STUB_FLAGGED_EXIT: '5', STUB_FLAGGED_STDERR: 'Not logged in')

    assert_equal 2, status.exitstatus, err
    assert_match(/set ARM_SETTINGS/, err)
  end

  def test_does_not_point_at_arm_settings_when_one_was_given
    _out, err, status = check(ARM_SETTINGS: arm_settings, STUB_FLAGGED_EXIT: '5')

    assert_equal 2, status.exitstatus, err
    assert_match(/arm with the flag exited 5/, err)
    refute_match(/set ARM_SETTINGS/, err)
  end

  def test_does_not_point_at_arm_settings_when_the_arm_without_the_flag_failed
    _out, err, status = check(STUB_PLAIN_EXIT: '4')

    assert_equal 2, status.exitstatus, err
    assert_match(/arm without the flag exited 4/, err)
    refute_match(/set ARM_SETTINGS/, err)
  end

  # --- usage and messages ---

  def test_refuses_arguments_and_runs_nothing
    out, err, status = check('--verbose')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/usage/, err)
    assert_no_arm_ran
  end
end
