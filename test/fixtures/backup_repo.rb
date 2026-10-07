# frozen_string_literal: true

require_relative 'repo_builder'

module Fixtures
  # A throwaway repository holding backups of story branches that were
  # squashed and merged, one per clause of the sweep's backup rule. It
  # is a fixture of its own rather than more rows in BranchRepo because
  # nearly every test sweeps a copy of that one, and these branches
  # would be swept by all of them while being read by a handful.
  #
  # The default branch is main, and HEAD is left on it.
  class BackupRepo < RepoBuilder
    # Backups taken before a story branch was squashed. Each holds two
    # commits that write the same line twice, so its tip adds nothing
    # once the story merges while its first commit still would: the
    # content check reports proof-a:tip-only, and what the pull request
    # for the story branch says is the only thing that can improve on
    # that. The story branches themselves are gone, as they are once a
    # pull request merges; their heads stay reachable under
    # refs/fixture/, which is where the canned records read them from.
    #
    # One per clause of the backup rule, named for the branch it backs
    # up:
    #
    #   backup/w-squashed         the merged head carries its tree
    #   backup/x-grew-pre-squash  labelled, and the story branch gained
    #                             a commit after the squash, so the tree
    #                             is an earlier commit's and not the
    #                             head's
    #   backup/z-differs          the merged head carries a file the
    #                             backup never had
    #   backup/aa-layer           the story merged as a stack layer, so
    #                             its base is the layer below
    #   backup/ab-elsewhere       the story merged into a release branch
    #   backup/ac-absent          the merged head is in no local object
    #   backup/ad-fork            the merged pull request is a fork's
    #   backup/ae-closed          the pull request closed unmerged
    #   backup/aj-two             three merged pull requests: one head
    #                             absent, one with another tree, and
    #                             one with the backup's
    #   backup/ao-v2              labelled v2, and a pull request that
    #                             closed unmerged is named ao-v2: the
    #                             merged one belongs to ao
    #   backup/ap-merge-absent    a stack layer whose merge commit is in
    #                             no local object
    #   backups/af-plural         not under backup/ at all
    BACKUPS = {
      'backup/w-squashed' => 'w-squashed',
      'backup/x-grew-pre-squash' => 'x-grew',
      'backup/z-differs' => 'z-differs',
      'backup/aa-layer' => 'aa-layer',
      'backup/ab-elsewhere' => 'ab-elsewhere',
      'backup/ac-absent' => 'ac-absent',
      'backup/ad-fork' => 'ad-fork',
      'backup/ae-closed' => 'ae-closed',
      'backup/aj-two' => 'aj-two',
      'backup/ao-v2' => 'ao',
      'backup/ap-merge-absent' => 'ap-merge-absent',
      'backups/af-plural' => 'af-plural'
    }.freeze

    # The default branch edited the story's lines after the squash, so
    # merging the backup conflicts and the content check cannot answer.
    BACKUP_CONFLICTED = 'backup/y-conflicted'

    # The default branch reverted the story after merging it. The
    # backup's tree is still the merged head's, and merging it would put
    # the reverted content back, so the content check keeps it before
    # any pull request is read.
    BACKUP_REVERTED = 'backup/ah-reverted'

    # One commit, so nothing on it is the only copy of anything and the
    # content check clears it with no pull request.
    BACKUP_ONE_COMMIT = 'backup/ak-clean'

    # The rewrite never happened: the story branch carried on from the
    # backup's tip, added a commit, and was squash-merged. Every commit
    # on the backup is in the merged head, and its tree is no commit's
    # that the head has and the backup lacks.
    BACKUP_NEVER_REWRITTEN = 'backup/al-ancestor'

    # A feature branch that happens to live under backup/, with a merged
    # pull request of its own at this tip. Cut at a hyphen its name
    # reads as a backup of `an`, whose pull request merged at a head
    # this clone lacks.
    BRANCH_UNDER_THE_PREFIX = 'backup/an-own-job'

    # A backup somebody opened a pull request on, pushed and left on the
    # remote as a branch with an open pull request has to be.
    BACKUP_WITH_OPEN_PR = 'backup/ai-open'

    # Returns self so a caller can build and use in one expression.
    def build
      prepare_root
      init_remote_and_clone('main')
      commit('base.txt', 'base', 'base')
      build_backups
      git('checkout', '-q', 'main')
      git('push', '-q', 'origin', 'main')
      git('push', '-q', 'origin', "#{BACKUP_WITH_OPEN_PR}:#{BACKUP_WITH_OPEN_PR}")
      git('fetch', '-q', '--prune', 'origin')
      self
    end

    private

    def build_backups
      BACKUPS.each { |backup, story| build_backup(backup, story) }
      build_one_commit_backup
      build_backup(BACKUP_CONFLICTED, 'y-conflicted')
      write_lines('y-conflicted.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits y-conflicted's lines")
      build_backup(BACKUP_REVERTED, 'ah-reverted')
      git('revert', '--no-edit', 'HEAD')
      build_backup(BACKUP_WITH_OPEN_PR, 'ai-open')
      build_never_rewritten
      build_branch_under_the_prefix
    end

    # A backup, the story branch squashed from it, and the squash-merge
    # of that story into the default branch. Leaves HEAD on the default
    # branch at the merge, which refs/fixture/<story>-merge points at for
    # the pull request record of a story that merged as a stack layer.
    def build_backup(backup, story)
      git('checkout', '-q', 'main')
      git('checkout', '-qb', backup)
      write_lines("#{story}.txt", %w[l1 DRAFT l3])
      git('add', "#{story}.txt")
      git('commit', '-qm', "#{story} draft")
      write_lines("#{story}.txt", %w[l1 FINAL l3])
      git('commit', '-qam', "#{story} final")
      build_story_from(backup, story)
      squash_into('main', story, "squash #{story}")
      git('update-ref', "refs/fixture/#{story}-merge", 'HEAD')
      git('branch', '-q', '-D', story)
    end

    # The rewritten story branch: one commit where the backup has two.
    # refs/fixture/<story> is the head its pull request merged at.
    def build_story_from(backup, story)
      git('checkout', '-q', 'main')
      git('checkout', '-qb', story)
      git('merge', '-q', '--squash', backup)
      stage('z-extra.txt', 'never in the backup') if story == 'z-differs'
      git('commit', '-qm', "#{story} squashed")
      commit('x-later.txt', 'added after the squash', 'x-grew later work') if story == 'x-grew'
      git('update-ref', "refs/fixture/#{story}", 'HEAD')
    end

    def stage(path, contents)
      File.write(File.join(work, path), "#{contents}\n")
      git('add', path)
    end

    def build_one_commit_backup
      git('checkout', '-q', 'main')
      git('checkout', '-qb', BACKUP_ONE_COMMIT)
      commit('ak-clean.txt', 'ak', 'ak-clean work')
      squash_into('main', BACKUP_ONE_COMMIT, 'squash ak-clean')
    end

    def build_never_rewritten
      git('checkout', '-q', 'main')
      git('checkout', '-qb', BACKUP_NEVER_REWRITTEN)
      write_lines('al-ancestor.txt', %w[l1 DRAFT l3])
      git('add', 'al-ancestor.txt')
      git('commit', '-qm', 'al-ancestor draft')
      write_lines('al-ancestor.txt', %w[l1 FINAL l3])
      git('commit', '-qam', 'al-ancestor final')
      git('checkout', '-qb', 'al-ancestor')
      commit('al-later.txt', 'added after the backup', 'al-ancestor later work')
      git('update-ref', 'refs/fixture/al-ancestor', 'HEAD')
      squash_into('main', 'al-ancestor', 'squash al-ancestor')
      git('branch', '-q', '-D', 'al-ancestor')
    end

    # Built the way BranchRepo forces a branch to the pull-request
    # stage: squash-merge, then edit the same lines on the default
    # branch, so that merging the branch back conflicts.
    def build_branch_under_the_prefix
      git('checkout', '-q', 'main')
      git('checkout', '-qb', BRANCH_UNDER_THE_PREFIX)
      write_lines('an-own-job.txt', %w[l1 l2 l3])
      git('add', 'an-own-job.txt')
      git('commit', '-qm', 'an-own-job work')
      squash_into('main', BRANCH_UNDER_THE_PREFIX, 'squash an-own-job')
      write_lines('an-own-job.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits an-own-job's lines")
    end
  end
end
