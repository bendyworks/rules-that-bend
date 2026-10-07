#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/dry-run-cleanup.
#
# The bin file guards its CLI dispatch behind $PROGRAM_NAME == __FILE__,
# so loading it here exposes the DryRunCleanup module without executing
# the CLI. Run: ruby test/dry_run_cleanup_test.rb

require_relative 'cli_test_case'

require 'json'

load File.expand_path('../bin/dry-run-cleanup', __dir__)

class DryRunCleanupNamesTest < Minitest::Test
  def test_folder_name_turns_every_other_character_into_a_dash
    assert_equal '-private-tmp-run-1--arm-a', DryRunCleanup.folder_name('/private/tmp/run.1/_arm a')
  end

  def test_a_path_whose_folder_name_ends_inside_the_cut_is_accepted
    DryRunCleanup.check_run_directory_path!("/#{'x' * 197}")
  end

  def test_a_path_claude_code_would_cut_short_is_refused
    path = "/#{'x' * 198}"
    error = assert_raises(DryRunCleanup::Error) { DryRunCleanup.check_run_directory_path!(path) }
    assert_match(/too long.*a 199-character folder name/m, error.message)
    assert_includes error.message, path
  end

  def test_a_path_with_a_control_character_is_refused
    error = assert_raises(DryRunCleanup::Error) { DryRunCleanup.check_run_directory_path!("/tmp/run\n1") }
    assert_match(/outside printable ASCII/, error.message)
  end

  def test_a_path_outside_ascii_is_refused
    error = assert_raises(DryRunCleanup::Error) { DryRunCleanup.check_run_directory_path!("/tmp/café") }
    assert_match(/outside printable ASCII/, error.message)
  end

  def test_left_by_takes_the_run_directory_and_everything_under_it
    names = %w[-tmp-run1 -tmp-run1-arm-a -tmp-run1-arm-b-work -tmp-run10-arm-a -tmp-run -work-me-project]
    assert_equal %w[-tmp-run1 -tmp-run1-arm-a -tmp-run1-arm-b-work], DryRunCleanup.left_by(names, '/tmp/run1')
  end

  def test_config_directory_comes_from_the_environment_when_set
    assert_equal '/elsewhere', DryRunCleanup.config_directory({ 'CLAUDE_CONFIG_DIR' => '/elsewhere' }, '/base/me')
  end

  def test_config_directory_defaults_to_dot_claude_under_home
    assert_equal '/base/me/.claude', DryRunCleanup.config_directory({}, '/base/me')
    assert_equal '/base/me/.claude', DryRunCleanup.config_directory({ 'CLAUDE_CONFIG_DIR' => '' }, '/base/me')
  end

  def test_recent_is_a_write_inside_the_window
    now = Time.at(10_000)
    assert DryRunCleanup.recent?(now - DryRunCleanup::RECENT_SECONDS + 1, now)
    refute DryRunCleanup.recent?(now - DryRunCleanup::RECENT_SECONDS, now)
  end

  def test_a_file_gone_before_it_is_read_counts_as_a_recent_write
    Dir.mktmpdir do |directory|
      assert DryRunCleanup::Tree.any_recent?(directory, %w[gone.jsonl], Time.now)
    end
  end

  def test_a_marker_round_trips_both_directories
    text = DryRunCleanup.marker_text('/tmp/run1', '/base/me/.claude')
    assert_equal({ run_directory: '/tmp/run1', config_directory: '/base/me/.claude' },
                 DryRunCleanup.parse_marker(text))
  end

  def test_a_marker_missing_either_line_does_not_parse
    assert_nil DryRunCleanup.parse_marker("Made by hand.\n")
    assert_nil DryRunCleanup.parse_marker("run directory: /tmp/run1\n")
  end

  def test_reason_to_keep
    here = ['/tmp/run1/arm-a']
    keep = lambda do |kind, entries, logged, has_directory = false|
      DryRunCleanup.reason_to_keep(kind: kind, entries: entries, logged_directories: logged,
                                   has_directory: has_directory)
    end
    assert_nil keep.call(:directory, %w[a.jsonl memory-notes.jsonl sub/memory/x], here)
    assert_nil keep.call(:directory, [], [])
    assert_nil keep.call(:missing, [], [])
    assert_equal 'it is a symbolic link', keep.call(:link, [], [])
    assert_equal 'it is not a directory', keep.call(:file, [], [])
    assert_equal 'it is not a directory', keep.call(:other, [], [])
    assert_equal 'its memory directory holds a file', keep.call(:directory, %w[memory/sub/n.md], here)
    assert_equal 'its memory entry is not a directory', keep.call(:directory, %w[memory], here)
    assert_equal 'a session log in it does not say where it ran', keep.call(:directory, %w[a.jsonl], here + [nil])
    assert_match(/\Ait holds files and no session log, and no directory/, keep.call(:directory, %w[id/out.txt], []))
    assert_nil keep.call(:directory, %w[id/out.txt], [], true)
  end

  def test_names_a_directory_allows_for_the_cut_claude_code_makes
    long = "-tmp-run1-#{'x' * 250}"
    assert DryRunCleanup.names_a_directory?('-tmp-run1-arm-a', %w[-tmp-run1 -tmp-run1-arm-a])
    refute DryRunCleanup.names_a_directory?('-tmp-run1-copy-arm-a', %w[-tmp-run1 -tmp-run1-arm-a])
    assert DryRunCleanup.names_a_directory?("#{long[0, 200]}-1942o1", [long])
    refute DryRunCleanup.names_a_directory?("#{long[0, 199]}-1942o1", [long])
  end

  def test_directory_elsewhere_is_the_first_logged_directory_outside_the_run_directory
    assert_nil DryRunCleanup.directory_elsewhere('/tmp/run1', ['/tmp/run1', '/tmp/run1/arm-a', nil])
    assert_equal '/tmp/run1-copy/arm-a',
                 DryRunCleanup.directory_elsewhere('/tmp/run1', %w[/tmp/run1/a /tmp/run1-copy/arm-a])
  end

  def test_split_arguments_reads_everything_after_a_double_dash_as_a_path
    assert_equal [%w[--delete], %w[run]], DryRunCleanup.split_arguments(%w[run --delete])
    assert_equal [%w[--delete], %w[-run]], DryRunCleanup.split_arguments(%w[--delete -- -run])
  end

  def test_deleted_lines_end_with_what_went_and_what_stayed
    assert_equal ['Removed 2 folders and the run directory.'],
                 DryRunCleanup.deleted_lines(removed: 2, kept: 0, kept_late: {})
    assert_equal ['Removed 1 folder. Kept 3 folders and the run directory.'],
                 DryRunCleanup.deleted_lines(removed: 1, kept: 3, kept_late: {})
  end

  def test_deleted_lines_say_why_a_folder_listed_for_removal_stayed
    assert_equal ['  kept    -tmp-run1-a (it was written while the sweep ran)',
                  'Removed 0 folders. Kept 1 folder and the run directory.'],
                 DryRunCleanup.deleted_lines(removed: 0, kept: 1,
                                             kept_late: { '-tmp-run1-a' => DryRunCleanup::LATE_WRITE })
  end

  def test_a_session_log_names_its_directory_within_the_lines_read
    Dir.mktmpdir do |directory|
      log = File.join(directory, 'session.jsonl')
      filler = "#{JSON.generate(type: 'queue-operation')}\n" * (DryRunCleanup::LOG_LINES_READ - 1)
      File.write(log, "not json\n#{JSON.generate(cwd: 7)}\n")
      assert_nil DryRunCleanup::Tree.logged_directory(log)
      File.write(log, "#{filler}#{JSON.generate(cwd: '/tmp/run1')}\n")
      assert_equal '/tmp/run1', DryRunCleanup::Tree.logged_directory(log)
      File.write(log, "#{filler}#{JSON.generate(type: 'user')}\n#{JSON.generate(cwd: '/tmp/run1')}\n")
      assert_nil DryRunCleanup::Tree.logged_directory(log)
    end
  end

  def test_a_config_directory_path_ruby_cannot_expand_is_refused
    error = assert_raises(DryRunCleanup::Error) { DryRunCleanup::Tree.resolved('~no-such-user-here/config') }
    assert_match(/CLAUDE_CONFIG_DIR/, error.message)
  end

  def test_resolved_does_not_depend_on_whether_the_last_part_exists
    Dir.mktmpdir do |directory|
      real = File.realpath(directory)
      File.symlink(real, File.join(real, 'link'))
      assert_equal File.join(real, 'later', 'on'), DryRunCleanup::Tree.resolved(File.join(real, 'link', 'later', 'on'))
    end
  end
