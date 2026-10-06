# frozen_string_literal: true

# Tests for bin/safe-to-leave, which reports what a finished story has
# left behind in a repository: uncommitted files, commits the remote does
# not have, stashes, and linked worktrees.
#
# Two halves, split the way the CLI is. The decisions are a function of
# gathered facts and are tested without a repository. The gathering is
# shelling out, and is tested against real throwaway repositories, since
# the ways it goes wrong are git's: a stash subject that names no
# branch, a remote that cannot be asked, an ignored file that must not
# count.

require_relative 'cli_test_case'
require_relative 'fixtures/leave_repo'

require 'fileutils'
require 'tmpdir'

# Driven in-process for the reasons test/stale_branches_test.rb gives
# beside its own load: coverage, capture_io, and version managers.
CLI_PATH = File.expand_path('../bin/safe-to-leave', __dir__)
load CLI_PATH

class WorkingTreeDecisionTest < Minitest::Test
  def test_no_entries_is_one_clean_line
    lines = SafeToLeave::Checks.working_tree([])

    assert_equal [%w[working-tree ok]], lines.map { |line| [line.check, line.status] }
  end

  def test_every_entry_counts_against_leaving_and_is_named
    lines = SafeToLeave::Checks.working_tree(['notes.md', '.claude/settings.json'])

    assert_equal ['AGAINST'], lines.map(&:status)
    assert_equal '2 uncommitted or untracked files: notes.md, .claude/settings.json', lines.first.detail
  end

  def test_one_entry_is_counted_in_the_singular
    lines = SafeToLeave::Checks.working_tree(['notes.md'])

    assert_equal '1 uncommitted or untracked file: notes.md', lines.first.detail
  end
end

class StashDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def stash(index, subject)
    SafeToLeave::Stash.new("stash@{#{index}}", subject)
  end

  def statuses(stashes, prefixes = PREFIXES)
    SafeToLeave::Checks.stashes(stashes, prefixes).map(&:status)
  end

  def test_no_stashes_is_one_clean_line
    assert_equal ['ok'], statuses([])
  end

  def test_a_stash_made_on_a_story_branch_counts
    lines = SafeToLeave::Checks.stashes([stash(0, 'WIP on abc-12-fix-export: 1a2b3c4 Start')], PREFIXES)

    assert_equal ['AGAINST'], lines.map(&:status)
    assert_equal 'stash@{0} (WIP on abc-12-fix-export: 1a2b3c4 Start)', lines.first.detail
  end

  # `git stash push -m` writes "On <branch>: <message>" where a bare
  # `git stash` writes "WIP on <branch>: <sha> <subject>".
  def test_a_named_stash_on_a_story_branch_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'On abc-12-fix-export: half a fix')])
  end

  def test_a_stash_from_another_branch_is_listed_and_does_not_count
    lines = SafeToLeave::Checks.stashes([stash(0, 'WIP on other-work: 1a2b3c4 Start')], PREFIXES)

    assert_equal ['listed'], lines.map(&:status)
    assert_equal 'not counted, from other work: stash@{0} (WIP on other-work: 1a2b3c4 Start)', lines.first.detail
  end

  def test_story_and_other_stashes_are_reported_on_separate_lines
    stashes = [stash(0, 'On abc-12-fix-export: half a fix'), stash(1, 'WIP on other-work: 1a2b3c4 Start')]

    assert_equal %w[AGAINST listed], statuses(stashes)
  end

  # A stash made with HEAD detached names no branch, and housekeeping
  # can leave HEAD detached. Nothing says whose it is, so it counts.
  def test_a_stash_that_names_no_branch_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'WIP on (no branch): 1a2b3c4 Start')])
  end

  def test_a_hand_written_subject_that_names_no_branch_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'something I saved')])
  end

  # `git stash list` can print a line that is no stash, such as a
  # signature check under log.showSignature. It carries no separator
  # and names no branch.
  def test_a_listing_line_with_no_subject_counts
    stray = SafeToLeave::Stash.parse('gpg: Signature made')

    assert_equal '', stray.subject
    assert_equal ['AGAINST'], statuses([stray])
  end

  # With no story branch named there is nothing to attribute a stash to.
  def test_with_no_story_prefix_every_stash_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'WIP on other-work: 1a2b3c4 Start')], [])
  end

  def test_a_branch_that_only_contains_the_prefix_is_not_a_story_branch
    assert_equal ['listed'], statuses([stash(0, 'WIP on my-abc-12-copy: 1a2b3c4 Start')])
  end

  # Cut at the slash, the first name would start with the prefix.
  def test_a_branch_name_holding_a_slash_is_read_whole
    assert_equal ['listed'], statuses([stash(0, 'On other/abc-12-fix: wip')])
    assert_equal ['AGAINST'], statuses([stash(0, 'On abc-12-fix/export: wip')])
  end
