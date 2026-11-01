#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/open-items. The decisions (what changed, whether a
# review is due, where the file lives) are tested against the pure
# module. Run: ruby test/open_items_test.rb

require_relative 'cli_test_case'
require 'date'

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
