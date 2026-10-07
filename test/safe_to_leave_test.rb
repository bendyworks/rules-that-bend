# frozen_string_literal: true

# Tests for bin/safe-to-leave, which reports what a finished story has
# left behind in a repository: uncommitted files, commits the remote does
# not have, stashes, and linked worktrees, and on GitHub: the story's
# open pull requests and issues, and the workflow runs since it merged.
#
# Two halves, split the way the CLI is. The decisions are a function of
# gathered facts and are tested without a repository. The gathering is
# shelling out, and is tested against real throwaway repositories, since
# the ways it goes wrong are git's: a stash subject that names no
# branch, a remote that cannot be asked, an ignored file that must not
# count. What GitHub says is served by a stand-in for gh, since those
# tests are about what the command asks and what it makes of each
# answer.

require_relative 'cli_test_case'
require_relative 'fixtures/leave_repo'
require_relative 'fixtures/forge_stub'

require 'fileutils'
require 'json'
require 'time'
require 'tmpdir'

# Driven in-process for the reasons test/stale_branches_test.rb gives
# beside its own load: coverage, capture_io, and version managers.
CLI_PATH = File.expand_path('../bin/safe-to-leave', __dir__)
load CLI_PATH

# Loaded for the test that the two commands' copied lists agree.
load File.expand_path('../bin/stale-branches', __dir__)

# bin/safe-to-leave and bin/stale-branches are single files that share
# no code, and each carries its own copy of two lists. A variable added
# to one has to reach the other.
class SiblingCommandTest < Minitest::Test
  def test_both_commands_unset_the_same_git_location_variables
    assert_equal StaleBranches::REDIRECTING_ENV_KEYS, SafeToLeave::Git::LOCATION_ENV_KEYS
  end

  def test_both_commands_unset_the_same_variables_for_gh
    assert_equal StaleBranches::FORGE_REDIRECTING_ENV_KEYS, SafeToLeave::Host::REDIRECTING_ENV_KEYS
  end

  def test_both_commands_refuse_a_flag_where_a_value_belongs_by_the_same_pattern
    assert_equal StaleBranches::VALUE_NOT_FLAG, SafeToLeave::CLI::VALUE_NOT_FLAG
  end
end

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

class InProgressDecisionTest < Minitest::Test
  def test_no_operation_is_one_clean_line
    lines = SafeToLeave::Checks.in_progress([])

    assert_equal [%w[in-progress ok none]], lines.map { |line| [line.check, line.status, line.detail] }
  end

  def test_each_operation_is_named
    lines = SafeToLeave::Checks.in_progress(['a rebase', 'a bisect'])

    assert_equal [['AGAINST', 'a rebase, a bisect']], lines.map { |line| [line.status, line.detail] }
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

  # Read from after its slash, `other/abc-12-fix` would start with the
  # prefix.
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

  # A detached worktree's files can be read when its commits cannot be
  # measured, and both facts are reported.
  def test_a_detached_worktree_whose_commits_were_not_measured_is_unchecked_and_keeps_its_changes
    unmeasured = SafeToLeave::Worktree.unmeasured('/tmp/elsewhere', nil, 1, 'the remote did not answer')
    lines = SafeToLeave::Checks.worktrees([unmeasured], PREFIXES)

    assert_equal %w[UNCHECKED AGAINST], lines.map(&:status)
    assert_equal 'commits on a detached HEAD not measured: /tmp/elsewhere (the remote did not answer)',
                 lines.first.detail
    assert_equal '/tmp/elsewhere (detached, 1 uncommitted or untracked file)', lines.last.detail
  end

  def test_a_clean_detached_worktree_whose_commits_were_not_measured_is_not_listed_as_clean
    unmeasured = SafeToLeave::Worktree.unmeasured('/tmp/elsewhere', nil, 0, 'the remote did not answer')

    assert_equal ['UNCHECKED'], statuses([unmeasured])
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
  # unknown state, which counts against leaving.
  def test_a_linked_worktree_that_could_not_be_read_is_unchecked_with_the_reason
    lines = SafeToLeave::Checks.worktrees([worktree('other-work', nil, nil, 'its directory is missing')], PREFIXES)

    assert_equal ['UNCHECKED'], lines.map(&:status)
    assert_equal 'could not be read: /tmp/elsewhere (its directory is missing)', lines.first.detail
  end
end

class PullRequestDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def pull_request(number, title, branch, closes: [])
    { 'number' => number, 'title' => title, 'headRefName' => branch,
      'closingIssuesReferences' => closes.map { |issue| { 'number' => issue } } }
  end

  def lines(pull_requests, prefixes: PREFIXES)
    SafeToLeave::Checks.pull_requests(pull_requests, prefixes: prefixes, issue: 12)
  end

  # A title is text anyone who can open a pull request wrote. In
  # quotes, with its own quotes escaped, it cannot pass for a second
  # entry in the list.
  def test_a_title_is_quoted_and_cannot_pass_for_another_entry
    result = lines([pull_request(45, 'x"), #232 ("Filed', 'abc-12-steady-export-test')])

    assert_equal 'open: #45 "x\\"), #232 (\\"Filed"', result.first.detail
  end

  def test_a_long_title_is_cut_and_says_by_how_much
    result = lines([pull_request(45, 'a' * 200, 'abc-12-steady-export-test')])

    assert_equal "open: #45 \"#{'a' * 80}\" (+120 characters)", result.first.detail
  end

  # "Every branch is the story's" is a rule for one machine's branches.
  # Applied to a shared list it would count every open pull request.
  def test_with_no_prefix_a_pull_request_counts_only_by_closing_the_issue
    others = [pull_request(45, 'Other work', 'anything'), pull_request(46, 'Another go', 'retry', closes: [12])]
    result = lines(others, prefixes: [])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, '#46'
    refute_includes result.first.detail, '#45'
  end

  def test_no_open_pull_requests_is_one_clean_line
    assert_equal ['ok'], lines([]).map(&:status)
  end

  def test_an_open_pull_request_from_a_story_branch_counts_and_is_named
    result = lines([pull_request(45, 'Steady the export test', 'abc-12-steady-export-test')])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, '#45'
    assert_includes result.first.detail, 'Steady the export test'
  end

  def test_an_open_pull_request_that_closes_the_story_issue_counts
    assert_equal ['AGAINST'], lines([pull_request(45, 'Another go', 'retry', closes: [12])]).map(&:status)
  end

  def test_an_open_pull_request_titled_with_the_story_key_counts
    assert_equal ['AGAINST'], lines([pull_request(45, 'ABC-12 Steady the Export Test', 'retry')]).map(&:status)
  end

  def test_a_longer_key_that_starts_the_same_is_another_story
    assert_equal ['ok'], lines([pull_request(45, 'ABC-123 Something Else', 'abc-123-something-else')]).map(&:status)
  end

  def test_an_open_pull_request_for_other_work_is_not_mentioned
    result = lines([pull_request(45, 'Speed up the 12 slowest reports', 'faster-reports', closes: [99])])

    assert_equal ['ok'], result.map(&:status)
  end

  # A bare number prefix, the form a project with no issue key uses,
  # says nothing a title could be matched on.
  def test_a_bare_number_prefix_matches_branches_and_never_titles
    result = lines([pull_request(45, '12 Angry Reports', 'reports'), pull_request(46, 'Other', '12-fix-export')],
                   prefixes: ['12-'])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, '#46'
    refute_includes result.first.detail, '#45'
  end