end

class UnpushedDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def lines(default_ahead: 0, detached: 0, branches: {}, prefixes: PREFIXES)
    SafeToLeave::Checks.unpushed(default: 'main', default_ahead: default_ahead, detached: detached,
                                 branches: branches, prefixes: prefixes)
  end

  def test_nothing_unpushed_is_one_clean_line
    assert_equal ['ok'], lines.map(&:status)
  end

  def test_the_default_branch_ahead_of_its_remote_counts
    result = lines(default_ahead: 2)

    assert_equal ['AGAINST'], result.map(&:status)
    assert_equal 'main is 2 commits ahead of the remote', result.first.detail
  end

  def test_a_story_branch_with_unpushed_commits_counts
    result = lines(branches: { 'abc-12-fix-export' => 1 })

    assert_equal ['AGAINST'], result.map(&:status)
    assert_equal 'abc-12-fix-export (1 commit)', result.first.detail
  end

  def test_the_default_branch_and_a_story_branch_share_one_line
    result = lines(default_ahead: 1, branches: { 'abc-12-fix-export' => 3 })

    assert_equal ['main is 1 commit ahead of the remote, abc-12-fix-export (3 commits)'], result.map(&:detail)
  end

  # Another story's unpushed work is that story's to report. Counting it
  # here would make every session on a machine with one long-lived local
  # branch unsafe to leave for good.
  def test_another_branch_with_unpushed_commits_is_listed_and_does_not_count
    result = lines(branches: { 'other-work' => 3 })

    assert_equal ['listed'], result.map(&:status)
    assert_equal 'not counted, on other branches: other-work (3 commits)', result.first.detail
  end

  # With no story branch named there is nothing to attribute a branch
  # to, as with a stash.
  def test_with_no_story_prefix_every_branch_with_unpushed_commits_counts
    result = lines(branches: { 'other-work' => 3 }, prefixes: [])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_equal 'other-work (3 commits)', result.first.detail
  end

  # Commits made with HEAD detached are on no branch, so no branch's
  # count includes them.
  def test_commits_on_a_detached_head_count
    result = lines(detached: 2)

    assert_equal ['AGAINST'], result.map(&:status)
    assert_equal 'HEAD is detached with 2 commits on no branch', result.first.detail
  end

  def test_a_branch_with_nothing_unpushed_is_not_mentioned
    assert_equal ['ok'], lines(branches: { 'other-work' => 0, 'abc-12-fix-export' => 0 }).map(&:status)
  end
end

class WorktreeDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def worktree(branch, changes, detached_commits = 0, reason = nil)
    SafeToLeave::Worktree.new('/tmp/elsewhere', branch, changes, detached_commits, reason)
  end

  def statuses(worktrees, prefixes = PREFIXES)
    SafeToLeave::Checks.worktrees(worktrees, prefixes).map(&:status)
  end

  def test_no_linked_worktrees_is_one_clean_line
    assert_equal ['ok'], statuses([])
  end

  def test_a_clean_linked_worktree_on_another_branch_does_not_count
    lines = SafeToLeave::Checks.worktrees([worktree('other-work', 0)], PREFIXES)

    assert_equal ['listed'], lines.map(&:status)
    assert_equal 'not counted, clean and on other work: /tmp/elsewhere', lines.first.detail
  end

  def test_a_linked_worktree_with_changes_counts
    assert_equal ['AGAINST'], statuses([worktree('other-work', 2)])
  end

  def test_a_linked_worktree_on_a_story_branch_counts
    assert_equal ['AGAINST'], statuses([worktree('abc-12-fix-export', 0)])
  end

  def test_with_no_story_prefix_a_clean_worktree_on_any_branch_counts
    assert_equal ['AGAINST'], statuses([worktree('other-work', 0)], [])
  end

  def test_a_detached_worktree_holding_commits_on_no_branch_counts
    lines = SafeToLeave::Checks.worktrees([worktree(nil, 0, 2)], PREFIXES)

    assert_equal ['AGAINST'], lines.map(&:status)
    assert_equal '/tmp/elsewhere (detached, 2 commits on no branch)', lines.first.detail
  end

  def test_a_clean_detached_worktree_holding_no_such_commit_does_not_count
    assert_equal ['listed'], statuses([worktree(nil, 0, 0)])
  end

  def test_a_counted_worktree_is_described_by_its_branch_and_its_changes
    described = lambda do |branch, changes|
      SafeToLeave::Checks.worktrees([worktree(branch, changes)], PREFIXES).first.detail
    end

    assert_equal '/tmp/elsewhere (on abc-12-fix-export)', described.call('abc-12-fix-export', 0)
    assert_equal '/tmp/elsewhere (on other-work, 2 uncommitted or untracked files)', described.call('other-work', 2)
    assert_equal '/tmp/elsewhere (detached, 1 uncommitted or untracked file)', described.call(nil, 1)
  end

  # A worktree whose directory is gone, or that git cannot read, has an
  # unknown state. Unknown is not clean.
  def test_a_linked_worktree_that_could_not_be_read_is_unchecked_with_the_reason
    lines = SafeToLeave::Checks.worktrees([worktree('other-work', nil, nil, 'its directory is missing')], PREFIXES)

    assert_equal ['UNCHECKED'], lines.map(&:status)
    assert_equal 'could not be read: /tmp/elsewhere (its directory is missing)', lines.first.detail
  end
