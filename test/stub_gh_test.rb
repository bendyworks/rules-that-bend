#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the canned GitHub CLI under test/fixtures/stub_gh.rb.
# Run: ruby test/stub_gh_test.rb
#
# The stub is the only thing standing between the sweep's forge tests
# and a real network call, and every verdict those tests assert is
# reached from what it says. A stub that answered a question it does
# not know -- an empty array for a repository it has no data for, a
# null for a field a record does not carry -- would hand the sweep the
# exact evidence shape that means "no pull request", and the suite
# would grade a wrong verdict as right. So its refusals are tested as
# closely as its answers.
#
# It is run here as a program rather than loaded, which is how the
# sweep reaches it: its argument handling, its exit statuses, and the
# two logs it writes are the whole of its contract, and none of them
# are observable from a method call.

require_relative 'coverage_helper'
require_relative 'fixtures/stub_gh'

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class StubGhTest < Minitest::Test
  STUB = File.expand_path('fixtures/stub_gh.rb', __dir__)

  REPO = 'github.com/fixture/repo'
  UPSTREAM = 'github.com/fixture/upstream'

  MERGED = { 'number' => 101, 'state' => 'MERGED', 'headRefName' => 'a-landed',
             'headRefOid' => 'a' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => false }.freeze
  OPENED = { 'number' => 102, 'state' => 'OPEN', 'headRefName' => 'b-open',
             'headRefOid' => 'b' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => false }.freeze
  FORKED = { 'number' => 103, 'state' => 'MERGED', 'headRefName' => 'a-landed',
             'headRefOid' => 'c' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => true }.freeze

  DATA = { '@cwd' => [MERGED, OPENED, FORKED], REPO => [MERGED, OPENED, FORKED],
           UPSTREAM => [] }.freeze

  FIELDS = 'number,state,headRefName,headRefOid,baseRefName,isCrossRepository'

  def setup
    @dir = Dir.mktmpdir('stub-gh-test')
    @data_path = File.join(@dir, 'prs.json')
    File.write(@data_path, JSON.generate(DATA))
    @log = File.join(@dir, 'served.log')
    @refusals = File.join(@dir, 'refusals.log')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Result of one run: the parsed stdout where there is any, the raw
  # streams, the exit status, and whatever the two logs recorded.
  Run = Struct.new(:stdout, :stderr, :status, :log, :refusals) do
    def ok?
      status.zero?
    end

    def json
      JSON.parse(stdout)
    end
  end

  # Every switch the stub reads is named here, cleared unless a test
  # asks for it. Merging only what a test sets would leave the run at
  # the mercy of the developer's shell: an ambient STUB_GH_SHAPE=1 turns
  # most of this file red, and an ambient STUB_GH_FAIL would turn it red
  # in a way that reads like a broken stub.
  def stub_env(overrides = {})
    cleared = StubGh::ENV_KEYS.to_h { |key| [key, nil] }
    cleared.merge('STUB_GH_PRS' => @data_path,
                  'CLI_STUB_LOG' => @log,
                  'CLI_STUB_REFUSALS' => @refusals)
           .merge(overrides)
  end

  def run_stub(*argv, env: {})
    out, err, status = Open3.capture3(stub_env(env), STUB, *argv)
    Run.new(out, err, status.exitstatus, read_log(@log), read_log(@refusals))
  end

  def read_log(path)
    File.exist?(path) ? File.readlines(path).map(&:chomp) : []
  end

  def list(*argv, env: {})
    run_stub('pr', 'list', '--repo', REPO, '--json', FIELDS, '--state', 'all', *argv, env: env)
  end

  def test_a_matching_query_answers_with_the_records_for_that_branch
    result = list('--head', 'a-landed')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal [101, 103], result.json.map { |record| record['number'] }
    assert_empty result.refusals
  end

  def test_head_matches_on_branch_name_alone_so_a_forks_request_comes_back_too
    forked = list('--head', 'a-landed').json.find { |record| record['number'] == 103 }

    assert forked, 'the cross-repository pull request must not be filtered out by --head'
    assert forked['isCrossRepository'], 'the sweep has to be able to see that it came from a fork'
  end

  def test_a_query_matching_nothing_is_an_empty_array_and_a_clean_exit
    result = list('--head', 'never-existed')

    assert result.ok?, "a no-match must not be a failure: #{result.stderr}"
    assert_empty result.json
    assert_empty result.refusals, 'a no-match is an answer, not a refusal'
  end

  def test_state_defaults_to_open_the_way_the_real_client_does
    result = run_stub('pr', 'list', '--repo', REPO, '--json', FIELDS)

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal [102], result.json.map { |record| record['number'] },
                 'omitting --state must hide merged pull requests, as it does for real'
  end

  def test_limit_truncates_in_silence
    result = list('--limit', '1')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal 1, result.json.length
    assert_empty result.stderr, 'the real client says nothing when it truncates'
  end

  def test_only_the_requested_fields_come_back
    record = list('--head', 'b-open').json.fetch(0)

    assert_equal %w[number state], run_stub('pr', 'list', '--repo', REPO, '--state', 'all',
                                            '--head', 'b-open', '--json',
                                            'number,state').json.fetch(0).keys
    assert_equal FIELDS.split(','), record.keys
  end

  def test_a_configured_failure_is_a_message_and_a_nonzero_exit
    result = list('--head', 'a-landed', env: { 'STUB_GH_FAIL' => '1' })

    refute result.ok?, 'a configured failure must not exit 0'
    assert_match(/error connecting/, result.stderr)
    assert_empty result.stdout, 'a failure must not also print a result the sweep could parse'
    assert_empty result.refusals, 'a failure the sweep must degrade on is served, not refused'
  end

  # The other way an answer can be useless: a clean exit carrying
  # something that is not JSON. Served rather than refused, because the
  # sweep degrades on it, and reached by a parse error rather than by a
  # status -- so it exercises a different path than the failure above.
  # Every line carries the directory the call was made from, which is
  # the only place a caller's chdir is observable.
  def test_each_logged_invocation_names_the_directory_it_was_made_from
    list('--head', 'a-landed')

    assert_match(/ @#{Regexp.escape(Dir.pwd)}\z/, read_log(@log).first)
  end

  def test_a_configured_garble_is_a_clean_exit_carrying_something_that_is_not_json
    result = list('--head', 'a-landed', env: { 'STUB_GH_GARBAGE' => '1' })

    assert result.ok?, 'a garbled answer must still exit 0, or it is just the failure case'
    refute_empty result.stdout
    assert_raises(JSON::ParserError) { result.json }
    assert_empty result.refusals, 'a garble the sweep must degrade on is served, not refused'
  end

  # The switch that serves valid JSON of the wrong shape, which is the
  # one the parse rescue cannot catch.
  def test_a_configured_mis_shape_is_a_clean_exit_carrying_json_that_is_not_a_list
    result = list('--head', 'a-landed', env: { 'STUB_GH_SHAPE' => '1' })

    assert result.ok?, 'a mis-shaped answer must still exit 0, or it is just the failure case'
    refute_kind_of Array, result.json
    assert_empty result.refusals
  end

  def test_a_configured_mis_shape_can_also_be_a_list_of_the_wrong_things
    result = list('--head', 'a-landed', env: { 'STUB_GH_SHAPE' => '2' })

    assert result.ok?
    assert_equal ['not a pull request'], result.json
  end

  # gh honours --head, so this stub does too, and this switch is the
  # only way a caller's own filter gets a record to discard.
  def test_a_configured_mismatch_serves_a_record_about_another_branch
    result = list('--head', 'a-landed', env: { 'STUB_GH_MISMATCH' => '1' })

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_includes result.json.map { |r| r['headRefName'] }, 'a-branch-nobody-asked-about'
  end

  def test_every_invocation_is_logged_including_a_refused_one
    list('--head', 'a-landed')
    run_stub('pr', 'view', '1')

    assert_equal ["gh pr list --repo #{REPO} --json #{FIELDS} --state all --head a-landed",
                  'gh pr view 1'],
                 read_log(@log).map { |line| line.sub(/ @\S+\z/, '') }
  end

  def refusal_case(*argv, env: {})
    result = run_stub(*argv, env: env)

    refute result.ok?, "expected a refusal, got a clean exit: #{result.stdout}"
    refute_empty result.refusals, 'a refusal must be recorded where the seam reads it'
    result
  end

  def test_an_unserved_subcommand_is_refused
    result = refusal_case('pr', 'view', '1')

    assert_match(/unserved command: pr view/, result.refusals.join("\n"))
  end

  def test_an_unserved_flag_is_refused_rather_than_skipped
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--author', 'someone')

    assert_match(/unserved flag: --author/, result.refusals.join("\n"))
  end

  def test_a_flag_given_no_value_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--head')

    assert_match(/--head given no value/, result.refusals.join("\n"))
  end

  def test_a_listing_without_json_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO)

    assert_match(/without --json/, result.refusals.join("\n"))
  end

  # With no --repo the real client answers for the repository it
  # resolves from its own working directory, which is the resolution the
  # sweep leaves to it rather than deriving one of its own.
  def test_a_listing_without_repo_is_answered_from_the_working_directory
    result = run_stub('pr', 'list', '--json', FIELDS, '--state', 'all', '--head', 'a-landed')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal [101, 103], result.json.map { |record| record['number'] }
    assert_empty result.refusals
  end

  # The one case where a missing key is not the caller's mistake: data
  # that never described the working directory cannot answer for it, and
  # answering [] would read as "no pull request".
  def test_a_listing_without_repo_against_data_that_names_no_working_directory_is_refused
    File.write(@data_path, JSON.generate(UPSTREAM => []))
    result = refusal_case('pr', 'list', '--json', FIELDS)

    assert_match(/no data for @cwd/, result.refusals.join("\n"))
  end

  def test_a_repo_the_data_does_not_describe_is_refused_rather_than_answered_empty
    result = refusal_case('pr', 'list', '--repo', 'github.com/somebody/else',
                          '--json', FIELDS, '--state', 'all')

    assert_match(/no data for github\.com\/somebody\/else/, result.refusals.join("\n"))
  end

  def test_a_repo_the_data_describes_as_empty_is_answered_empty
    result = run_stub('pr', 'list', '--repo', UPSTREAM, '--json', FIELDS, '--state', 'all')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_empty result.json
    assert_empty result.refusals,
                 'a repository the data covers and that has no pull requests is an answer'
  end

  def test_a_field_no_record_carries_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--state', 'all',
                          '--json', 'number,mergedAtt')

    assert_match(/unknown --json field/, result.refusals.join("\n"))
  end

  def test_unset_data_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS,
                          env: { 'STUB_GH_PRS' => nil })

    assert_match(/STUB_GH_PRS is unset/, result.refusals.join("\n"))
  end

  def test_a_data_path_naming_no_file_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS,
                          env: { 'STUB_GH_PRS' => File.join(@dir, 'absent.json') })

    assert_match(/names no such file/, result.refusals.join("\n"))
  end

  def test_a_limit_that_is_not_a_positive_number_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--limit', '0')

    assert_match(/--limit is not a positive number/, result.refusals.join("\n"))
  end

  # Without a refusals log there is nowhere to report a refusal, and a
  # refusal reported nowhere is a test that passes on a question the
  # stub threw out. It exits non-zero saying so rather than serving.
  def test_a_run_with_nowhere_to_report_refusals_says_so_and_serves_nothing
    _out, err, status = Open3.capture3(stub_env('CLI_STUB_REFUSALS' => nil), STUB, 'pr', 'view')

    refute status.success?, 'a run that cannot report refusals must not exit 0'
    assert_match(/CLI_STUB_REFUSALS is unset/, err)
  end

  def test_a_run_with_nowhere_to_log_says_so_before_doing_anything
    _out, err, status = Open3.capture3(stub_env('CLI_STUB_LOG' => nil), STUB,
                                       'pr', 'list', '--repo', REPO, '--json', FIELDS)

    refute status.success?, 'a run whose calls go unrecorded must not exit 0'
    assert_match(/CLI_STUB_LOG is unset/, err)
    assert_empty read_log(@refusals), 'nothing ran far enough to refuse'
  end

  # Issues are served from their own data file, in the same shape and
  # under the same refusals as pull requests.
  STORY_ISSUE = { 'number' => 12, 'state' => 'OPEN', 'title' => 'Fix the export',
                  'body' => 'The export drops rows.' }.freeze
  CLOSED_ISSUE = { 'number' => 13, 'state' => 'CLOSED', 'title' => 'Done already',
                   'body' => 'Follows #12.' }.freeze

  def issue_env
    path = File.join(@dir, 'issues.json')
    File.write(path, JSON.generate('@cwd' => [STORY_ISSUE, CLOSED_ISSUE], REPO => []))
    { 'STUB_GH_ISSUES' => path }
  end

  def test_an_issue_listing_answers_with_the_open_issues_by_default
    result = run_stub('issue', 'list', '--json', 'number,title,body', env: issue_env)

    assert result.ok?, result.stderr
    assert_equal [{ 'number' => 12, 'title' => 'Fix the export', 'body' => 'The export drops rows.' }],
                 result.json
  end

  def test_an_issue_listing_of_every_state_includes_the_closed_issue
    result = run_stub('issue', 'list', '--json', 'number', '--state', 'all', env: issue_env)

    assert_equal [{ 'number' => 12 }, { 'number' => 13 }], result.json
  end

  def test_an_issue_listing_honours_its_limit
    result = run_stub('issue', 'list', '--json', 'number', '--state', 'all', '--limit', '1', env: issue_env)

    assert_equal [{ 'number' => 12 }], result.json
  end

  def test_an_issue_listing_for_a_named_repo_is_answered_from_that_repos_data
    result = run_stub('issue', 'list', '--repo', REPO, '--json', 'number', env: issue_env)

    assert_empty result.json
  end

  def test_an_issue_listing_with_a_pull_request_flag_is_refused
    result = refusal_case('issue', 'list', '--json', 'number', '--head', 'a-landed', env: issue_env)

    assert_match(/unserved flag for issue list: --head/, result.refusals.join("\n"))
  end

  def test_an_issue_listing_with_no_issue_data_is_refused
    result = refusal_case('issue', 'list', '--json', 'number')

    assert_match(/STUB_GH_ISSUES is unset/, result.refusals.join("\n"))
  end

  # Workflow runs, and the earlier attempts of one, which `run list`
  # does not show: it reports a rerun run by its latest attempt alone.
  EARLY_RUN = { 'databaseId' => 500, 'attempt' => 1, 'event' => 'push', 'headBranch' => 'main',
                'createdAt' => '2027-03-01T10:00:00Z' }.freeze
  LATE_RUN = { 'databaseId' => 501, 'attempt' => 2, 'event' => 'pull_request', 'headBranch' => 'other-work',
               'createdAt' => '2027-03-01T12:00:00Z' }.freeze

  def run_env
    runs = File.join(@dir, 'runs.json')
    File.write(runs, JSON.generate('@cwd' => [LATE_RUN, EARLY_RUN]))
    attempts = File.join(@dir, 'attempts.json')
    File.write(attempts, JSON.generate('@cwd' => { '501' => { '1' => { 'conclusion' => 'failure' } } }))
    { 'STUB_GH_RUNS' => runs, 'STUB_GH_ATTEMPTS' => attempts }
  end

  def test_a_run_listing_answers_with_every_run_when_no_time_is_given
    result = run_stub('run', 'list', '--json', 'databaseId', env: run_env)

    assert_equal [{ 'databaseId' => 501 }, { 'databaseId' => 500 }], result.json
  end

  def test_a_run_listing_created_since_a_time_leaves_out_the_earlier_runs
    result = run_stub('run', 'list', '--json', 'databaseId,attempt', '--created', '>=2027-03-01T11:00:00Z',
                      env: run_env)

    assert_equal [{ 'databaseId' => 501, 'attempt' => 2 }], result.json
  end

  # An offset form names the same instant as its UTC form, and the real
  # client accepts either.
  def test_a_created_time_with_an_offset_is_compared_as_an_instant
    result = run_stub('run', 'list', '--json', 'databaseId', '--created', '>=2027-03-01T06:00:00-05:00',
                      env: run_env)

    assert_equal [{ 'databaseId' => 501 }], result.json
  end

  def test_a_created_filter_in_a_form_this_stub_does_not_know_is_refused
    result = refusal_case('run', 'list', '--json', 'databaseId', '--created', '2027-03-01', env: run_env)

    assert_match(/unserved --created form/, result.refusals.join("\n"))
  end

  def test_a_run_listing_with_a_state_flag_is_refused
    result = refusal_case('run', 'list', '--json', 'databaseId', '--state', 'open', env: run_env)

    assert_match(/unserved flag for run list: --state/, result.refusals.join("\n"))
  end

  def test_a_run_listing_for_one_event_leaves_out_the_others
    result = run_stub('run', 'list', '--json', 'databaseId', '--event', 'push', env: run_env)

    assert_equal [{ 'databaseId' => 500 }], result.json
  end

  def test_a_run_listing_for_one_branch_leaves_out_the_others
    result = run_stub('run', 'list', '--json', 'databaseId', '--branch', 'other-work', env: run_env)

    assert_equal [{ 'databaseId' => 501 }], result.json
  end

  def test_one_attempt_of_a_run_is_answered_with_its_record
    result = run_stub('run', 'view', '501', '--attempt', '1', '--json', 'conclusion', env: run_env)

    assert result.ok?, result.stderr
    assert_equal({ 'conclusion' => 'failure' }, result.json)
  end

  def test_an_attempt_the_data_does_not_describe_is_refused
    result = refusal_case('run', 'view', '999', '--attempt', '1', '--json', 'conclusion', env: run_env)

    assert_match(/no data for run 999, attempt 1/, result.refusals.join("\n"))
  end

  # Without --attempt the real client answers for the latest attempt,
  # which the listing already gave.
  def test_a_run_view_naming_no_attempt_is_refused
    result = refusal_case('run', 'view', '501', '--json', 'conclusion', env: run_env)

    assert_match(/run view without --attempt/, result.refusals.join("\n"))
  end

  def test_a_run_view_naming_no_run_is_refused
    result = refusal_case('run', 'view', '--attempt', '1', '--json', 'conclusion', env: run_env)

    assert_match(/run view without a run id/, result.refusals.join("\n"))
  end

  # The run view tests of a caller need an answer that is not a record,
  # which the real client never gives for --json.
  def test_an_attempt_recorded_as_something_other_than_a_record_is_printed_as_it_is
    attempts = File.join(@dir, 'odd.json')
    File.write(attempts, JSON.generate('@cwd' => { '501' => { '1' => ['failure'] } }))
    result = run_stub('run', 'view', '501', '--attempt', '1', '--json', 'conclusion',
                      env: { 'STUB_GH_ATTEMPTS' => attempts })

    assert_equal ['failure'], result.json
  end

  def test_a_configured_failure_can_say_nothing_or_follow_its_message_with_advice
    silent = run_stub('pr', 'list', '--json', 'number', env: { 'STUB_GH_FAIL' => '2' })
    advised = run_stub('pr', 'list', '--json', 'number', env: { 'STUB_GH_FAIL' => '3' })

    refute silent.ok?
    assert_empty silent.stderr
    refute advised.ok?
    assert_equal 2, advised.stderr.lines.length
  end

  def test_a_call_that_arrives_with_a_tracing_variable_set_is_refused
    StubGh::TRACING_ENV_KEYS.each do |variable|
      result = refusal_case('pr', 'list', '--json', 'number', env: { variable => '1' })

      assert_match(/#{variable} reached me/, result.refusals.join("\n"))
    end
  end
end
