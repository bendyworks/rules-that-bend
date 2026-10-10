---
name: pause-work
description: Pause an unfinished story so a fresh session can carry it on. Writes dated resume notes into the story's plan file (what is pushed and what is only local, decisions with their reasons, checks already run, tests failing on purpose, what is waiting on the developer) and ends by naming the resume-work skill. Use when the user says "let's continue this in a fresh session", "I'm running low on context", "hand this off to a new session", "pause this story", "wrap up for a new session", or invokes the pause-work skill. Not for a story that has shipped; that is the finished-issue-housekeeping skill.
---

# Pause work

A session about to be replaced knows things the next one cannot work
out from the repository. This skill writes them into the story's plan
file, where the resume-work skill (bundled in this plugin) reads them.
It usually runs when little context is left, so do the steps below and
nothing more.

**The notes go in the story's plan file, never in memory and never
only in chat.** The plan-issue skill (bundled in this plugin) keeps
plans at `.claude/plans/<name>.md`; a project may keep them elsewhere.
A story with no plan file has no fixed place for the notes: ask the
developer where to write them.

## Steps

1. **Read the state now; never write it from recall.**

   ```bash
   git status --short --branch
   git log --oneline @{u}..          # commits not on the remote
   git stash list
   gh pr list --head <branch> --state all --json number,title,state,isDraft
   ```

2. **Bring the plan up to date.** Tick each to-do whose work is
   finished and verified, and correct any sentence in the plan about
   the story's current state that is no longer true.

3. **Append the notes to the end of the plan file** under
   `## Resume notes (<today's date>)`, after any earlier notes, which
   stay as they are. Keep the heading at `##` and write no checkboxes
   under it: tools that read the plan's to-dos end the list at the
   next `##` heading and fail on a checkbox they cannot parse. Refer to
   a to-do by its number. The notes say:

   - **Pushed and local:** the branch, each commit not on the remote
     (short hash and subject), each uncommitted path and why it is
     uncommitted, each stash, and each pull request with its state.
   - **Decisions:** each one made this session, with its reason. A
     decision recorded without its reason gets argued again.
   - **Checks already run:** each fact learned by running something,
     with the command and what came back.
   - **Failing on purpose:** each such test by name, and what it is
     waiting for.
   - **Waiting on the developer:** each question or approval, with its
     text or the path to it. A draft not yet posted is listed here.
   - **Next:** the next to-do by its number, where in it the work
     stopped, and which item above it waits on, if any.

4. **Correct memory; add nothing to it.** Where the project's memory
   has an entry about this story's position that is now wrong, rewrite
   it as one true line that points at the plan file. The notes
   themselves never go there.

5. **End on one line:** start a fresh session and invoke the
   resume-work skill with the plan's name, written the way this
   session invokes skills (`/bendyworks:resume-work <name>` where the
   plugin is installed). Print no prompt to copy, and do not repeat
   the notes in chat.
