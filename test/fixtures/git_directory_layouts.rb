# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'

module Fixtures
  # The directory layouts a parallel-checkouts template can be run from,
  # built as real git repositories. The templates find a checkout's git
  # directory by reading .git, gitdir and commondir files themselves
  # (git may be missing, old, or redirected by an exported GIT_DIR), and
  # they do it in more than one language, since each is copied into a
  # project as a single file. Running every reader against these layouts
  # is what keeps them agreeing.
  #
  #   checkout      a clone's main working tree
  #   subdirectory  a directory inside it, as for an app that is not at
  #                 its repository's root
  #   nested        a linked worktree inside the checkout, where Claude
  #                 Code puts its own
  #   outside       a linked worktree elsewhere on disk
  #   crlf          a linked worktree whose .git file has CRLF endings
  #   relative      a linked worktree whose .git file names its git
  #                 directory by a relative path
  #   absolute_common  a linked worktree whose commondir file holds an
  #                 absolute path, where git writes a relative one
  #   crlf_common   a linked worktree whose commondir file has CRLF
  #                 endings
  #   missing       a linked worktree whose git directory is gone
  #   unreachable   a nested worktree whose .git file names a path that
  #                 does not exist, while the checkout around it still
  #                 holds its git directory: what a container sees when
  #                 it mounts the checkout at another path
  module GitDirectoryLayouts
    # Variables that point git at a repository or hand it configuration
    # from outside. Open3 merges an environment into the inherited one,
    # and `git -C` does not override an inherited GIT_DIR, so each is
    # removed for every git command here: a build that kept one would
    # commit to the repository it names.
    AMBIENT_GIT_KEYS = %w[
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
      GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_TEMPLATE_DIR
    ].freeze

    GIT_ENV = AMBIENT_GIT_KEYS.to_h { |key| [key, nil] }.merge(
      'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_SYSTEM' => File::NULL,
      'GIT_AUTHOR_NAME' => 'Test', 'GIT_AUTHOR_EMAIL' => 'test@example.com',
      'GIT_COMMITTER_NAME' => 'Test', 'GIT_COMMITTER_EMAIL' => 'test@example.com'
    ).freeze

    # git_dir is the layout's own git directory and common_dir the one
    # every worktree of its checkout shares; both are nil where nothing
    # on disk can say. For the unreachable layout they are what a reader
    # can still recover from the checkout around the worktree.
    Layout = Struct.new(:name, :path, :git_dir, :common_dir, :linked)

    module_function

    # Builds every layout under `scratch`, which must exist and be a
    # real path, and returns them by name.
    def build(scratch)
      checkout = File.join(scratch, 'checkout')
      common = File.join(checkout, '.git')
      git('init', '-q', checkout)
      git('-C', checkout, 'commit', '-q', '--allow-empty', '-m', 'init')
      FileUtils.mkdir_p(File.join(checkout, 'app'))

      layouts = [
        Layout.new(:checkout, checkout, common, common, false),
        Layout.new(:subdirectory, File.join(checkout, 'app'), common, common, false),
        worktree(:nested, checkout, File.join(checkout, '.claude', 'worktrees', 'nested')),
        worktree(:outside, checkout, File.join(scratch, 'outside')),
        crlf(worktree(:crlf, checkout, File.join(scratch, 'crlf'))),
        relative(worktree(:relative, checkout, File.join(scratch, 'relative'))),
        absolute_common(worktree(:absolute_common, checkout, File.join(scratch, 'absolute_common'))),
        crlf_common(worktree(:crlf_common, checkout, File.join(scratch, 'crlf_common'))),
        missing(worktree(:missing, checkout, File.join(scratch, 'missing'))),
        unreachable(worktree(:unreachable, checkout, File.join(checkout, '.claude', 'worktrees', 'unreachable')))
      ]
      layouts.to_h { |layout| [layout.name, layout] }
    end

    def git(*args)
      _out, err, status = Open3.capture3(GIT_ENV, 'git', *args)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?
    end

    def worktree(name, checkout, path)
      git('-C', checkout, 'worktree', 'add', '-q', '--detach', path)
      Layout.new(name, path, File.join(checkout, '.git', 'worktrees', File.basename(path)),
                 File.join(checkout, '.git'), true)
    end

    def crlf(layout)
      File.binwrite(File.join(layout.path, '.git'), "gitdir: #{layout.git_dir}\r\n")
      layout
    end

    def relative(layout)
      from_worktree = Pathname.new(layout.git_dir).relative_path_from(Pathname.new(layout.path))
      File.write(File.join(layout.path, '.git'), "gitdir: #{from_worktree}\n")
      layout
    end

    def absolute_common(layout)
      File.write(File.join(layout.git_dir, 'commondir'), "#{layout.common_dir}\n")
      layout
    end

    def crlf_common(layout)
      File.binwrite(File.join(layout.git_dir, 'commondir'), "../..\r\n")
      layout
    end

    def missing(layout)
      FileUtils.rm_rf(layout.git_dir)
      layout.git_dir = nil
      layout.common_dir = nil
      layout
    end

    def unreachable(layout)
      elsewhere = File.join('/nonexistent-host-path', '.git', 'worktrees', File.basename(layout.git_dir))
      File.write(File.join(layout.path, '.git'), "gitdir: #{elsewhere}\n")
      layout
    end

    private_class_method :worktree, :crlf, :relative, :absolute_common, :crlf_common, :missing, :unreachable
  end
end
