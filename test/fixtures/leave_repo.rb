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
      git('push', '-q', 'origin', DEFAULT_BRANCH)
      git('fetch', '-q', '--prune', 'origin')
      self
    end

    def write(path, contents)
      File.write(File.join(work, path), "#{contents}\n")
    end

    # A commit on the current branch that no remote has.
    def commit_locally(path, message)
      commit(path, message, message)
    end

    def branch_from_main(name)
      git('checkout', '-q', '-b', name, DEFAULT_BRANCH)
    end

    def push(branch)
      git('push', '-q', 'origin', branch)
      git('fetch', '-q', '--prune', 'origin')
    end

    # Stashes a change to a tracked file, which is what a plain
    # `git stash` takes; an untracked file alone would leave nothing to
    # stash and the command would exit 0 having done nothing.
    def stash_change(message = nil)
      write('README', "changed #{rand(1_000_000)}")
      args = message ? ['stash', 'push', '-q', '-m', message] : %w[stash push -q]
      git(*args)
    end

    # A linked worktree beside the main one, on a new branch.
    def add_worktree(name, branch)
      path = File.join(root, name)
      git('worktree', 'add', '-q', '-b', branch, path, DEFAULT_BRANCH)
      path
    end
  end
end
