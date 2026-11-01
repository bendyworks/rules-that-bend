#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/open-items. The decisions (what changed, whether a
# review is due, where the file lives) are tested against the pure
# module; the commands run against a snapshot file in a throwaway state
# directory. Run: ruby test/open_items_test.rb

require_relative 'cli_test_case'
require 'date'
require 'fileutils'
require 'tmpdir'

load File.expand_path('../bin/open-items', __dir__)

class StatePathTest < Minitest::Test
  def test_says_so_when_there_is_no_home_directory
    error = assert_raises(OpenItems::Error) { OpenItems.state_path('acme/app', {}) }
    assert_equal 'neither XDG_STATE_HOME nor HOME is set', error.message
  end

  def test_uses_xdg_state_home
    assert_equal '/state/bendyworks/open-items/acme/app.tsv',
                 OpenItems.state_path('acme/app', { 'XDG_STATE_HOME' => '/state', 'HOME' => '/users-root/dev' })
  end

  def test_falls_back_to_the_home_directory
    assert_equal '/users-root/dev/.local/state/bendyworks/open-items/acme/app.tsv',
                 OpenItems.state_path('acme/app', { 'HOME' => '/users-root/dev' })
  end

  def test_ignores_an_empty_or_relative_xdg_state_home
    ['', 'relative/state'].each do |value|
      assert_equal '/users-root/dev/.local/state/bendyworks/open-items/acme/app.tsv',
                   OpenItems.state_path('acme/app', { 'XDG_STATE_HOME' => value, 'HOME' => '/users-root/dev' })
    end
  end

  def test_two_repositories_that_join_to_the_same_name_keep_separate_files
    env = { 'HOME' => '/users-root/dev' }
    refute_equal OpenItems.state_path('a-b/c', env), OpenItems.state_path('a/b-c', env)
  end
end

class ReviewDueTest < Minitest::Test
  TODAY = Date.new(2026, 10, 31)

  def row(date, reviewed: false)
    OpenItems::Row.new(date: date, prs: 1, prs_stale: 0, issues: 1, issues_stale: 0, reviewed: reviewed)
  end

  def test_due_with_no_reviewed_row
    assert OpenItems.review_due?([row('2026-10-30')], TODAY)
  end

  def test_not_due_six_days_after_a_review
    refute OpenItems.review_due?([row('2026-10-25', reviewed: true), row('2026-10-30')], TODAY)
  end

  def test_an_older_review_does_not_hide_a_recent_one
    refute OpenItems.review_due?([row('2026-01-01', reviewed: true), row('2026-10-30', reviewed: true)], TODAY)
  end

  def test_due_seven_days_after_a_review
    assert OpenItems.review_due?([row('2026-10-24', reviewed: true), row('2026-10-30')], TODAY)
  end
end

class ChangedTest < Minitest::Test
  def row(prs: 5, prs_stale: 1, issues: 9, issues_stale: 2)
    OpenItems::Row.new(date: '2026-10-30', prs: prs, prs_stale: prs_stale, issues: issues,
                       issues_stale: issues_stale, reviewed: false)
  end

  def test_a_first_snapshot_counts_as_a_change
    assert OpenItems.changed?([row])
  end

  def test_identical_counts_are_no_change
    refute OpenItems.changed?([row, row])
  end

  def test_each_count_can_be_the_change
    { prs: 6, prs_stale: 2, issues: 8, issues_stale: 3 }.each do |column, value|
      assert OpenItems.changed?([row, row(column => value)]), column.to_s
    end
  end

  def test_a_pass_that_could_not_read_the_tracker_is_no_change_in_issues
    refute OpenItems.changed?([row, row(issues: nil, issues_stale: nil)])
  end

  def test_the_first_issue_count_after_passes_with_none_is_a_change
    assert OpenItems.changed?([row(issues: nil, issues_stale: nil), row])
  end

  def test_each_count_compares_with_the_last_row_that_holds_it
    gap = row(issues: nil, issues_stale: nil)
    refute OpenItems.changed?([row(issues: 5), row(issues: 6), gap, row(issues: 6)])
    assert OpenItems.changed?([row(issues: 6), row(issues: 5), gap, row(issues: 6)])
  end
