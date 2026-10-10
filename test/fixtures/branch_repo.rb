# frozen_string_literal: true

require_relative 'repo_builder'

module Fixtures
  # A throwaway repository holding one local branch per row of the
  # stale-branch decision table, so the sweep's verdicts can be graded
  # against a known oracle rather than against reasoning about git. Every
  # branch named here belongs to that throwaway repository; see
  # repo_builder.rb for what that means and for the properties its setup
  # deliberately preserves.
  #
  # The default branch is main throughout, which is the common case and
  # the one this fixture is for. GitflowRepo covers the repository where
  # that assumption is wrong.
  class BranchRepo < RepoBuilder
    # Stand-ins for the long-lived branches a team keeps regardless of what
    # any signal says. Each is built as a plain ancestor of the throwaway
    # repo's default branch, so the cheap first pass lists every one of
    # them and only the protected set stands between them and deletion.
    LONG_LIVED = %w[develop staging production gh-pages].freeze

    # Stands in for a manual safety net, protected by its name alone. Also
    # an ancestor, for the same reason as the branches above.
    BACKUP = 'r-spike-backup'

    # A branch sharing its name with a tag that points at the throwaway
    # repo's default branch, so a bare-name lookup resolves to the tag and
    # reports the branch as holding nothing. The branch's own work has not
    # landed, which makes the mistake a wrongful deletion rather than a
    # wrongful keep.
    TAG_SHADOWED = 's-tag-shadow'

    # Adds a file and then removes it, so its net diff against the
    # default branch is empty while its history holds content no other
    # branch ever received. The tip check clears it and the branch is
    # not deletable: deleting it takes the reflog too, and that content
    # is then reachable from nothing.
    ADDED_THEN_REMOVED = 'u-added-then-removed'

    # Where HEAD is left standing, and deletable on the evidence alone.
    CURRENT = 'o-current'

    # Returns self so a caller can build and use in one expression.
    def build
      prepare_root
      init_remote_and_clone('main')
      build_default_branch
      build_ancestor_branch
      build_squash_merged_branches
      build_stacked_pair
      build_protected_lookalikes
      build_tag_shadowed_branch
      build_added_then_removed
      publish_default_branch
      build_worktree_branch
      git('checkout', '-q', 'main')
      git('fetch', '-q', '--prune', 'origin')
      stand_on_a_non_default_branch
      self
    end

    private

    # HEAD ends on a branch that is neither the default one nor otherwise
    # protected. o-current sits at the default branch's tip, so the cheap
    # first pass lists it and nothing but current-branch protection stands
    # between it and deletion.
    #
    # Leaving HEAD on the default branch instead -- as this fixture once
    # did -- makes the current-branch rule untestable, because the
    # default-branch rule decides that row first. A sweep with no
    # current-branch protection at all then scores full marks on every row
    # of both tables. It also leaves the default-branch rule itself only
    # half-graded, since the two rules were covering for each other.
    def stand_on_a_non_default_branch
      git('checkout', '-qb', CURRENT)
    end

    def worktree_path
      File.join(root, 'wt')
    end

    def build_default_branch
      commit('base.txt', 'base', 'base')
      git('push', '-q', 'origin', 'main')
    end

    # Merged with a real merge commit, so it stays an ancestor of main and
    # the cheap first pass finds it without any content comparison.
    def build_ancestor_branch
      git('checkout', '-qb', 'p1-ancestor')
      commit('p1.txt', 'p1', 'p1 work')
      git('checkout', '-q', 'main')
      git('merge', '-q', '--no-ff', 'p1-ancestor', '-m', 'merge p1-ancestor')
    end

    def build_squash_merged_branches
      squash_clean
      main_edited_after_squash
      main_merged_back_in
    end

    # Squash-merged, with main later advancing on an unrelated file: the
    # content comparison still clears it.
    def squash_clean
      git('checkout', '-qb', 'a-squash-clean')
      commit('a.txt', 'a', 'a work')
      squash_into('main', 'a-squash-clean', 'squash a')
      commit('unrelated.txt', 'u', 'unrelated advance')
    end

    # Squash-merged, then main edits the SAME lines. The content
    # comparison conflicts here, and the check can say nothing either
    # way. Multi-line files are what make this work: a one-line file
    # edited on both sides can merge cleanly.
    def main_edited_after_squash
      git('checkout', '-qb', 'b-main-edited')
      write_lines('b.txt', %w[l1 l2 l3])
      git('add', 'b.txt')
      git('commit', '-qm', 'b work')
      squash_into('main', 'b-main-edited', 'squash b')
      write_lines('b.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits b's lines")
    end

    # Squash-merged, then the developer merged main back in -- a tip that
    # is not an ancestor of main yet adds nothing to it.
    def main_merged_back_in
      git('checkout', '-qb', 'c-merged-main-back')
      commit('c.txt', 'c', 'c work')
      squash_into('main', 'c-merged-main-back', 'squash c')
      git('checkout', '-q', 'c-merged-main-back')
      git('merge', '-q', 'main', '-m', 'merge main into c')
    end

    # A child branch merged into its PARENT, never into the default
    # branch: reaching some other feature branch is not reaching main.
    def build_stacked_pair
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'e-parent')
      commit('e-parent.txt', 'ep', 'parent work')
      git('checkout', '-qb', 'e-stacked-child')
      commit('e-child.txt', 'ec', 'child work')
      squash_into('e-parent', 'e-stacked-child', 'squash child into parent')
    end

    # Branches whose only defense is the protected set. Each is a plain
    # ancestor of the default branch and so appears in the first pass's
    # own output, which is what makes the protection load-bearing rather
    # than decorative.
    def build_protected_lookalikes
      git('checkout', '-q', 'main')
      (LONG_LIVED + [BACKUP]).each { |branch| git('branch', '-q', branch) }
    end

    def build_tag_shadowed_branch
      git('checkout', '-q', 'main')
      git('checkout', '-qb', TAG_SHADOWED)
      commit('s.txt', 's', 's work that never landed')
      git('checkout', '-q', 'main')
      git('tag', TAG_SHADOWED)
    end

    def build_added_then_removed
      git('checkout', '-q', 'main')
      git('checkout', '-qb', ADDED_THEN_REMOVED)
      commit('u-research.txt', 'THE ONLY COPY OF THIS RESEARCH', 'research worth keeping')
      git('rm', '-q', 'u-research.txt')
      git('commit', '-qm', 'drop the research file')
    end

    # Every verdict is measured against the remote-tracking ref of the
    # default branch, so the remote has to hold what the builders above
    # committed to it.
    def publish_default_branch
      git('checkout', '-q', 'main')
      git('push', '-q', 'origin', 'main')
    end

    # Checked out in a second worktree, so it must never become a
    # candidate: git refuses to delete it either way, and a sweep that
    # tries only produces a mid-run error.
    def build_worktree_branch
      git('checkout', '-q', 'main')
      git('branch', '-q', 'n-worktree')
      git('worktree', 'add', '-q', worktree_path, 'n-worktree')
    end
  end
end
