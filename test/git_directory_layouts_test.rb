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

  # git -C does not override an inherited GIT_DIR, so a build that kept
  # one would commit to the repository it names.
  def test_it_builds_inside_its_scratch_directory_when_git_dir_is_exported
    ambient = File.join(@scratch, 'ambient')
    Fixtures::GitDirectoryLayouts.git('init', '-q', ambient)
    saved = ENV.to_h.slice('GIT_DIR', 'GIT_WORK_TREE')
    ENV['GIT_DIR'] = File.join(ambient, '.git')
    ENV['GIT_WORK_TREE'] = ambient
    begin
      layouts = Fixtures::GitDirectoryLayouts.build(File.realpath(Dir.mktmpdir('built', @scratch)))
      found = rev_parse(layouts.fetch(:nested).path, '--git-common-dir')
    ensure
      %w[GIT_DIR GIT_WORK_TREE].each { |key| ENV[key] = saved[key] }
    end
    assert_equal layouts.fetch(:checkout).common_dir, found
    assert_empty Dir.children(File.join(ambient, '.git', 'refs', 'heads'))
    refute File.exist?(File.join(ambient, '.git', 'worktrees'))
  end

  def test_it_builds_the_layouts_in_order
    assert_equal %i[checkout subdirectory nested outside crlf relative absolute_common crlf_common missing unreachable],
                 @layouts.keys
    @layouts.each_value { |layout| assert File.directory?(layout.path), layout.name.to_s }
  end

  def test_git_agrees_with_every_layout_it_can_still_read
    %i[checkout subdirectory nested outside relative absolute_common].each do |name|
      layout = @layouts.fetch(name)
      assert_equal layout.git_dir, rev_parse(layout.path, '--git-dir'), "#{name} git directory"
      assert_equal layout.common_dir, rev_parse(layout.path, '--git-common-dir'), "#{name} common directory"
    end
  end

  def test_only_the_checkout_and_its_subdirectory_are_not_linked_worktrees
    linked = @layouts.select { |_name, layout| layout.linked }.keys
    assert_equal %i[nested outside crlf relative absolute_common crlf_common missing unreachable], linked
  end

  def test_the_crlf_layout_differs_from_a_readable_worktree_only_in_line_endings
    crlf = @layouts.fetch(:crlf)
    dot_git = File.binread(File.join(crlf.path, '.git'))
    assert dot_git.end_with?("\r\n"), dot_git.inspect
    assert_equal "gitdir: #{crlf.git_dir}", dot_git.strip
    assert File.directory?(crlf.git_dir)
  end

  def test_the_relative_layout_names_its_git_directory_by_a_relative_path
    relative = @layouts.fetch(:relative)
    named = File.read(File.join(relative.path, '.git'))[/\Agitdir: (.+)$/, 1]
    refute named.start_with?('/'), named
    assert_equal relative.git_dir, File.realpath(named, relative.path)
  end

  def test_the_commondir_layouts_change_only_the_commondir_file
    absolute = @layouts.fetch(:absolute_common)
    assert_equal "#{absolute.common_dir}\n", File.read(File.join(absolute.git_dir, 'commondir'))
    crlf = @layouts.fetch(:crlf_common)
    assert_equal "../..\r\n", File.binread(File.join(crlf.git_dir, 'commondir'))
    assert_equal crlf.common_dir, File.realpath('../..', crlf.git_dir)
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