end

class OpenItemsCliTestCase < CliTestCase
  def setup
    @state_home = Dir.mktmpdir('open-items-test')
    ENV['XDG_STATE_HOME'] = @state_home
  end

  def teardown
    FileUtils.remove_entry(@state_home)
  end

  def extra_scrubbed_env_keys
    %w[XDG_STATE_HOME]
  end

  # A test that reached the real state directory would write counts into
  # the developer's own history.
  def guard_cli_invocation(_argv)
    return if @state_home && ENV['XDG_STATE_HOME'] == @state_home

    flunk 'XDG_STATE_HOME does not point at the test directory'
  end

  def dispatch_cli(argv)
    OpenItems::CLI.run(argv)
  end

  def today
    Date.today.iso8601
  end

  def snapshot_path
    File.join(@state_home, 'bendyworks/open-items/acme/app.tsv')
  end

  def plant(*rows)
    FileUtils.mkdir_p(File.dirname(snapshot_path))
    File.write(snapshot_path, ["date\tprs\tprs_stale\tissues\tissues_stale\treviewed", *rows].join("\n") + "\n")
  end

  def record(prs: 5, prs_stale: 1, issues: 9, issues_stale: 2)
    argv = %W[record --repo acme/app --prs #{prs} --prs-stale #{prs_stale}]
    argv += %W[--issues #{issues} --issues-stale #{issues_stale}] if issues
    cli_stdout(argv)
  end
end

class RecordTest < OpenItemsCliTestCase
  def test_first_snapshot_writes_the_file_and_says_so
    output = record
    assert_equal ["date\tprs\tprs_stale\tissues\tissues_stale\treviewed", "#{today}\t5\t1\t9\t2\t"],
                 File.read(snapshot_path).lines.map(&:chomp)
    assert_equal <<~OUTPUT, output
      pull requests: 5 (1 stale), first count
      issues: 9 (2 stale), first count
      changed: yes
      review: due
    OUTPUT
  end

  def test_reports_the_change_since_the_last_snapshot_and_the_first
    plant("2026-01-01\t8\t3\t7\t1\t", "2026-02-01\t6\t1\t9\t2\t")
    assert_equal <<~OUTPUT, record(prs: 5, prs_stale: 1, issues: 10, issues_stale: 2)
      pull requests: 5 (1 stale), -1 (0 stale) since 2026-02-01, -3 (-2 stale) since 2026-01-01
      issues: 10 (2 stale), +1 (0 stale) since 2026-02-01, +3 (+1 stale) since 2026-01-01
      changed: yes
      review: due
    OUTPUT
  end

  def test_says_no_change_and_still_appends_a_row
    plant("2026-02-01\t5\t1\t9\t2\t")
    output = record
    assert_includes output, "changed: no\n"
    assert_equal 3, File.read(snapshot_path).lines.size
  end

  def test_one_earlier_snapshot_is_reported_once
    plant("2026-02-01\t6\t1\t9\t2\t")
    assert_equal "pull requests: 5 (1 stale), -1 (0 stale) since 2026-02-01\n", record.lines.first
  end

  def test_keeps_the_history_private_to_the_developer
    record
    assert_equal 0o600, File.stat(snapshot_path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(snapshot_path)).mode & 0o777
  end

  def test_two_snapshots_alike_on_one_day_are_reported_once
    plant("2026-02-01\t6\t1\t9\t2\t", "2026-02-01\t6\t1\t9\t2\t")
    assert_equal "pull requests: 5 (1 stale), -1 (0 stale) since 2026-02-01\n", record.lines.first
  end

  def test_two_snapshots_on_one_day_report_one_change_for_that_day
    plant("2026-02-01\t7\t1\t9\t2\t", "2026-02-01\t6\t1\t9\t2\t")
    assert_equal "pull requests: 5 (1 stale), -1 (0 stale) since 2026-02-01\n", record.lines.first
  end

  def test_refuses_a_file_that_is_not_text
    FileUtils.mkdir_p(File.dirname(snapshot_path))
    File.binwrite(snapshot_path, "\xFF\xFE\n")
    assert_includes abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0]), 'not a snapshot file'
  end

  def test_review_is_not_due_after_a_recent_review
    plant("#{today}\t5\t1\t9\t2\tyes")
    assert_includes record, "review: not due\n"
  end

  def test_a_pass_with_no_issue_counts_reports_no_false_drop
    plant("2026-02-01\t5\t1\t9\t2\t")
    output = record(issues: nil)
    assert_includes output, "issues: not counted\n"
    assert_includes output, "changed: no\n"
    assert_equal "#{today}\t5\t1\t\t\t", File.read(snapshot_path).lines.last.chomp
  end

  def test_issue_counts_compare_past_a_pass_that_had_none
    plant("2026-02-01\t5\t1\t9\t2\t", "2026-02-02\t5\t1\t\t\t")
    assert_includes record(issues: 8), 'issues: 8 (2 stale), -1 (0 stale) since 2026-02-01'
  end

  def test_refuses_stale_above_the_total_and_writes_nothing
    assert_equal 'open-items: --prs-stale (6) is more than --prs (5)',
                 abort_message(%w[record --repo acme/app --prs 5 --prs-stale 6])
    assert_equal 'open-items: --issues-stale (6) is more than --issues (5)',
                 abort_message(%w[record --repo acme/app --prs 5 --prs-stale 0 --issues 5 --issues-stale 6])
    refute File.exist?(snapshot_path)
  end

  def test_refuses_a_count_that_is_not_a_whole_number
    assert_equal 'open-items: --prs must be a whole number, got "1.5"',
                 abort_message(%w[record --repo acme/app --prs 1.5 --prs-stale 0])
    assert_equal 'open-items: --issues must be a whole number, got "many"',
                 abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0 --issues many --issues-stale 0])
  end

  def test_refuses_a_value_that_looks_like_a_flag
    assert_equal 'open-items: invalid argument: --prs -1',
                 abort_message(%w[record --repo acme/app --prs -1 --prs-stale 0])
    assert_equal 'open-items: invalid argument: --repo --x/y',
                 abort_message(%w[record --repo --x/y --prs 1 --prs-stale 0])
  end

  def test_refuses_a_repeated_option
    assert_equal 'open-items: duplicate --prs',
                 abort_message(%w[record --repo acme/app --prs 1 --prs 2 --prs-stale 0])
  end

  def test_requires_the_repository_and_both_pull_request_counts
    [%w[--prs 1 --prs-stale 0], %w[--repo acme/app --prs-stale 0], %w[--repo acme/app --prs 1]].each do |args|
      assert_includes abort_message(['record', *args]), 'Usage: open-items record', args.inspect
    end
  end

  def test_refuses_an_unknown_option_and_a_missing_value
    assert_equal 'open-items: invalid option: --nope', abort_message(%w[record --nope])
    assert_equal 'open-items: missing argument: --repo', abort_message(%w[record --repo])
  end

  def test_says_what_failed_when_the_history_cannot_be_written
    FileUtils.mkdir_p(File.dirname(File.dirname(snapshot_path)))
    File.write(File.dirname(snapshot_path), 'a file where the directory goes')
    assert_includes abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0]), 'open-items: '
  end

  def test_refuses_one_issue_count_without_the_other
    assert_equal 'open-items: --issues and --issues-stale go together',
                 abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0 --issues 3])
  end

  def test_refuses_a_repository_that_is_not_owner_and_name
    ['app', '../app', 'acme/..', 'acme/app/extra'].each do |repo|
      assert_equal "open-items: --repo must be owner/name, got #{repo.inspect}",
                   abort_message(%W[record --repo #{repo} --prs 1 --prs-stale 0])
    end
  end

  def test_refuses_a_file_it_cannot_read_and_leaves_it_alone
    FileUtils.mkdir_p(File.dirname(snapshot_path))
    File.write(snapshot_path, "something else\n")
    assert_includes abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0]), 'not a snapshot file'
    assert_equal "something else\n", File.read(snapshot_path)
  end
