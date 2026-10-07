# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Fixtures
  # One fixture repository, built once and kept for the length of the
  # test process, so each test takes a copy in place of a build. A build
  # runs a few hundred git commands and takes seconds; a copy takes a few
  # hundredths of one.
  #
  # git records a repository's absolute path inside it: in the clone's
  # remote URL, in FETCH_HEAD, and in the two files that tie a second
  # worktree to its clone. A copy that kept those would fetch from and
  # push to the original's bare repository, and its worktree entry would
  # name a directory belonging to the original. So #copy_to rewrites the
  # path in every file that holds it. Those files are found by searching
  # the built repository, never listed here, which covers a git version
  # that records the path somewhere else.
  class BuiltFixture
    def initialize(builder)
      @holder = Dir.mktmpdir('stale-branches-built')
      remove_holder_at_exit
      @root = builder.new(File.join(@holder, 'fixture')).build.root
      # git writes the resolved path, and on macOS the temporary
      # directory has two forms (see RepoBuilder.under_tmpdir?). Paths
      # are matched as bytes, the form git writes them in.
      @recorded = [File.realpath(@root), @root].uniq.map(&:b)
      refuse_links_into_root
      @files_recording_root = find_files_recording_root
    rescue StandardError
      FileUtils.rm_rf(@holder) if @holder
      raise
    end

    # cp_r into a directory that exists would put the copy one level
    # down, at a path the caller's repository object does not name.
    def copy_to(root)
      if File.exist?(root)
        raise RepoBuilder::Error, "refusing to copy a fixture to #{root}: it already exists"
      end

      FileUtils.cp_r(@root, root)
      replacements = @recorded.zip([File.realpath(root), root].map(&:b)).to_h
      @files_recording_root.each do |relative|
        path = File.join(root, relative)
        File.binwrite(path, File.binread(path).gsub(Regexp.union(@recorded), replacements))
      end
    end

    private

    def entries
      Dir.glob('**/*', File::FNM_DOTMATCH, base: @root)
    end

    # A link's target is in no file's contents, so the search below
    # cannot find it and a copy would keep a link into the original.
    def refuse_links_into_root
      links = entries.select do |relative|
        path = File.join(@root, relative)
        File.symlink?(path) && @recorded.any? { |form| File.readlink(path).b.include?(form) }
      end
      return if links.empty?

      raise RepoBuilder::Error, "#{links.join(', ')}: a symbolic link to the fixture's own " \
                                'path, which a copy cannot be given its own of'
    end

    def find_files_recording_root
      entries.select do |relative|
        path = File.join(@root, relative)
        next false unless File.file?(path)

        contents = File.binread(path)
        next false unless @recorded.any? { |form| contents.include?(form) }
        next true unless contents.include?("\0")

        raise RepoBuilder::Error, "#{relative} records the fixture's path and is not a " \
                                  'text file, so a copy cannot be given its own'
      end
    end

    # Registered before the build, so a build that is interrupted leaves
    # nothing behind either. The tests run inside minitest's own at_exit
    # block, and a block registered from inside one still runs. The
    # process check keeps a forked child from removing a directory its
    # parent is still copying.
    def remove_holder_at_exit
      owner = Process.pid
      at_exit { FileUtils.rm_rf(@holder) if Process.pid == owner }
    end
  end
end
