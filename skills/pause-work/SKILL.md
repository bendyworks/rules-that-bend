---
name: pause-work
description: Pause an unfinished story so a fresh session can carry it on. Writes dated resume notes into the story's plan file (what is pushed and what is only local, decisions with their reasons, checks already run, tests failing on purpose, what is waiting on the developer) and ends by naming the resume-work skill. Use when the user says "let's continue this in a fresh session", "I'm running low on context", "hand this off to a new session", "pause this story", "wrap up for a new session", or invokes the pause-work skill. Not for a story that has shipped; that is the finished-issue-housekeeping skill.
---

# Pause work

This skill writes what the next session cannot work out from the
repository into the story's plan file, where the resume-work skill
(bundled in this plugin) reads it. Little context is usually left, so
do only these steps.

**The notes go in the story's plan file, never in memory and never
only in chat.** The plan-issue skill (bundled in this plugin) keeps
plans at `.claude/plans/<name>.md`; a project may keep them elsewhere.
With no plan file, ask the developer where to write them.

## Steps

1. **Read the state now; never write it from recall.**

   ```bash
   git branch --show-current
   git status --short
   git log --oneline <remote>/<branch>..   # commits not on the remote
   git stash list
   gh pr list --head <branch> --state all --json number,title,state,isDraft
   ```

   `<remote>` is the project's remote, usually `origin`; never use
   `@{u}`, which may be unset or name the base branch. With no
   `<remote>/<branch>`, the branch is not on the remote: say so, and
   list its commits since the base branch.

2. **Bring the plan up to date.** Tick each to-do whose work is
   finished and verified, and correct any sentence in the plan about
   the story's state that is no longer true.

3. **Append the notes to the end of the plan file** under
   `## Resume notes (<today's date>)`, after any earlier notes. Keep
   the heading at `##`, which is where the to-do list ends for the
   tools that read it, and write no checkboxes under it: the finished-issue-housekeeping skill (bundled in this
   plugin) counts every unchecked box in the file as unfinished work.
   Refer to a to-do by its number. The next session acts on the newest
   notes only, so repeat what is still open. The notes say:

   - **Pushed and local:** the branch, each commit not on the remote
     (short hash and subject), each uncommitted path and why it is
     uncommitted (the plan file too, where git tracks it), each stash
     made on this branch, and each pull request with its state.
   - **Decisions:** each one made this session, with its reason.
   - **Checks already run:** each fact learned by running something,
     with the command and what came back.
   - **Failing on purpose:** each such test by name, and what it is
     waiting for.
   - **Waiting on the developer:** each question or approval, with its
     text or the path to it.
   - **Next:** the next to-do by its number, where in it the work
     stopped, and which item above it waits on, if any.

4. **Correct memory; add nothing to it.** Where the project's memory
   has an entry about this story's position that is now wrong, rewrite
   it as one true line that points at the plan file. The notes
   themselves never go there.

5. **End on one line:** start a fresh session and invoke the
   resume-work skill with the plan's name, written the way this
   session invokes skills (`/bendyworks:resume-work <name>` where the
   plugin is installed). Print no prompt to copy.