end

class DamagedFileTest < OpenItemsCliTestCase
  def test_refuses_a_damaged_row_and_leaves_the_file_alone
    ["2026-13-45\t5\t1\t\t\t", "2026-02-01\tfive\t1\t\t\t", "2026-02-01\t5", "2026-02-01\t5\t1\t9\t\t",
     "2026-02-01\t5\t1\t9\t2\t\textra"].each do |line|
      plant(line)
      before = File.read(snapshot_path)
      [%w[record --repo acme/app --prs 1 --prs-stale 0], %w[reviewed --repo acme/app]].each do |argv|
        assert_includes abort_message(argv), 'not a snapshot file', line.inspect
        assert_equal before, File.read(snapshot_path), line.inspect
      end
    end
  end
end

class FileWithNoFinalNewlineTest < OpenItemsCliTestCase
  def test_keeps_rows_apart_when_the_file_has_no_final_newline
    plant("2026-02-01\t5\t1\t9\t2\t")
    File.write(snapshot_path, File.read(snapshot_path).chomp)
    2.times { record }
    assert_equal 4, File.readlines(snapshot_path).size
    assert_includes record, "changed: no\n"
  end
end

class FileWithABlankTailTest < OpenItemsCliTestCase
  def test_refuses_a_blank_tail_and_leaves_the_file_alone
    plant("2026-02-01\t5\t1\t9\t2\t")
    File.write(snapshot_path, "#{File.read(snapshot_path)}\n")
    before = File.read(snapshot_path)
    assert_includes abort_message(%w[record --repo acme/app --prs 1 --prs-stale 0]), 'not a snapshot file'
    assert_equal before, File.read(snapshot_path)
  end
