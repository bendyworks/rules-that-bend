---
name: resume-work
description: Carry on an unfinished story in a fresh session. Reads the story's plan file and its resume notes, checks them against the branch, the remote, and the pull requests before trusting them, rebuilds the task list under the plan's own numbers, says what is waiting on the developer, and starts the next to-do. Use when the user says "resume <name>", "pick <story> back up", "continue where the last session left off", "carry on with <plan>", or invokes the resume-work skill, with or without a plan name. Works on a story the pause-work skill paused and on one whose last session ended without pausing. Not Claude Code's own /resume, which reopens an old conversation.
---

# Resume work

A fresh session knows nothing the last one learned. The plan file is
where that survives: its to-dos, and the resume notes the pause-work
skill (bundled in this plugin) appends to it. Notes describe the moment
they were written, and a merge or a push since then makes them wrong
with no error, so this skill checks them before acting on them.

## Steps

1. **Find the plan.** The name given is the plan's filename without
   `.md`, and by the plan-issue skill's convention usually the branch
   too; with no name, use the current branch's. The plan-issue skill
   (bundled in this plugin) keeps plans at `.claude/plans/<name>.md`,
   and a project may keep them elsewhere. When no plan file matches,
   list the plans there are and ask.

2. **Read the plan whole,** every `## Resume notes` section included,
   and any file the newest notes point at.

3. **Check before trusting.** Read each of these now:

   ```bash
   git fetch
   git status --short --branch
   git log --oneline @{u}..          # local commits not on the remote
   git log --oneline ..@{u}          # remote commits not here
   git stash list
   gh pr list --head <branch> --state all --json number,title,state,isDraft
   ```

   **Say where the plan and its notes disagree with what these show,
   before anything else.** Then:

   - **Stop and ask** when a pull request for the story has merged or
     closed, when the remote branch holds commits this checkout lacks,
     or when the story's branch is missing or is not the one checked
     out. Change nothing first: no switch, pull, or stash.
   - **Any other difference** (a commit the notes call local is now
     pushed, a stash is gone) is reported and stops nothing: go on to
     step 4 with what is true now. What the notes say is waiting on
     the developer is still waiting.

   With no resume notes in the plan, say so, and say what cannot then
   be known: the last session's decisions and their reasons, which
   tests fail on purpose, and what it was waiting on. Uncommitted
   changes are then unexplained work: describe them and ask before
   building on them or discarding them.

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
