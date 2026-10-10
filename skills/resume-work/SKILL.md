---
name: resume-work
description: Carry on an unfinished story in a fresh session. Reads the story's plan file and its resume notes, checks them against the branch, the remote, and the pull requests before trusting them, rebuilds the task list under the plan's own numbers, says what is waiting on the developer, and starts the next to-do. Use when the user says "resume <name>", "pick <story> back up", "continue where the last session left off", or invokes the resume-work skill. Not Claude Code's own /resume, which reopens an old conversation.
---

# Resume work

What the last session learned survives in the plan file: its to-dos,
and the resume notes the pause-work skill (bundled in this plugin)
appends. Notes describe the moment they were written; a merge or push
since then makes them wrong with no error.

## Steps

1. **Find the plan.** The name given is the plan's filename without
   `.md`; with no name, use the current branch's. The plan-issue skill (bundled in this plugin) keeps plans
   at `.claude/plans/<name>.md`; a project may keep them elsewhere.
   When no plan file matches, list the plans and ask.

2. **Read the plan whole,** and any file its last `## Resume notes`
   section points at. Act on that section only: what earlier ones list as
   waiting may since be settled.
   The story's branch is the one those notes name; without notes, the
   one named like the plan.

3. **Check before trusting.** Run:

   ```bash
   git fetch <remote>
   git branch --show-current
   git status --short
   git log --oneline <remote>/<branch>..   # local commits not on the remote
   git log --oneline ..<remote>/<branch>   # remote commits not here
   git stash list
   gh pr list --head <branch> --state all --json number,title,state,isDraft
   ```

   **Say where the plan and its notes disagree with what these show,
   before anything else.** Then:

   - **Stop and ask** when a pull request for the story has merged or
     closed and the notes do not say so, when the branch's own remote
     branch holds commits this checkout lacks, or when the story's
     branch is missing or is not the one checked out. Change nothing
     first: no switch, pull, or stash.
   - **Any other difference** (a commit the notes call local is now
     pushed, a stash is gone) is reported and stops nothing: go on to
     step 4 with what is true now. What the notes say is waiting on
     the developer is still waiting.

   `<remote>` is the project's remote, usually `origin`; never use
   `@{u}`, which may be unset or name the base branch. With no
   `<remote>/<branch>`, the branch is not on the remote: no reason to
   stop.

   With no resume notes in the plan, say so, and say what cannot then
   be known: the last session's decisions and their reasons, which
   tests fail on purpose, and what it was waiting on.

   **Uncommitted changes, and stashes made on the story's branch, that
   the notes do not account for are unexplained work:** describe them
   and ask before building on them or discarding them.

4. **Rebuild the task list** from the plan's unchecked to-dos, in the
   session's task list and not as a list in chat: one task for each,
   in order, the plan's own number leading the subject
   (`4. Add dedupe_slug`).

5. **Say what is waiting on the developer,** each item with its text
   or the path to it.

6. **Start the next to-do,** under the plan's own rules for working
   one. **A to-do the notes show waiting on the developer (a review,
   an answer, an approval) is never started on a guess:** ask for
   what it waits on and stop there, with nothing written toward it.