end

class DryRunCleanupCliTest < CliTestCase
  LONG_AGO = 3600
  JUST_NOW = 5
  ISOLATED_ENV_KEYS = %w[CLAUDE_CONFIG_DIR TMPDIR].freeze

  def extra_scrubbed_env_keys
    ISOLATED_ENV_KEYS
  end

  def setup
    @root = File.realpath(Dir.mktmpdir('dry-run-cleanup-test'))
    @config = File.join(@root, 'config')
    @projects = File.join(@config, 'projects')
    @tmp = File.join(@root, 'tmp')
    FileUtils.mkdir_p([@config, @tmp])
    ENV['CLAUDE_CONFIG_DIR'] = @config
    ENV['TMPDIR'] = @tmp
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # The CLI deletes under the config directory and creates under the
  # temporary one, so both must be this test's own before it runs.
  # Dir.tmpdir falls back to the system directory when TMPDIR names one
  # it will not use, so the check is on where it resolves.
  def guard_cli_invocation(_argv)
    config = DryRunCleanup::Tree.resolved(ENV.fetch('CLAUDE_CONFIG_DIR', ''))
    inside = [config, File.realpath(Dir.tmpdir)].all? { |path| path.start_with?("#{@root}/") }
    flunk "CLAUDE_CONFIG_DIR and the temporary directory must be inside the test's own directory" unless inside
  end

  def dispatch_cli(argv)
    DryRunCleanup::CLI.run(argv)
  end

  # A run directory as a batch that ended more than ten minutes ago
  # leaves it. Only the passing of time ages one outside a test, and
  # test_sweep_delete_refuses_a_run_directory_made_a_moment_ago covers
  # the directory as `new` leaves it.
  def new_run_directory
    age_directories(cli_stdout(%w[new]).chomp)
  end

  def aged_file(path, age, content = "{}\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.utime(Time.now - age, Time.now - age, path)
    path
  end

  # Creating a file updates its directory's time, so directories are
  # aged once everything in them exists.
  def age_directories(root)
    inside = Dir.glob('**/', File::FNM_DOTMATCH, base: root).map { |entry| File.join(root, entry) }
    ([root] + inside).each { |directory| File.utime(Time.now - LONG_AGO, Time.now - LONG_AGO, directory) }
    root
  end

  def aged_link(target, link)
    File.symlink(target, link)
    File.lutime(Time.now - LONG_AGO, Time.now - LONG_AGO, link)
  end

  # Builds the folder Claude Code would leave for a run in
  # arm_directory, holding each named file at the age given in seconds.
  # A session log records the directory its run started in.
  def session_folder(arm_directory, files = { 'session.jsonl' => LONG_AGO })
    folder = File.join(@projects, DryRunCleanup.folder_name(arm_directory))
    FileUtils.mkdir_p(File.join(folder, 'memory'))
    files.each do |name, age|
      content = name.end_with?('.jsonl') ? session_log(arm_directory) : "{}\n"
      aged_file(File.join(folder, name), age, content)
    end
    age_directories(folder)
  end

  def session_log(directory)
    "#{JSON.generate(type: 'queue-operation')}\n#{JSON.generate(type: 'user', cwd: directory)}\n"
  end

  def test_new_prints_a_marked_directory_at_its_physical_path
    link = File.join(@root, 'tmp-link')
    File.symlink(@tmp, link)
    ENV['TMPDIR'] = link
    run_directory = new_run_directory
    assert run_directory.start_with?("#{@tmp}/dry-run-"), run_directory
    assert File.directory?(run_directory)
    marker = DryRunCleanup.parse_marker(File.read(File.join(run_directory, DryRunCleanup::MARKER)))
    assert_equal({ run_directory: run_directory, config_directory: @config }, marker)
  end

  def test_new_refuses_a_temporary_directory_too_long_to_sweep_and_leaves_nothing
    ENV['TMPDIR'] = File.join(@tmp, 'x' * 150)
    FileUtils.mkdir_p(ENV.fetch('TMPDIR'))
    result = abort_result(%w[new])
    assert_equal 1, result.status
    assert_match(/too long.*Point TMPDIR at a shorter directory/m, result.message)
    assert_empty Dir.children(ENV.fetch('TMPDIR'))
  end

  def test_new_refuses_a_temporary_directory_outside_ascii_and_leaves_nothing
    ENV['TMPDIR'] = File.join(@tmp, "café")
    FileUtils.mkdir_p(ENV.fetch('TMPDIR'))
    assert_match(/outside printable ASCII/, abort_message(%w[new]))
    assert_empty Dir.children(ENV.fetch('TMPDIR'))
  end

  def test_sweep_without_delete_lists_and_removes_nothing
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    assert_equal <<~OUT, cli_stdout(['sweep', run_directory])
      Run directory: #{run_directory}
      Looking in: #{@projects}
      Session-history folders: 1
        remove  #{File.basename(folder)}
      Nothing removed. --delete removes 1 folder and the run directory.
    OUT
    assert File.directory?(folder)
    assert File.directory?(run_directory)
  end

  def test_sweep_without_delete_says_what_delete_would_keep
    run_directory = new_run_directory
    session_folder(File.join(run_directory, 'arm-a'))
    session_folder(File.join(run_directory, 'arm-b'))
    session_folder(File.join(run_directory, 'arm-c'), 'memory/MEMORY.md' => LONG_AGO)
    out = cli_stdout(['sweep', run_directory])
    assert_operator out.index('arm-a'), :<, out.index('arm-b')
    assert_operator out.index('arm-b'), :<, out.index('arm-c')
    assert_match(/^Nothing removed\. --delete removes 2 folders, and keeps 1 folder and the run directory\.$/, out)
  end

  def test_the_guard_refuses_a_temporary_directory_outside_the_tests_own
    ENV['TMPDIR'] = File.join(@root, 'missing')
    assert_raises(Minitest::Assertion) { run_cli(%w[new]) }
  end

  def test_sweep_delete_refuses_a_run_directory_made_a_moment_ago
    run_directory = cli_stdout(%w[new]).chomp
    message = abort_message(['sweep', run_directory, '--delete'])
    assert_match(/written in the last 10 minutes: the run directory\./, message)
  end

  def test_sweep_without_delete_reports_a_recent_run_directory
    run_directory = new_run_directory
    FileUtils.mkdir_p(File.join(run_directory, 'arm-a'))
    out = cli_stdout(['sweep', run_directory])
    assert_match(/^Nothing removed\. --delete would refuse for now\. These were written .*: the run directory\.$/, out)
  end

  def test_sweep_without_delete_reports_a_recent_write_and_exits_cleanly
    run_directory = new_run_directory
    fresh = session_folder(File.join(run_directory, 'arm-b'), 'session.jsonl' => JUST_NOW)
    out = cli_stdout(['sweep', run_directory])
    assert_match(/^Nothing removed\. --delete would refuse for now\. These were written in the last 10 minutes: /, out)
    assert_includes out, File.basename(fresh)
    refute_match(/--delete removes/, out)
    assert File.directory?(fresh)
  end

  def test_sweep_delete_removes_the_folders_and_the_run_directory
    run_directory = new_run_directory
    aged_file(File.join(run_directory, 'arm-a', 'output.txt'), LONG_AGO)
    age_directories(run_directory)
    folders = [session_folder(run_directory), session_folder(File.join(run_directory, 'arm-a')),
               session_folder(File.join(run_directory, 'arm-b', 'work'), 'memory-notes.jsonl' => LONG_AGO,
                                                                         'sub/memory/x' => LONG_AGO)]
    cut_short = File.join(@projects, "#{DryRunCleanup.folder_name(run_directory)}-#{'x' * 60}-1942o1")
    age_directories(FileUtils.mkdir_p(cut_short).first)
    aged_link(File.join(@root, 'absent'), File.join(folders.first, 'dangling'))
    age_directories(folders.first)
    out = cli_stdout(['sweep', '--delete', run_directory])
    (folders + [cut_short]).each { |folder| assert_includes out, "  remove  #{File.basename(folder)}\n" }
    assert_match(/^Removed 4 folders and the run directory\.$/, out)
    (folders + [cut_short, run_directory]).each { |path| refute File.exist?(path), path }
  end

  def test_sweep_delete_leaves_other_runs_alone
    run_directory = new_run_directory
    own = session_folder(File.join(run_directory, 'arm-a'))
    others = [session_folder("#{run_directory}0/arm-a"), session_folder("#{run_directory.chop}/arm-a"),
              session_folder('/work/someone/project')]
    cli_stdout(['sweep', run_directory, '--delete'])
    refute File.exist?(own)
    others.each { |folder| assert File.directory?(folder), folder }
  end

  def test_sweep_leaves_a_folder_whose_session_log_ran_somewhere_else
    run_directory = new_run_directory
    own = session_folder(File.join(run_directory, 'arm-a'))
    copy = session_folder("#{run_directory}-copy/arm-a")
    dotted = session_folder("#{run_directory}.bak/arm-a")
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_match(/^Session-history folders: 1$/, out)
    assert_match(/^Left for other directories: 2$/, out)
    assert_includes out, "  leave   #{File.basename(copy)} (its session log ran in #{run_directory}-copy/arm-a)"
    assert_match(/^Removed 1 folder and the run directory\.$/, out)
    refute File.exist?(own)
    [copy, dotted].each { |folder| assert File.directory?(folder), folder }
  end

  def test_sweep_reads_no_session_log_through_a_symbolic_link
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    elsewhere = aged_file(File.join(@root, 'elsewhere.jsonl'), LONG_AGO, session_log('/work/someone/project'))
    aged_link(elsewhere, File.join(folder, 'linked.jsonl'))
    age_directories(folder)
    assert_match(/^Removed 1 folder and the run directory\.$/, cli_stdout(['sweep', run_directory, '--delete']))
    assert File.file?(elsewhere)
  end

  def test_sweep_leaves_a_folder_whose_hidden_session_log_ran_somewhere_else
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    aged_file(File.join(folder, '.hidden.jsonl'), LONG_AGO, session_log('/work/someone/project'))
    age_directories(folder)
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_includes out, "  leave   #{File.basename(folder)} (its session log ran in /work/someone/project)"
    assert File.directory?(folder)
  end

  def test_sweep_keeps_a_folder_with_files_and_no_session_log_that_matches_no_directory
    run_directory = new_run_directory
    folder = session_folder("#{run_directory}-copy/arm-a", 'id/tool-results/out.txt' => LONG_AGO)
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_includes out, "keep    #{File.basename(folder)} (it holds files and no session log, and no directory"
    assert File.directory?(folder)
  end

  def test_sweep_removes_the_folder_of_a_run_that_saved_no_session
    run_directory = new_run_directory
    FileUtils.mkdir_p(File.join(run_directory, 'arm-a'))
    age_directories(run_directory)
    folder = session_folder(File.join(run_directory, 'arm-a'), 'id/tool-results/out.txt' => LONG_AGO)
    assert_match(/^Removed 1 folder and the run directory\.$/, cli_stdout(['sweep', run_directory, '--delete']))
    refute File.exist?(folder)
  end

  def test_sweep_keeps_a_folder_whose_session_log_does_not_say_where_it_ran
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'), 'notes.txt' => LONG_AGO)
    aged_file(File.join(folder, 'session.jsonl'), LONG_AGO, "not json\n{}\n")
    age_directories(folder)
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_includes out, "keep    #{File.basename(folder)} (a session log in it does not say where it ran)"
    assert File.directory?(folder)
  end

  def test_sweep_resolves_a_symlinked_path_to_the_run_directory
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    link = File.join(@root, 'link')
    File.symlink(run_directory, link)
    cli_stdout(['sweep', link, '--delete'])
    refute File.exist?(folder)
    refute File.exist?(run_directory)
  end

  def test_sweep_refuses_a_directory_new_did_not_make
    unmarked = File.join(@tmp, 'dry-run-by-hand')
    folder = session_folder(File.join(unmarked, 'arm-a'))
    FileUtils.mkdir_p(unmarked)
    [nil, "Made by hand.\n"].each do |marker_text|
      File.write(File.join(unmarked, DryRunCleanup::MARKER), marker_text) if marker_text
      result = abort_result(['sweep', unmarked, '--delete'])
      assert_equal 1, result.status
      assert_match(/`dry-run-cleanup new` did not make it\. Nothing was removed\./, result.message)
    end
    assert File.directory?(folder)
    assert File.directory?(unmarked)
  end

  def test_sweep_refuses_a_directory_not_named_as_new_names_them
    run_directory = new_run_directory
    renamed = File.join(@tmp, 'project')
    File.rename(run_directory, renamed)
    File.write(File.join(renamed, DryRunCleanup::MARKER), DryRunCleanup.marker_text(renamed, @config))
    age_directories(renamed)
    assert_match(/is not named dry-run-.*did not make it\. Nothing was removed\./m,
                 abort_message(['sweep', renamed, '--delete']))
    assert File.directory?(renamed)
  end

  def test_sweep_refuses_a_marker_with_bytes_that_are_not_text
    run_directory = new_run_directory
    File.binwrite(File.join(run_directory, DryRunCleanup::MARKER), "run directory: \xFF\n")
    assert_match(/did not make it/, abort_message(['sweep', run_directory, '--delete']))
  end

  def test_sweep_refuses_a_marker_that_is_not_a_regular_file
    run_directory = new_run_directory
    by_link = File.join(@tmp, 'dry-run-by-link')
    by_directory = File.join(@tmp, 'dry-run-by-directory')
    FileUtils.mkdir_p([by_link, File.join(by_directory, DryRunCleanup::MARKER)])
    File.symlink(File.join(run_directory, DryRunCleanup::MARKER), File.join(by_link, DryRunCleanup::MARKER))
    [by_link, by_directory].each do |directory|
      assert_match(/did not make it/, abort_message(['sweep', directory, '--delete']))
      assert File.directory?(directory)
    end
  end

  def test_sweep_refuses_a_run_directory_that_was_copied_or_moved
    run_directory = new_run_directory
    copy = "#{run_directory}-copy"
    FileUtils.cp_r(run_directory, copy)
    folder = session_folder(File.join(copy, 'arm-a'))
    assert_match(/copied or moved.*Nothing was removed\./m, abort_message(['sweep', copy, '--delete']))
    assert File.directory?(folder)
    assert File.directory?(copy)
  end

  def test_sweep_refuses_a_run_directory_another_user_owns
    run_directory = new_run_directory
    error = assert_raises(DryRunCleanup::Error) do
      DryRunCleanup::Sweep.open(run_directory, @config, uid: Process.euid + 1)
    end
    assert_match(/belongs to another user\. Nothing was removed\./, error.message)
  end

  def test_sweep_refuses_a_config_directory_other_than_the_one_new_recorded
    run_directory = new_run_directory
    other = File.join(@root, 'other-config')
    FileUtils.mkdir_p(other)
    ENV['CLAUDE_CONFIG_DIR'] = other
    message = abort_message(['sweep', run_directory, '--delete'])
    assert_match(/CLAUDE_CONFIG_DIR=#{Regexp.escape(@config)}.*Nothing was removed\./m, message)
    assert File.directory?(run_directory)
  end

  def test_sweep_keeps_a_folder_whose_memory_directory_holds_a_file
    run_directory = new_run_directory
    plain = session_folder(File.join(run_directory, 'arm-a'))
    kept = [session_folder(File.join(run_directory, 'arm-b'), 'memory/MEMORY.md' => LONG_AGO),
            session_folder(File.join(run_directory, 'arm-c'), 'memory/.hidden' => LONG_AGO),
            session_folder(File.join(run_directory, 'arm-d'), 'memory/sub/n.md' => LONG_AGO)]
    out = cli_stdout(['sweep', run_directory, '--delete'])
    kept.each do |folder|
      assert_includes out, "keep    #{File.basename(folder)} (its memory directory holds a file)"
      assert File.directory?(folder)
    end
    assert_match(/^Removed 1 folder\. Kept 3 folders and the run directory\.$/, out)
    refute File.exist?(plain)
    assert File.directory?(run_directory)
  end

  def test_sweep_keeps_a_folder_whose_memory_entry_is_a_symbolic_link
    run_directory = new_run_directory
    folder = File.join(@projects, DryRunCleanup.folder_name(File.join(run_directory, 'arm-a')))
    FileUtils.mkdir_p(folder)
    aged_link(@config, File.join(folder, 'memory'))
    age_directories(folder)
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_includes out, "keep    #{File.basename(folder)} (its memory entry is not a directory)"
    assert File.directory?(folder)
  end

  def test_sweep_keeps_an_entry_that_is_a_symbolic_link_or_a_file_and_reads_nothing_behind_it
    run_directory = new_run_directory
    target = File.join(@root, 'elsewhere')
    aged_file(File.join(target, 'written-just-now'), JUST_NOW)
    aged_file(File.join(target, 'session.jsonl'), LONG_AGO, session_log('/work/someone/project'))
    link = File.join(@projects, DryRunCleanup.folder_name(File.join(run_directory, 'arm-a')))
    plain_file = File.join(@projects, DryRunCleanup.folder_name(File.join(run_directory, 'arm-b')))
    FileUtils.mkdir_p(@projects)
    File.symlink(target, link)
    aged_file(plain_file, LONG_AGO)
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_includes out, "keep    #{File.basename(link)} (it is a symbolic link)"
    assert_includes out, "keep    #{File.basename(plain_file)} (it is not a directory)"
    assert_match(/^Removed 0 folders\. Kept 2 folders and the run directory\.$/, out)
    assert File.symlink?(link)
    assert File.file?(plain_file)
    assert File.directory?(run_directory)
  end

  def test_sweep_refuses_while_a_session_log_was_written_recently
    run_directory = new_run_directory
    old = session_folder(File.join(run_directory, 'arm-a'))
    fresh = session_folder(File.join(run_directory, 'arm-b'), '.session.jsonl' => JUST_NOW)
    result = abort_result(['sweep', run_directory, '--delete'])
    assert_equal 1, result.status
    assert_match(/written in the last 10 minutes: #{File.basename(fresh)}\. .*Nothing was removed\./m, result.message)
    [old, fresh, run_directory].each { |path| assert File.directory?(path), path }
  end

  def test_a_recent_write_in_a_kept_folder_refuses_the_delete_too
    run_directory = new_run_directory
    old = session_folder(File.join(run_directory, 'arm-a'))
    session_folder(File.join(run_directory, 'arm-b'), 'memory/MEMORY.md' => JUST_NOW)
    assert_match(/written in the last 10 minutes/, abort_message(['sweep', run_directory, '--delete']))
    assert File.directory?(old)
  end

  def test_sweep_refuses_while_a_file_in_the_run_directory_was_written_recently
    run_directory = new_run_directory
    aged_file(File.join(run_directory, 'arm-a', '.git', 'index'), JUST_NOW)
    age_directories(run_directory)
    message = abort_message(['sweep', run_directory, '--delete'])
    assert_match(/written in the last 10 minutes: the run directory\./, message)
    assert File.directory?(run_directory)
  end

  def test_sweep_refuses_while_a_directory_in_the_run_directory_was_just_made
    run_directory = new_run_directory
    FileUtils.mkdir_p(File.join(run_directory, 'arm-a'))
    message = abort_message(['sweep', run_directory, '--delete'])
    assert_match(/written in the last 10 minutes: the run directory\./, message)
    assert File.directory?(run_directory)
  end

  def test_delete_reads_the_run_directory_again_before_removing_anything
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    sweep = DryRunCleanup::Sweep.open(run_directory, @config)
    aged_file(File.join(run_directory, 'arm-a', 'late.txt'), JUST_NOW)
    age_directories(run_directory)
    error = assert_raises(DryRunCleanup::Error) { sweep.delete(Time.now) }
    assert_match(/written in the last 10 minutes: the run directory\./, error.message)
    assert File.directory?(folder)
    assert File.directory?(run_directory)
  end

  def test_delete_reads_each_folder_again_before_removing_it
    run_directory = new_run_directory
    plain = session_folder(File.join(run_directory, 'arm-a'))
    late = session_folder(File.join(run_directory, 'arm-b'))
    listed = session_folder(File.join(run_directory, 'arm-c'), 'memory/MEMORY.md' => LONG_AGO)
    sweep = DryRunCleanup::Sweep.open(run_directory, @config)
    aged_file(File.join(late, 'memory', 'MEMORY.md'), LONG_AGO)
    result = sweep.delete(Time.now)
    assert_equal [File.basename(plain)], result.removed.map(&:name)
    assert_equal [File.basename(late), File.basename(listed)], result.kept.map(&:name)
    assert_equal({ File.basename(late) => 'its memory directory holds a file' }, result.kept_late)
    assert File.directory?(run_directory)
  end

  def test_delete_passes_over_a_folder_that_is_gone_by_then
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    sweep = DryRunCleanup::Sweep.open(run_directory, @config)
    FileUtils.remove_entry(folder)
    result = sweep.delete(Time.now)
    assert_empty result.kept
    assert_empty result.removed
    refute File.exist?(run_directory)
  end

  def test_delete_keeps_a_folder_written_after_the_listing
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    sweep = DryRunCleanup::Sweep.open(run_directory, @config)
    aged_file(File.join(folder, 'late.jsonl'), JUST_NOW, session_log(File.join(run_directory, 'arm-a')))
    result = sweep.delete(Time.now)
    assert_equal({ File.basename(folder) => DryRunCleanup::LATE_WRITE }, result.kept_late)
    assert File.directory?(folder)
  end

  def test_a_removal_the_filesystem_refuses_is_reported_without_a_backtrace
    run_directory = new_run_directory
    skip 'root ignores the mode this test relies on' if Process.euid.zero?
    folder = session_folder(File.join(run_directory, 'arm-a'), 'session.jsonl' => LONG_AGO,
                                                               'locked/tool-result.txt' => LONG_AGO)
    File.chmod(0o500, File.join(folder, 'locked'))
    result = abort_result(['sweep', run_directory, '--delete'])
    assert_equal 1, result.status
    assert_match(/\Adry-run-cleanup: Permission denied.*Run sweep again to see what is left\./m, result.message)
    assert_includes cli_stdout(['sweep', run_directory]), "  remove  #{File.basename(folder)}\n"
    File.chmod(0o700, File.join(folder, 'locked'))
    age_directories(folder)
    age_directories(run_directory)
    assert_match(/^Removed 1 folder and the run directory\.$/, cli_stdout(['sweep', run_directory, '--delete']))
  ensure
    File.chmod(0o700, File.join(folder, 'locked')) if folder && File.exist?(File.join(folder, 'locked'))
  end

  def test_a_run_directory_whose_removal_failed_can_be_swept_again
    run_directory = new_run_directory
    skip 'root ignores the mode this test relies on' if Process.euid.zero?
    locked = File.join(run_directory, 'arm-a', 'locked')
    aged_file(File.join(locked, 'out.txt'), LONG_AGO)
    age_directories(run_directory)
    File.chmod(0o500, locked)
    assert_match(/Run sweep again to see what is left\./, abort_message(['sweep', run_directory, '--delete']))
    assert_match(/^Session-history folders: 0$/, cli_stdout(['sweep', run_directory]))
  ensure
    File.chmod(0o700, locked) if locked
  end

  def test_a_run_directory_that_would_not_go_keeps_its_marker
    skip 'root ignores the mode this test relies on' if Process.euid.zero?
    run_directory = new_run_directory
    sweep = DryRunCleanup::Sweep.open(run_directory, @config)
    File.chmod(0o500, @tmp)
    assert_raises(DryRunCleanup::Error) { sweep.delete(Time.now) }
    File.chmod(0o700, @tmp)
    assert_kind_of DryRunCleanup::Sweep, DryRunCleanup::Sweep.open(run_directory, @config)
  ensure
    File.chmod(0o700, @tmp)
  end

  def test_sweep_matches_a_config_directory_the_locale_cannot_decode
    ENV['CLAUDE_CONFIG_DIR'] = File.join(@root, "config-\u00e9")
    FileUtils.mkdir_p(ENV.fetch('CLAUDE_CONFIG_DIR'))
    run_directory = new_run_directory
    external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    assert_match(/^Session-history folders: 0$/, cli_stdout(['sweep', run_directory]))
  ensure
    Encoding.default_external = external if external
  end

  def test_the_config_directory_advice_is_quoted_for_a_shell
    ENV['CLAUDE_CONFIG_DIR'] = File.join(@root, 'my config')
    FileUtils.mkdir_p(ENV.fetch('CLAUDE_CONFIG_DIR'))
    run_directory = new_run_directory
    ENV['CLAUDE_CONFIG_DIR'] = @config
    assert_includes abort_message(['sweep', run_directory]), "CLAUDE_CONFIG_DIR=#{@root}/my\\ config."
  end

  def test_sweep_accepts_a_config_directory_made_after_new
    link = File.join(@root, 'root-link')
    File.symlink(@root, link)
    ENV['CLAUDE_CONFIG_DIR'] = File.join(link, 'later-config')
    run_directory = new_run_directory
    FileUtils.mkdir_p(File.join(link, 'later-config', 'projects'))
    assert_match(%r{^Looking in: #{Regexp.escape(@root)}/later-config/projects$}, cli_stdout(['sweep', run_directory]))
  end

  def test_sweep_delete_removes_the_run_directory_when_no_folder_matches
    run_directory = new_run_directory
    session_folder('/work/someone/project')
    out = cli_stdout(['sweep', run_directory, '--delete'])
    assert_match(/^Session-history folders: 0$/, out)
    assert_match(/^Removed 0 folders and the run directory\.$/, out)
    refute File.exist?(run_directory)
  end

  def test_a_projects_directory_that_cannot_be_read_is_reported_without_a_backtrace
    skip 'root ignores the mode this test relies on' if Process.euid.zero?
    run_directory = new_run_directory
    FileUtils.mkdir_p(@projects)
    File.chmod(0o000, @projects)
    message = abort_message(['sweep', run_directory])
    assert_match(/\Adry-run-cleanup: Permission denied/, message)
    refute_match(/stopped partway/, message)
  ensure
    File.chmod(0o700, @projects) if File.exist?(@projects)
  end

  def test_sweep_reads_a_missing_projects_directory_as_no_folders
    run_directory = new_run_directory
    assert_match(/^Session-history folders: 0$/, cli_stdout(['sweep', run_directory]))
  end

  def test_sweep_refuses_a_path_that_is_not_a_directory
    message = abort_message(['sweep', File.join(@root, 'absent')])
    assert_match(/not a directory.*the path `dry-run-cleanup new` printed/m, message)
  end

  def test_help_prints_usage
    [[], %w[help], %w[--help], %w[-h], %w[sweep --help], %w[sweep -h], %w[new --help]].each do |argv|
      assert_equal DryRunCleanup::USAGE, cli_stdout(argv), argv.inspect
    end
  end

  def test_an_unknown_command_is_refused
    assert_match(/unknown command: purge.*Usage/m, abort_message(%w[purge]))
  end

  def test_sweep_takes_exactly_one_run_directory
    assert_match(/sweep takes one run directory/, abort_message(%w[sweep]))
    assert_match(/sweep takes one run directory/, abort_message(%w[sweep a b]))
  end

  def test_new_takes_no_arguments
    assert_match(/new takes no arguments/, abort_message(%w[new extra]))
  end

  def test_sweep_refuses_any_option_but_delete_spelled_in_full
    run_directory = new_run_directory
    folder = session_folder(File.join(run_directory, 'arm-a'))
    %w[--force --d --del --version].each do |option|
      assert_match(/invalid option: #{option}.*Usage/m, abort_message(['sweep', run_directory, option]))
    end
    assert File.directory?(folder)
  end
end