end

class IssueDecisionTest < Minitest::Test
  PREFIXES = ['abc-12-'].freeze

  def issue(number, title, body = '')
    { 'number' => number, 'title' => title, 'body' => body }
  end

  def lines(issues, plan_numbers: [])
    SafeToLeave::Checks.issues(issues, issue: 12, prefixes: PREFIXES, plan_numbers: plan_numbers)
  end

  def test_no_open_issue_naming_the_story_is_one_clean_line
    assert_equal ['ok'], lines([issue(30, 'Unrelated', 'Nothing to do with it.')]).map(&:status)
  end

  def test_the_story_issue_still_open_counts
    result = lines([issue(12, 'Fix the export')])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, '#12'
    assert_includes result.first.detail, 'still open'
  end

  def test_an_open_issue_whose_body_names_the_story_by_number_counts
    result = lines([issue(31, 'Export test fails one run in ten', 'Added in #12.')])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, '#31'
  end

  def test_an_open_issue_that_names_the_story_by_key_counts
    assert_equal ['AGAINST'], lines([issue(31, 'Follow-up to ABC-12', '')]).map(&:status)
  end

  def test_an_issue_the_plan_mentions_is_listed_and_does_not_count
    result = lines([issue(31, 'Export test fails one run in ten', 'Added in #12.')], plan_numbers: [31])

    assert_equal ['listed'], result.map(&:status)
    assert_includes result.first.detail, '#31'
  end

  def test_a_longer_number_that_starts_the_same_is_another_issue
    assert_equal ['ok'], lines([issue(31, 'Other', 'See #123 and ABC-123.')]).map(&:status)
  end

  def test_the_same_number_in_another_repository_is_another_issue
    assert_equal ['ok'], lines([issue(31, 'Other', 'See elsewhere/project#12.')]).map(&:status)
  end

  def test_an_issue_with_no_body_is_read_without_complaint
    assert_equal ['ok'], lines([{ 'number' => 31, 'title' => 'Other', 'body' => nil }]).map(&:status)
  end

  def test_with_no_story_issue_named_none_are_looked_for
    result = SafeToLeave::Checks.issues(nil, issue: nil, prefixes: PREFIXES, plan_numbers: [])

    assert_equal ['listed'], result.map(&:status)
    assert_match(/no --issue/, result.first.detail)
  end
end

class WorkflowRunDecisionTest < Minitest::Test
  def run_record(id, conclusions, holds_merge: true, event: 'push', branch: 'main', status: 'completed',
                 workflow: 'checks')
    SafeToLeave::Run.new(id: id, workflow: workflow, branch: branch, event: event, status: status,
                         conclusions: conclusions, holds_merge: holds_merge)
  end

  def lines(on_default, elsewhere = [], cut_short: false)
    SafeToLeave::Checks.workflow_runs(on_default, elsewhere, default: 'main', cut_short: cut_short)
  end

  def test_with_no_merge_commit_named_none_are_looked_for
    result = lines(nil)

    assert_equal ['listed'], result.map(&:status)
    assert_match(/no --merge-commit/, result.first.detail)
  end

  # Seconds after a merge the run has not been created yet, and "none
  # failed" would be an answer about nothing.
  def test_no_run_on_the_default_branch_since_the_merge_is_listed_not_clean
    result = lines([])

    assert_equal ['listed'], result.map(&:status)
    assert_match(/no run on "main"/, result.first.detail)
  end

  def test_a_passing_run_on_a_commit_containing_the_merge_is_clean
    assert_equal ['ok'], lines([run_record(500, ['success'])]).map(&:status)
  end

  def test_a_failed_run_on_a_commit_containing_the_merge_counts_and_is_named
    result = lines([run_record(500, ['failure'])])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_equal 'failed: "checks" run 500 on "main" (attempt 1 failure)', result.first.detail
  end

  # The run a listing shows as green, having failed first.
  def test_a_run_that_failed_and_was_rerun_to_green_still_counts
    result = lines([run_record(500, %w[failure success])])

    assert_equal ['AGAINST'], result.map(&:status)
    assert_includes result.first.detail, 'attempt 1'
  end

  def test_a_cancelled_or_timed_out_run_counts
    %w[cancelled timed_out startup_failure].each do |conclusion|
      assert_equal ['AGAINST'], lines([run_record(500, [conclusion])]).map(&:status), conclusion
    end
  end

  # A conclusion GitHub adds later is not one this command can call a
  # pass.
  def test_a_finished_attempt_with_any_other_conclusion_counts
    ['action_required', 'stale', 'no conclusion', 'one added later'].each do |conclusion|
      assert_equal ['AGAINST'], lines([run_record(500, [conclusion])]).map(&:status), conclusion
    end
  end

  def test_a_conclusion_is_printed_in_words
    assert_includes lines([run_record(500, ['timed_out'])]).first.detail, 'attempt 1 timed out'
  end

  def test_a_skipped_or_neutral_run_does_not_count
    %w[skipped neutral].each do |conclusion|
      assert_equal ['ok'], lines([run_record(500, [conclusion])]).map(&:status), conclusion
    end
  end

  def test_a_run_still_going_is_unchecked_and_named
    result = lines([run_record(500, [nil], status: 'in_progress')])

    assert_equal ['UNCHECKED'], result.map(&:status)
    assert_includes result.first.detail, '500'
  end

  # Whether that commit contains the merge is a question this clone
  # cannot answer, and the run may be the one that matters.
  def test_a_run_on_a_commit_this_clone_lacks_is_unchecked_and_says_to_fetch
    result = lines([run_record(500, ['failure'], holds_merge: nil)])

    assert_equal ['UNCHECKED'], result.map(&:status)
    assert_match(/fetch.*run 500/, result.first.detail)
  end

  def test_a_run_on_a_commit_from_before_the_merge_is_not_mentioned
    result = lines([run_record(500, ['failure'], holds_merge: false), run_record(501, ['success'])])

    assert_equal ['ok'], result.map(&:status)
    refute_includes result.first.detail, '500'
  end

  # A pull request's run tests that pull request's own changes on top
  # of the merged code, so its failure may be nobody's but its author's.
  # It is named for a reader to judge, and not counted.
  def test_a_failed_pull_request_run_is_listed_and_does_not_count
    result = lines([run_record(1, ['success'])],
                   [run_record(500, ['failure'], event: 'pull_request', branch: 'other-work')])

    assert_equal %w[ok listed], result.map(&:status)
    assert_equal 'not counted, failed elsewhere since the merge: ' \
                 '"checks" run 500 on "other-work", pull_request (attempt 1 failure)', result.last.detail
  end

  # A branch someone rebased onto the merge and pushed tests their
  # change as well.
  def test_a_failed_push_run_on_another_branch_is_listed_and_does_not_count
    result = lines([run_record(1, ['success'])], [run_record(500, ['failure'], branch: 'feature-x')])

    assert_equal %w[ok listed], result.map(&:status)
    assert_includes result.last.detail, 'feature-x'
  end

  def test_passing_runs_elsewhere_are_not_mentioned
    result = lines([run_record(1, ['success'])], [run_record(500, ['success'], event: 'pull_request')])

    assert_equal ['ok'], result.map(&:status)
  end

  def test_a_failure_that_counts_and_one_that_is_listed_are_separate_lines
    result = lines([run_record(500, ['failure'])], [run_record(501, ['failure'], event: 'pull_request')])

    assert_equal %w[AGAINST listed], result.map(&:status)
  end

  def test_a_listing_of_runs_elsewhere_that_was_cut_short_says_so
    result = lines([run_record(1, ['success'])], [], cut_short: true)

    assert_equal %w[ok listed], result.map(&:status)
    assert_match(/cut short/, result.last.detail)
  end

  # A workflow's name and a branch's are text a fork's pull request
  # sets.
  def test_a_workflow_name_is_quoted_and_cut
    result = lines([run_record(500, ['failure'], workflow: "#{'w' * 80}), run 7 on main")])

    assert_includes result.first.detail, "\"#{'w' * 80}\" (+16 characters) run 500"
  end

  def test_a_run_with_no_branch_says_so
    result = lines([run_record(1, ['success'])], [run_record(500, ['failure'], event: 'schedule', branch: nil)])

    assert_includes result.last.detail, 'run 500 on no branch, schedule'
  end
