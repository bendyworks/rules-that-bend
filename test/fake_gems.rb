# frozen_string_literal: true

# Helpers for tests that check which version of a gem a file activates.
# A test installs a stand-in gem into a throwaway gem directory and runs
# the file in a subprocess whose GEM_PATH names that directory.
# This file lives outside CI's test/*_test.rb glob: it defines no tests.

require 'fileutils'

module FakeGems
  private

  # Decided from what this process sees installed, never from the
  # child's output, so a missing pin skips the test while a file that
  # loads the wrong version fails it.
  def skip_unless_installed(name, version)
    return if Gem::Specification.find_all_by_name(name, version).any?

    skip "#{name} #{version} not installed in this environment"
  end

  # Writes a gemspec and one source file, lib/<lib_file>, which is the
  # path a require of the gem's entry point resolves to.
  def install_fake_gem(gem_dir, name, version, source, deps: {}, lib_file: "#{name}.rb")
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = 'stand-in for a version other than the pin'
      s.authors = ['fake_gems']
      s.require_paths = ['lib']
      deps.each { |dep_name, requirement| s.add_runtime_dependency(dep_name, requirement) }
    end
    FileUtils.mkdir_p(File.join(gem_dir, 'specifications'))
    File.write(File.join(gem_dir, 'specifications', "#{name}-#{version}.gemspec"), spec.to_ruby)
    lib_path = File.join(gem_dir, 'gems', "#{name}-#{version}", 'lib', lib_file)
    FileUtils.mkdir_p(File.dirname(lib_path))
    File.write(lib_path, source)
  end
end
