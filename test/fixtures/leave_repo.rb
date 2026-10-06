# frozen_string_literal: true

# A small pushed repository for the safe-to-leave tests: one commit on
# main, present on the remote, with a clean working tree. Each test then
# leaves behind the one thing it is about -- a stash, an unpushed commit,
# a linked worktree -- through the helpers below.
#
# This file lives under test/fixtures/ rather than test/ so CI's
# test/*_test.rb glob does not run it as a suite of its own; it defines
# no tests. repo_builder.rb documents the containment every repository
# built here inherits.

require_relative 'repo_builder'

module Fixtures
  class LeaveRepo < RepoBuilder
    DEFAULT_BRANCH = 'main'

    def build
      prepare_root
      init_remote_and_clone(DEFAULT_BRANCH)
      commit('README', 'a project', 'Start the project')
      push(DEFAULT_BRANCH)
      self
    end

    def write(path, contents)
      File.write(File.join(work, path), "#{contents}\n")
    end

    # A commit on the current branch that is pushed nowhere.
    def commit_locally(path, message)
      commit(path, message, message)
    end

    def branch_from_main(name)
      git('checkout', '-q', '-b', name, DEFAULT_BRANCH)
    end

    # The fetch reproduces what the command's usage text asks of its
    # caller, which is to fetch first. It is a plain fetch, without
    # --prune, so the tracking ref of a branch the remote has deleted
    # stays in place.
    def push(branch, remote: 'origin')
      git('push', '-q', remote, branch)
      fetch(remote)
    end

    def fetch(remote = 'origin')
      git('fetch', '-q', remote)
    end

    # A second remote beside origin, empty until something is pushed.
    def add_remote(name)
      git('init', '-q', '-b', DEFAULT_BRANCH, '--bare', "#{name}.git", dir: root)
      git('remote', 'add', name, File.join(root, "#{name}.git"))
    end

    # Stashes a change to a tracked file, which is what a plain
    # `git stash` takes; an untracked file alone would leave nothing to
    # stash and the command would exit 0 having done nothing. Each call
    # writes different contents, since stashing an unchanged file does
    # nothing either.
    def stash_change(message = nil)
      @stashes = @stashes.to_i + 1
      write('README', "changed #{@stashes}")
      args = message ? ['stash', 'push', '-q', '-m', message] : %w[stash push -q]
      git(*args)
    end

    # A linked worktree beside the main one, with HEAD detached at the
    # default branch's tip.
    def add_detached_worktree(name)
      path = File.join(root, name)
      git('worktree', 'add', '-q', '--detach', path, DEFAULT_BRANCH)
      path
    end

    # A linked worktree beside the main one, on a new branch.
    def add_worktree(name, branch)
      path = File.join(root, name)
      git('worktree', 'add', '-q', '-b', branch, path, DEFAULT_BRANCH)
      path
    end
  end
end
