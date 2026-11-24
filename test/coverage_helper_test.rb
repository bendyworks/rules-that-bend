#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract tests for test/coverage_helper.rb, the opt-in SimpleCov
# bootstrap. Each test drives the helper in a subprocess so the
# COVERAGE guard and the missing-gem abort can be exercised without
# disturbing this process's own (possibly coverage-measuring) run.
# Run: ruby test/coverage_helper_test.rb

require_relative 'cli_test_case'

require 'fileutils'
require 'open3'
require 'tmpdir'

class CoverageHelperTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  HELPER = File.join(REPO_ROOT, 'test', 'coverage_helper.rb')

  # A stand-in for a newer simplecov than the pin. Its no-op start
  # ignores the helper's configuration block, so the helper runs to
  # the end with the fake loaded and the version assertion is what
  # fails, not a crash.
  FAKE_SIMPLECOV = <<~RUBY
    warn 'FAKE SIMPLECOV LOADED'
    module SimpleCov
      VERSION = '9.9.9'
      def self.start(*) = nil
    end
  RUBY

  FAKE_JSON_FORMATTER = <<~RUBY
    module SimpleCov
      module Formatter
        class JSONFormatter; end
      end
    end
  RUBY

  def test_loads_pinned_simplecov_beside_a_newer_one
    skip_unless_installed('simplecov', '0.22.0')
    skip_unless_installed('simplecov_json_formatter', '0.1.4')

    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'simplecov', '9.9.9', FAKE_SIMPLECOV)
      out, err, _status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_PATH' => [fake_gem_dir, *Gem.path].join(File::PATH_SEPARATOR) },
        RbConfig.ruby, '-e',
        "require #{HELPER.dump}; print SimpleCov::VERSION; $stdout.flush; Process.exit!(0)",
        chdir: REPO_ROOT
      )
      assert_equal '0.22.0', out, "the helper must load the pinned simplecov; stderr: #{err}"
      refute_includes err, '[DEPRECATION]'
    end
  end

  # simplecov accepts any simplecov_json_formatter ~> 0.1, and the
  # integrity guard in CI depends on coverage.json's schema, so the
  # formatter carries a pin of its own.
  def test_loads_pinned_json_formatter_beside_a_newer_one
    skip_unless_installed('simplecov', '0.22.0')
    skip_unless_installed('simplecov_json_formatter', '0.1.4')

    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'simplecov_json_formatter', '0.1.99', FAKE_JSON_FORMATTER)
      out, err, _status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_PATH' => [fake_gem_dir, *Gem.path].join(File::PATH_SEPARATOR) },
        RbConfig.ruby, '-e',
        "require #{HELPER.dump}; print Gem.loaded_specs['simplecov_json_formatter'].version; " \
        '$stdout.flush; Process.exit!(0)',
        chdir: REPO_ROOT
      )
      assert_equal '0.1.4', out, "the helper must load the pinned json formatter; stderr: #{err}"
    end
  end

  # The pinned formatter is present, so the simplecov pin is the only
  # thing that can stop the fake from loading.
  def test_abort_names_install_hint_when_only_another_version_installed
    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'simplecov', '9.9.9', FAKE_SIMPLECOV)
      install_fake_gem(fake_gem_dir, 'simplecov_json_formatter', '0.1.4', FAKE_JSON_FORMATTER)
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_HOME' => fake_gem_dir, 'GEM_PATH' => fake_gem_dir },
        RbConfig.ruby, '-e', "require #{HELPER.dump}",
        chdir: REPO_ROOT
      )
      assert_equal 1, status.exitstatus, 'a missing pinned version must exit 1'
      refute_includes err, 'FAKE SIMPLECOV LOADED', 'the helper must not load an unpinned simplecov'
      assert_includes err, 'gem install simplecov -v 0.22.0'
    end
  end

  # Another simplecov activated before the helper runs (RUBYOPT, an
  # earlier require) is a conflict, not a missing install: the install
  # hint would name a gem that is already there.
  def test_version_conflict_reports_the_conflict_not_the_install_hint
    skip_unless_installed('simplecov', '0.22.0')
    skip_unless_installed('simplecov_json_formatter', '0.1.4')

    Dir.mktmpdir('fake-gems') do |fake_gem_dir|
      install_fake_gem(fake_gem_dir, 'simplecov', '9.9.9', FAKE_SIMPLECOV)
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_PATH' => [fake_gem_dir, *Gem.path].join(File::PATH_SEPARATOR) },
        RbConfig.ruby, '-e', "gem 'simplecov', '9.9.9'; require #{HELPER.dump}",
        chdir: REPO_ROOT
      )
      refute status.success?, 'a version conflict must not let the run go on'
      assert_includes err, 'already activated simplecov-9.9.9'
      refute_includes err, 'gem install simplecov'
    end
  end

  def test_noop_when_coverage_unset
    out, err, status = Open3.capture3(
      { 'COVERAGE' => nil },
      RbConfig.ruby, '-e', "require #{HELPER.dump}; print defined?(SimpleCov).inspect",
      chdir: REPO_ROOT
    )
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal 'nil', out, 'SimpleCov must not load when COVERAGE is unset'
  end

  def test_noop_when_coverage_set_but_empty
    out, err, status = Open3.capture3(
      { 'COVERAGE' => '' },
      RbConfig.ruby, '-e', "require #{HELPER.dump}; print defined?(SimpleCov).inspect",
      chdir: REPO_ROOT
    )
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal 'nil', out, 'an empty COVERAGE value must not turn coverage on'
  end

  def test_abort_names_install_hint_when_gem_unfindable
    Dir.mktmpdir('no-gems') do |empty_gem_dir|
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_HOME' => empty_gem_dir, 'GEM_PATH' => empty_gem_dir },
        RbConfig.ruby, '-e', "require #{HELPER.dump}",
        chdir: REPO_ROOT
      )
      assert_equal 1, status.exitstatus, 'the missing-gem path must exit 1'
      refute_includes err, 'LoadError', 'the abort must replace the raw LoadError, not follow it'
      # The versions are hardcoded on purpose: a bump to the pins in
      # test/coverage_helper.rb and .github/workflows/checks.yml must
      # consciously touch this tripwire too, so the three sites cannot
      # drift apart silently.
      assert_includes err, 'gem install simplecov_json_formatter -v 0.1.4'
      assert_includes err, 'gem install simplecov -v 0.22.0'
    end
  end

  # Guards the two settings CI cannot: SimpleCov.root resolution
  # (CI always runs from the repo root, so a regression to
  # CWD-relative roots stays green there) and the widened merge
  # window (CI finishes inside the 600s default). Process.exit! skips
  # SimpleCov's at_exit, so the probe writes no artifact and leaves
  # no resultset entry behind.
  def test_pins_root_and_merge_window_from_any_cwd
    skip_unless_installed('simplecov', '0.22.0')
    skip_unless_installed('simplecov_json_formatter', '0.1.4')

    out, err, status = Open3.capture3(
      { 'COVERAGE' => '1' },
      RbConfig.ruby, '-e',
      "require #{HELPER.dump}; print [SimpleCov.root, SimpleCov.merge_timeout].inspect; " \
      '$stdout.flush; Process.exit!(0)',
      chdir: File.join(REPO_ROOT, 'test')
    )
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal [REPO_ROOT, 3600].inspect, out
  end

  # The require order in cli_test_case.rb is load-bearing and no
  # artifact check can stand in for it. SimpleCov's Minitest plugin
  # reports from Minitest.after_run, but Minitest.run only installs
  # that plugin when minitest loads AFTER SimpleCov has started;
  # required the other way round, SimpleCov's own at_exit harvests
  # coverage before a single test body runs. Every bin/ file still
  # gets its module body measured at load time, so the artifact keeps
  # its shape and CI's integrity guard stays green while roughly
  # four fifths of real measurement silently disappears.
  def test_cli_test_case_requires_coverage_helper_before_minitest
    source = File.read(File.join(REPO_ROOT, 'test', 'cli_test_case.rb'))
    helper_require = source.index("require_relative 'coverage_helper'")
    minitest_require = source.index("require 'minitest/autorun'")

    refute_nil helper_require, 'cli_test_case.rb must require the coverage helper'
    refute_nil minitest_require, 'cli_test_case.rb must require minitest/autorun'
    assert helper_require < minitest_require,
           'coverage_helper must be required before minitest/autorun, or coverage ' \
           'collapses to load-time-only while every artifact check stays green'
  end

  private

  # Decided here, from what this process can see installed, rather
  # than from the child's output: before the pin, a newer simplecov
  # on the path makes the helper print the install hint too.
  def skip_unless_installed(name, version)
    return if Gem::Specification.find_all_by_name(name, version).any?

    skip "#{name} #{version} not installed in this environment"
  end

  def install_fake_gem(gem_dir, name, version, source)
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = 'stand-in for a version other than the pin'
      s.authors = ['coverage_helper_test']
      s.require_paths = ['lib']
    end
    FileUtils.mkdir_p(File.join(gem_dir, 'specifications'))
    File.write(File.join(gem_dir, 'specifications', "#{name}-#{version}.gemspec"), spec.to_ruby)
    lib_dir = File.join(gem_dir, 'gems', "#{name}-#{version}", 'lib')
    FileUtils.mkdir_p(lib_dir)
    File.write(File.join(lib_dir, "#{name}.rb"), source)
  end
end
