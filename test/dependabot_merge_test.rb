#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/dependabot-merge. A stand-in gh on PATH answers the
# read, records every call and merges nothing, so a refusal test shows
# whether the merge was asked for.
# Run: ruby test/dependabot_merge_test.rb

require_relative 'cli_test_case'
require 'json'

load File.expand_path('../bin/dependabot-merge', __dir__)

class DependabotMergeTest < CliTestCase
  SHA = 'a' * 40
  OTHER_SHA = 'c' * 40

  def setup
    @dir = Dir.mktmpdir('dependabot-merge-test')
    @log = File.join(@dir, 'calls.log')
    @answer = File.join(@dir, 'answer.json')
    @commits = File.join(@dir, 'commits.json')
    File.write(File.join(@dir, 'gh'), <<~SH)
      #!/bin/sh
      echo "$*" >> "#{@log}"
      [ -n "$GH_REPO_SEEN_LOG" ] && echo "GH_REPO=$GH_REPO GH_HOST=$GH_HOST" >> "$GH_REPO_SEEN_LOG"
      case "$1 $2" in
        "api repos/acme/app/pulls/12/commits?per_page=100")
          [ -n "$GH_API_FAILS" ] && { echo 'HTTP 404: Not Found' >&2; exit 1; }
          cat "#{@commits}" ;;
        "api "*) echo 'unexpected api path' >&2; exit 1 ;;
        "repo view") echo '{"nameWithOwner":"acme/app","defaultBranchRef":{"name":"main"}}' ;;
        "pr view")
          [ -n "$GH_VIEW_FAILS" ] && { echo 'no pull requests found' >&2; exit 1; }
          [ -n "$GH_VIEW_GARBLED" ] && { echo 'not json'; exit 0; }
          if [ "$5" = state ]; then
            [ -n "$GH_STATE_FAILS" ] && { echo 'HTTP 502' >&2; exit 1; }
            [ -f "#{@answer}.after" ] && { cat "#{@answer}.after"; exit 0; }
            [ -f "#{@log}.merged" ] && { echo '{"state":"MERGED"}'; exit 0; }
          fi
          cat "#{@answer}" ;;
        "pr merge")
          [ -n "$GH_MERGE_WARNS" ] && echo 'skipping local delete' >&2
          [ -n "$GH_MERGE_FAILS" ] && { echo "$GH_MERGE_FAILS" >&2; exit 1; }
          touch "#{@log}.merged" ;;
      esac
    SH
    File.chmod(0o755, File.join(@dir, 'gh'))
    @path = ENV.fetch('PATH')
    ENV['PATH'] = "#{@dir}:#{@path}"
    answer_with({})
    commits_are([commit])
  end

  def teardown
    ENV['PATH'] = @path
    ENV.delete('GH_VIEW_FAILS')
    %w[GH_API_FAILS GH_MERGE_FAILS GH_MERGE_WARNS GH_VIEW_GARBLED GH_STATE_FAILS GH_REPO_SEEN_LOG GH_REPO GH_HOST].each { |key| ENV.delete(key) }
    FileUtils.remove_entry(@dir)
  end

  def guard_cli_invocation(_argv)
    found = ENV.fetch('PATH').split(':').find { |dir| File.executable?(File.join(dir, 'gh')) }
    flunk 'the stand-in gh is not first on PATH' unless found == @dir
  end

  def dispatch_cli(argv)
    DependabotMerge::CLI.run(argv)
  end

  def answer_with(overrides)
    File.write(@answer, JSON.generate({
      'author' => { 'login' => 'app/dependabot', 'is_bot' => true },
      'headRefOid' => SHA,
      'state' => 'OPEN',
      'baseRefName' => 'main',
      'files' => [{ 'path' => 'Gemfile', 'changeType' => 'MODIFIED' }, { 'path' => 'Gemfile.lock', 'changeType' => 'MODIFIED' }],
      'changedFiles' => 2
    }.merge(overrides)))
  end

  # A commit as the REST pull request commits endpoint gives it, signed
  # by GitHub for Dependabot unless told otherwise.
  def commit(sha: SHA, author: 'dependabot[bot]', committer: 'web-flow', verified: true, reason: 'valid')
    {
      'sha' => sha,
      'author' => author && { 'login' => author },
      'committer' => committer && { 'login' => committer },
      'commit' => { 'verification' => { 'verified' => verified, 'reason' => reason } }
    }
  end

  def commits_are(list)
    File.write(@commits, JSON.generate(list))
  end

  def calls
    File.exist?(@log) ? File.readlines(@log, chomp: true) : []
  end

  def merge_calls
    calls.grep(/\Apr merge/)
  end

  def good_args
    ['12', '--squash', '--match-head-commit', SHA]
  end

  def test_merges_a_dependabot_pull_request_pinned_to_its_head
    cli_stdout(good_args)

    assert_equal ["pr merge 12 --squash --delete-branch --match-head-commit #{SHA}"], merge_calls
    assert_includes calls, 'pr view 12 --json author,baseRefName,changedFiles,files,headRefOid,state'
    assert_includes calls, 'repo view --json nameWithOwner,defaultBranchRef'
    assert_includes calls, 'api repos/acme/app/pulls/12/commits?per_page=100'
  end

  def test_says_it_merged_and_passes_on_what_gh_warned
    ENV['GH_MERGE_WARNS'] = '1'

    out = capture_io { run_cli(good_args) }.join

    assert_includes out, 'merged #12'
    assert_includes out, 'skipping local delete'
  end

  def test_ignores_a_repository_named_in_the_environment
    ENV['GH_REPO'] = 'other/repo'
    ENV['GH_HOST'] = 'other.example'
    seen = File.join(@dir, 'seen.log')
    ENV['GH_REPO_SEEN_LOG'] = seen

    cli_stdout(good_args)

    assert_equal ['GH_REPO= GH_HOST='], File.readlines(seen, chomp: true).uniq
  end

  def test_refuses_a_change_beyond_dependency_files
    answer_with('files' => [{ 'path' => 'Gemfile' }, { 'path' => 'app/models/user.rb' }], 'changedFiles' => 2)

    assert_includes abort_message(good_args), 'changes app/models/user.rb'
    assert_empty merge_calls
  end

  def test_refuses_a_file_named_like_a_dependency_file_inside_another_name
    answer_with('files' => [{ 'path' => 'notGemfile' }], 'changedFiles' => 1)

    assert_includes abort_message(good_args), 'changes notGemfile'
    assert_empty merge_calls
  end

  def test_allows_dependency_files_in_any_directory_and_workflow_pins
    paths = %w[services/api/package.json yarn.lock bun.lock .github/workflows/ci.yml go.sum
               .github/actions/setup/action.yml packages.lock.json src/Directory.Packages.props
               Directory.Build.props packages.config .config/dotnet-tools.json app/app.fsproj
               pubspec.yaml pubspec.lock gradle/wrapper/gradle-wrapper.properties
               gradle/libs.versions.toml settings.gradle.kts .mvn/wrapper/maven-wrapper.properties
               Package.resolved Package.swift setup.py requirements/prod.txt ci-constraints.txt
               Dockerfile Dockerfile.prod docker/Dockerfile.ci]
    answer_with('files' => paths.map { |path| { 'path' => path } }, 'changedFiles' => paths.size)

    cli_stdout(good_args)

    assert_equal 1, merge_calls.size
  end

  def test_refuses_code_named_after_a_dockerfile_and_wrapper_scripts
    %w[Dockerfile.rb Dockerfile.sh mvnw gradlew gradle/wrapper/gradle-wrapper.jar .github/actions/setup/run.sh
       .github/workflows/sub/deep.yml].each do |path|
      answer_with('files' => [{ 'path' => path }], 'changedFiles' => 1)

      assert_includes abort_message(good_args), "changes #{path}"
    end
    assert_empty merge_calls
  end

  def test_refuses_a_file_list_that_stops_short
    answer_with('changedFiles' => 150)

    assert_includes abort_message(good_args), 'changes 150 files, and only 2 are listed'
    assert_empty merge_calls
  end

  def test_refuses_a_rename_whose_old_path_it_cannot_see
    answer_with('files' => [{ 'path' => 'Gemfile', 'changeType' => 'RENAMED' }], 'changedFiles' => 1)

    assert_includes abort_message(good_args), 'renames Gemfile'
    assert_empty merge_calls
  end

  def test_refuses_a_pull_request_with_no_files
    answer_with('files' => [], 'changedFiles' => 0)

    assert_includes abort_message(good_args), 'changes no files'
    assert_empty merge_calls
  end

  def test_refuses_a_base_other_than_the_default_branch
    answer_with('baseRefName' => 'production')

    assert_includes abort_message(good_args), 'targets production'
    assert_empty merge_calls
  end

  def test_passes_the_merge_method_it_was_given
    %w[--merge --rebase].each do |method|
      cli_stdout(['12', method, '--match-head-commit', SHA])

      assert_includes merge_calls.last, method
    end
  end

  def test_refuses_a_pull_request_a_person_opened
    answer_with('author' => { 'login' => 'someone', 'is_bot' => false })

    assert_includes abort_message(good_args), 'opened by someone'
    assert_empty merge_calls
  end

  def test_refuses_another_bot_named_like_dependabot
    answer_with('author' => { 'login' => 'app/dependabot-preview', 'is_bot' => true })

    assert_includes abort_message(good_args), 'opened by app/dependabot-preview'
    assert_empty merge_calls
  end

  def test_refuses_a_commit_someone_else_wrote
    commits_are([commit(sha: OTHER_SHA, author: 'someone'), commit])

    assert_includes abort_message(good_args), "commit #{OTHER_SHA} is authored by someone, not dependabot[bot]"
    assert_empty merge_calls
  end

  def test_refuses_an_author_with_no_account
    commits_are([commit(author: nil)])

    assert_includes abort_message(good_args), "commit #{SHA} has no GitHub account as its author"
    assert_empty merge_calls
  end

  def test_refuses_an_author_login_left_empty
    commits_are([commit(author: '')])

    assert_includes abort_message(good_args), "commit #{SHA} has no GitHub account as its author"
    assert_empty merge_calls
  end

  def test_refuses_a_commit_someone_other_than_github_committed
    commits_are([commit(committer: 'someone')])

    assert_includes abort_message(good_args), "commit #{SHA} is committed by someone, not web-flow"
    assert_empty merge_calls
  end

  def test_refuses_a_committer_with_no_account
    commits_are([commit(committer: nil)])

    assert_includes abort_message(good_args), "commit #{SHA} has no GitHub account as its committer"
    assert_empty merge_calls
  end

  # A commit made through GitHub's REST API with Dependabot's name shows
  # committer web-flow, but GitHub does not sign it.
  def test_refuses_an_unsigned_commit_even_from_web_flow
    commits_are([commit(sha: OTHER_SHA, verified: false, reason: 'unsigned'), commit])

    assert_includes abort_message(good_args), "commit #{OTHER_SHA} is not verified by GitHub (unsigned)"
    assert_empty merge_calls
  end

  def test_refuses_a_signature_github_did_not_verify
    commits_are([commit(verified: false, reason: 'bad_email')])

    assert_includes abort_message(good_args), "commit #{SHA} is not verified by GitHub (bad_email)"
    assert_empty merge_calls
  end

  def test_refuses_a_verified_answer_that_is_not_true
    commits_are([commit(verified: 'false', reason: 'valid')])

    assert_includes abort_message(good_args), "commit #{SHA} is not verified by GitHub (valid)"
    assert_empty merge_calls
  end

  def test_refuses_a_commit_with_no_verification_answer
    no_answer = commit
    no_answer['commit'].delete('verification')
    commits_are([no_answer])

    assert_includes abort_message(good_args), 'verification'
    assert_empty merge_calls
  end

  def test_refuses_a_commit_list_that_does_not_reach_the_head
    commits_are([commit(sha: OTHER_SHA)])

    assert_includes abort_message(good_args), 'commit list does not reach the head'
    assert_empty merge_calls
  end

  def test_refuses_no_commits
    commits_are([])

    assert_includes abort_message(good_args), 'commit list does not reach the head'
    assert_empty merge_calls
  end

  def test_reports_a_commit_read_that_fails_and_merges_nothing
    ENV['GH_API_FAILS'] = '1'

    assert_includes abort_message(good_args), 'HTTP 404'
    assert_empty merge_calls
  end

  def test_refuses_a_head_that_moved
    answer_with('headRefOid' => 'b' * 40)

    assert_includes abort_message(good_args), 'head moved'
    assert_empty merge_calls
  end

  def test_refuses_a_pull_request_that_is_not_open
    answer_with('state' => 'MERGED')

    assert_includes abort_message(good_args), 'is MERGED'
    assert_empty merge_calls
  end

  def test_refuses_any_argument_it_does_not_name
    [
      good_args + ['--admin'],
      good_args + ['--auto'],
      good_args + ['--repo', 'other/repo'],
      good_args + ['-R', 'other/repo'],
      ['12', '--squash'],
      ['12', '--match-head-commit', SHA],
      ['12', '--squash', '--merge', '--match-head-commit', SHA],
      ['--squash', '12', '--match-head-commit', SHA],
      ['12;x', '--squash', '--match-head-commit', SHA],
      ['12', '--squash', '--match-head-commit', 'abc1234'],
      ['12', '--squash', '--match-head-commit', 'a' * 39],
      ["12\n", '--squash', '--match-head-commit', SHA],
      ['12', '--admin', '--match-head-commit', SHA],
      ['12', '--auto', '--match-head-commit', SHA],
      ['12', '--squash', '--auto', SHA],
      []
    ].each do |argv|
      assert_includes abort_message(argv), 'usage:', argv.join(' ')
    end
    assert_empty calls
  end

  def test_reports_a_read_that_fails_and_merges_nothing
    ENV['GH_VIEW_FAILS'] = '1'

    assert_includes abort_message(good_args), 'no pull requests found'
    assert_empty merge_calls
  end

  def test_reports_a_refused_merge
    ENV['GH_MERGE_FAILS'] = 'base branch policy prohibits the merge'

    assert_includes abort_message(good_args), 'base branch policy'
  end

  def test_reports_a_merge_that_landed_before_gh_failed_as_merged
    ENV['GH_MERGE_FAILS'] = 'failed to delete local branch'
    File.write("#{@answer}.after", JSON.generate('state' => 'MERGED'))

    out = cli_stdout(good_args)

    assert_includes out, 'merged #12'
    assert_includes out, 'failed to delete local branch'
  end

  def test_does_not_claim_a_merge_gh_only_queued
    File.write("#{@answer}.after", JSON.generate('state' => 'OPEN'))

    assert_includes abort_message(good_args), 'not merged: the pull request is OPEN'
  end

  def test_keeps_gh_s_message_when_the_state_cannot_be_read_afterward
    ENV['GH_MERGE_FAILS'] = 'merge failed'
    ENV['GH_STATE_FAILS'] = '1'

    message = abort_message(good_args)

    assert_includes message, 'merge failed'
    assert_includes message, 'HTTP 502'
  end

  def test_gives_a_reason_when_gh_fails_with_no_message
    ENV['GH_MERGE_FAILS'] = ' '

    assert_includes abort_message(good_args), 'gh failed'
  end

  def test_refuses_an_answer_it_cannot_read
    ENV['GH_VIEW_GARBLED'] = '1'

    refute_empty abort_message(good_args)
    assert_empty merge_calls
  end

  def test_refuses_an_answer_of_the_wrong_type
    File.write(@answer, '[]')

    refute_empty abort_message(good_args)
    assert_empty merge_calls
  end

  def test_refuses_an_answer_missing_a_field
    File.write(@answer, JSON.generate('author' => { 'login' => 'app/dependabot' }, 'state' => 'OPEN', 'baseRefName' => 'main'))

    refute_empty abort_message(good_args)
    assert_empty merge_calls
  end
end
