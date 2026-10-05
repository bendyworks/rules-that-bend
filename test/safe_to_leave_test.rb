# frozen_string_literal: true

# Tests for bin/safe-to-leave, which reports what a finished story has
# left behind in a repository: uncommitted files, commits no remote has,
# stashes, and linked worktrees.
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
    assert_includes lines.first.detail, 'notes.md'
    assert_includes lines.first.detail, '.claude/settings.json'
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
    assert_includes lines.first.detail, 'stash@{0}'
  end

  # `git stash push -m` writes "On <branch>: <message>" where a bare
  # `git stash` writes "WIP on <branch>: <sha> <subject>".
  def test_a_named_stash_on_a_story_branch_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'On abc-12-fix-export: half a fix')])
  end

  def test_a_stash_from_another_branch_is_listed_and_does_not_count
    lines = SafeToLeave::Checks.stashes([stash(0, 'WIP on other-work: 1a2b3c4 Start')], PREFIXES)

    assert_equal ['listed'], lines.map(&:status)
    assert_includes lines.first.detail, 'stash@{0}'
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

  # With no story branch named there is nothing to attribute a stash to.
  def test_with_no_story_prefix_every_stash_counts
    assert_equal ['AGAINST'], statuses([stash(0, 'WIP on other-work: 1a2b3c4 Start')], [])
  end

  def test_a_branch_that_only_contains_the_prefix_is_not_a_story_branch
    assert_equal ['listed'], statuses([stash(0, 'WIP on my-abc-12-copy: 1a2b3c4 Start')])
  end

  def test_a_branch_name_holding_a_colon_free_slash_is_read_whole
    assert_equal ['AGAINST'], statuses([stash(0, 'On abc-12-fix/export: wip')])
  end
end

class UnpushedDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def lines(default_ahead: 0, branches: {})
    SafeToLeave::Checks.unpushed(default: 'main', default_ahead: default_ahead,
                                 branches: branches, prefixes: PREFIXES)
  end

  def test_nothing_unpushed_is_one_clean_line
    assert_equal ['ok'], lines.map(&:status)
  end

  def test_the_default_branch_ahead_of_its_remote_counts
    result = lines(default_ahead: 2)

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, 'main'
    assert_includes result.first.detail, '2'
  end

  def test_a_story_branch_with_unpushed_commits_counts
    result = lines(branches: { 'abc-12-fix-export' => 1 })

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, 'abc-12-fix-export'
  end

  # Another story's unpushed work is that story's to report. Counting it
  # here would make every session on a machine with one long-lived local
  # branch unsafe to leave for good.
  def test_another_branch_with_unpushed_commits_is_listed_and_does_not_count
    result = lines(branches: { 'other-work' => 3 })

    assert_equal ['listed'], result.map(&:status)
    assert_includes result.first.detail, 'other-work'
  end

  def test_a_branch_with_nothing_unpushed_is_not_mentioned
    assert_equal ['ok'], lines(branches: { 'other-work' => 0, 'abc-12-fix-export' => 0 }).map(&:status)
  end
end

class WorktreeDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def worktree(branch, changes)
    SafeToLeave::Worktree.new('/tmp/elsewhere', branch, changes)
  end

  def statuses(worktrees)
    SafeToLeave::Checks.worktrees(worktrees, PREFIXES).map(&:status)
  end

  def test_no_linked_worktrees_is_one_clean_line
    assert_equal ['ok'], statuses([])
  end

  def test_a_clean_linked_worktree_on_another_branch_does_not_count
    assert_equal ['listed'], statuses([worktree('other-work', 0)])
  end

  def test_a_linked_worktree_with_changes_counts
    assert_equal ['AGAINST'], statuses([worktree('other-work', 2)])
  end

  def test_a_linked_worktree_on_a_story_branch_counts
    assert_equal ['AGAINST'], statuses([worktree('abc-12-fix-export', 0)])
  end

  # A worktree whose directory is gone, or that git cannot read, has an
  # unknown state. Unknown is not clean.
  def test_a_linked_worktree_that_could_not_be_read_is_unchecked
    assert_equal ['UNCHECKED'], statuses([worktree('other-work', nil)])
  end
end

