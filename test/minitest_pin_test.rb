#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the minitest pin in test/cli_test_case.rb. Each test loads
# cli_test_case.rb in a subprocess beside a fake minitest, so this
# process's own minitest is untouched.
# Run: ruby test/minitest_pin_test.rb

require_relative 'cli_test_case'

require_relative 'fake_gems'
require 'open3'
require 'tmpdir'

class MinitestPinTest < Minitest::Test
  include FakeGems

  REPO_ROOT = File.expand_path('..', __dir__)
  CLI_TEST_CASE = File.join(REPO_ROOT, 'test', 'cli_test_case.rb')

  # A stand-in for a minitest other than the pin, with just enough for
  # cli_test_case.rb to define its class.
  FAKE_MINITEST = <<~RUBY
    warn 'FAKE MINITEST LOADED'
    module Minitest
      VERSION = '9.9.9'
      class Test; end
    end
  RUBY

  def test_loads_pinned_minitest_beside_a_newer_one
    skip_unless_installed('minitest', '6.0.6')

    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'minitest', '9.9.9', FAKE_MINITEST, lib_file: 'minitest/autorun.rb')
      out, err, status = Open3.capture3(
        { 'COVERAGE' => nil, 'GEM_PATH' => [fake_gem_dir, *Gem.path].join(File::PATH_SEPARATOR) },
        RbConfig.ruby, '-e',
        "require #{CLI_TEST_CASE.dump}; print Minitest::VERSION; $stdout.flush; Process.exit!(0)",
        chdir: REPO_ROOT
      )
      assert status.success?, "cli_test_case subprocess failed: #{err}"
      assert_equal '6.0.6', out, "cli_test_case must load the pinned minitest; stderr: #{err}"
    end
  end

  def test_abort_names_install_hint_when_only_another_version_installed
    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'minitest', '9.9.9', FAKE_MINITEST, lib_file: 'minitest/autorun.rb')
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => nil, 'GEM_HOME' => fake_gem_dir, 'GEM_PATH' => fake_gem_dir },
        RbConfig.ruby, '-e', "require #{CLI_TEST_CASE.dump}",
        chdir: REPO_ROOT
      )
      assert_equal 1, status.exitstatus, 'a missing pinned minitest must exit 1'
      refute_includes err, 'FAKE MINITEST LOADED', 'cli_test_case must not load an unpinned minitest'
      assert_includes err, 'minitest (= 6.0.6) is not installed'
      # Hardcoded on purpose, like the simplecov tripwire in
      # coverage_helper_test.rb: a bump to the pin in cli_test_case.rb
      # and .github/workflows/checks.yml must touch this line too.
      assert_includes err, 'gem install minitest -v 6.0.6'
    end
  end
end