end

# What both CLI suites share: the entry point, the refusal to report on
# anything outside the temporary directory, and one way to run a report.
class LeaveCliTestCase < CliTestCase
  STORY = 'abc-12-'
  Result = Struct.new(:status, :stdout, :stderr) do
    # check name => every status reported for it, in order.
    def statuses
      stdout.lines(chomp: true).filter_map { |line| line.match(/\A  (\S+)\s+(\S+): /) }
            .each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |match, hash| hash[match[2]] << match[1] }
    end

    def line_for(check)
      stdout.lines(chomp: true).grep(/\A  \S+\s+#{Regexp.escape(check)}: /).join("\n")
    end
  end

  # The repository lines are git's alone. A report that reached for the
  # code host here would be asking a question no flag gave it.
  def shimmed_commands
    ['gh']
  end

  def guard_cli_invocation(argv)
    index = argv.index('-C')
    target = index ? argv[index + 1] : Dir.pwd
    return if target && Fixtures::RepoBuilder.under_tmpdir?(File.expand_path(target))

    flunk "refusing to report on #{target.inspect}: outside #{Dir.tmpdir}"
  end

  def dispatch_cli(argv)
    SafeToLeave::CLI.run(argv)
  end

  # The exit status is 0 when the CLI returns without exiting.
  def run_report(argv)
    status = 0
    out, err = capture_io do
      run_cli(argv)
    rescue SystemExit => e
      status = e.status
    end
    Result.new(status, out, err)
  end
end

class LeaveArgumentTest < LeaveCliTestCase
  def in_empty_directory(&)
    Dir.mktmpdir('safe-to-leave-empty', &)
  end

  def test_an_unknown_flag_is_a_usage_error_with_its_own_exit_status
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--no-such-flag'])

      assert_equal 2, result.status
      assert_match(/--no-such-flag/, result.stderr)
    end
  end

  def test_a_stray_argument_is_a_usage_error
    in_empty_directory do |dir|
      result = run_report(['-C', dir, 'stray'])

      assert_equal 2, result.status
      assert_equal %(safe-to-leave: unexpected extra arguments: "stray"\n), result.stderr
    end
  end

  # OptionParser answers --version itself by exiting 1, which is this
  # command's answer that something counts against leaving.
  def test_version_is_refused_as_the_unknown_flag_it_is
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--version'])

      assert_equal 2, result.status
      assert_match(/invalid option: --version/, result.stderr)
    end
  end

  # OptionParser also answers two completion flags itself, by printing
  # a script or a list and exiting 0, which is this command's answer
  # that nothing counts against leaving.
  def test_a_completion_flag_is_refused
    in_empty_directory do |dir|
      script = run_report(['-C', dir, '--*-completion-zsh'])
      list = run_report(['-C', dir, '--*-completion-bash=--r'])

      assert_equal [2, 2], [script.status, list.status]
      assert_equal ['', ''], [script.stdout, list.stdout]
      assert_match(/invalid option: --\*-completion-zsh/, script.stderr)
    end
  end

  def test_an_abbreviated_flag_is_refused
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--story', 'abc-12-'])

      assert_equal 2, result.status
      assert_match(/invalid option: --story/, result.stderr)
    end
  end

  # Taking the last of two would report on one directory, or against
  # one remote, where the caller named two.
  def test_a_repeated_directory_or_remote_is_refused
    in_empty_directory do |dir|
      twice_dir = run_report(['-C', dir, '-C', dir])
      twice_remote = run_report(['-C', dir, '--remote', 'origin', '--remote', 'fork'])

      assert_equal [2, 2], [twice_dir.status, twice_remote.status]
      assert_match(/duplicate -C/, twice_dir.stderr)
      assert_match(/duplicate --remote/, twice_remote.stderr)
    end
  end

  # Without the refusal, `--story-branch --remote` would read --remote
  # as the prefix.
  def test_a_flag_where_a_value_belongs_is_a_usage_error
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--story-branch', '--remote'])

      assert_equal 2, result.status
      assert_match(/--story-branch/, result.stderr)
    end
  end

  def test_help_prints_usage_and_exits_clean
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--help'])

      assert_equal 0, result.status
      assert_match(/Usage: safe-to-leave/, result.stdout)
    end
  end

  def test_help_is_answered_beside_a_stray_argument
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--help', 'stray'])

      assert_equal 0, result.status
      assert_match(/Usage: safe-to-leave/, result.stdout)
    end
  end

  def test_a_directory_that_is_not_a_repository_is_an_error_not_a_verdict
    in_empty_directory do |dir|
      result = run_report(['-C', dir])

      assert_equal 2, result.status
      assert_match(/not a git repository/i, result.stderr)
    end
  end

  def test_an_error_names_a_directory_on_one_line
    in_empty_directory do |dir|
      result = run_report(['-C', File.join(dir, "gone\nsafe-to-leave: nothing counts against leaving")])

      assert_equal 2, result.status
      assert_equal 1, result.stderr.lines.length, result.stderr
    end
  end

  # git's own reason is carried, since "not a repository" is the wrong
  # thing to go and check when the directory is missing.
  def test_a_directory_that_does_not_exist_is_named_as_missing
    in_empty_directory do |dir|
      result = run_report(['-C', File.join(dir, 'gone')])

      assert_equal 2, result.status
      assert_match(/cannot report on .*gone: fatal: cannot change to/, result.stderr)
    end
  end

  # Under the C locale Ruby hands over an argument holding a non-ASCII
  # byte tagged as binary, which no UTF-8 pattern can be matched
  # against and no UTF-8 string joined to.
  def test_a_non_ascii_directory_named_under_an_ascii_locale_is_an_error_not_a_crash
    in_empty_directory do |dir|
      named = File.join(dir, 'café')
      FileUtils.mkdir_p(named)
      result = run_report(['-C', named.b])

      assert_equal 2, result.status
      assert_match(/cannot report on .*café: fatal: not a git repository/, result.stderr)
    end
  end

  def test_a_non_ascii_flag_under_an_ascii_locale_is_a_usage_error
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--café'.b])

      assert_equal 2, result.status
      assert_match(/invalid option: --café/, result.stderr)
    end
  end

  def test_git_missing_from_the_path_is_an_error_not_a_verdict
    in_empty_directory do |dir|
      result = with_path(dir) { run_report(['-C', dir]) }

      assert_equal 2, result.status
      assert_match(/could not run git/, result.stderr)
    end
  end

  # Exit status 1 means something counts against leaving, and Ruby exits
  # 1 on an exception nothing rescued.
  def test_an_unexpected_failure_is_an_error_not_a_verdict
    in_empty_directory do |dir|
      result = with_git_raising(ArgumentError.new('invalid byte sequence')) { run_report(['-C', dir]) }

      assert_equal 2, result.status
      assert_match(/ArgumentError: invalid byte sequence/, result.stderr)
      assert_empty result.stdout
    end
  end

  def with_git_raising(error)
    SafeToLeave::Git.define_singleton_method(:new) { |**| raise error }
    yield
  ensure
    SafeToLeave::Git.singleton_class.send(:remove_method, :new)
  end

  def with_path(path)
    saved = ENV.fetch('PATH')
    ENV['PATH'] = path
    yield
  ensure
    ENV['PATH'] = saved
  end
end

class LeaveReportTest < LeaveCliTestCase
  def with_repo
    Dir.mktmpdir('safe-to-leave') do |dir|
      yield Fixtures::LeaveRepo.new(File.join(dir, 'project')).build
    end
  end

  def with_repo_env(repo)
    saved = repo.env.keys.to_h { |key| [key, ENV[key]] }
    repo.env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def report(repo, *extra)
    report_on(repo, ['-C', repo.work, '--story-branch', STORY, *extra])
  end

  def report_on(repo, argv)
    with_repo_env(repo) { run_report(argv) }
  end

  def test_a_clean_pushed_repository_has_nothing_against_leaving
    with_repo do |repo|
      result = report(repo)

      assert_equal 0, result.status, result.stdout + result.stderr
      assert_equal({ 'working-tree' => ['ok'], 'unpushed' => ['ok'], 'stashes' => ['ok'], 'worktrees' => ['ok'] },
                   result.statuses)
      assert_match(/nothing counts against leaving/, result.stdout.lines.last)
    end
  end

  def test_an_untracked_file_counts_and_is_named
    with_repo do |repo|
      repo.write('draft.md', 'a reply nobody sent')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['working-tree']
      assert_includes result.line_for('working-tree'), 'draft.md'
      assert_match(/1 line counts against leaving/, result.stdout.lines.last)
    end
  end

  def test_a_modified_tracked_file_counts
    with_repo do |repo|
      repo.write('README', 'edited')

      assert_equal ['AGAINST'], report(repo).statuses['working-tree']
    end
  end

  def test_an_ignored_file_does_not_count
    with_repo do |repo|
      repo.write('.gitignore', 'tmp/')
      repo.git('add', '.gitignore')
      repo.git('commit', '-qm', 'Ignore tmp')
      repo.push('main')
      FileUtils.mkdir_p(File.join(repo.work, 'tmp'))
      repo.write('tmp/draft.md', 'local only')

      assert_equal ['ok'], report(repo).statuses['working-tree']
    end
  end

  # `status.showUntrackedFiles=no` hides untracked files from a plain
  # `git status`, and the developer may have set it.
  def test_an_untracked_file_counts_whatever_git_is_configured_to_show
    with_repo do |repo|
      repo.git('config', 'status.showUntrackedFiles', 'no')
      repo.write('draft.md', 'unsent')

      assert_equal ['AGAINST'], report(repo).statuses['working-tree']
    end
  end

  def test_a_changed_submodule_counts_whatever_git_is_configured_to_ignore
    with_repo do |repo|
      repo.git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', repo.origin, 'vendored')
      repo.git('commit', '-qm', 'Add a submodule')
      repo.push('main')
      repo.git('config', 'diff.ignoreSubmodules', 'all')
      File.write(File.join(repo.work, 'vendored', 'README'), "edited\n")

      assert_equal ['AGAINST'], report(repo).statuses['working-tree']
    end
  end

  # A tracked file whose timestamp changed and whose contents did not is
  # what makes `git status` rewrite the index to record the new time.
  def test_the_report_leaves_the_index_as_it_found_it
    with_repo do |repo|
      index = File.join(repo.work, '.git', 'index')
      an_hour_ago = Time.now - 3600
      File.utime(an_hour_ago, an_hour_ago, File.join(repo.work, 'README'))
      before = File.binread(index)
      report(repo)

      assert_equal before, File.binread(index)
    end
  end

  # git quotes a path that holds a space and escapes one that holds a
  # non-ASCII letter. The developer has to be able to find the file, so
  # both must come back as written.
  def test_a_path_with_a_space_is_named_as_written
    with_repo do |repo|
      repo.write('my draft.md', 'unsent')

      assert_equal '  AGAINST   working-tree: 1 uncommitted or untracked file: my draft.md',
                   report(repo).line_for('working-tree')
    end
  end

  def test_a_path_with_a_non_ascii_letter_is_named_as_written
    with_repo do |repo|
      repo.write('café.md', 'unsent')

      assert_equal '  AGAINST   working-tree: 1 uncommitted or untracked file: café.md',
                   report(repo).line_for('working-tree')
    end
  end

  # Ruby tags a child's output with the locale's encoding, which under
  # the C locale is US-ASCII, and a pattern match on a string holding
  # bytes outside its encoding raises.
  def test_a_non_ascii_path_is_reported_under_an_ascii_locale
    with_repo do |repo|
      repo.write('café.md', 'unsent')
      result = with_external_encoding(Encoding::US_ASCII) { report(repo) }

      assert_equal 1, result.status, result.stderr
      assert_includes result.stdout.dup.force_encoding(Encoding::UTF_8), 'working-tree: 1 uncommitted or untracked file: café.md'
    end
  end

  def test_a_non_ascii_stash_subject_is_reported_under_an_ascii_locale
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.stash_change('café fix')
      repo.checkout('main')
      result = with_external_encoding(Encoding::US_ASCII) { report(repo) }

      assert_equal 1, result.status, result.stderr
      assert_includes result.stdout.dup.force_encoding(Encoding::UTF_8), 'café fix'
    end
  end

  def with_external_encoding(encoding)
    saved = Encoding.default_external
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = saved
  end

  # A file name can hold a newline, and what follows it would print as
  # a line of the report.
  def test_a_file_name_cannot_add_a_line_to_the_report
    with_repo do |repo|
      repo.write("x\n  ok        stashes: none", 'unsent')
      result = report(repo)

      assert_equal 6, result.stdout.lines.length, result.stdout
      assert_includes result.line_for('working-tree'), 'x\n  ok        stashes: none'
    end
  end

  def test_a_terminal_escape_in_a_file_name_is_printed_as_text
    with_repo do |repo|
      repo.write("a\e[2Jb", 'unsent')
      result = report(repo)

      refute_includes result.stdout, "\e"
      assert_includes result.line_for('working-tree'), 'a\e[2Jb'
    end
  end

  # A staged rename is one entry, named by where the file is now.
  def test_a_renamed_file_is_one_entry_under_its_new_name
    with_repo do |repo|
      repo.git('mv', 'README', 'README.md')

      assert_equal '  AGAINST   working-tree: 1 uncommitted or untracked file: README.md',
                   report(repo).line_for('working-tree')
    end
  end

  def test_a_commit_on_the_default_branch_that_the_remote_lacks_counts
    with_repo do |repo|
      repo.commit_locally('notes', 'Add notes')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'main is 1 commit ahead of the remote'
    end
  end

  def test_a_story_branch_never_pushed_counts
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.checkout('main')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export (1 commit)'
    end
  end

  def test_a_story_branch_fully_pushed_does_not_count
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.push('abc-12-fix-export')
      repo.checkout('main')

      assert_equal ['ok'], report(repo).statuses['unpushed']
    end
  end

  def test_another_branch_with_unpushed_commits_is_listed_and_leaves_the_answer_alone
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.commit_locally('other', 'Other work')
      repo.checkout('main')
      result = report(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal ['listed'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'other-work'
    end
  end

  def test_branches_under_either_of_two_story_prefixes_count
    with_repo do |repo|
      repo.branch_from_main('abc-12-second-layer')
      repo.commit_locally('fix', 'Second layer')
      repo.branch_from_main('zzz-9-third-layer')
      repo.commit_locally('more', 'Third layer')
      repo.checkout('main')
      result = report(repo, '--story-branch', 'zzz-9-')

      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'abc-12-second-layer'
      assert_includes result.line_for('unpushed'), 'zzz-9-third-layer'
    end
  end

  # A remote-tracking ref records the last fetch, and a plain fetch
  # keeps the ref of a branch the remote has since deleted. The commits
  # it names are then on this machine alone.
  def test_a_story_branch_deleted_on_the_remote_counts_after_a_plain_fetch
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.push('abc-12-fix-export')
      repo.checkout('main')
      repo.git('branch', '-D', 'abc-12-fix-export', dir: repo.origin)
      repo.fetch
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export (1 commit)'
    end
  end

  # The remote's default branch was put back a commit after the last
  # fetch, so the tracking ref names a commit the remote no longer has.
  def test_a_default_branch_the_remote_has_moved_leaves_unpushed_unchecked
    with_repo do |repo|
      start = repo.git('rev-parse', 'main').strip
      repo.commit_locally('notes', 'Add notes')
      repo.push('main')
      repo.git('update-ref', 'refs/heads/main', start, dir: repo.origin)
      result = report(repo)

      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'fetch origin first'
    end
  end

  # A branch pushed to a second remote is still absent from the remote
  # the report measures against, and --remote chooses which one that is.
  def test_unpushed_is_measured_against_the_named_remote_alone
    with_repo do |repo|
      repo.add_remote('fork')
      repo.push('main', remote: 'fork')
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.push('abc-12-fix-export', remote: 'fork')
      repo.checkout('main')

      assert_equal ['AGAINST'], report(repo).statuses['unpushed']
      assert_equal ['ok'], report(repo, '--remote', 'fork').statuses['unpushed']
    end
  end

  # Housekeeping can leave HEAD detached, and a commit made there is on
  # no branch for the branch counts to find.
  def test_a_commit_on_a_detached_head_counts
    with_repo do |repo|
      repo.detach_head
      repo.commit_locally('notes', 'Add notes')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'HEAD is detached with 1 commit on no branch'
    end
  end

  def test_a_detached_head_at_a_pushed_commit_does_not_count
    with_repo do |repo|
      repo.detach_head

      assert_equal ['ok'], report(repo).statuses['unpushed']
    end
  end

  # git takes a URL or a path where a remote's name is expected, and
  # would contact whatever it was handed.
  def test_a_remote_that_is_not_configured_is_never_contacted
    with_repo do |repo|
      repo.add_remote('fork')
      repo.git('remote', 'remove', 'fork')
      result = report(repo, '--remote', File.join(repo.root, 'fork.git'))

      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'no such remote: '
      assert_includes result.line_for('unpushed'), '(configured: origin)'
    end
  end

  # An empty remote answers, and names a default branch it does not have.
  def test_a_remote_with_no_default_branch_leaves_unpushed_unchecked
    with_repo do |repo|
      repo.add_remote('fork')
      result = report(repo, '--remote', 'fork')

      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'fork names no default branch'
    end
  end

  def test_a_non_ascii_remote_named_under_an_ascii_locale_is_reported_whole
    with_repo do |repo|
      result = report(repo, '--remote', 'café'.b)

      assert_equal 6, result.stdout.lines.length, result.stdout + result.stderr
      assert_includes result.line_for('unpushed'), 'no such remote: café (configured: origin)'
    end
  end

  # The remote is asked which branch is its default. When it cannot be
  # asked, how far ahead the default branch is has no answer, and no
  # answer counts against leaving.
  def test_a_remote_that_cannot_be_asked_leaves_unpushed_unchecked
    with_repo do |repo|
      FileUtils.remove_entry(repo.origin)
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'git ls-remote failed: '
      assert_equal ['ok'], result.statuses['working-tree']
    end
  end

  # git's complaint about an unreachable remote runs to several lines,
  # each starting "fatal:" or blank. The report is one line per finding.
  def test_an_unchecked_line_carries_one_line_of_gits_complaint
    with_repo do |repo|
      FileUtils.remove_entry(repo.origin)
      result = report(repo)

      assert_equal 6, result.stdout.lines.length, result.stdout
      refute_match(/^fatal:/, result.stdout)
    end
  end

  # The default branch's remote-tracking ref is what "ahead" is measured
  # from. A repository never fetched has none, and that is not zero.
  def test_a_default_branch_never_fetched_leaves_unpushed_unchecked
    with_repo do |repo|
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'fetch origin first'
    end
  end

  # Deleting the local default branch is ordinary, and leaves nothing of
  # it to be ahead.
  def test_no_local_default_branch_is_not_an_error
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.git('branch', '-D', 'main')

      assert_equal ['ok'], report(repo).statuses['unpushed']
    end
  end

  def test_a_stash_made_on_a_story_branch_counts
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.stash_change('half a fix')
      repo.checkout('main')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['stashes']
      assert_includes result.line_for('stashes'), 'half a fix'
    end
  end

  def test_a_stash_from_other_work_is_listed_and_leaves_the_answer_alone
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.stash_change
      repo.checkout('main')
      result = report(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal ['listed'], result.statuses['stashes']
    end
  end

  # The subject git writes with HEAD detached, read from git itself.
  def test_a_stash_made_with_head_detached_counts
    with_repo do |repo|
      repo.detach_head
      repo.stash_change
      repo.checkout('main')
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['stashes']
      assert_includes result.line_for('stashes'), '(no branch)'
    end
  end

  def test_a_linked_worktree_with_changes_counts
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      File.write(File.join(path, 'scratch'), "left behind\n")
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['worktrees']
      assert_includes result.line_for('worktrees'), 'elsewhere (on other-work, 1 uncommitted or untracked file)'
    end
  end

  def test_a_clean_linked_worktree_on_other_work_leaves_the_answer_alone
    with_repo do |repo|
      repo.add_worktree('elsewhere', 'other-work')
      result = report(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal ['listed'], result.statuses['worktrees']
    end
  end

  def test_a_linked_worktree_on_a_story_branch_counts
    with_repo do |repo|
      repo.add_worktree('elsewhere', 'abc-12-fix-export')

      assert_equal ['AGAINST'], report(repo).statuses['worktrees']
    end
  end

  def test_a_detached_linked_worktree_holding_a_commit_on_no_branch_counts
    with_repo do |repo|
      path = repo.add_detached_worktree('elsewhere')
      repo.git('commit', '-q', '--allow-empty', '-m', 'Left on no branch', dir: path)
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['worktrees']
      assert_includes result.line_for('worktrees'), 'elsewhere (detached, 1 commit on no branch)'
    end
  end

  # A bare repository's own record names no checkout to read.
  def test_run_from_a_worktree_of_a_bare_repository_the_bare_record_is_skipped
    with_repo do |repo|
      bare = File.join(repo.root, 'bare.git')
      checkout = File.join(repo.root, 'from-bare')
      repo.git('clone', '-q', '--bare', repo.origin, bare, dir: repo.root)
      repo.git('worktree', 'add', '-q', checkout, 'main', dir: bare)
      result = report_on(repo, ['-C', checkout, '--story-branch', STORY])

      assert_equal ['ok'], result.statuses['worktrees'], result.stdout + result.stderr
    end
  end

  def test_a_linked_worktree_whose_directory_is_gone_is_unchecked
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      FileUtils.remove_entry(path)
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['worktrees']
      assert_includes result.line_for('worktrees'), 'elsewhere (its directory is missing)'
    end
  end

  # A worktree directory that has lost its .git file is a plain
  # directory, and git run inside it answers for whatever repository
  # encloses it, or fails when none does.
  def test_a_linked_worktree_that_is_no_longer_one_is_unchecked
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      FileUtils.rm(File.join(path, '.git'))

      assert_equal ['UNCHECKED'], report(repo).statuses['worktrees']
    end
  end

  def test_a_former_worktree_inside_the_repository_is_not_read_as_the_repository
    with_repo do |repo|
      path = repo.add_worktree('work/nested', 'other-work')
      FileUtils.rm(File.join(path, '.git'))
      result = report(repo)

      assert_equal ['UNCHECKED'], result.statuses['worktrees']
      assert_includes result.line_for('worktrees'), "nested (git finds #{File.realpath(repo.work)} there)"
    end
  end

  # git prints a worktree's path as it is, newline included, and a line
  # reading "bare" marks a record the report skips.
  def test_a_worktree_path_holding_a_newline_is_one_record
    with_repo do |repo|
      repo.add_worktree("else\nbare", 'abc-12-fix-export')

      assert_equal ['AGAINST'], report(repo).statuses['worktrees']
    end
  end

  # Run from a linked worktree, the main one is the other checkout, and
  # its uncommitted files are as much left behind as anyone's.
  def test_run_from_a_linked_worktree_the_main_one_is_the_other_checkout
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      repo.write('scratch', 'left in the main checkout')
      result = report_on(repo, ['-C', path, '--story-branch', STORY])

      assert_equal ['ok'], result.statuses['working-tree']
      assert_equal ['AGAINST'], result.statuses['worktrees']
    end
  end

  # `git -C` does not override an inherited GIT_DIR, so without the
  # command unsetting it the report would describe another repository.
  # The variable is set after the fixture's environment is applied,
  # since that environment unsets it too.
  def test_an_ambient_git_dir_does_not_redirect_the_report
    with_repo do |repo|
      repo.write('draft.md', 'unsent')
      Dir.mktmpdir('safe-to-leave-decoy') do |decoy|
        result = with_repo_env(repo) do
          ENV['GIT_DIR'] = File.join(decoy, '.git')
          run_report(['-C', repo.work, '--story-branch', STORY])
        ensure
          ENV.delete('GIT_DIR')
        end

        assert_equal 1, result.status, result.stdout + result.stderr
        assert_includes result.line_for('working-tree'), 'draft.md'
      end
    end
  end

  def test_with_no_story_branch_named_every_stash_counts
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.stash_change
      repo.checkout('main')
      result = report_on(repo, ['-C', repo.work])

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['stashes']
    end
  end

  def test_with_no_story_branch_named_every_branch_with_unpushed_commits_counts
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.commit_locally('other', 'Other work')
      result = report_on(repo, ['-C', repo.work])

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['unpushed']
    end
  end

  def test_two_lines_against_are_counted_in_the_last_line
    with_repo do |repo|
      repo.write('draft.md', 'unsent')
      repo.commit_locally('notes', 'Add notes')
      result = report(repo)

      assert_match(/2 lines count against leaving/, result.stdout.lines.last)
    end
  end
end