end

# An issue the plan mentions at all is one the developer already knows
# about, whatever words surround the number. A Shipment paragraph names
# its follow-ups in a sentence, not in a fixed phrase.
class PlanNumberTest < Minitest::Test
  def test_every_issue_number_the_plan_mentions_is_known
    plan = <<~PLAN
      - [x] **3.** Search for the same bug elsewhere (filed as #31)
      - [x] **4.** Tidy the fixtures (deferred to #32)

      Shipped via pull request #40. Follow-ups #33 and #34 were filed.
    PLAN

    assert_equal [31, 32, 40, 33, 34], SafeToLeave::Checks.plan_numbers(plan)
  end

  def test_a_number_in_another_repository_is_not_this_projects_issue
    assert_empty SafeToLeave::Checks.plan_numbers('See elsewhere/project#31 and color #12ab.')
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

  # The argument tests end before the report asks gh anything. One that
  # got as far as gh would be reaching for a developer's own client.
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

  # The exit status is 0 when the CLI returns without exiting. An
  # exception the CLI lets out is a failed assertion here, so a test
  # about one reads as failing and not as broken.
  def run_report(argv)
    status = 0
    escaped = nil
    out, err = capture_io do
      run_cli(argv)
    rescue SystemExit => e
      status = e.status
    rescue StandardError => e
      escaped = e
    end
    assert_nil escaped, "the command let #{escaped.class} out: #{escaped&.message}"
    Result.new(status, out, err)
  end

  def with_path(path)
    saved = ENV.fetch('PATH')
    ENV['PATH'] = path
    yield
  ensure
    ENV['PATH'] = saved
  end

  def with_external_encoding(encoding)
    saved = Encoding.default_external
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = saved
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

  # The likeliest wrong values, each answered with what the flag takes.
  def test_a_malformed_value_is_a_usage_error_that_says_what_the_flag_takes
    { ['--issue', '#12'] => /--issue takes an issue number, without the #/,
      ['--merge-commit', 'HEAD'] => /--merge-commit takes a commit SHA of 7 or more hex digits/,
      ['--repo', 'project'] => %r{--repo takes \[HOST/\]OWNER/NAME} }.each do |flags, message|
      in_empty_directory do |dir|
        result = run_report(['-C', dir, *flags])

        assert_equal 2, result.status, flags.inspect
        assert_match(message, result.stderr)
      end
    end
  end

  def test_a_story_flag_given_twice_is_a_usage_error
    in_empty_directory do |dir|
      result = run_report(['-C', dir, '--issue', '12', '--issue', '13'])

      assert_equal 2, result.status
      assert_match(/duplicate --issue/, result.stderr)
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
      assert_match(/invalid option: --\*-completion-bash=--r/, list.stderr)
    end
  end

  def test_a_timeout_that_is_no_positive_number_is_refused
    in_empty_directory do |dir|
      zero = run_report(['-C', dir, '--remote-timeout', '0'])
      word = run_report(['-C', dir, '--remote-timeout', 'soon'])

      assert_equal [2, 2], [zero.status, word.status]
      assert_match(/--remote-timeout/, zero.stderr)
      assert_match(/--remote-timeout/, word.stderr)
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

  # git names the directory in its own complaint, and Ruby tags that
  # complaint with the locale's encoding as it does git's other output.
  def test_gits_complaint_about_a_non_ascii_directory_is_carried_under_an_ascii_locale
    in_empty_directory do |dir|
      gone = File.join(dir, 'café', 'gone')
      result = with_external_encoding(Encoding::US_ASCII) { run_report(['-C', gone]) }

      assert_equal 2, result.status
      assert_match(%r{cannot report on .*café/gone: fatal: cannot change to}, result.stderr.dup.force_encoding(Encoding::UTF_8))
    end
  end

  # An exception's message can arrive tagged as binary too.
  def test_an_unexpected_failure_with_a_non_ascii_message_is_still_an_error
    in_empty_directory do |dir|
      result = with_git_raising(ArgumentError.new('café'.b)) { run_report(['-C', dir]) }

      assert_equal 2, result.status
      assert_match(/ArgumentError: café/, result.stderr)
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

end

class LeaveReportTest < LeaveCliTestCase
  # A stand-in answers for gh, so nothing here can reach a developer's
  # own authenticated client.
  def shimmed_commands
    []
  end

  def served_commands
    { 'gh' => Fixtures::ForgeStub.program }
  end

  def extra_scrubbed_env_keys
    StubGh::ENV_KEYS + SafeToLeave::Host::REDIRECTING_ENV_KEYS + SafeToLeave::Host::TRACING_ENV_KEYS
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

  # The data files are written beside the repository, never inside it:
  # an untracked file in the working tree is one of the things reported.
  # `attempts` maps a run's id to its earlier attempts by number.
  def serve(repo, pull_requests: [], issues: [], runs: [], attempts: {}, key: Fixtures::ForgeStub::CWD)
    { 'STUB_GH_PRS' => pull_requests, 'STUB_GH_ISSUES' => issues, 'STUB_GH_RUNS' => runs,
      'STUB_GH_ATTEMPTS' => attempts }.each do |variable, contents|
      path = File.join(repo.root, "#{variable.downcase}.json")
      File.write(path, JSON.generate(key => contents))
      ENV[variable] = path
    end
  end

  def report(repo, *extra, ambient: {})
    report_on(repo, ['-C', repo.work, '--story-branch', STORY, *extra], ambient: ambient)
  end

  def workflow_run(id, sha, conclusion: 'success', attempt: 1, event: 'push', branch: 'main', status: 'completed')
    { 'databaseId' => id, 'workflowName' => 'checks', 'status' => status, 'conclusion' => conclusion,
      'headSha' => sha, 'headBranch' => branch, 'event' => event, 'attempt' => attempt,
      'createdAt' => (Time.now.utc + 60).iso8601 }
  end

  def report_since_merge(repo, *extra)
    report(repo, '--merge-commit', repo.sha('origin/main'), *extra)
  end

  # `ambient` is set inside the fixture's environment, which unsets
  # the git variables it neutralizes and would otherwise undo it.
  def report_on(repo, argv, ambient: {})
    serve(repo) unless ENV['STUB_GH_PRS']
    with_repo_env(repo) do
      ambient.each { |key, value| ENV[key] = value }
      run_report(argv)
    end
  end

  CLEAN = { 'working-tree' => ['ok'], 'in-progress' => ['ok'], 'unpushed' => ['ok'], 'stashes' => ['ok'],
            'worktrees' => ['ok'], 'pull-requests' => ['ok'], 'issues' => ['listed'],
            'workflow-runs' => ['listed'] }.freeze

  def open_pull_request(number, title, branch, closes: [], state: 'OPEN')
    { 'number' => number, 'state' => state, 'title' => title, 'headRefName' => branch,
      'closingIssuesReferences' => closes.map { |issue| { 'number' => issue } } }
  end

  def open_issue(number, title, body = '')
    { 'number' => number, 'state' => 'OPEN', 'title' => title, 'body' => body }
  end

  def test_a_clean_pushed_repository_has_nothing_against_leaving
    with_repo do |repo|
      result = report(repo)

      assert_equal 0, result.status, result.stdout + result.stderr
      assert_equal CLEAN, result.statuses
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

  # A file marked skip-worktree or assume-unchanged is one `git status`
  # is told not to look at, edited or not.
  def test_an_edited_file_that_status_is_told_to_skip_counts
    with_repo do |repo|
      repo.git('update-index', '--skip-worktree', 'README')
      repo.write('README', 'edited')
      result = report(repo)

      assert_equal '  AGAINST   working-tree: 1 uncommitted or untracked file: README', result.line_for('working-tree')
    end
  end

  def test_an_edited_file_that_status_assumes_unchanged_counts
    with_repo do |repo|
      repo.git('update-index', '--assume-unchanged', 'README')
      repo.write('README', 'edited')

      assert_equal ['AGAINST'], report(repo).statuses['working-tree']
    end
  end

  def test_an_unedited_file_that_status_is_told_to_skip_does_not_count
    with_repo do |repo|
      repo.git('update-index', '--skip-worktree', 'README')

      assert_equal ['ok'], report(repo).statuses['working-tree']
    end
  end

  def test_a_deleted_file_that_status_is_told_to_skip_counts
    with_repo do |repo|
      repo.git('update-index', '--skip-worktree', 'README')
      FileUtils.rm(File.join(repo.work, 'README'))

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

  # A stash subject is whatever bytes it was given. One that is not
  # UTF-8 is reported with U+FFFD in its place.
  def test_a_stash_subject_that_is_not_utf8_is_reported
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.stash_change("caf\xE9".b)
      repo.checkout('main')
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['stashes'], result.stderr
      assert_includes result.line_for('stashes'), "caf\uFFFD"
    end
  end

  # The prefix is an argument, and a branch name is git's output.
  def test_a_non_ascii_story_prefix_under_an_ascii_locale_matches_its_branch
    with_repo do |repo|
      repo.branch_from_main('café-fix')
      repo.commit_locally('fix', 'Fix the export')
      repo.checkout('main')
      result = report_on(repo, ['-C', repo.work, '--story-branch', 'café-'.b])

      assert_equal ['AGAINST'], result.statuses['unpushed'], result.stderr
      assert_includes result.line_for('unpushed'), 'café-fix (1 commit)'
    end
  end

  def test_run_with_no_directory_named_the_working_directory_is_reported
    with_repo do |repo|
      repo.write('draft.md', 'unsent')
      result = Dir.chdir(repo.work) { report_on(repo, ['--story-branch', STORY]) }

      assert_equal 1, result.status, result.stderr
      assert_includes result.line_for('working-tree'), 'draft.md'
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

  # A file name can hold a newline, and what follows it would print as
  # a line of the report.
  def test_a_file_name_cannot_add_a_line_to_the_report
    with_repo do |repo|
      repo.write("x\n  ok        stashes: none", 'unsent')
      result = report(repo)

      assert_equal ['ok'], result.statuses['stashes'], result.stdout
      assert_includes result.line_for('working-tree'), 'x\n  ok        stashes: none'
    end
  end

  # U+2028 is a line end to some readers and is no control character.
  def test_a_line_separator_in_a_file_name_is_printed_as_text
    with_repo do |repo|
      repo.write("x\u2028  ok        stashes: none", 'unsent')
      result = report(repo)

      refute_includes result.stdout, "\u2028"
      assert_includes result.line_for('working-tree'), 'x\u2028  ok        stashes: none'
    end
  end

  # U+2029 is the paragraph separator, and U+202E reverses the text
  # after it.
  def test_a_paragraph_separator_or_a_text_reversal_in_a_file_name_is_printed_as_text
    with_repo do |repo|
      repo.write("p\u2029x", 'unsent')
      repo.write("r\u202Ex", 'unsent')
      result = report(repo)

      refute_match(/[\u2029\u202E]/, result.stdout)
      assert_includes result.line_for('working-tree'), 'p\u2029x'
      assert_includes result.line_for('working-tree'), 'r\u202Ex'
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

  # A bisect leaves the tree clean and HEAD wherever it was, so no other
  # check shows it.
  def test_a_bisect_in_progress_counts
    with_repo do |repo|
      repo.git('bisect', 'start')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['ok'], result.statuses['working-tree']
      assert_equal '  AGAINST   in-progress: a bisect', result.line_for('in-progress')
    end
  end

  def test_a_merge_stopped_before_its_commit_counts
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.commit_locally('other', 'Other work')
      repo.checkout('main')
      repo.git('merge', '-q', '--no-ff', '--no-commit', 'other-work')

      assert_equal '  AGAINST   in-progress: a merge', report(repo).line_for('in-progress')
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

  # Anyone merging to the default branch since the last fetch leaves its
  # tracking ref behind. The story's own branches are still measured.
  def test_a_default_branch_the_remote_has_moved_leaves_the_branch_counts_standing
    with_repo do |repo|
      start = repo.git('rev-parse', 'main').strip
      repo.commit_locally('notes', 'Add notes')
      repo.push('main')
      repo.git('update-ref', 'refs/heads/main', start, dir: repo.origin)
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.checkout('main')
      result = report(repo)

      assert_equal %w[UNCHECKED AGAINST], result.statuses['unpushed'], result.stdout
      assert_includes result.line_for('unpushed'), 'fetch origin first'
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export'
    end
  end

  # A replace ref makes git read one commit as another. Here the commit
  # the remote has is read as a child of the story branch's tip, which
  # puts the story's commit among those the remote has.
  def test_a_replace_ref_does_not_make_local_commits_read_as_pushed
    with_repo do |repo|
      pushed = repo.git('rev-parse', 'refs/remotes/origin/main').strip
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      child = repo.git('commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'A child of the tip').strip
      repo.git('replace', pushed, child)
      repo.checkout('main')
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['unpushed'], result.stdout
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export (1 commit)'
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

  # HEAD can name a ref that is no branch. A commit made there is on no
  # branch either, and `git symbolic-ref` still answers.
  def test_a_commit_on_a_head_that_names_no_branch_counts
    with_repo do |repo|
      repo.git('symbolic-ref', 'HEAD', 'refs/elsewhere/notes')
      repo.commit_locally('notes', 'Add notes')
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['unpushed'], result.stdout
      assert_includes result.line_for('unpushed'), 'HEAD is detached with 1 commit on no branch'
    end
  end

  # A detached HEAD's commits are measured against the local branches
  # and against the remote's, and either alone accounts for a commit.
  def test_a_detached_head_at_a_local_branch_tip_adds_no_count
    with_repo do |repo|
      repo.branch_from_main('other-work')
      repo.commit_locally('other', 'Other work')
      repo.detach_head
      result = report(repo)

      assert_equal ['listed'], result.statuses['unpushed'], result.stdout
      refute_includes result.stdout, 'HEAD is detached'
    end
  end

  def test_a_detached_head_at_a_commit_only_the_remote_branch_holds_adds_no_count
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.push('abc-12-fix-export')
      repo.detach_head
      repo.git('branch', '-D', 'abc-12-fix-export')

      assert_equal ['ok'], report(repo).statuses['unpushed']
    end
  end

  # A HEAD that names a ref with no commit yet holds no commits, and
  # the branches are still counted.
  def test_an_unborn_head_that_names_no_branch_leaves_the_branch_counts_standing
    with_repo do |repo|
      repo.branch_from_main('abc-12-fix-export')
      repo.commit_locally('fix', 'Fix the export')
      repo.git('symbolic-ref', 'HEAD', 'refs/elsewhere/unborn')
      result = report(repo)

      assert_equal ['AGAINST'], result.statuses['unpushed'], result.stdout
      assert_includes result.line_for('unpushed'), 'abc-12-fix-export (1 commit)'
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

      assert_equal 1, result.status, result.stdout + result.stderr
      assert_equal CLEAN.keys, result.statuses.keys
      assert_includes result.line_for('unpushed'), 'no such remote: café (configured: origin)'
    end
  end

  # A remote that accepts the connection and says nothing would hold an
  # unattended session for as long as it liked.
  def test_a_remote_that_does_not_answer_leaves_unpushed_unchecked
    with_repo do |repo|
      repo.git('config', 'remote.origin.uploadpack', 'sleep 30 #')
      started = Time.now
      result = report(repo, '--remote-timeout', '1')

      assert_operator Time.now - started, :<, 15
      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'origin did not answer within 1s'
      assert_equal ['ok'], result.statuses['working-tree']
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

      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      refute_includes result.line_for('unpushed'), '\n'
      refute_includes result.line_for('unpushed'), 'Could not read from remote repository'
    end
  end

  # The default branch's remote-tracking ref is what "ahead" is measured
  # from. A repository never fetched has none, which leaves the count
  # unknown.
  def test_a_default_branch_never_fetched_leaves_unpushed_unchecked
    with_repo do |repo|
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')
      result = report(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_includes result.line_for('unpushed'), 'refs/remotes/origin/main is absent; fetch origin first'
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

  # Only a detached worktree's commits need the remote's answer, so a
  # worktree on a branch is read without one.
  def test_a_linked_worktree_on_a_branch_is_read_when_the_remote_cannot_be_asked
    with_repo do |repo|
      repo.add_worktree('elsewhere', 'other-work')
      FileUtils.remove_entry(repo.origin)
      result = report(repo)

      assert_equal ['UNCHECKED'], result.statuses['unpushed']
      assert_equal ['listed'], result.statuses['worktrees']
    end
  end

  # `git worktree list` gives a branch field to any worktree whose HEAD
  # names a ref, and a ref outside refs/heads/ is no branch.
  def test_a_linked_worktree_whose_head_names_no_branch_is_described_as_detached
    with_repo do |repo|
      path = repo.add_detached_worktree('elsewhere')
      repo.git('symbolic-ref', 'HEAD', 'refs/elsewhere/notes', dir: path)
      repo.git('commit', '-q', '--allow-empty', '-m', 'Left on no branch', dir: path)

      assert_includes report(repo).line_for('worktrees'), 'elsewhere (detached, 1 commit on no branch)'
    end
  end

  def test_a_clean_linked_worktree_whose_head_names_no_branch_counts_as_a_detached_one_does
    with_repo do |repo|
      path = repo.add_detached_worktree('elsewhere')
      repo.git('update-ref', 'refs/elsewhere/notes', 'main')
      repo.git('symbolic-ref', 'HEAD', 'refs/elsewhere/notes', dir: path)
      result = report_on(repo, ['-C', repo.work])

      assert_equal ['listed'], result.statuses['worktrees'], result.stdout
    end
  end

  # A detached worktree's commits need the remote's answer. Its files
  # do not, and are still reported when the remote cannot be asked.
  def test_a_detached_linked_worktree_keeps_its_changes_when_the_remote_cannot_be_asked
    with_repo do |repo|
      path = repo.add_detached_worktree('elsewhere')
      File.write(File.join(path, 'scratch'), "left behind\n")
      FileUtils.remove_entry(repo.origin)
      result = report(repo)

      assert_equal %w[UNCHECKED AGAINST], result.statuses['worktrees'], result.stdout
      assert_includes result.line_for('worktrees'), 'commits on a detached HEAD not measured: '
      assert_includes result.line_for('worktrees'), 'elsewhere (detached, 1 uncommitted or untracked file)'
    end
  end

  # GIT_TRACE has git log each command it runs.
  def test_a_remote_that_cannot_be_asked_is_asked_once
    with_repo do |repo|
      repo.add_detached_worktree('elsewhere')
      repo.add_detached_worktree('another')
      FileUtils.remove_entry(repo.origin)
      trace = File.join(repo.root, 'trace.log')
      serve(repo)
      with_repo_env(repo) do
        ENV['GIT_TRACE'] = trace
        run_report(['-C', repo.work, '--story-branch', STORY])
      ensure
        ENV.delete('GIT_TRACE')
      end

      assert_equal 1, File.readlines(trace).grep(/built-in: git ls-remote/).length
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

  # Read with its last character dropped, the path names no directory,
  # and the report cannot be made.
  def test_a_directory_whose_name_ends_in_a_carriage_return_is_itself
    with_repo do |repo|
      path = repo.add_worktree("elsewhere\r", 'other-work')
      result = report_on(repo, ['-C', path, '--story-branch', STORY])

      assert_equal 0, result.status, result.stderr
      assert_includes result.stdout.lines.first, 'elsewhere\r'
      refute_includes result.line_for('worktrees'), 'elsewhere'
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
        result = report(repo, ambient: { 'GIT_DIR' => File.join(decoy, '.git') })

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

  def test_an_open_pull_request_from_a_story_branch_counts_and_is_named
    with_repo do |repo|
      serve(repo, pull_requests: [open_pull_request(45, 'Steady the export test', 'abc-12-steady-export-test')])
      result = report(repo, '--issue', '12')

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['pull-requests']
      assert_includes result.line_for('pull-requests'), '#45'
      assert_equal ['ok'], result.statuses['issues']
    end
  end

  def test_the_story_issue_still_open_counts
    with_repo do |repo|
      serve(repo, issues: [open_issue(12, 'Fix the export')])
      result = report(repo, '--issue', '12')

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['issues']
    end
  end

  def test_an_issue_the_plan_mentions_is_listed_and_leaves_the_answer_alone
    with_repo do |repo|
      plan = File.join(repo.root, 'plan.md')
      File.write(plan, "Shipped. A follow-up, #31, covers the flaky test.\n")
      serve(repo, issues: [open_issue(31, 'Export test fails one run in ten', 'Added in #12.')])
      result = report(repo, '--issue', '12', '--plan', plan)

      assert_equal 0, result.status, result.stdout
      assert_equal ['listed'], result.statuses['issues']
    end
  end

  def test_the_same_issue_counts_when_no_plan_mentions_it
    with_repo do |repo|
      serve(repo, issues: [open_issue(31, 'Export test fails one run in ten', 'Added in #12.')])
      result = report(repo, '--issue', '12')

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['issues']
    end
  end

  def test_a_plan_that_cannot_be_read_is_an_error_not_a_verdict
    with_repo do |repo|
      result = report(repo, '--issue', '12', '--plan', File.join(repo.root, 'absent.md'))

      assert_equal 2, result.status
      assert_match(/absent\.md/, result.stderr)
    end
  end

  def test_with_no_issue_named_issues_are_never_asked_for
    with_repo do |repo|
      report(repo)

      assert_empty served_invocations.grep(/issue list/)
      refute_empty served_invocations.grep(/pr list/)
    end
  end

  # gh resolves the project from its working directory, so the question
  # has to be asked from the repository reported on.
  def test_the_code_host_is_asked_from_the_repository_reported_on
    with_repo do |repo|
      report(repo, '--issue', '12')

      here = "@#{File.realpath(repo.work)}"

      refute_empty served_invocations
      assert(served_invocations.all? { |call| call.end_with?(here) }, served_invocations.inspect)
    end
  end

  def test_a_named_repo_is_the_one_asked
    with_repo do |repo|
      serve(repo, key: 'fixture/upstream',
                  pull_requests: [open_pull_request(45, 'Steady the export test', 'abc-12-steady-export-test')])
      result = report(repo, '--issue', '12', '--repo', 'fixture/upstream')

      assert_equal ['AGAINST'], result.statuses['pull-requests']
      assert(served_invocations.all? { |call| call.include?('--repo fixture/upstream') })
    end
  end

  # An unanswered question is not a clean answer: each code-host line
  # says it could not be checked, and the repository lines still report.
  def test_a_code_host_that_fails_leaves_every_one_of_its_lines_unchecked
    with_repo do |repo|
      ENV['STUB_GH_FAIL'] = '1'
      result = report_since_merge(repo, '--issue', '12')

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['pull-requests']
      assert_equal ['UNCHECKED'], result.statuses['issues']
      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_includes result.line_for('pull-requests'), 'error connecting'
      assert_equal ['ok'], result.statuses['working-tree']
    end
  end

  def test_an_answer_that_is_not_json_is_unchecked
    with_repo do |repo|
      ENV['STUB_GH_GARBAGE'] = '1'

      assert_equal ['UNCHECKED'], report(repo, '--issue', '12').statuses['pull-requests']
    end
  end

  def test_an_answer_of_the_wrong_shape_is_unchecked
    with_repo do |repo|
      %w[1 2].each do |shape|
        ENV['STUB_GH_SHAPE'] = shape

        assert_equal ['UNCHECKED'], report(repo, '--issue', '12').statuses['pull-requests'], "shape #{shape}"
      end
    end
  end

  def test_with_no_gh_installed_the_code_host_lines_are_unchecked
    with_repo do |repo|
      serve(repo)
      Dir.mktmpdir('only-git') do |dir|
        git = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, 'git') }
                 .find { |path| File.executable?(path) }
        File.symlink(git, File.join(dir, 'git'))
        result = with_path(dir) { report(repo, '--issue', '12') }

        assert_equal 1, result.status
        assert_equal ['UNCHECKED'], result.statuses['pull-requests']
        assert_equal ['ok'], result.statuses['working-tree']
      end
    end
  end

  # A listing that fills its limit may have been cut short, and the
  # pull request that matters may be the one cut.
  def test_a_listing_that_fills_its_limit_is_unchecked
    with_repo do |repo|
      crowd = Array.new(SafeToLeave::Host::LIMIT) do |index|
        open_pull_request(index + 100, 'Other work', "other-#{index}")
      end
      serve(repo, pull_requests: crowd)
      result = report(repo, '--issue', '12')

      assert_equal ['UNCHECKED'], result.statuses['pull-requests']
      assert_includes result.line_for('pull-requests'), SafeToLeave::Host::LIMIT.to_s
    end
  end

  # The stand-in refuses a call that arrives with one of these set: a
  # real gh would answer about another project, colour its JSON, or
  # write a trace of its requests to the stderr this command quotes.
  def test_a_variable_that_would_change_ghs_answer_does_not_reach_it
    (SafeToLeave::Host::REDIRECTING_ENV_KEYS + SafeToLeave::Host::TRACING_ENV_KEYS).each do |variable|
      with_repo do |repo|
        serve(repo)
        ENV[variable] = 'someone/elsewhere'

        assert_equal ['ok'], report(repo, '--issue', '12').statuses['pull-requests'], variable
      ensure
        ENV.delete(variable)
      end
    end
  end

  # Ruby tags what gh wrote with the locale's encoding, and under an
  # ASCII locale a title with an accent would not parse.
  def test_a_title_outside_ascii_is_reported_under_an_ascii_locale
    with_repo do |repo|
      serve(repo, pull_requests: [open_pull_request(45, 'Café export', 'abc-12-steady-export-test')])
      result = with_external_encoding(Encoding::US_ASCII) { report(repo, '--issue', '12') }

      assert_equal 1, result.status, result.stderr
      assert_includes result.line_for('pull-requests'), '#45 "Café export"'
    end
  end

  # gh follows its complaint with lines of advice. A report line is one
  # line.
  def test_a_failure_is_quoted_by_its_first_line
    with_repo do |repo|
      ENV['STUB_GH_FAIL'] = '3'
      line = report(repo, '--issue', '12').line_for('pull-requests')

      assert_includes line, 'gh pr list failed: error connecting to api.github.com'
      refute_includes line, 'githubstatus'
    end
  end

  def test_a_failure_that_says_nothing_is_reported_as_giving_no_reason
    with_repo do |repo|
      ENV['STUB_GH_FAIL'] = '2'

      assert_includes report(repo, '--issue', '12').line_for('pull-requests'), 'gh pr list failed: it gave no reason'
    end
  end

  # gh is given as long as the remote is. One that accepts the
  # connection and never answers would otherwise hold the report.
  def test_a_gh_that_does_not_answer_in_time_is_unchecked
    with_repo do |repo|
      ENV['STUB_GH_HANG'] = '1'
      result = report(repo, '--remote-timeout', '1')

      assert_equal ['UNCHECKED'], result.statuses['pull-requests']
      assert_includes result.line_for('pull-requests'), 'gh pr list did not answer within 1s'
      assert_equal ['ok'], result.statuses['unpushed']
    end
  end

  def test_a_merged_pull_request_and_a_closed_issue_do_not_count
    with_repo do |repo|
      serve(repo, pull_requests: [open_pull_request(45, 'Landed', 'abc-12-fix-export', state: 'MERGED')],
                  issues: [open_issue(12, 'Fix the export').merge('state' => 'CLOSED')])
      result = report(repo, '--issue', '12')

      assert_equal ['ok'], result.statuses['pull-requests']
      assert_equal ['ok'], result.statuses['issues']
    end
  end

  def test_with_no_story_branch_and_no_issue_pull_requests_are_not_asked_for
    with_repo do |repo|
      result = report_on(repo, ['-C', repo.work])

      assert_equal ['listed'], result.statuses['pull-requests']
      assert_includes result.line_for('pull-requests'), 'not looked for'
      assert_empty served_invocations
    end
  end

  # The last line is the one a reader takes the answer from, so it says
  # which questions were never asked.
  def test_the_closing_line_names_the_checks_not_looked_for
    with_repo do |repo|
      assert_equal "safe-to-leave: nothing counts against leaving; not looked for: issues, workflow-runs\n",
                   report(repo).stdout.lines.last
    end
  end

  def test_the_closing_line_names_nothing_when_every_check_was_made
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha)])

      assert_equal "safe-to-leave: nothing counts against leaving\n",
                   report_since_merge(repo, '--issue', '12').stdout.lines.last
    end
  end

  def test_a_plan_that_is_not_a_file_is_an_error_not_a_verdict
    with_repo do |repo|
      result = report(repo, '--issue', '12', '--plan', repo.root)

      assert_equal 2, result.status
      assert_match(/not a regular file/, result.stderr)
    end
  end

  def test_a_passing_run_on_the_merge_commit_is_clean
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha)])
      result = report_since_merge(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal ['ok'], result.statuses['workflow-runs']
    end
  end

  def test_a_failed_run_on_a_later_commit_of_the_default_branch_counts
    with_repo do |repo|
      merge = repo.sha
      repo.commit_locally('later', 'A later change')
      repo.push('main')
      serve(repo, runs: [workflow_run(501, repo.sha, conclusion: 'failure'), workflow_run(500, merge)])
      result = report(repo, '--merge-commit', merge)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), '501'
    end
  end

  # `gh run list` shows a rerun run by its latest attempt, so the
  # earlier ones have to be asked for one at a time.
  def test_a_run_rerun_to_green_counts_for_the_attempt_that_failed
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha, attempt: 2)],
                  attempts: { 500 => { 1 => { 'conclusion' => 'failure' } } })
      result = report_since_merge(repo)

      assert_equal 1, result.status
      assert_equal ['AGAINST'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'attempt 1'
    end
  end

  def test_with_a_named_repo_an_earlier_attempt_is_asked_of_that_repo
    with_repo do |repo|
      serve(repo, key: 'fixture/upstream', runs: [workflow_run(500, repo.sha, attempt: 2)],
                  attempts: { 500 => { 1 => { 'conclusion' => 'success' } } })
      result = report_since_merge(repo, '--repo', 'fixture/upstream')

      assert_equal ['ok'], result.statuses['workflow-runs']
    end
  end

  def test_an_earlier_attempt_that_cannot_be_read_leaves_workflow_runs_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha, attempt: 2)],
                  attempts: { 500 => { 1 => { 'conclusion' => 'success' } } })
      # The pull request listing and the run listing are answered; the
      # attempt lookup, the third call, is not.
      ENV['STUB_GH_FAIL_AFTER'] = '2'
      result = report_since_merge(repo)

      assert_equal ['ok'], result.statuses['pull-requests']
      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
    end
  end

  def test_a_run_still_going_is_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha, conclusion: '', status: 'in_progress')])
      result = report_since_merge(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
    end
  end

  def test_a_failed_pull_request_run_is_listed_and_leaves_the_answer_alone
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, '0' * 40, conclusion: 'failure', event: 'pull_request',
                                                     branch: 'other-work')])
      result = report_since_merge(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal %w[listed listed], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'other-work'
    end
  end

  def test_a_failed_run_on_a_commit_from_before_the_merge_is_not_mentioned
    with_repo do |repo|
      before = repo.sha
      repo.commit_locally('story', 'The story')
      repo.push('main')
      serve(repo, runs: [workflow_run(501, repo.sha), workflow_run(500, before, conclusion: 'failure')])
      result = report_since_merge(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal ['ok'], result.statuses['workflow-runs']
    end
  end

  # After the merge every branch someone rebases contains it, and a
  # push there tests their change too.
  def test_a_failed_push_run_on_another_branch_is_listed_and_leaves_the_answer_alone
    with_repo do |repo|
      serve(repo, runs: [workflow_run(501, repo.sha, conclusion: 'failure', branch: 'feature-x'),
                         workflow_run(500, repo.sha)])
      result = report_since_merge(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal %w[ok listed], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'feature-x'
    end
  end

  def test_a_run_on_a_default_branch_commit_this_clone_lacks_is_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, '0' * 40, conclusion: 'failure')])
      result = report_since_merge(repo)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'fetch'
    end
  end

  # What gh says a run's commit is goes to git as a revision.
  def test_a_run_whose_commit_is_not_a_sha_is_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, '--all')])
      result = report_since_merge(repo)

      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'headSha'
    end
  end

  def test_a_run_with_more_attempts_than_are_read_is_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha, attempt: SafeToLeave::Host::ATTEMPT_LIMIT + 2)])
      result = report_since_merge(repo)

      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'attempts'
      assert_empty served_invocations.grep(/run view/)
    end
  end

  def test_an_attempt_answered_with_something_that_is_not_a_record_is_unchecked
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha, attempt: 2)], attempts: { 500 => { 1 => ['failure'] } })
      result = report_since_merge(repo)

      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'not a record'
    end
  end

  # The runs that count are asked for by event and branch, so a busy
  # project's pull request runs cannot crowd them out of the listing.
  def test_the_runs_that_count_are_asked_for_by_event_and_branch
    with_repo do |repo|
      report_since_merge(repo)

      assert_equal 1, served_invocations.grep(/run list .*--event push --branch main/).length,
                   served_invocations.inspect
    end
  end

  def test_a_listing_of_other_runs_that_fills_its_limit_is_listed_not_unchecked
    with_repo do |repo|
      crowd = Array.new(SafeToLeave::Host::LIMIT) do |index|
        workflow_run(1000 + index, repo.sha, event: 'pull_request', branch: "other-#{index}")
      end
      serve(repo, runs: crowd + [workflow_run(500, repo.sha)])
      result = report_since_merge(repo)

      assert_equal 0, result.status, result.stdout
      assert_equal %w[ok listed], result.statuses['workflow-runs']
      assert_includes result.line_for('workflow-runs'), 'cut short'
    end
  end

  # A commit can be authored long before it lands. The runs to read
  # are the ones since it landed.
  def test_runs_are_asked_for_from_the_time_the_merge_commit_was_committed
    with_repo do |repo|
      repo.git('commit', '-q', '--allow-empty', '--date=2001-02-03T04:05:06+00:00', '-m', 'Authored long ago')
      repo.push('main')
      report_since_merge(repo)
      committed, authored = repo.git('show', '-s', '--format=%cI %aI', 'origin/main').split

      refute_equal committed, authored
      assert_equal 2, served_invocations.grep(/run list .*--created >=#{Regexp.escape(committed)}/).length,
                   served_invocations.inspect
    end
  end

  def test_a_merge_commit_named_by_a_short_sha_is_read_by_its_full_one
    with_repo do |repo|
      serve(repo, runs: [workflow_run(500, repo.sha)])
      result = report(repo, '--merge-commit', repo.sha('origin/main')[0, 7])

      assert_equal ['ok'], result.statuses['workflow-runs'], result.stdout
    end
  end

  def test_a_merge_commit_this_clone_lacks_leaves_workflow_runs_unchecked
    with_repo do |repo|
      result = report(repo, '--merge-commit', 'f' * 40)

      assert_equal 1, result.status
      assert_equal ['UNCHECKED'], result.statuses['workflow-runs']
      assert_empty served_invocations.grep(/run list/)
    end
  end

  def test_with_no_merge_commit_named_runs_are_never_asked_for
    with_repo do |repo|
      report(repo)

      assert_empty served_invocations.grep(/run list/)
    end
  end
end
