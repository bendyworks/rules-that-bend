#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests that gh-calls.txt lists the GitHub CLI commands this project
# names, and no others. The project requires a GitHub-hosted repository
# because everything that reads pull requests or GitHub issues goes through
# `gh`; the list is what a `gh`-compatible command for another host
# would have to answer, so it is compared in both directions with the
# commands the skills, the guidance, and the CLIs name.
# Run: ruby test/gh_calls_test.rb

require_relative 'cli_test_case'
require 'open3'

load File.expand_path('../bin/gh-issue-sync', __dir__)
load File.expand_path('../bin/stale-branches', __dir__)

class GhCallsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LIST = File.join(ROOT, 'gh-calls.txt')
  SCANNED = %w[skills/ guidance/ bin/].freeze
  # gh's own top-level commands, and those of the gh-stack extension.
  # Naming them keeps prose such as "gh would resolve" from reading as
  # a command; a command whose first word is missing here is not seen.
  GROUPS = %w[alias api attestation auth browse cache codespace completion config extension gist
              gpg-key issue label org pr project release repo ruleset run search secret ssh-key
              stack status variable workflow].freeze
  # Each tool under bin/ that runs gh, and the module holding its
  # GH_CALLS. A new one goes here.
  TOOLS = { 'bin/gh-issue-sync' => GhIssueSync, 'bin/stale-branches' => StaleBranches }.freeze
  # Commands that take no second word.
  BARE = %w[browse status].freeze
  # Flags that take a value, which can stand between a command's words.
  VALUE_FLAGS = %w[-R --repo -X --method -H --header -f -F --field --raw-field --hostname
                   -q --jq --json -t --template].freeze
  # The word gh, whatever stands in front of it: a backtick, `$(`, a
  # permission rule's `Bash(`. A path (bin/gh) or a longer name
  # (gh-stack) is not it.
  GH = %r{(?:\A|[^\w./-])gh\z}

  def tracked_files
    out, status = Open3.capture2('git', 'ls-files', '-z', '--', *SCANNED, chdir: ROOT)
    assert status.success?, 'git ls-files failed'
    files = out.split("\0")
    refute_empty files, 'git ls-files listed nothing to scan'
    files.select { |file| File.file?(File.join(ROOT, file)) }
  end

  # Each call mapped to the files naming it, so a failure says where.
  def named_calls
    tracked_files.each_with_object({}) do |file, calls|
      text = File.read(File.join(ROOT, file), encoding: 'UTF-8', invalid: :replace)
      calls_in(text).each { |call| (calls[call] ||= []) << file }
    end
  end

  # Splitting on whitespace reads a command wrapped across a line, or
  # spaced unevenly, as the words it is.
  def calls_in(text)
    words = text.split
    words.each_index.filter_map { |index| call_at(words, index + 1) if words[index].match?(GH) }.uniq
  end

  # `gh api` takes a path, so its second word is the path's first
  # segment: `gh api "repos/<owner>/<repo>"` is `gh api repos`.
  def call_at(words, index)
    index = past_flags(words, index)
    group = words[index].to_s[/\A[a-z][a-z-]*/]
    return unless GROUPS.include?(group)
    return "gh #{group}" if BARE.include?(group)
    return unless words[index] == group

    verb = words[past_flags(words, index + 1)].to_s.sub(%r{\A["'/]+}, '')[/\A[a-z][a-z-]*/]
    verb && "gh #{group} #{verb}"
  end

  def past_flags(words, index)
    while words[index].to_s.start_with?('-')
      index = VALUE_FLAGS.include?(words[index]) ? past_value(words, index + 1) : index + 1
    end
    index
  end

  # A quoted value can hold spaces, which the split made into several
  # words; it ends at the word that closes the quote.
  def past_value(words, index)
    quote = words[index].to_s[/\A["']/]
    last = index
    last += 1 while quote && words[last] && !closes?(words[last], quote, opening: last == index)
    last + 1
  end

  def closes?(word, quote, opening:)
    word.end_with?(quote) && !(opening && word.length == 1)
  end

  def declared_calls
    TOOLS.values.flat_map { |tool| tool::GH_CALLS }.map { |call| "gh #{call}" }
  end

  def listed_calls
    File.readlines(LIST, chomp: true).map { |line| line.sub(/\s*#.*\z/, '').strip }.reject(&:empty?)
  end

  def test_the_list_is_sorted_and_names_each_call_once
    assert_equal listed_calls.uniq.sort, listed_calls
  end

  def test_every_call_a_skill_guidance_file_or_cli_names_is_listed
    missing = named_calls.reject { |call, _| listed_calls.include?(call) }

    assert_empty missing.map { |call, files| "#{call} (#{files.uniq.join(', ')})" },
                 'add these to gh-calls.txt, or reword the text if it names no command'
  end

  # The CLIs build their gh arguments as lists, which the scan above
  # cannot read, so each declares the calls it makes.
  def test_every_call_a_cli_declares_is_listed
    refute_empty declared_calls
    assert_empty declared_calls - listed_calls
  end

  # A declared call the tool no longer makes would keep its line in
  # gh-calls.txt. Both tools write a call's words as a list of quoted
  # strings, which is what this looks for.
  def test_every_call_a_cli_declares_is_one_its_source_makes
    TOOLS.each do |path, tool|
      source = File.read(File.join(ROOT, path))
      unused = tool::GH_CALLS.reject { |call| source.include?(call.split.map { |word| "'#{word}'" }.join(', ')) }

      assert_empty unused, "#{path} declares gh calls its source does not make"
    end
  end

  # The forms a command takes in prose and code blocks, each of which
  # the scan has to read as the command it is.
  def test_the_scan_reads_quoted_flagged_wrapped_and_ungrouped_commands
    text = <<~TEXT
      gh api "orgs/{org}/teams" and gh api /users/someone and gh api -X DELETE repos/o/r
      gh pr --repo o/r close 5, gh  pr  reopen 5, then gh release
      delete v1, gh gist create, gh secret set, and gh browse.
      Bash(gh run rerun *) and sha=$(gh release view v1 --json tagName)
      gh -R o/r workflow run ci.yml, gh api --jq .login teams/acme
      **`gh auth status`** and [`gh cache delete`](x)
      gh api -H "Accept: application/vnd.github+json" repos/o/r/pulls
      gh api --jq '.[] | .name' gists/public
      Prose: gh would resolve the wrong project, and gh answers.
      Not a verb: the `gh stack`'s output, and where `gh stack` exits 9.
      Not gh: bin/gh pr merge, the gh-stack pr list, high pr view,
      x.gh pr edit, and my-gh pr checks. Bare: gh status.
    TEXT

    assert_equal ['gh api gists', 'gh api orgs', 'gh api repos', 'gh api teams', 'gh api users',
                  'gh auth status', 'gh browse', 'gh cache delete', 'gh gist create', 'gh pr close',
                  'gh pr reopen', 'gh release delete', 'gh release view', 'gh run rerun',
                  'gh secret set', 'gh status', 'gh workflow run'],
                 calls_in(text).sort
  end

  def test_every_listed_call_is_named_somewhere
    assert_empty listed_calls - named_calls.keys - declared_calls,
                 'gh-calls.txt lists a command no skill, guidance file, or CLI names or declares'
  end
end
