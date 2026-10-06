#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the fixture every reader of a git directory in the
# parallel-checkouts templates is run against. The templates find a
# checkout's git directory by reading .git, gitdir and commondir files
# themselves, in more than one language, so the layouts they must agree
# on live in one place. These tests check the fixture against git's own
# answers wherever git can still give one.
# Run: ruby test/git_directory_layouts_test.rb

require_relative 'cli_test_case'
require_relative 'fixtures/git_directory_layouts'
require 'open3'

class GitDirectoryLayoutsTest < Minitest::Test
  def setup
    @scratch = File.realpath(Dir.mktmpdir('layouts'))
    @layouts = Fixtures::GitDirectoryLayouts.build(@scratch)
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def rev_parse(path, flag)
    out, _err, status = Open3.capture3(
      Fixtures::GitDirectoryLayouts::GIT_ENV, 'git', '-C', path, 'rev-parse', '--path-format=absolute', flag
    )
    status.success? ? File.realpath(out.strip) : nil
  end

  def test_it_builds_every_layout_once
    assert_equal %i[checkout subdirectory nested outside crlf missing unreachable], @layouts.keys
    @layouts.each_value { |layout| assert File.directory?(layout.path), layout.name.to_s }
  end

  def test_git_agrees_with_every_layout_it_can_still_read
    %i[checkout subdirectory nested outside].each do |name|
      layout = @layouts.fetch(name)
      assert_equal layout.git_dir, rev_parse(layout.path, '--git-dir'), "#{name} git directory"
      assert_equal layout.common_dir, rev_parse(layout.path, '--git-common-dir'), "#{name} common directory"
    end
  end

  def test_only_the_checkout_and_its_subdirectory_are_not_linked_worktrees
    linked = @layouts.select { |_name, layout| layout.linked }.keys
    assert_equal %i[nested outside crlf missing unreachable], linked
  end

  def test_the_crlf_layout_differs_from_a_readable_worktree_only_in_line_endings
    crlf = @layouts.fetch(:crlf)
    dot_git = File.binread(File.join(crlf.path, '.git'))
    assert dot_git.end_with?("\r\n"), dot_git.inspect
    assert_equal "gitdir: #{crlf.git_dir}", dot_git.strip
    assert File.directory?(crlf.git_dir)
  end

  def test_the_missing_layout_points_at_a_git_directory_that_is_gone
    missing = @layouts.fetch(:missing)
    named = File.read(File.join(missing.path, '.git'))[/\Agitdir: (.+)$/, 1]
    refute File.exist?(named)
    assert_nil missing.git_dir
    assert_nil rev_parse(missing.path, '--git-dir')
  end

  # What a nested worktree looks like from inside a container that
  # mounts the checkout at another path: its .git file names a path
  # that does not exist there, while the checkout around it still holds
  # the worktree's git directory.
  def test_the_unreachable_layout_names_a_path_that_is_absent_while_the_checkout_still_holds_it
    unreachable = @layouts.fetch(:unreachable)
    named = File.read(File.join(unreachable.path, '.git'))[/\Agitdir: (.+)$/, 1]
    refute File.exist?(named)
    assert unreachable.path.start_with?("#{@layouts.fetch(:checkout).path}/")
    assert_equal File.basename(named), File.basename(unreachable.git_dir)
    assert File.directory?(unreachable.git_dir)
    assert_equal @layouts.fetch(:checkout).git_dir, unreachable.common_dir
  end
end