end

class ReviewedTest < OpenItemsCliTestCase
  def test_stamps_the_newest_row_alone
    plant("2026-02-01\t5\t1\t\t\tyes", "2026-02-02\t4\t1\t9\t2\t")
    File.chmod(0o600, snapshot_path)
    assert_equal "reviewed: 2026-02-02\n", cli_stdout(%w[reviewed --repo acme/app])
    assert_equal ["2026-02-01\t5\t1\t\t\tyes", "2026-02-02\t4\t1\t9\t2\tyes"],
                 File.read(snapshot_path).lines.drop(1).map(&:chomp)
    assert_equal 0o600, File.stat(snapshot_path).mode & 0o777
  end

  def test_refuses_when_nothing_has_been_recorded
    assert_equal 'open-items: no snapshot for acme/app yet; run record first',
                 abort_message(%w[reviewed --repo acme/app])
  end
end

class UsageTest < OpenItemsCliTestCase
  def test_no_arguments_and_help_print_usage
    [[], ['help'], ['--help'], ['-h']].each do |argv|
      assert_includes cli_stdout(argv), 'open-items record', argv.inspect
    end
  end

  def test_refuses_an_unknown_subcommand
    assert_includes abort_message(%w[nonesuch]), 'unknown subcommand'
  end

  def test_refuses_a_stray_argument
    assert_includes abort_message(%w[reviewed --repo acme/app extra]), 'unexpected argument'
  end

  def test_requires_the_repository
    assert_equal 'Usage: open-items reviewed --repo OWNER/NAME', abort_message(%w[reviewed])
  end
end