class LeaveArgumentTest < CliTestCase
  def shimmed_commands
    ['gh']
  end

  def dispatch_cli(argv)
    SafeToLeave::CLI.run(argv)
  end

  def test_an_unknown_flag_is_a_usage_error_with_its_own_exit_status
    result = abort_result(['--no-such-flag'])

    assert_equal 2, result.status
    assert_match(/--no-such-flag/, result.stderr)
  end

  def test_a_stray_argument_is_a_usage_error
    result = abort_result(['stray'])

    assert_equal 2, result.status
    assert_match(/stray/, result.stderr)
  end

  def test_help_prints_usage_and_exits_clean
    result = abort_result(['--help'])

    assert_equal 0, result.status
    assert_match(/Usage: safe-to-leave/, result.stdout)
  end

  def test_a_directory_that_is_not_a_repository_is_an_error_not_a_verdict
    Dir.mktmpdir('safe-to-leave-empty') do |dir|
      result = abort_result(['-C', dir])

      assert_equal 2, result.status
      assert_match(/not a git repository/i, result.stderr)
    end
  end
end

class LeaveReportTest < CliTestCase
  STORY = 'abc-12-'
  Report = Struct.new(:status, :stdout, :stderr) do
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
    with_repo_env(repo) do
      status = 0
      out, err = capture_io do
        run_cli(['-C', repo.work, '--story-branch', STORY, *extra])
      rescue SystemExit => e
        status = e.status
      end
      Report.new(status, out, err)
    end
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

  # A path git would quote (a space, a non-ASCII letter) must come back
  # as the path, since the developer has to be able to find the file.
  def test_a_path_with_a_space_is_named_as_written
    with_repo do |repo|
      repo.write('my draft.md', 'unsent')

      assert_includes report(repo).line_for('working-tree'), 'my draft.md'
    end
  end

  def test_a_commit_on_the_default_branch_that_the_remote_lacks_counts
    with_repo do |repo|
      repo.commit_locally('notes', 'Add notes')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'main'
    end
  end

  def test_a_story_branch_never_pushed_counts
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.checkout('main')
      result = report(repo)

      assert_equal 1, result.status
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export'
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

  def test_a_story_branch_named_twice_is_matched_by_either_prefix
    with_repo do |repo|
      repo.branch_from_main('abc-12-second-layer')
      repo.commit_locally('fix', 'Second layer')
      repo.checkout('main')
      result = report(repo, '--story-branch', 'zzz-9-')

      assert_equal ['AGAINST'], result.statuses['unpushed']
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
      assert_equal ['ok'], result.statuses['working-tree']
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

  def test_a_linked_worktree_with_changes_counts
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      File.write(File.join(path, 'scratch'), "left behind\n")
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['worktrees']
      assert_includes result.line_for('worktrees'), 'elsewhere'
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

  def test_a_linked_worktree_whose_directory_is_gone_is_unchecked
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      FileUtils.remove_entry(path)
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['worktrees']
    end
  end

  # Run from a linked worktree, the main one is the other checkout, and
  # its uncommitted files are as much left behind as anyone's.
  def test_run_from_a_linked_worktree_the_main_one_is_the_other_checkout
    with_repo do |repo|
      path = repo.add_worktree('elsewhere', 'other-work')
      repo.write('scratch', 'left in the main checkout')
      result = with_repo_env(repo) do
        status = 0
        out, err = capture_io do
          run_cli(['-C', path, '--story-branch', STORY])
        rescue SystemExit => e
          status = e.status
        end
        Report.new(status, out, err)
      end

      assert_equal ['ok'], result.statuses['working-tree']
      assert_equal ['AGAINST'], result.statuses['worktrees']
    end
  end

  # `git -C` does not override an inherited GIT_DIR, so without the
  # command unsetting it the report would describe another repository.
  def test_an_ambient_git_dir_does_not_redirect_the_report
    with_repo do |repo|
      repo.write('draft.md', 'unsent')
      Dir.mktmpdir('safe-to-leave-decoy') do |decoy|
        result = with_repo_env(repo) do
          ENV['GIT_DIR'] = File.join(decoy, '.git')
          report(repo)
        ensure
          ENV.delete('GIT_DIR')
        end

        assert_includes result.line_for('working-tree'), 'draft.md'
      end
    end
  end

  def test_with_no_story_branch_named_every_stash_counts
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.stash_change
      repo.checkout('main')
      result = with_repo_env(repo) do
        status = 0
        out, err = capture_io do
          run_cli(['-C', repo.work])
        rescue SystemExit => e
          status = e.status
        end
        Report.new(status, out, err)
      end

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['stashes']
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
