# frozen_string_literal: true

# Opt-in SimpleCov bootstrap for the bin/ CLI test suite. Does nothing
# unless the COVERAGE env var is set to a non-empty value (matching
# how bin/linear treats env tokens), so a plain test run needs no
# gems and the bin/ CLIs' stdlib-only posture is untouched.
#
# Required at the very top of test/cli_test_case.rb, above
# minitest/autorun, so coverage starts before any bin/ file is
# loaded. That order is load-bearing, not cosmetic: simplecov reports
# through a Minitest plugin that Minitest.run installs only when
# minitest loads after SimpleCov has started. Required the other way
# round, SimpleCov's own at_exit harvests coverage before any test
# body runs, leaving load-time-only numbers that still look like a
# valid artifact. test/coverage_helper_test.rb pins the order.
#
# CI runs each test/*_test.rb as its own process, so every process
# records its own resultset entry (keyed by command_name below) and
# SimpleCov merges them; coverage/coverage.json carries the merged
# union and is the artifact of record. coverage/.resultset.json is
# per-process raw data, where a tracked-but-unloaded file shows as all
# zeros -- do not read uncovered lines from it directly.

unless ENV['COVERAGE'].to_s.empty?
  # Both must match the pinned installs in .github/workflows/checks.yml
  # (ruby-tests job) and the tripwire assertions in
  # test/coverage_helper_test.rb; update all three together.
  formatter_version = '0.1.4'
  simplecov_version = '0.22.0'

  begin
    # A plain require activates the newest version installed, which
    # may not be the one CI measures with. The formatter needs its own
    # pin: simplecov accepts any formatter ~> 0.1 and leaves choosing
    # one to its require, which takes the newest 0.x. With a pin
    # missing, gem raises Gem::MissingSpecError and the hint below
    # names the fix. Any other load error, such as another simplecov
    # already activated, raises as it is, since installing the pin
    # would not fix it.
    gem 'simplecov_json_formatter', formatter_version
    gem 'simplecov', simplecov_version
    require 'simplecov'
    require 'simplecov_json_formatter'
  rescue Gem::MissingSpecError
    abort 'coverage_helper: COVERAGE is set but the pinned simplecov is ' \
          "not installed; run: gem install simplecov_json_formatter -v #{formatter_version} " \
          "&& gem install simplecov -v #{simplecov_version}"
  end

  # Root and the tracked glob are both pinned to absolute paths:
  # SimpleCov resolves each against the current working directory by
  # default, and a test run started from inside test/ would silently
  # drop all bin/ coverage. The glob assumes bin/ holds only files --
  # SimpleCov reads every tracked path line by line to simulate
  # coverage for the ones no test loaded, so a subdirectory there
  # would end each measuring run in Errno::EISDIR.
  repo_root = File.expand_path('..', __dir__)

  SimpleCov.start do
    root repo_root
    command_name File.basename($PROGRAM_NAME)
    track_files File.join(repo_root, 'bin', '*')
    add_filter '/test/'
    enable_coverage :branch
    # Default merge window is 600s; a slow local gauntlet session can
    # exceed it between test-file processes, silently shrinking the
    # merged union.
    merge_timeout 3600
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::JSONFormatter
      ]
    )
  end
end
