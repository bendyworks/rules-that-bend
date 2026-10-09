---
name: gauntlet
description: Multi-front quality pass on a feature branch whose business requirements are already met -- specs pass, lint passes, the user-facing feature works. Runs `/code-review` first, then dispatches parallel sub-agents to audit idioms, test quality, validation-bypass risk, and security, then consolidates findings into one punch list, fixes every clear-cut finding without stopping, hunts for a bug in the result, checks the branch's commit messages against the final code and for prose defaults, and batches the judgment calls into one set of questions at the end. Tuned for Ruby on Rails projects (RSpec, RuboCop, Pundit); runs elsewhere with reduced audit depth. Use when the user says "run the gauntlet", "gauntlet this branch", "gauntlet this PR", "challenge the branch", "stress test this branch", "is this ready to merge?", "audit this branch", or invokes the gauntlet skill.
---

# Run the gauntlet

The user has finished a story to the satisfaction of clients and end-users. Specs pass. Lint passes. The feature works. *Now* they want to improve the code itself -- sharpen idioms, surface false-positive tests, plug validation holes, look for accidental authorization gaps -- before the PR leaves draft.

This skill orchestrates that pass in six phases:

1. **Phase 0** -- pre-flight and scope
2. **Phase 1** -- finding sources: `/code-review`, then parallel sub-agent audits (report-only)
3. **Phase 2** -- consolidate findings into one ranked punch list
4. **Phase 3** -- sort every finding, fix the clear-cut ones without asking, drop the ones for a case that cannot happen yet, and batch the judgment calls as questions at the end (see "When Phase 3 fixes")
5. **Phase 4** -- a fresh-eyes "find the bug" sub-agent on the final state; runs unless the developer opted out up front (see "When Phase 4 runs")
6. **Phase 5** -- two fresh sub-agents check commit bodies, the pull request description, and follow-up drafts against the final code, and read the commit messages for prose defaults (see "When Phase 5 runs")

The main agent's job is orchestration: dispatch sub-agents in parallel, merge their reports, dedupe, rank by severity, and build a single coherent list to act on. Sub-agents never write to the working tree (see "Never write to the tree to find something out"). Fixes happen in the main agent, from Phase 3 on, with full cross-cutting context.

## Standing pre-approval -- do NOT prompt for component steps

When the user invokes the gauntlet, every component step and nested skill call is **already approved**. Run them all without pausing to ask permission: `/code-review`, `/security-review` (the security agent), every Phase 1 sub-agent dispatch, the suite gate whenever "When the suite gate runs" says to run it, the Phase 4 "find the bug" pass and its second pass, and Phase 5's two lanes. Never stop to ask "is it ok to run /code-review?" or "should I dispatch the audit agents?" -- just proceed through the phases.

Fixing is covered too: every finding "When Phase 3 fixes" sorts into its fix bucket is fixed without asking, in Phases 3, 4, and 5 alike. After Phase 0's precondition checks, the run stops for the developer only where that subsection says: the question batch at the end, or the pick when the developer asked to triage. One more stop sits outside it: a change in the tree that nobody chose ("Watching the tree"). **Filing an issue, or posting anything else to a tracker, is never pre-approved** (that subsection says why). Everything else runs unprompted.

## Rules already covered elsewhere -- do NOT restate

Do not pad sub-agent prompts with rules that already live in:

- **The project's CLAUDE.md files** -- testing philosophy, lint policy, commit conventions, and whatever house rules the project declares.
- **`/code-review` (built-in)** -- generic reuse / quality / efficiency findings. That is its lane: don't ask sub-agents to duplicate it by hunting duplicated code or readability micro-improvements.
- **`/security-review` (built-in)** -- a general security review of pending changes. The gauntlet's security agent should *invoke* `/security-review` and incorporate its findings, not redo that work from scratch.

Each sub-agent should *read* the relevant CLAUDE.md(s) to inform its findings. The briefs below assume that and don't re-list the rules. The one exception is Phase 5's `prose-defaults` brief, which says why beside it.

## Never write to the tree to find something out

**No sub-agent whose prompt this skill writes changes the working tree, in any phase, not even with a change it means to undo. Every such prompt carries, word for word, the parts of the no-write block the table gives its lane.** A sub-agent sees only its prompt, never this skill, so a rule left out of the prompt does not exist for it. The built-ins this skill invokes, `/code-review` and `/security-review`, write their own prompts; Phase 1 says what to do if `/code-review` edits, and `/security-review` runs inside the `security` agent, whose prompt carries the block. Nobody is watching the tree while an audit runs, and a change an agent leaves behind reads as the developer's own edit in the next commit.

### The no-write block

The block is two paragraphs and one of two endings.

> **Never write to the working tree, not even a change you intend to undo.** An undo that depends on you finishing normally is not an undo. Run `git rev-parse --show-toplevel` first: that directory is the checkout. Inside it, do not edit, create, move, or delete any file (the records git keeps under `.git` aside), and do not run `git stash`, `git restore`, `git reset`, `git checkout <ref> -- <path>`, or any other command that rewrites files there. Do not run the project's tests or code there either: a run writes coverage files, logs, and test-database rows. Read files, run read-only commands, and report.
>
> **Reading a test can rule a dependency out, never in.** A test that never observes a value cannot depend on it, and reading settles that. A test that does observe it may still pass with the production code broken: a default, a setup record, a second code path, or a loose assertion can supply the same answer. A claim that a test does or does not depend on something it observes needs a run, not a read. **A doubt you reach by reading is a finding either way, never something to drop:** report it as confirmed when a run confirms it, and with `unverified:` in front when no run settled it.

The experiments ending:

> **Your lane runs experiments, and the ordinary way is a throwaway worktree.** If the project's tests run inside a container, they cannot run in a worktree outside the checkout: do none of the steps below, and report the finding as `unverified:`, naming the experiment that would settle it: what to break, which test file to run, and what a failure would show. Your shell keeps neither its directory nor its variables between commands, so begin every command by setting `checkout`, and `scratch` once it exists, to their absolute paths written out in full, as the commands below do.
>
> **If you are confirming a suspected bug, not checking what a test depends on, read steps 3 to 5 this way.** In step 3, run the existing test file nearest the code, to show the worktree can run tests; with no such file, or if it fails, skip to step 6 and report `unverified:`. In step 4, add a test that reproduces the bug under `$scratch/tree` and run that test file. In step 5, the bug is confirmed only when the new test fails on its assertion: a load or setup error, or a test that passes, settles nothing. Paste the test into your finding, because step 6 deletes it.
>
> 1. Fingerprint the checkout before anything else: `checkout=<absolute path>; { git -C "$checkout" rev-parse HEAD; git -C "$checkout" symbolic-ref -q HEAD || echo detached; git -C "$checkout" status --porcelain --untracked-files=all -- . ':(exclude).claude/gauntlets' ':(exclude).claude/plans'; git -C "$checkout" diff HEAD -- . ':(exclude).claude/gauntlets' ':(exclude).claude/plans'; git -C "$checkout" ls-files -z --others --exclude-standard -- . ':(exclude).claude/gauntlets' ':(exclude).claude/plans' | xargs -0 -n1 git -C "$checkout" hash-object --; } | git hash-object --stdin`. A `fatal:` line naming the path means `checkout` is wrong: correct it and run the command again. A `fatal:` from `hash-object` naming a file is an untracked entry git cannot hash; it prints on both runs, and the fingerprint stands.
> 2. Make the worktree outside the checkout: `checkout=<absolute path>; scratch="$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-experiment.XXXXXX")"; echo "$scratch"; git -C "$checkout" worktree add --detach "$scratch/tree" HEAD`. Keep the path it printed. Copy into the worktree the ignored files the project needs to boot. Link a dependency directory only when a test run does not write to it, and never a log, cache, or coverage directory: a write through a link lands in the checkout. The worktree holds `HEAD`: when a file you are testing differs in the checkout, say so in the finding.
> 3. Run the test there unchanged. It must pass. If it does not, the tests cannot run in this worktree: skip to step 6 and report the finding as `unverified:`.
> 4. Make the one change the claim is about, in the file under `$scratch/tree`: remove or alter the argument, line, or condition the test's description says it covers, and nothing else. A test that fails when something else breaks says nothing about that claim. Every edit and every command in an experiment names that absolute path: a relative path lands in the checkout. Run only the test file that covers the changed line.
> 5. Read the result. The test depends on the code only when the test cases in question fail on their assertions. A load error, a setup error, or a failure somewhere else settles nothing: report `unverified:`.
> 6. `checkout=<absolute path>; scratch=<the path step 2 printed>; git -C "$checkout" worktree remove --force "$scratch/tree"`, delete the scratch directory, and run step 1's command again. The two fingerprints must match; if they do not, say so in the first line of your report.
>
> Run one test file at a time, never two runs at once.

The report-only ending:

> **Your lane does not run experiments.** When a finding rests on a claim only a run can settle, report it with `unverified:` in front, under the severity it would have if confirmed, and name the experiment that would settle it: what to break, which test file to run, and what a failure would show. Never state it as settled, and never touch a file to find out.

Which prompt carries which part:

| Dispatch                                                                 | Block                                 |
|--------------------------------------------------------------------------|---------------------------------------|
| `rspec-quality`                                                          | Both paragraphs, experiments ending   |
| The Phase 4 agent, on both of its passes                                 | Both paragraphs, experiments ending   |
| Every other Phase 1 agent                                                | Both paragraphs, report-only ending   |
| Phase 5's `prose` and `prose-defaults` lanes                             | The first paragraph only              |

**Only one agent holding the experiments ending runs at a time.** Worktrees of one checkout may share its test database, so two experiment runs can collide. Each dispatch above sends at most one such agent. The main agent starts no gate or coverage run while such an agent is running.

### The main agent's experiments

**The main agent runs its own experiments by the experiments ending's steps 1 to 6, in a throwaway worktree whenever one can run the test.** An experiment is a change made only to be discarded: breaking a line to see whether a test fails. That covers step 2 of Phase 3's sort, any other such check in the sort, and light mode's inline audits. A fix that will be committed is not an experiment, and its failing test is written in the working tree as "When Phase 3 fixes" says. Run experiments one at a time, with no gate or coverage run in flight and no agent holding the experiments ending running, and with nothing uncommitted in the tree apart from the bookkeeping files "When the suite gate runs" names, so `HEAD` holds what is being tested. Where a step tells a sub-agent what to report, the main agent acts instead: step 3's `unverified:` means there is no isolated run, and the fallback below applies; step 5's means the experiment settled nothing, and the finding goes to `[ask]`; differing fingerprints mean the stop in "Watching the tree".

**There is no isolated run in the two cases the ending names: the project's tests run inside a container, or the unchanged run (the ending's step 3) does not pass.** A container that mounts the checkout cannot reach a worktree elsewhere on disk. A sub-agent then reports `unverified:` and writes nothing. The main agent has one fallback:

**In the working tree, and only the main agent.** Take the fingerprint from the ending's step 1, make the change, run the test, restore every changed file to exactly its prior content, and take the fingerprint again before anything else runs. The two must match; when they do not, the stop in "Watching the tree" applies. "When the suite gate runs" says why the gate's evidence then still stands.

**Never borrow another checkout of the project for an experiment, even one the developer says is free.** Switching its branch overwrites files its own branch ignores and abandons a merge in progress, and `git status` there shows neither loss, before or after.

An experiment that cannot run either way, or that uncommitted work in the tree rules out, settles nothing, and its finding goes to `[ask]` (see "When Phase 3 fixes").

### Watching the tree

**The main agent fingerprints the checkout itself, around every dispatch and around `/code-review`.** Take the fingerprint (the experiments ending's step 1), and note `git rev-parse HEAD` and the branch beside it, before `/code-review` runs and before each dispatch of sub-agents. Take it again when `/code-review` returns and when the last agent of a dispatch has returned. Change nothing in the tree in between apart from the bookkeeping files. A check that waits for an agent to finish and report on itself misses the agent that was interrupted.

**When the two differ, or a report or one of the main agent's own experiments says its fingerprints differ, the whole run stops: no fix, commit, gate run, or further dispatch until the developer answers.** Find what changed with `git status`, `git diff HEAD`, the noted `HEAD` and branch against the current ones, and `git reflog -5`. A change the main agent made itself is not a mismatch, and an edit `/code-review` made takes Phase 1's path: commit it and snapshot the diff again. Anything else is a change nobody chose. Leave it in place, treat the gate's evidence as stale, append `Tree changed: <which dispatch or agent>; waiting on the developer` to the record file, and tell the developer what changed. When they answer, append `Tree change answer: <what they said>` and go on from there. A resumed run that finds a `Tree changed:` line with no `Tree change answer:` line after it asks again before doing anything else.

**Remove experiment worktrees left behind: when an agent holding the experiments ending returns, when a run resumes, and before every batch.** With no experiment of the main agent's own in progress, for each path `git worktree list --porcelain` names that contains `gauntlet-experiment.` and whose `HEAD` line names a commit `git rev-list main..HEAD` lists (`main` standing for the base branch, as in every command here), run `git worktree remove --force <path>` and delete its scratch directory, then `git worktree prune`. A worktree at any other commit belongs to another run: leave it. If `rev-list` prints `fatal:`, no match is established: remove nothing and say so. The commit match is wrong at two edges. On a branch stacked on another it also matches a worktree at the lower branch's tip, so skip the sweep while a gauntlet may be running on that branch. And a worktree made at a tip that was later amended no longer matches, and stays until someone deletes it.

---

## Phase 0 -- Pre-flight and scope

### Step 1 -- Confirm preconditions

Before starting, verify:

1. **We're on a feature branch.** Not `main` / `master`. Run `git branch --show-current`.
2. **The branch has changes vs main.** Run `git diff main...HEAD --stat`. If the diff is empty, ask the user what they actually want to gauntlet.
3. **Specs and lint already pass.** Decided by "When the suite gate runs" below, not here. That subsection is the one home of the decision, and it governs the Phase 3 tail's run by the same list.
4. **Working tree is clean, or close to it.** Uncommitted scratch changes muddle the diff. Ask the user to stash or commit first.

Settle preconditions 1, 2, and 4 before entering the gate list, so a ten-minute suite is never spent on a tree the developer is about to stash. If any of the three is off, surface it and pause -- don't push forward on a broken assumption. Those three stay asks because their remedies are the user's to choose: what to gauntlet instead when the diff is empty, whether to stash or commit a dirty tree. Precondition 3's remedy is mechanical -- the gate either has a result already or can produce one -- so it is decided rather than asked, and a run that lands on branch 1 or branch 4 of that list stops or ends there on its own terms.

**Non-git version control:** the commands throughout this skill assume git. If the user works in another VCS (e.g. Jujutsu colocated with git), ask them for the change range ("which revisions are the current work?") and translate the `git diff main...HEAD` commands to that tool's equivalents -- the phases themselves don't change. Don't make the user volunteer this; ask when the working-copy state looks unfamiliar.

**Cost expectations:** a full run is deliberately thorough and correspondingly token-hungry -- /code-review plus four parallel audits, a Phase 4 agent, and two prose lanes can consume a noticeable slice of a subscription session's budget. Before starting Phase 1, tell the user the planned agent count so they can trim (Step 3), choose light mode, or exclude Phase 4 -- an opt-out given any time before the Phase 3 tail is honored, and this is the natural moment for it. Say that Phase 4 runs on every diff, a small one included, unless they opt out, that Phase 3 fixes clear-cut findings without stopping, and that "let me triage" keeps the pick-first pause instead. These choices are the run's cost levers; "When Phase 3 fixes" says why none applies once findings exist.

### When the suite gate runs

The gauntlet decides the project's lint+test gate at three points: Phase 0 Step 1, to establish the branch is green before auditing it; the Phase 3 tail, to establish the fixes did not break it; and again after any Phase 4 fix, or any fix made from the batch's answers, which re-enters as the tail. **All three are decided here, by this one list.** Step 1's precondition 3, the standing pre-approval, and the Phase 3 tail defer to it rather than restating any of it. Step 4's patch coverage is not a fourth gate run: it reads the facts this list records, and when they show no usable coverage artifact it defers to the tail rather than running a coverage suite of its own in Phase 0.

**Evidence, and when it goes stale.** Evidence is either a gate result -- a run that reported pass or fail -- or a statement the developer volunteered, in this session and about this branch, that specs and lint pass. The skill's own premise that specs and lint pass is not that statement: it describes when to reach for the gauntlet, not a claim about the tree in front of you, so invoking the gauntlet is never itself the evidence. Both kinds are evidence about *the tree as it stood when they were obtained*, and both go stale by the same test, whichever branch is reading them.

A piece of evidence holds until any file in the working tree is added, changed, or deleted -- tracked or not, staged or not, matching what the targeted-specs skill counts toward scope. Files the project ignores never count: a gate run writes coverage artifacts, logs, and scratch output as it goes, and counting those would make every result stale the instant it was produced. Four things are not changes for this purpose: committing content that has already been tested; a history rewrite that changed only commit messages, proven by an empty `git diff <old> <new>`; an experiment's edit in the working tree (the fallback in "The main agent's experiments") that was restored to exactly its prior content before anything else ran; and writing the bookkeeping files this skill and the plan-issue skill maintain (the record file under `.claude/gauntlets/`, a plan file under `.claude/plans/`), which no suite exercises. Judge that by whether a suite or a project check could read the file, never by its extension -- in a repository whose deliverable is prose, a shipped markdown file is production code.

Evidence from another session, or from a sibling worktree, is not evidence here until it has been re-checked against the current tree by that same test. An experiment's throwaway worktree sits outside the checkout and changes no file in it, so it leaves the evidence standing.

**Where to read it.** At Phase 0 Step 1 the evidence is what this session has seen. At the Phase 3 tail and afterwards, read it from the record file's header rather than from memory -- Phase 1 is the run's most compaction-prone stretch, and the header is written precisely so the decision survives it.

**How to announce.** Evaluate the branch fully *before* announcing it: the searches and mode checks a branch's condition depends on all happen first, and only the announcement has to precede the action. Then announce in a sentence of its own, in one of these forms, and **substitute every `<...>` -- a placeholder that reaches the transcript verbatim is a bug, not an announcement**:

    Suite gate: stop (red evidence: <the failing run and what it reported>)
    Suite gate: proceeding past red at the user's direction (<the failing run and what it reported>)
    Suite gate: satisfied (green evidence: <the run this session observed, or the developer's statement and when it was given>)
    Suite gate: running (<full|targeted>; <no evidence|escalated: the targeted verdict established nothing>)
    Suite gate: cannot run (<no runner found|user declined the run>)
    Suite gate: unestablished, continuing at the user's direction (declined the run)
    Suite gate: could not complete (<what the runner reported>)

**What ending means depends on which of the three call sites entered the list.** At Phase 0 Step 1 it is literal: nothing has happened yet, so the gauntlet ends and the developer starts it again once the branch is green or a gate exists. **At the Phase 3 tail, and at the re-entry after a Phase 4 fix or a fix from the batch's answers, branch 1 and branch 4 end the gate, never the run.** The tail still owes this gauntlet a Phase 4 decision and a Phase 5 decision, and a run that reaches Phase 1 and ends without either is a bug by the rules in "When Phase 4 runs" and "When Phase 5 runs". So there: announce as written, record the gate's state in the record file's header, skip the patch-coverage re-check that would have nothing to read (a deferred one included), and continue to the tail's remaining steps. Say plainly in the closing message that the post-fix gate did not pass or did not run, so "ready for human review" cannot be read as "verified green".

Then work the list top to bottom and act on the first branch that matches.

1. **Red evidence in hand -- stop.** A gate result on this tree that failed, whoever obtained it, subject to the staleness test above: a failure the Phase 3 fixes have since invalidated is not evidence, and the list is re-entered without it. Announce `Suite gate: stop`, and stop: the gauntlet is a *quality* pass, not a *rescue* pass, and a red branch gets fixed first, separately. This branch is ordered ahead of branch 2 so a red result cannot be laundered into a green one -- branch 2 accepts a statement the developer volunteers, and "gauntlet it anyway" is such a statement. Accepting a red suite is a call only the developer gets to make, so honor an explicit one: announce the `proceeding past red` form instead, so a transcript never reads as stopped when the run continued, and record **both halves** in the record file's header -- the failure and the waiver, as in `gate: failed; user override: proceed`. Recording only the failure loses the waiver by construction: the tail is required to read the header rather than memory, so a header holding a bare failure sends the tail straight back to this branch to stop on a failure the developer already waived. Before stopping here, check the header for a recorded override covering this same failure; where one stands, this branch does not fire.
2. **Green evidence in hand -- satisfied, run nothing.** Announce `Suite gate: satisfied`, naming in the parenthetical which kind of evidence it was.

   A targeted verdict is evidence only where the project declares Targeted Spec Verification Mode, and only on the terms the targeted-specs skill sets: read that skill's opening boundaries, which say when a subset may stand in for a caller at all, together with its verdict contract, which says what a given verdict establishes. Do not reinterpret either here. What it does not establish as green is not evidence, and falls through to branch 3.
3. **No evidence, and the gate can run -- announce it, run it, then re-enter this list with the result.** Announce `Suite gate: running` and run it in the same message, without waiting for permission: the standing pre-approval covers this run, and waiting for an acknowledgement that may never come is the stall this list exists to remove. Say `escalated` in the parenthetical when a targeted verdict sent the run here, so two attempts on one branch are told apart.

   Which gate: the targeted-specs skill (bundled in this plugin) where the project declares the mode, since that skill confirms the declaration itself and ends with a verdict line; the project's full lint+test gate otherwise.

   **A targeted verdict that left the precondition unestablished goes to the full gate, however it arrived** -- as a fall-through from branch 2, or as this branch's own result. A second targeted run selects from the same diff and returns the same verdict, which is a loop.

   When the run finishes, state its facts on their own line before doing anything else, so they are greppable later and survive a compaction:

       Suite gate result: <full|targeted>; <passed|failed|escalated>; coverage <on|off>; resultset <deleted first|not deleted>; previous coverage <figure|none>; log <path>

   `escalated` is for a targeted attempt that ended ESCALATED rather than reporting pass or fail. Write that line before escalating, so the header shows a targeted run was tried and abandoned; the full gate that follows writes its own.

   Then take the result back to the top of this list, where a pass lands on branch 2 and a failure on branch 1.
4. **The gate cannot run -- announce it and end.** Only two things put a run here, and both are evidence you can state: no runner could be found, or the developer has said not to run it. "No runner" means all five of these came back empty -- a suite-runner skill at any level, the project's CLAUDE.md or rules files, a Rakefile default task, `package.json` scripts, and the test job in the project's continuous-integration config. Four of the five are checkable with a command; the first is not -- it is whatever suite-runner skills this session can actually see -- so say which you checked and how. Anything short of that is branch 3; an unverified hunch that the gate is unrunnable is not an entry form.

   Announce `Suite gate: cannot run`, say what would unblock it, and end. **Do not make this turn on whether a user is watching.** A session has no reliable test for its own attendance, so a rule that asks when someone is present and ends otherwise fires its asking branch precisely when a session wrongly believes it can tell -- the one case where it is wrong. Ending and naming the blocker serves both worlds: a developer who is watching reads it as the question it is and acts at once, and a run nobody is watching leaves the reason in the transcript rather than waiting for an answer that will never come.

   One exception, for the `user declined the run` condition only: the developer who declines the gate has not declined the audits. Announce the `unestablished, continuing` form, record it in the header, and continue the run from wherever the gate was entered -- the run goes on without the precondition, exactly as branch 1's override does. `no runner found` at Phase 0 Step 1 ends the run, because nothing has happened yet and the developer can start it again once a gate exists.

**A run that never returns a verdict is not a result.** A gate that dies before reporting pass or fail -- a database container that is down, a missing binstub, a runner that exits non-zero with no summary -- is neither branch 1 nor branch 2, and re-entering at branch 3 would re-run the same broken command forever. Announce `Suite gate: could not complete`, quoting what the runner reported. It then takes branch 4's `no runner found` continuation, not the declined one: at Phase 0 Step 1 the run ends, and at the tail the gate ends while the run continues. The developer did not choose to skip this gate, so nothing here is waived -- the environment is simply not able to answer, and that is worth stopping a not-yet-started pass over. Fixing the environment is the developer's, not this pass's.

**Running the gate.** Invoke a suite-runner skill or script if one is available, at any level -- project, user, or one a plugin ships -- instead of hand-typing the command. Otherwise run the project's own gate command once, teeing all stdout and stderr to a uniquely-named log under /tmp, and answer every follow-up by grepping that log; never re-run a suite just to re-read its output. That is the clean-and-green guidance's capture rule, where a team imports it, and a suite-runner skill or script that already captures this way satisfies it as-is -- do not add a second capture on top.

Where the project measures coverage at all, run the gate **with coverage on**, having first deleted the coverage tool's raw resultset and its lock (for SimpleCov, `coverage/.resultset.json` and `coverage/.resultset.json.lock`), so Step 4 can reuse the artifacts instead of paying for a second run. Before the Phase 0 run starts, note the overall figure in the tool's last-run summary (SimpleCov's `coverage/.last_run.json`) if one exists, and put it in the run's `Suite gate result:` line: the run rewrites the file, and Step 4's artifact check can use the earlier figure only when it was read first and survives in the record file. Step 4 explains why a resultset from a run not started that way cannot be trusted, and why a gate task that chains several suites may still leave no usable artifact. On a project with no coverage tooling this paragraph does not apply, and Step 4 says so too.

**What to record.** The Phase 0 decision is made at Step 1, one step before the record file exists, so carry the branch and the `Suite gate result:` facts to Step 2, which says what the header holds. The tail's decision is appended to that header when it is made. Step 2 says which facts the header holds and why; do not restate the list here.

### Step 2 -- Snapshot the scope

Capture once, near the top of the run, and refer back to it:

```bash
git diff main...HEAD --stat
git diff main...HEAD --name-only
git diff main...HEAD
```

Note the categories present: Ruby code, specs, JS, SCSS, migrations, Gemfile / Gemfile.lock, config. This drives which Phase 1 agents are worth spawning.

Then create the record file, `.claude/gauntlets/<branch-name>-gauntlet.md`, with a header carrying what the Step 1 suite gate established, any Phase 4 opt-out, and any developer-triage request ("When Phase 3 fixes") the user has already given. Record the gate as facts rather than as a branch label -- which gate ran or what evidence stood in for it, whether it passed, whether coverage was on, whether the run began from a deleted resultset, the log path, and any previous coverage figure noted before the run -- because Step 4's question is not which branch decided the run but whether a trustworthy coverage-bearing run happened against this tree. Step 4 appends its deferral line when it defers patch coverage, since the tail reads that line rather than memory. Phase 2 adds the findings below that header later. It is created this early because Phase 1 is the most compaction-prone stretch of the run, and a fact that lives only in context until then is lost before anything wrote it down. Write the file directly -- do NOT pre-run `mkdir -p .claude/gauntlets` as a precaution; that probe is wasted overhead on every run after the first. Only if the write fails because the directory does not exist (a project that has never run the gauntlet) do you `mkdir -p .claude/gauntlets` once and retry. Phase 2 explains the filename.

### Step 3 -- Decide which Phase 1 agents to spawn

The default set is four: `rspec-quality`, `idioms`, `data-validation`, `security`. Trim based on the scope snapshot:

| Agent             | Skip when ...                                                                          |
|-------------------|----------------------------------------------------------------------------------------|
| `rspec-quality`   | No test files changed: no spec or test, and no fixture or helper one loads.            |
| `idioms`          | Only config / docs / migrations changed (no app code).                                 |
| `data-validation` | No app code, services, controllers, jobs, or migrations changed.                       |
| `security`        | Only test / config changed AND no new routes, policies, params, or external endpoints. |

If the user explicitly asked to skip something ("gauntlet but skip security") or focus on one thing ("just the rspec audit"), honor that.

### Step 4 -- Patch coverage on the added lines

Reviewers and CI (Codecov, etc.) flag **patch coverage**: lines *added by this branch* that no test executes. The Phase 1 audits reason about test *quality*, not line coverage, so an untested new line slips past them -- catch it here mechanically instead of in a review round-trip.

The record file's header holds the gate facts this step reads: in Phase 0, what Step 1 established, with nothing having edited the tree since; at a later re-check, the latest gate facts the header holds. On a project with no coverage tooling at all, this step has nothing to measure: say so and move on, rather than inventing an invocation. Everywhere else, those facts report exactly one of four states.

   - **A run that passed, with coverage on** -- reuse its artifacts, once they pass the artifact check (step 1 below). An artifact that fails it moves the run to the next state.
   - **The gate satisfied from evidence rather than run, a run without coverage, or an artifact that failed the check** -- defer the whole check to the Phase 3 tail, and run no coverage suite here. Getting a usable artifact now would take a run of its own, and the fixes will shift line numbers and invalidate its result, so the tail's run is the one that counts. Append `Patch coverage: deferred to the Phase 3 tail (<reason>)` to the record file's header, naming what left no usable artifact -- no coverage-bearing run, or the check that failed and why -- and put the same line in the Phase 2 list so the check reads as deferred rather than skipped. The tail owes the run; its step 1 says when. That is this state's Phase 0 reading. After Phase 0 there is nothing later to defer to: an artifact that failed the check re-measures as step 1 below says, and a gate that left no coverage-bearing run gets a coverage run there and then, the way tail step 1 runs an owed one.
   - **A run that failed**, which branch 1's override path allows -- neither reuse nor re-run. A failed run's resultset stops at the failure, so every spec that never executed reads as uncovered and intersecting against it manufactures a flood of false findings. Report that patch coverage could not be measured against a red gate.
   - **The gate unestablished because the developer declined it** -- report patch coverage as not measured, exactly as for a red gate. Do not read this as "satisfied from evidence" and run a coverage suite: the developer declined that suite, and the decline covers this step too. Neither of these last two states is a deferral, so neither makes the tail owe a coverage run.

**Every artifact you read must come from a run that started with `coverage/.resultset.json` (and its `.lock`) deleted** -- raw results are keyed by a per-process command name, so an entry an earlier session left under a name this run does not reproduce is never overwritten and merges into the union as stale coverage, hiding a genuinely uncovered added line. That applies to the reuse path too, and merging with the age check disabled (below) removes the last thing that would have dropped such an entry: a header that does not say the run began from a deleted resultset is not a promise of a clean start, so unless the deletion is recorded or you performed it yourself, treat the artifact as failing the check, which defers it. Delete those two files specifically rather than all of `coverage/` -- removing `.last_run.json` disables a project's `maximum_coverage_drop` gate, which passes unconditionally when no last run exists. **Read the artifact as soon as the run that wrote it exits, before `/code-review`, any agent, or anything else runs:** a process that boots the application with coverage active writes its own result when it exits, over the one you meant to read. So never start a coverage run in the background alongside Phase 1 to hide its cost -- the deferral exists so that cost is paid once, at the tail. The artifact check is the backstop for processes outside this run, such as another session sharing the container. Subset coverage is not ground truth: one-hop selection can miss a spec that covers an added line transitively, so treat a subset-uncovered added line as a candidate to verify (or defer to CI's full-run patch coverage) rather than an automatic finding. Then check the artifact and intersect added lines with uncovered lines:

1. **Check the artifact before reading any line of it.** A resultset that another process wrote over after the measured suite exited looks like a sound one -- started from a deleted file, one entry, named for the suite you expect -- while its line data describes whatever that process happened to load, so intersecting it reports well-tested lines as uncovered. Compare the merged artifact's overall line figure (step 3 below says how to merge it) with a reference, in this order:
   - **The measured suite's own line-coverage summary in the run's log** -- SimpleCov's `Line Coverage:` line, the Lines row of Istanbul's text summary, `coverage report`'s total. **When the gate task runs more than one command, the reference is the last line summary the measured suite printed before a command outside it starts, never simply the last one in the log -- a per-file loop is many commands of one suite, and its last process's summary is the one:** a later command that boots the application with coverage active writes its own result over the measured suite's and prints its own summary, and the artifact will match that later figure. Within the measured suite's own output, a parallel runner's final merged total is its summary; the figures it prints on the way can rise or fall as files join the union.
   - With no summary in the log, **the previous run's figure** (SimpleCov's `coverage/.last_run.json`), only in Phase 0 and only when it was recorded before the gate run began, because the process that overwrites the resultset rewrites it too. After Phase 0 it is no reference at all: the gauntlet's own single-spec runs rewrite it with a single file's figure. It is not a floor: a branch that adds untested lines lowers the figure a little, so a figure more than ten points below it fails and anything closer counts as cross-checked -- the overwrites this check exists for drop tens of points.
   - With neither, **a floor the project sets** -- SimpleCov's `minimum_coverage`, Jest's `coverageThreshold`, nyc's `check-coverage`, coverage.py's `fail_under`, a CI threshold. A figure below the floor fails; a figure above it is only "not cross-checked", since a floor is not the project's usual band.
   - With none of these, report the figure and say it could not be cross-checked.

   A figure more than a couple of points either side of the log's summary fails: a higher one is another process's result as surely as a lower one, such as a later suite whose entry, under the same command name, replaced the measured suite's. One case makes the log's summary, not the artifact, the unreliable figure: SimpleCov's own merge drops every entry at least `merge_timeout` old, so a SimpleCov run that took at least that long (its log or runner reports the elapsed time) prints a summary low by design. There, skip the log's summary and use the next reference. Read `merge_timeout` from the project's coverage configuration (`.simplecov` or the spec helper), and take 600 seconds when it is absent or not an integer, which SimpleCov ignores; the reading process loads neither, so asking it returns the default. In Targeted Spec Verification Mode a subset run's figure sits far below any whole-project floor by design, so compare it only with its own log summary.

   **A failed check yields no line findings from that artifact.** In Phase 0 it defers the whole check to the tail (the second state above), with the reason in the header. After Phase 0 it re-measures once: run only the measured suite's own command -- the RSpec invocation, say, not a default task that chains it with a JavaScript tier -- from a deleted resultset, and check again; a subset run repeats its subset. A re-measure that also fails the check reports patch coverage as not measured, with the reason, and nothing retries it. Whenever a failed check traces to a gate task that chains suites, in Phase 0 or later, append `Patch coverage: gate task chains suites; measure with <command>` to the record file's header at once. Once the header records that, every later coverage run in this gauntlet goes straight to the measured suite's own command instead of reading the gate's artifact, which would only fail again. Every coverage run after Phase 0 -- the re-measure, these runs, and the tail's owed run -- runs the way the gate runs, with coverage on and from a deleted resultset, and captures its full output to a log as "Running the gate" says, since the log's summary is this check's first reference.
2. **Added lines** -- `git diff main...HEAD --unified=0` (or parse `+` hunks) gives the new-file line numbers per file. Leave out moved lines, such as those of a whole-file layout reorder: they are old code in a new place. A moved line shows in the same diff twice, removed in one place and added in another, so drop an added line only when the same file's diff also removes a line with identical text (ignoring indentation), matching each removed line to one added line at most. A line with no removed twin stays in, so new code is never dropped, whichever order its commits came in; a moved line that was also edited has no twin and stays in too.
3. **Uncovered lines** -- from the coverage run's machine-readable output. **Always read the tool's *merged* artifact, never per-process raw data.** A suite that forks (parallel runners, per-file loops, sharded CI) writes one raw entry per process, and a file that process never loaded is either absent from that entry or, when the tool simulates tracked-but-unloaded files, present as all zeros. Read one entry directly and an entire untouched file looks uncovered.
   - Ruby / SimpleCov -> `coverage/coverage.json` is already merged, but it exists only when the project enables the JSON formatter (SimpleCov adds it only when `CC_TEST_REPORTER_ID` is set), so usually only `coverage/.resultset.json` is on disk -- and that one is raw. Merge it with `SimpleCov::ResultMerger.merge_results`, which takes an explicit path and an `ignore_timeout:` keyword and returns a `SimpleCov::Result` without re-running anything. Take `missed_lines` off the resulting files rather than selecting on a hit count of `0`: `:nocov:`-skipped lines carry a `0` too, and only `missed_lines` excludes them. Two cautions on the reading process. It inherits SimpleCov's own defaults, including autoloading any `.simplecov` found by walking up from the root -- in a project whose `.simplecov` calls `SimpleCov.start`, merely requiring simplecov begins a coverage run that writes its own junk entry at exit, so require `simplecov/no_defaults` (or set `external_at_exit`) when reading. And SimpleCov filters out every file stored outside its root, which defaults to the working directory -- a resultset a container wrote with `/app/...` paths yields an empty file list, so treat "no files at all" as a wrong-root error rather than a clean report.
   - `ignore_timeout` matters: SimpleCov's merge drops, without a warning, entries older than `merge_timeout` (default 600s), so a slow per-file loop loses its earliest processes. **`coverage.json` is subject to that same timeout** -- it is generated through the merge path with no override -- so on a slow suite it can under-report. Reading it directly: hit count `0` is uncovered, `null` is non-executable, and the string `"ignored"` marks a `:nocov:` skip. **Do not sum hit counts across entries by hand.** SimpleCov merges nil-wins (`nil + 0 = nil`), and a simulated entry marks far more lines executable than a real measurement does, so summing reports non-executable lines as uncovered -- on a two-process run of this plugin's own suite, summing claimed 189 uncovered lines for `bin/gh-issue-sync` alone against a true 53.
   - JS / Istanbul -> read the merged artifact, not per-worker output. Jest and Vitest merge their workers themselves; a raw nyc setup writes per-process `.nyc_output/*.json` and needs `nyc report` first. Which files appear depends on the configured reporters -- `lcov.info` and `cobertura-coverage.xml` are each written only when that reporter is enabled -- so check what the project actually emits rather than assuming (`<line number=.. hits="0"/>` / `DA:line,0`). Note JS coverage is usually a **separate** run from the Ruby suite (e.g. an `npm test` invocation with coverage on), and when the diff touches JS it is owed too, or the JS patch stays invisible. Unless the gate run already produced it, it is a run of its own, so in Phase 0 it defers like the second state above, with its own `Patch coverage: JS deferred to the Phase 3 tail` line, and the tail runs it along with anything else owed.
   - Other stacks: `coverage.py` (`coverage combine` first **only** if the run used parallel mode -- it errors when there is nothing to combine, and consumes its inputs unless given `--keep` -- then `coverage json`), `go test -coverprofile`, etc.
4. **Intersect.** Added line numbers the merged artifact reports as uncovered are the uncovered patch. Two matching hazards, both of which fail toward a silent clean result: file paths are relative to different roots in the two inputs (the diff's are relative to the repository root, a coverage artifact's to whatever root the coverage tool used -- these differ whenever the app is not at the repository root, and cobertura/lcov paths may be absolute), and the diff's base branch is whatever this project actually uses, not necessarily `main`. **A changed source file that appears nowhere in the coverage artifact is not "covered" -- it is unmeasured.** That is the normal shape of a brand-new file no test loads, which is the highest-value patch-coverage finding there is; report every added line in it rather than skipping the file. Use the diff's `+` side for line numbers.

Surface each uncovered added line as a **should-fix** coverage finding in the Phase 2 list (`file:line -- added by this branch, no test exercises it`). Beware two traps the categorical agents won't: a *partial* branch (line runs but one side of a conditional never does -- still a gap a reviewer will flag; branch data exists only when the suite ran with branch coverage enabled, and reading it back requires branch coverage enabled in the reading process too, so an empty branch list means "not measured", not "no gaps"), and a new line landing inside a method that had **no** prior coverage (easy to miss because the whole method reads as "unchanged-looking"). If a line is genuinely not worth testing (defensive guard, logging), say so explicitly rather than leaving it unexplained.

The Phase 3 tail decides whether a further coverage run happens, per its step 1, which also owns the run a deferral owes; when one happens, it starts from a deleted resultset like any other, because the fixes have shifted line numbers and results carried over from the pre-fix run describe a file that no longer exists.

### Light mode for small PRs

If the diff is under ~50 lines across fewer than ~5 files, sub-agent dispatch overhead probably isn't worth it. Tell the user, then run the same checks (including `/code-review`) **sequentially in the main agent** without spawning sub-agents. Keep the same Phase 2 / Phase 3 structure (consolidate, then sort and fix, then batch the questions). In light mode the main agent is the auditor, so "The main agent's experiments" governs its audits as it does the sort. Phase 4 is still a dispatched agent (see "When Phase 4 runs"), and Phase 5 still dispatches its two lanes as sub-agents.

---

## Phase 1 -- Finding sources (report-only)

First invoke `/code-review` (the built-in) in the main agent and capture its findings for Phase 2, with the tree fingerprinted before and after it ("Watching the tree"). It is a peer finding source: it reports a findings list and makes no edits and no commits, exactly like the sub-agents below. (If a future version of the built-in applies edits instead, commit those edits, re-snapshot the diff, and redo the Step 4 patch-coverage check before dispatching -- unless Step 4 deferred it, in which case the tail's run already covers those edits.)

Then dispatch the chosen agents **in a single message** so they run concurrently. Fingerprint the tree before the dispatch and when the last agent returns ("Watching the tree"). No gate or coverage run is in flight while `/code-review` or the agents run; Step 4 and "The no-write block" say why. Use `Agent` with `subagent_type: "general-purpose"` unless an agent's brief calls for a different one.

Every sub-agent prompt MUST tell the agent to:

1. Read the relevant CLAUDE.md(s) for project context and rules.
2. Run `git diff main...HEAD` (and `--name-only` / `--stat` as helpful) to see exactly what changed.
3. **Report only, and never write to the working tree.** Fixes happen in Phase 3.
4. Return findings in this exact format:

   ```markdown
   ## Findings

   ### must-fix
   - `path/to/file.rb:42` -- one-line description of the issue. Suggested fix: brief sketch.

   ### should-fix
   - `path/to/file.rb:107` -- ...
   - unverified: `path/to/file_spec.rb:8` -- a claim only a run can settle. Would settle it: what to break, which test file to run, what a failure would show.
   - setup question: `path/to/file_spec.rb:12` -- a setup step that may be doing the code's job, and what it prepares. Only the rspec-quality brief asks for these.

   ### nit
   - `path/to/file.rb:88` -- ...

   ## Considered but ruled out
   - One-line note on anything that looked suspicious but checked out, so the main agent can cross-check it against the other agents' findings.
   ```

5. Stay in lane. The idioms agent doesn't comment on RSpec patterns; the rspec-quality agent doesn't comment on security; etc.

**Under item 3, paste the no-write block word for word ("The no-write block"). Only `rspec-quality` gets the experiments ending; every other audit agent gets the report-only ending.**

The agent-specific briefs below are starting templates. Adjust wording to match the project's stack and conventions. Each says "Report only", which means no change to the checkout; the no-write block says what the lane may run, and it goes into the prompt unadjusted.

### Agent: rspec-quality

> Audit the test files changed on this branch for test quality: specs, tests, and the fixtures and helpers they load, wherever the project keeps them. The RSpec-specific items apply only where the project uses RSpec. Focus areas:
>
> - **False positives**: tests that pass for the wrong reason. Read the `describe` / `context` / `it` strings and verify the test actually exercises the behavior they describe (vs. passing because a stub returned the right value, or because a setup callback happened to satisfy the assertion). **Setup that does the code's job is one of these.** Look for a setup step (a `before` block, a `setup` method, a helper, a fixture script) that prepares state for the code under test, beyond the input it works on: creating a directory the code writes into, building or refreshing a value it caches, running a step it should run itself. Check the steps this branch adds or changes, and the steps a test this branch adds or changes relies on, wherever they sit, an unchanged helper or fixture included; a step only untouched tests use is not a finding. Ask what guarantees that state when the code runs in production, and whether it can have changed since: a step production runs only once, such as an install or setup script, leaves state that goes stale, and counts. This is a judgment you reach by reading: run no experiment for it, and never report it as `unverified:`. It ends one of three ways. When the code under test plainly does the step's work itself, the step is redundant, and that is an ordinary finding. When you find, in the project or its framework, what guarantees the state every time the code runs, a step whose comment names that guarantee is no finding, and one without the comment is an ordinary finding whose fix is the comment; a comment saying the developer confirmed the guarantee counts as found. In every other case, including a comment you cannot check that does not say the developer confirmed it, report the step under should-fix with `setup question:` in front, as a question for the developer and with no suggested fix. Building the input the code works on (records, input files, arguments) is not this, though refreshing or correcting that input afterward is; neither is a stub, a frozen clock, or any other control that isolates the test.
> - **Arrange-Act-Assert discipline**: tests where setup leaks into the `it` block, or where logic moved out of a `before` block ended up *inside* the `it` block. Both are smells.
> - **Single-assertion via `match_array`**: where two paired `expect(...).to include(...)` + `not_to include(...)` calls could be one `match_array`.
> - **Modern RSpec syntax**: prefer `is_expected.to` over the deprecated `should`; prefer `aggregate_failures` over exempting the file from `RSpec/ExampleLength` in `.rubocop_todo.yml`.
> - **Factory opportunities**: 5+ lines of setup that could become a new factory trait, even if used only once, when the trait improves readability.
> - **Mock-heavy tests** that would benefit from real factory objects. Preference order: real factory > `instance_double` > `double` > `nil`.
> - **Hand-rolled validation/association specs**: multi-line specs asserting a validation or association that shoulda-matchers expresses as a one-liner (`it { should validate_presence_of(:email) }`), when the project uses shoulda-matchers.
> - **External HTTP in specs**: new specs whose code path talks to an external service should go through the project's stubbing layer (VCR cassettes / WebMock), never live HTTP. Also flag overly-broad stubs (`stub_request(:any, /./)`-style) that hide request-shape regressions.
> - **Unused `let!` variables** that should be `_`-prefixed.
> - **Coverage gaps from removed or altered specs**: diff the test files against `main` and check whether any deleted or weakened tests left a real coverage gap. If a spec was deleted, was the behavior re-covered elsewhere -- and was the removal intentional?
>
> Read `CLAUDE.md` first and honor any spec-writing conventions it declares. Run `git diff main...HEAD --name-only` to find the changed test files, whatever directory they are in, and `git diff main...HEAD -- <those files>` to see what changed in them. Report only.

### Agent: idioms

> Audit this branch for Rails / ActiveRecord / Capybara / CI idioms that `/code-review` is least likely to catch. /code-review already covers general readability and duplication; you focus on idioms specific to *this* stack and *this* project's preferences. RSpec structure and quality belong to the rspec-quality agent -- do not comment on them here. Focus areas:
>
> - **Scopes vs. inline queries.** A query outside the queried model's class built from join keys or SQL rather than domain words -- a subquery on join keys (`where(id: other.select(:some_id))`), a join used to filter (`joins` or `left_joins` with a condition on the joined table), an `or` of conditions, or a SQL string condition (`where("...")`) -- belongs in a named scope on the model (a class method when a branch could return `nil`, since a scope turns `nil` into `all`; a query object when its subject is several models' rows or it takes many parameters), even with a single caller: the name makes the call site read as the question it answers ("records shared with this user"). Flag it in policies, controllers, views, jobs, and services, and propose the scope. **Flag only queries on lines this branch adds or changes; a query that already existed on `main` is not a finding, even when the diff shows it as context.** The authorization decision (an admin check) stays in the policy, not in the scope. A comment explaining what an inline query selects is the same finding: the scope's name replaces the comment. **Never flag a hash-condition `where` on the model's own columns, such as `where(owner: user, status: :draft)`, however many keys it has**; `where.not` and ranges count as hash conditions, but an `or` of them is still an `or`, and a hash condition on a joined table is still a join. Eager loading against N+1 queries (`includes`, `preload`, `eager_load` with no condition on the joined table) is not a finding here. Never propose replacing a framework's documented call shape such as Pundit's `policy_scope(Model).find(params[:id])`.
> - **File layout (Ruby).** A Ruby class reads top to bottom: `include` and `extend`, constants, macros, public class methods, `initialize`, public methods, `protected` methods, then one `private` keyword with every private method beneath it, and each helper defined below the first method that calls it. **Check first whether lint already enforces the layout:** run `bundle exec rubocop --show-cops Layout/ClassStructure,Style/AccessModifierDeclarations,Lint/IneffectiveAccessModifier` whenever the bundle includes RuboCop (`bundle exec rubocop -V` succeeds, as it does when a gem such as `rubocop-rails-omakase` or `standard` pulls it in), and plain `rubocop` otherwise, so the answer comes from the version and plugins the project pins; run it from the changed file's directory, since a nested `.rubocop.yml` there overrides the root one. When it shows all three cops with `Enabled: true`, `AllowModifiersOnSymbols: false`, and `EnforcedStyle: group`, the file matches none of their `Exclude` entries (printed as absolute paths, sometimes as globs), and `rubocop --force-exclusion <file>` reports 1 file inspected (an `AllCops: Exclude` makes it 0), lint already covers the order and the access modifiers, so check only helper order (next), a `private_class_method :name` (no cop flags it), and a method the branch adds that nothing outside the class calls but that is left public. **Helper order is never covered by lint, so always check it: for each private method, find the first method in the class that calls it; the private method must be defined below that caller. A helper defined above its first caller is a finding, wherever both sit, unless the two call each other, which may stand in either order; a helper below its first caller is in place even when a later method calls it too.** Otherwise (no RuboCop, or any part of that test not met: a cop not `Enabled: true`, a setting with another value, or the file excluded or not inspected) also flag a private method among the public ones, a trailing `private :name` line, an inline `private def` (unless the project states that style, below), a `public` keyword that reopens the public section, and a `private` above `def self.name`, which leaves that class method public (a private class method belongs in `class << self` with its own `private` section, not behind `private_class_method :name`). **Code the branch adds or moves is a finding to fix by moving it into place. A layout that was already wrong on `main` in a file the branch touched is one finding for the whole file, a nit saying it predates the branch and proposing a reorder in a commit that only moves code; report it under nit, never as separate findings and never only under "Considered but ruled out".** Never propose making an existing public method, or a framework entry point (a controller action, a job's `perform`, a policy predicate), private: its callers may be outside the file. A project's stated style wins, in its CLAUDE.md or its own `.rubocop.yml` (such as `EnforcedStyle: inline` on `Style/AccessModifierDeclarations`); the same setting in a generated `.rubocop_todo.yml` is RuboCop's, not the project's. Spec files are out of scope.
> - **Associations vs. IDs.** Code passing `foo_id` instead of `foo`, or querying through ID where the association is already loaded or available.
> - **Callbacks under suspicion.** Flag any newly-added `before_save` / `after_create` / etc. and ask whether overriding a method, using a service object, or handling it explicitly in the controller would be clearer. Check CLAUDE.md for the project's stance on callbacks. Do not flag callbacks that already existed on `main`.
> - **N+1 queries.** New queries or loops over associations missing `includes` / `preload` / `eager_load`. If the project runs Bullet, check its test-log output for the changed code paths.
> - **Rails built-ins reinvented.** `counter_cache`, `enum`, `delegate`, `alias_attribute`, `has_secure_password`, `dependent: ...`, and similar -- if the branch hand-rolls something Rails offers, flag it.
> - **Symbols over enum hash literals.** Enum values should be set and queried via symbols (`status: :active`), not raw integers or the enum hash, outside the rare raw-SQL case.
> - **Capybara idioms**: `have_current_path` with a regex over hard-coded strings when pagination or params can vary; `js: true` for any UI-behavior test when the project prioritizes integration tests.
>
> Read `CLAUDE.md` first. Run `git diff main...HEAD` to scope. Report only.

### Agent: data-validation

> Audit this branch for ActiveRecord methods that bypass model validations, and for database constraint vs. validation alignment. Focus on the diff, not the entire codebase.
>
> **Why this lane exists:** Rails' validations and callbacks only run on the normal save path, and ActiveRecord offers **more than a dozen** write methods that skip one or both -- with no naming convention separating the safe calls from the bypassing ones. `update` validates but `update_attribute` doesn't; `toggle!`'s bang means "saves immediately, skipping validation" while `update!`'s bang means the opposite. That makes this an extremely easy error for careful people to commit, which is why it gets a dedicated audit lane. A single bypassing call can plant rows the rest of the app assumes are impossible, and the failure surfaces much later, far from the write that caused it. The DB-constraint checks below are the same risk from the other side: a `null: false` or foreign key without a matching model validation doesn't prevent bad input, it just converts it from a friendly form error into a 500 at write time. Judge each finding by that lens: how far from this line would the damage surface, and who hits it first -- a validation message, an exception tracker, or a customer?
>
> **High-priority bypass methods to grep for in the diff:**
> - `update_column`, `update_columns`, `update_all`
> - `insert_all`, `upsert_all`
> - `increment_counter`, `decrement_counter`, `update_counters`
> - `toggle!`, `touch`, `delete_all`
> - Raw SQL: `connection.execute`, `ActiveRecord::Base.connection.exec_query`
>
> **For each instance:**
> 1. File path, line number, and short snippet for context.
> 2. Risk assessment: HIGH / MEDIUM / LOW. Controllers handling user input = HIGH. Admin / internal tools = MEDIUM. Migrations, seeds, one-shot data repair = LOW. Background jobs processing external data = MEDIUM.
> 3. Intent analysis: does this look intentional (explanatory comment, descriptive method name, batch-performance reason)?
> 4. Safer alternative if the bypass looks unintentional.
>
> **Also audit constraint/validation alignment** (defer to CLAUDE.md where the project declares its own rules):
> - New migration columns with `null: false` -- is there a corresponding model `validates :col, presence: true` (or `inclusion: { in: [true, false] }` for booleans)? Is the form input `required: true`?
> - New `foreign_key: true` references -- does the parent's `has_many` / `has_one` declare an explicit `dependent: ...` strategy?
> - New `_cents` columns -- does the model use `monetize :col` from money-rails rather than plain numericality validations?
> - New integer / float / decimal columns -- are bounds enforced (numericality validations + HTML5 min/max on inputs)?
> - If the project uses strong_migrations, flag any `safety_assured` block added by this branch without a stated reason -- it is the validation-bypass pattern in migration form.
>
> Read `CLAUDE.md` first. Report only.

### Agent: security

> Audit this branch for security gaps introduced by the change.
>
> **Step 1**: invoke the built-in `/security-review` skill, which already runs a general security review of pending changes. Incorporate its findings into your report.
>
> **Step 2**: go beyond it with branch-specific checks the general reviewer is less likely to catch:
>
> - **Authorization.** For each new or modified controller action, is there a Pundit policy method (or the project's authorization equivalent, e.g. a CanCanCan ability)? Is it actually invoked (`authorize @record` / `authorize!`)? Are roles that should not have access (e.g. a customer-level role) excluded by the policy?
> - **New routes** -- does each new route fall under the right scope (admin? authenticated?)? Is anything accidentally public? If the project uses rack-attack, should a new public or unauthenticated endpoint be rate-limited?
> - **Strong params.** Are any new attributes accepted via mass assignment that should not be (status fields, ownership IDs, role flags)?
> - **Search allowlists.** New Ransack (or similar user-driven search) usage needs explicit attribute/association allowlists -- an unallowlisted search surface lets users filter on fields they should never see.
> - **Cross-tenant data leaks.** If the change introduces a new query, can a user of one tenant, account, or organization hit it for another's data?
> - **Authentication bypass.** Any new endpoints that should require login but don't?
>
> Read `CLAUDE.md` first. Report only. The main agent sorts and acts on every finding, so report them all.

---

## Phase 2 -- Consolidate findings

When all sub-agents return, the main agent assembles **one** punch list:

0. **Fold in the /code-review findings and the Step 4 patch-coverage findings** alongside the sub-agent findings before deduping -- they belong in the same list and the same sorting. When Step 4 deferred patch coverage, its deferral line goes in the list instead, so the check reads as deferred rather than missing. That line is a note, not a finding: it sits above the severity headings, Phase 3 does not sort or tag it, and the tail settles it. Map /code-review's findings onto the severity bands by their stated severity or impact; a finding that carries neither clearly defaults to should-fix.
1. **Dedupe -- the only thing Phase 2 drops.** Same `file:line` flagged by multiple agents = one entry, listing both reasons. Whether a finding is in scope, or right at all, is Phase 3's call, so every other entry reaches it.
2. **Rank by severity first, then by file.** `must-fix` block at the top, then `should-fix`, then `nit`.
3. **Cross-reference.** When one agent's "considered but ruled out" covers another agent's finding, note both on the entry rather than dropping either: Phase 3 settles the disagreement with evidence (see "When Phase 3 fixes"). (/code-review reports findings only -- it has no "Considered but ruled out" section to cross-reference.)
4. **Persist.** Add the consolidated list to the record file Step 2 created (`.claude/gauntlets/<branch-name>-gauntlet.md`), below its header, so it survives a `/clear`, context compaction, or session resume. Write it even when the list is empty -- a zero-findings run still reaches the Phase 3 tail, and its Phase 4 decision line lands in this file. The `-gauntlet` suffix is mandatory: plan files under `.claude/plans/` often share the same slug-based basenames, and the harness permission prompt shows only the basename, so the suffix is what lets the user tell a gauntlet write from a plan write at approval time. This is a local working file -- suggest the user gitignore `.claude/gauntlets/` if it isn't already.
5. **Count, and keep going.** Note the counts ("12 findings: 2 must-fix, 6 should-fix, 4 nit") for the batch, and go straight on to Phase 3 in the same turn. The list reaches the user in the batch at the end of the run; a message showing it on its own would end the turn and stall the run here.

---

## Phase 3 -- Sort, fix, and batch the questions

### When Phase 3 fixes

**The default is fix. A finding leaves the fix bucket only on one of the grounds below; severity, time, and tokens are never grounds.** A nit is fixed like a must-fix: many developers are exacting about idioms and quality, and a nit in lines the branch already touches is cheaper now than it will ever be again. What a run costs is settled in Phase 0, before any finding exists, and is never a reason to leave one unfixed. This subsection is the one home of what happens to a finding; other sections point here.

**Sort.** **Every finding ends in exactly one of five buckets, each written in the record file, and each is checked against the code before it is sorted.** Read the lines the finding names and the lines its claim rests on: an "unused" method gets a search for its callers, a "bypass" gets the line that bypasses. A finding that looks clear on paper is only clear once that check agrees with it. A check that changes a file to see what happens is an experiment, and "The main agent's experiments" governs it wherever in the sort it happens. Then take the finding down this list and put it in the bucket of the first ground that matches, writing the ground next to it. A bucket with its reason is one the developer can overrule in a sentence; a bare one costs a round trip. One finding skips steps 2 to 4: a `setup question:` that step 1 does not disprove is step 5's, wherever the setup step sits, because no experiment answers it and a test this branch adds or changes passes because of the step.

1. **Disproved -> `[disproved: <evidence>]`.** The code or a test shows the finding is wrong. State the evidence (`called at app/jobs/x.rb:19`). "Looks pre-existing" and "seems minor" are not disproof, and neither is another audit's "considered but ruled out" note: a finding one audit reports and another ruled out is step 2's case.
2. **Audits disagree, or a finding is `unverified:` -> test, then sort again.** When one audit's finding contradicts another's "considered but ruled out", two findings contradict each other, or an agent reported a finding as `unverified:`, never pick the more confident report and never sort an unverified claim as though it were settled. Search for callers first: a finding step 3 would drop on that search alone needs no experiment and goes on to step 3. Settle it with evidence: read the line the claim depends on, or run a cheap experiment -- usually a mutation, breaking the thing on purpose to see whether a test fails. "The main agent's experiments" says where the experiment runs. Step 2 has no bucket of its own: evidence against the finding makes it `[disproved: <evidence>]`, evidence for it sends it on down the list, and evidence that settles nothing makes it `[ask]`.
3. **The fix is for a case that cannot happen yet -> `[dropped: <reason>]`.** The finding asks for code, a test, or text for a case that cannot occur until someone changes code: a caller in the repository would have to start passing the input, and none does. That holds whether or not the code already handles the case, so a test for an option no caller passes is this step's. It holds wherever the file sits, too: this step comes before the next one, and a finding of this kind in a file outside the branch is dropped, never drafted as a follow-up. Search for the callers before deciding, and write what the search showed as the reason (`no caller passes nil: three call sites, each passes a record`). **A case that can arrive with no code change is never dropped:** a request parameter, a user's file, a command-line argument, the environment the program runs in, a third party's payload, a second invocation. Its entry point exists, so it occurs, and a missing authorization check, a missing validation, or a boundary an outside input reaches goes on down the list. So does a bug confirmed by a failing test that drives the code the way an outside input or an existing caller does; a test that passes an input no caller passes confirms nothing here. Text takes the same test: a fix that changes what the text says about a case it already addresses goes on down the list, and one that makes it address a further case is dropped, unless a reader following the text as written would do the wrong thing in a case shown to occur. A fix that only removes or rewords lines the branch wrote, or restructures them without handling a further case (an extracted scope, a factory trait), is not this step's. A dropped finding stays in the record file under its tag and is counted in the batch; it is never asked about and never drafted as a follow-up. A fix ships with less review than the branch got, so one for a case that cannot occur costs more than it gives.
4. **Outside the branch -> `[follow-up]`.** The finding sits in a file that is not in Step 2's `--name-only` list and the branch did not introduce it, or it is a refactor of code that predates the branch and would outgrow it -- except a whole-file layout reorder in a file the branch touched, which step 5 owns at any size. That list is frozen when Step 2 captures it: a fix that edits another file does not bring that file's findings in. Nits in untouched files go into **one** grouped draft, never a draft each. A bug the branch introduced is never follow-up, wherever it shows -- a PR owns the bugs it introduces.
5. **A judgment the developer owns -> `[ask]`.** Only these: **a design or architecture tradeoff**; **a behavior change a user or stakeholder would notice** beyond what the branch set out to do, such as a changed URL or a different email -- fixing a bug so the branch does what it evidently set out to do is not one; **a new validation or constraint on an existing column**, which rows already in the database may fail; **a performance change** that needs measuring first; **a fix the size rule below sends here**; **a whole-file reorder of a layout that predates the branch**, at any size: every moved line counts toward the PR size, and the developer may want the reorder in its own commit or pull request; **a `setup question:` finding**, where only the developer knows what guarantees the state in production; **an experiment that settled nothing**.
6. **Everything else -> `[fix]`.**

Findings that are one gap seen from two places -- a nil the mailer cannot handle, and the missing validation that lets the nil in -- are sorted together: the same bucket, or an entry saying how the fix to one settles the other.

**Size.** Measure the PR the way the tail's step 2 does, when sorting and again after each fix, and state the latest figure in the batch. A bug the branch introduced is always fixed, whatever the size, and reverting a fix this run made, or amending one that no other branch holds (the shared-commit check in "Sorting and fixing Phase 5's findings"), is always allowed. Any other fix that carries the measured size past 400 is reverted and re-tagged `[ask]`, and once the size is past 400 -- from the start, or after the fixes so far -- every remaining fix of that kind goes to `[ask]` as one grouped question naming the size, because a PR past 400 lines should almost always be split. Measure the fix once it is made rather than estimating it beforehand: a running total of guesses is a number nobody checked.

**Record, then fix.** Before fixing anything, tag each Phase 2 entry in place in the record file, under its severity heading. These are the tag forms, and this is their one definition:

- `- [ ] [fix] <entry> -- <ground>`, checked when fixed as `- [x] [fix] <entry> -- <ground> (<short sha>)`.
- `- [x] [disproved: <evidence>] <entry>`, checked at sort time: nothing is left to do.
- `- [x] [dropped: <reason>] <entry>`, checked at sort time for the same reason.
- `- [ ] [follow-up] <entry> -- <ground>`, checked once its draft carries `filed as <ID>`.
- `- [ ] [ask] <entry> -- <ground>`. An accepted ask is re-tagged `[fix]`; a declined one gains `(declined)` and stays unchecked; a `setup question:` is re-tagged as "When the answers come" below says.

Then fix the `[fix]` bucket without asking:

1. **TDD where applicable.** A behavior fix gets a failing spec first -- write it, watch it fail, then fix and watch it pass. A spec that cannot be made to fail is evidence: remove it, and re-tag the finding `[disproved: <what the attempt showed>]`, or `[ask]` when the attempt was inconclusive. A pure-refactor fix needs no new spec. Whatever the fix, run the test file nearest the code it changed, where one exists, and commit only once its examples pass; a coverage floor that one file's run cannot meet is not a failure.
2. **One logical change per commit**, its message about the change itself, never about the gauntlet, and free of the prose defaults Phase 5's `prose-defaults` brief lists, wherever that brief applies to the project.
3. **A fix that outgrows its finding** -- a new production file (the new spec file rule 1 asks for does not count), a changed public interface, far more lines than the finding implied -- is reverted and re-tagged `[ask]` with what it turned out to need.
4. **Mark it off with its commit** in the form above as soon as the commit exists, so overruling any automatic fix later is one revert. A resumed run that finds an unchecked `[fix]` entry checks `git log main..HEAD` and the diff for that change before fixing it again.

**Follow-up drafts.** Write each follow-up issue's full title and body into the record file under `## Follow-up drafts`. Filing publishes text under the developer's name, so it is never automatic: it is one question in the batch. Once the batch approves, file each draft and write `filed as <ID>` next to it the moment it is filed, checking for that line before filing any draft, so a resumed run never files one twice.

**On a GitHub-tracked project that has priority labels, each draft carries one proposed priority label on a `Priority:` line under its title, and the batch shows that line with the draft. On a project that has none, write no such line and say nothing about priority.** In the issues list, an issue filed with no priority looks the same as one judged unimportant, and the run that found the problem holds the facts a later triage pass would reread the issue to find. Before writing the first draft, read the repository's labels with a limit:

```bash
gh label list --limit 200 --json name,description
```

Without `--limit`, `gh label list` returns 30 labels, oldest first, and a priority scale added later is not among them. A read that returns exactly 200 may have been cut short the same way: raise the limit and read again. Then take the first of these that fits:

- **The project declines them** in its checked-in CLAUDE.md (or a rules file every session loads), with a statement that the project does not use priority labels on its GitHub issues. It has none, even when the repository has some. Prose about priorities in general ("we don't fuss about priority here") is not a decline, and neither is anything said in conversation.
- **Otherwise, the project states its set** in those files: which labels are its priority levels, and which one means nobody has judged the issue yet. Use the stated labels the read returned, and tell the user of any stated label the repository does not have. With fewer than two levels among them, the project has none, and the name test is not tried: the project has said its labels are others.
- **Otherwise, the name test:** the labels whose names start with `priority` followed by the same separator (`:`, `/`, `-`, or a space; spaces around a `:`, `/`, or `-` do not matter), in any case. Among them, one whose value is `untriaged`, `triage`, or `needs triage` is the not-yet-judged label, in any case and with its words joined by a space, a hyphen, or an underscore (`needs-triage`), and the rest are the levels. Two or more levels make a scale, and fewer make none.
- **Otherwise, the project has none.** Never offer to create priority labels, and never propose or apply a lone `priority: high`, or a label the name test does not match (`P1`, `urgent`), as a priority, whatever is said about such labels in conversation.

On a project that has them, the line sits directly under the draft's title in the record file:

```
### <draft title>
Priority: <label> -- <one-line reason>
```

- **One level, never two candidates, and never the not-yet-judged label.** Choose it from the labels' own descriptions, or from their names where a description is empty, so the project's meanings decide; this skill carries no scale of its own. When two levels fit, pick one and let the reason say what would move it to the other. Where neither says which end of the scale is the higher (`priority: 1`, `priority: 2`, no descriptions), write `Priority: undecided -- <what the labels leave open>` and put that question wherever the filing question is asked, in the batch or, under developer triage, in the pick; such a draft is not filed until the answer names a label.
- **The filing question confirms the label, so the developer sees the line wherever that question is answered.** Show each draft's `Priority:` line under its title in the batch, and under developer triage in the pick, which answers the filing question there. An approval confirms the label, a different level in the answer replaces it, and an answer that changes some drafts' levels and objects to nothing else confirms the rest. Before filing, write the answer back to the line as `Priority: <label> -- <reason> (confirmed)`, so a resumed run reads the confirmed label from the file and never asks again.
- **File the draft's body, never its `Priority:` line.** Write the body to a file outside the working tree, leaving out the `### <draft title>` heading and the `Priority:` line, and run `gh issue create --title "<title>" --body-file <file> --label "<label>"` with exactly the confirmed label.
- **The developer does not want to judge it now:** the line becomes `Priority: <not-yet-judged label> -- left unjudged (confirmed)`, and the draft is filed with that label. Where the project has levels and no such label, the line becomes `Priority: none -- left unjudged (confirmed)`, the draft is filed with no `--label` for a priority, and the closing message says so.
- **After `gh issue create`, read the new issue's labels back** (`gh issue view <number> --json labels`). A filer without permission to label can get the issue without its labels and no error. When a priority label was passed and is not on the issue, put the proposal at the top of the issue's body: `gh issue edit <number> --body-file <file>` replaces the whole body, so the file holds a `Priority: <label> -- <reason>` line, a blank line, and then the body as filed. Say in the closing message that the label did not land. A resumed run reads back the labels of each draft that carries both `filed as` and a confirmed line that names a label, since the earlier run may have stopped between the filing and the read; "Resuming" says when.

The plan-issue skill (bundled in this plugin) owns the reasoning and the rarer cases in its "Priority label" section.

**The batch.** Every question goes in one message, which step 5 of the tail sends and nothing else does. It comes after Phase 4, when it runs, and after Phase 5, so a run nobody is watching finishes everything mechanical before it stops. It lists, in order: the fixed findings with their commits, the follow-up drafts (each with its `Priority:` line, where it has one, and beside them any priority label the project states that the repository does not have, which is where this run tells the user of one), the disproved findings with their evidence, the dropped findings with their count and each one's reason, any follow-up draft Phase 5 corrected, and then the questions -- each `[ask]` from Phases 3, 4, and 5, and whether to file the drafts. It ends with the close-out that subsection owns. Once it is sent, append `Batch sent` to the record file, after the last batch as after the first. A pass dispatched after a batch was sent -- a Phase 4 directly requested, or a pass or lane "Resuming" re-dispatches -- appends `Batch owed` before it is dispatched, because it ends in one last short batch. When a resumed run sends a batch is decided in one place, Phase 5's "Resuming" rule, from these two markers.

When the answers come: fix each accepted `[ask]` under the same four rules, file the approved drafts (each as "Follow-up drafts" says, with the label its `Priority:` line now carries where it has one), and tag each declined entry `(declined)`. A `setup question:` is answered in words, not simply accepted or declined. When the developer names what guarantees the state, add a comment beside the setup step naming it and saying the developer confirmed it, and re-tag the entry `[fix]`; the brief counts such a comment, so the next run does not ask again. When nothing guarantees it and the code is the branch's, remove the step and fix the code as a behavior fix, re-tagged `[fix]`. When that code is outside the branch, leave the step in place, since removing it turns the suite red, write a follow-up draft, and re-tag the entry `[follow-up]`; the close-out names the draft as not yet filed. An answer that settles none of these is recorded as `(declined)`, so the close-out names the question as still open. If anything was fixed, re-run step 1 of the tail -- the suite gate -- on the result. No bug hunt and no prose lane reads a fix made from the answers; the close-out names it. A Phase 4 the developer requests at this point runs on the final state, its findings are sorted and fixed like any others, and tail step 5 then sends one last batch holding only what it raised.

**Developer triage.** When the developer asks to pick the fixes themselves ("gauntlet, but let me triage"), the record file's header carries `Phase 3: developer triages`: Step 2 writes it when the request came at invocation, and a later request is appended the moment it is given. Phase 3 reads the header, never memory. Sort and record as above, then present the sorted list as recommendations and wait for the pick before fixing anything. Phase 5's findings reach the same pick through the batch (see Phase 5). The pick answers the `[ask]` entries and the filing question too: picked entries are re-tagged `[fix]`, entries turned down gain `(declined)`, a picked `setup question:` is handled by the answer the pick gives, asked for when the pick gives none, and the batch at the end carries only what Phases 4 and 5 raise. With no findings there is nothing to pick, so the run goes straight to the tail. A request that arrives after some fixes have landed stops further fixing; the pick then lists those fixes with their commits, for the developer to keep or revert.

### The Phase 3 tail

After the fix bucket is done -- or immediately, when it is empty -- this tail runs on every gauntlet:

1. Decide the gate again by "When the suite gate runs" (Phase 0), which owns this run as much as Phase 0's, including what still counts as evidence here. When no fix has changed anything the staleness test counts since that evidence was obtained, it still stands and the gate lands on its branch 2, and the Step 4 artifacts still stand too: on the Phase 3 run, skip to step 2; on a Phase 4 re-entry, or the re-run after the batch's answers, this step ends here. Otherwise re-run the Step 4 patch-coverage check: the fixes added lines, and those should be covered before the branch leaves draft. Each uncovered added line it finds is a finding, recorded in the record file under the section of the phase that entered this step and sorted and fixed under "When Phase 3 fixes" like any other, whichever phase that was. A line the record file already holds keeps its existing entry and tag rather than gaining a second one. Fixing one changes the tree, so decide the gate again before this step ends.

   **A deferral in the header** (Step 4's second state, or its JS deferral line) means the deferred run left no Step 4 artifact to stand, so the run it owes happens here even when the evidence still stands, and the skip above waits for it. Its uncovered added lines are findings exactly as above. The first artifact that passes Step 4's check satisfies it: this step's own gate run, when that ran with coverage on, or otherwise a coverage run of the measured suite, run as Step 4's check says. **When the header records that the gate task chains suites, the gate's artifact never counts:** Step 4's check names the command to run instead. A coverage run that reports failures is a gate result, never an artifact to read: take it back to the gate list. One that passes and ran the full gate is a gate result too, so write its `Suite gate result:` line. The deferral yields to a tail gate that is red, declined, or cannot run, as "What ending means" in that subsection says, and patch coverage is then reported as not measured. Settle each deferral line on its own: once one is settled either way, append `Patch coverage: measured at the tail` or `Patch coverage: not measured (<reason>)` to the header, naming the run (JS, say) when the header holds more than one deferral, so a Phase 4 re-entry reads each as settled rather than still owed.

   **When the gate goes red after this run's own fixes, those fixes are the suspects, and the PR owns them:** find the fix that broke it, repair it or revert it and re-tag it `[ask]`, and decide the gate again before going on. Only a red that no fix of this run explains ends the gate the way that subsection describes. Phase 4 re-runs this step after its fixes, and after its second pass's; there it ends once the gate decision stands and its patch-coverage findings are fixed or sorted out of the fix bucket, and the run returns where Phase 4 says, never on to step 2. The re-run after the batch's answers ("When Phase 3 fixes") ends the same way, with its findings recorded under the Phase 3 findings, and the answers flow continues from there.
2. Report the PR size in lines changed across files -- insertions plus deletions from `git diff main...HEAD --shortstat`, excluding generated files such as lockfiles, schema dumps, and recorded cassettes -- and whether it is more than 400 lines, the easy-review threshold, or not.
3. Write Phase 4's record line ("When Phase 4 runs" in Phase 4 below). Unless the header holds an opt-out that no later request cancelled, dispatch Phase 4, then sort and fix its findings as "What to do with the findings" says, second pass included, before going on.
4. Run Phase 5 ("Phase 5 -- Check the branch's prose"): write its decision line, dispatch its two lanes, and sort and fix their findings before going on.
5. Remove experiment worktrees left behind ("Watching the tree"), then send the batch ("When Phase 3 fixes"), ending with the close-out. This is the only step that sends it.

---

## Phase 4 -- Find the bug

### When Phase 4 runs

**Phase 4 runs on every gauntlet that reaches Phase 1, at step 3 of the Phase 3 tail, unless the developer opted out up front.** It is never offered as a question, and it does not wait for an acknowledgement: the run may be unattended. It is dispatched on the final state, after Phase 3's fixes, so its hunt reads those fixes along with the rest of the branch; Phase 1 audited the branch before any fix existed. A run that "When the suite gate runs" ends at Phase 0 Step 1 never reached Phase 1 and has no Phase 4. This subsection is the one home of when Phase 4 runs; other sections point here.

**The up-front opt-out.** An opt-out given at any point before the Phase 3 tail ("gauntlet but no phase 4" at invocation, or "skip phase 4" in reply to the cost note) is honored the same way Phase 0 Step 3 honors "gauntlet but skip security": neither of Phase 4's passes runs, and the record line says so. An opt-out given after Step 2 wrote the record file is appended to its header at once; the tail decides from the header, because an opt-out that lives only in memory is one a compaction can erase. **A direct request** ("run phase 4") given after an opt-out outranks it. Given before the Phase 3 tail, it cancels the opt-out: append it to the header, and Phase 4 runs at the tail as on any other run. Given at or after the tail, Phase 4 runs at once and a further decision line is appended.

**The record line.** Before dispatching, or on finding the opt-out, append one line to `.claude/gauntlets/<branch-name>-gauntlet.md` (a shell append such as `printf '\n%s\n' '<line>' >> <file>` is fine and needs no prior read; the leading newline keeps the line from gluing onto a file that lacks a trailing one) in one of these forms, so the decision is greppable after the fact:

- `Phase 4 decision: ran`, or `Phase 4 decision: ran (user request)` for a direct request after an opt-out
- `Phase 4 decision: opted out up front`

Writing it before dispatch means a crash mid-Phase-4 still leaves evidence that the pass was started.

**Closing out.** However Phase 4 ends -- opted out, ran and found nothing, or ran and its findings were sorted and fixed -- the gauntlet closes at the end of the batch, and again at the end of any message reporting what the answers led to. Tell the user the gauntlet is complete and the branch is ready for human review, and give the patch-coverage result for the final tree: measured, with any uncovered added lines left open, or not measured and why. In the same breath name everything still open, and leave those entries unchecked in the record file: a declined finding, a question not yet answered (in a batch that asks any, those questions), a draft not yet filed, and a must-fix sent to follow-up. Name these too, with their entries left checked: a dropped must-fix, a fix no bug hunt has read (every fix on an opted-out run; otherwise one accepted from the batch, or one the second pass led to), and a fix made after Phase 5 ran, whose commit message no prose lane has read. Otherwise "ready for review" reads as "nothing known". That sentence lives here; the Phase 3 tail and the findings section point to it.

**Light mode does not change this.** Light mode (Phase 0) runs the Phase 1 checks in the main agent, but Phase 4 is always a dispatched agent, on a diff under 50 lines too, and the brief below stays as written.

### Why this pass is different

The mental shift from Phase 1 is significant: Phase 1 agents look in narrow lanes for *categories* of issues. Phase 4 assumes a real bug exists in this branch's behavior and goes hunting laterally. The adversarial framing ("I'll bet you can't find the bug") is intentional and should be preserved -- it pushes the agent past surface-level review.

### Dispatch a fresh sub-agent

Use `Agent` with `subagent_type: "general-purpose"`. Do NOT pass the Phase 1 reports (including /code-review's) or the consolidated findings file to this agent -- the value is fresh eyes. Anchoring it on prior findings narrows its search.

**Paste the no-write block after the brief, word for word, with the experiments ending** ("The no-write block"), and add the findings format from item 4 of Phase 1's list: the brief names it, and a sub-agent sees only its prompt. This agent runs as unwatched as a Phase 1 audit and hunts the kind of bug an experiment would confirm. Fingerprint the tree around its dispatch ("Watching the tree").

### Sub-agent brief

> The user is challenging you: **"I'll bet you can't find the bug in our work!"** Take this as a serious adversarial framing -- assume a real bug exists in this branch's changes, and your job is to find it.
>
> This is a fresh-eyes pass. You may notice things the categorical reviewers missed because their lanes were too narrow.
>
> Read `CLAUDE.md` first for project context. Then read the diff (`git diff main...HEAD`), the files it touches, and -- crucially -- the *callers* of any changed methods. Mentally execute the changed code paths for representative inputs and look for:
>
> - **Boundary inputs**: nil, empty string, empty collection, single-item collection, very large collection, negative numbers, zero, max integer.
> - **Wrong field used**: `created_at` vs `updated_at`, `id` vs `external_id`, `name` vs `slug`, `email` vs `username`, `amount` vs `net_amount`.
> - **Unit / money errors**: cents vs dollars, signed vs unsigned, percentage vs fraction, gross vs net.
> - **Time-related bugs**: time-zone confusion, DST boundaries, end-of-day vs start-of-day, leap days.
> - **Inverted boolean logic, off-by-one, wrong comparison operator** (`<` vs `<=`, `&&` vs `||`).
> - **Concurrent or repeated invocations**: race conditions, double-submits, idempotency holes, re-entry of a callback.
> - **Bad data states**: orphaned records, partially completed migrations, inconsistent state across associations.
> - **Cross-tenant / cross-record data leaks** that don't trip explicit authorization checks but leak via query shape (a query missing its tenant / account scope, etc.).
> - **Sibling bugs of the same shape as a fix.** If this branch fixes a bug, is the same bug shape present elsewhere in the codebase that the fix didn't touch?
> - **Cache invalidation gaps**: anything new that writes data an existing cached read won't reflect.
>
> Use the same `## Findings` format as the Phase 1 agents. If you genuinely cannot find a bug after a thorough pass, say so explicitly under "Considered but ruled out" with a one-line summary of where you looked -- so the user knows the time was spent, not skipped.
>
> Report only. The main agent will sort your findings and act on them.

### What to do with the findings

When the agent returns, append its report to `.claude/gauntlets/<branch-name>-gauntlet.md` under a "Phase 4 -- find-the-bug" section, whatever it found, so the persisted record stays complete and a resumed run can tell the pass returned. A finding that does not survive a check against the code is sorted `[disproved: <evidence>]` like any other.

If the agent finds something credible:

1. Sort them by "When Phase 3 fixes", exactly as Phase 3's findings: a credible bug with an unambiguous fix is fixed without asking, and anything on a judgment ground joins the batch. A bug found here is almost always `must-fix` by nature, and a clear one is not a question.
2. Fix the fix bucket through the same four rules -- write the failing spec that captures the bug, watch it RED, then fix and confirm GREEN. Then re-run step 1 of the Phase 3 tail, which re-enters "When the suite gate runs" as the tail: Phase 4 fixes are unreviewed fixes too.
3. **The second pass.** When a Phase 4 fix changed anything but a test or a commit message, dispatch the brief once more, to a fresh sub-agent with the same no-write block and findings format, and the tree fingerprinted around the dispatch, with its scope narrowed, in its prompt, to those fix commits (`git show <sha>` for each). Append `Phase 4 second pass: ran (<short shas>)` before dispatching. Write its report in a "second pass" subsection of the Phase 4 section when it returns, even when it found nothing, and sort and fix its findings the same way. Its fixes get the suite gate and nothing more: there is no third pass, and the close-out names them.

If the agent finds nothing:

1. Relay the agent's "where I looked" summary in the batch. This is signal, not noise -- it tells the user the bug-hunt happened and what it covered. For a Phase 4 that ran after the batch, that summary is the whole of the last short batch it owes, and it is still sent.

Either way, return to step 4 of the Phase 3 tail, which runs Phase 5 -- or to step 5 when the record file already has a `Phase 5 decision:` line, as it does for a Phase 4 requested after the batch.

---

## Phase 5 -- Check the branch's prose

Phases 3 and 4 change code after the branch's commit messages were written, so a fix can leave a commit body describing code that no longer exists, and every gate still passes. Phase 5 checks the branch's prose against the final code and reads its commit messages for prose defaults. It audits no code: Phase 4 hunts bugs in the fixes.

### When Phase 5 runs

**Every gauntlet run that reaches Phase 1 runs Phase 5** at step 4 of the Phase 3 tail, after Phase 4 and its fixes, and before the batch. It is never offered as a question and has no opt-out. It runs once: a fix made after it, from the batch's answers or by a Phase 4 requested later, is not read again, and the close-out names it.

### Lanes

Two lanes, `prose` and `prose-defaults`, each read every commit on the branch, `git log main..HEAD` (`prose-defaults` leaves merge commits out): a stale claim can sit in a commit written before any fix, and no Phase 1 lane reads commit messages for their prose.

**Each lane is a fresh sub-agent, even in light mode**, dispatched in a single message with the tree fingerprinted around the dispatch ("Watching the tree"): the session that wrote the fixes is the least independent reviewer of what it wrote about them. Give each lane its brief, the first paragraph of the no-write block, and the findings format from item 4 of Phase 1's list: a sub-agent sees only its prompt.

### Agent: prose

> Check the branch's prose against the code as it now stands. Report only -- do not reword or post anything.
>
> - **Commit bodies.** For every commit in `git log main..HEAD`, compare each claim in its body with the code: a stated status code, a named method, a described behavior. For every SHA a body cites, confirm `git rev-parse --verify <sha>^{commit}` succeeds and `git merge-base --is-ancestor <sha> HEAD` exits 0; a SHA that fails either no longer names this branch's history.
> - **The pull request description**, when one exists and you can read it: the same comparison.
> - **The follow-up drafts** under `## Follow-up drafts` in `.claude/gauntlets/<branch-name>-gauntlet.md`: does each still hold against the final findings, including the Phase 4 section? A later phase can overturn an earlier phase's suggestion. Where a draft's `Priority:` line proposes a level, does the reason on that line still hold against the draft's body and the final code? Report a line whose reason no longer holds; never propose a different label.
>
> For each finding, name the commit SHA, the description, or the draft title. Use the standard findings format.

Paste the no-write block's first paragraph after this brief ("The no-write block").

### Agent: prose-defaults

> Read the branch's commit messages for prose defaults: the rhetorical moves and stand-in words a reader of `git log` learns to skim. Report only -- do not reword or post anything, and do not check the messages against the code; another lane does that.
>
> Read the project's CLAUDE.md and rules files first. Where they state a commit message style of their own that differs from this list, report nothing and say so in one line. Rules that import or restate the guidance this list comes from are not a style of their own. Otherwise check every commit in `git log --no-merges main..HEAD`, quoting the words that match:
>
> - **In a title:** a leading verb that names what was done to the code, not what a user or operator gets (`Tighten`, `Lock`, `Harden`, `Cover`, `Guard`, `Add`, `Update`, `Move`, or another verb doing that job); a slogan form ("One <Noun> for ...", "X, Not Y").
> - **In a body:** two or more ", so" joins in one paragraph; more than one dash used as punctuation (" -- " or an em dash) in one body; "silently" or "quietly" where the mechanism could be stated; a hazard or topology metaphor used as if it were the project's vocabulary (phantom, ghost, orphan, landmine, footgun, clobber, band-aid, twin, surface, basis, seam, load-bearing, latent, "by construction", "shape" for a kind of thing); code given a mental verb (learn, trust, believe, promise, argue, overclaim); a contrast against something no one proposed ("proven rather than assumed"); a guarantee with no mechanism ("so the two can no longer disagree"); a sentence of two to five words that judges the one before it ("It did not."); a general saying as a paragraph's last line; irony about what the code was for ("the one case the guard exists to catch"); an imagined person or event ("a future maintainer", a "would have" sentence about a case that did not happen, "Left alone,"); "nothing" or "nobody" as a sentence's subject; a counted opener ("Two smaller corrections.") or a paragraph that starts "Also"; the review pass, tool, bot, or review round that found the problem.
> - **Not findings:** a term the code, its framework, or its domain already uses (look in the changed files' identifiers and comments before reporting a metaphor: "orphaned" is no finding where the code calls its records orphaned), an identifier, or quoted text; a contrast between two options a reader could confuse; a single ", so" in a paragraph; a lint rule or check the commit is about; a title's `Pin` on a spec that pins existing output; a noun-phrase title on a change with no user outcome; a counted opener or an "Also" paragraph on a change that cannot be split; a generated message (a merge commit, a bot's commit, git's own `Revert "..."` title).
>
> Report each commit's matches as one finding under nit, in the form `<sha> -- prose defaults: <the quoted words>`. In the pull request description, when one exists and you can read it, check only the words ("silently" and "quietly", the metaphors, and the mental verbs), and report its matches as one finding under nit: `pull request description -- prose defaults: <the quoted words>`. Use the standard findings format.

Paste the no-write block's first paragraph after this brief ("The no-write block").

This brief restates lists the commit-messages and code-comments guidance own, on purpose, where every other brief leaves a rule to the file that owns it: the lane has to work for a team that does not import that guidance. It is a lane of its own, which leaves the `prose` brief's comparison with the code as the one job of the agent that gets it.

### Sorting and fixing Phase 5's findings

Record the findings in the record file under a `## Phase 5 -- prose` section, one subsection per lane, and write each lane's subsection when its agent returns, even when it found nothing. Prose findings have fixed buckets, because correcting prose rewrites history or publishes text. None of these fixes changes a file a suite reads, so the gate's evidence stands.

- **A wrong body on the tip commit, when that commit is unpushed, is `[fix]`**: amend its message, confirm `git diff <old> <new>` is empty, and update every short SHA in the record file that named it. Confirm `git rev-parse HEAD` names that commit before amending: `--amend` rewrites whatever commit is at HEAD. A commit counts as pushed, and so as shared, when after a `git fetch` `git branch -a --contains <sha>` names any remote-tracking branch, including this branch's own, or any local branch other than the current one (in a detached HEAD no branch is current, so any branch counts): a local branch stacked on this one holds the tip too, and an amend would strand it. A fetch that fails counts as pushed.
- **A wrong body on any other commit, or on a pushed tip, is `[ask]`.** Rewording it rewrites every later commit, which changes the SHAs the record file logs and any body that cites them.
- **A wrong pull request description is `[ask]`**, with the corrected text in the batch: the description is text under the developer's name.
- **Prose defaults follow the same buckets, with one difference: on a pushed commit they are a note, never a question.** History that others may hold is not rewritten for how a message reads. List those commits on one line in the batch (`prose defaults on pushed commits: <short shas>`), write the same line in the `prose-defaults` subsection, and tag nothing. On unpushed commits below the tip they are one grouped `[ask]` naming every commit, never one question each.
- **When more than one finding names the unpushed tip, from either lane, make one amend that settles them all**, and record the new SHA on each entry: after the first amend the other findings' SHA no longer names HEAD. Likewise the pull request description gets one corrected text that answers both lanes.
- **An accepted reword of commits below the tip is a history rewrite, done in this order:** check again, by the first bullet's test, whether any commit from the oldest one named to the tip now counts as pushed, and stop if one does; take a backup ref of the branch; reword; confirm `git diff <backup> HEAD` is empty; then replace every short SHA the rewrite changed in the record file (the `[fix]` entries' and the `Phase 4 second pass:` line's), and say in the closing message that commit bodies citing a rewritten SHA were not rechecked.
- **A wrong follow-up draft is corrected in place** in the record file, since it has not been filed, under developer triage too: the correction publishes nothing, and filing still waits for the developer. Say in the batch what changed. A `Priority:` line whose reason no longer holds is corrected the same way: read the labels' descriptions again and write the line the draft now calls for. A line marked `(confirmed)` is never rewritten, and neither is one on a draft carrying `filed as`: the developer has answered for that label. Report the stale reason in the batch instead.

**Developer triage.** Under `Phase 3: developer triages`, Phase 5's findings are sorted and recorded, then presented in the batch for the developer's pick; none is fixed first.

### The record line

Before dispatching, append `Phase 5 decision: ran (prose, prose-defaults)` to the record file.

**Resuming.** A resumed run starts with the two checks "Watching the tree" gives it: an unanswered `Tree changed:` line, and experiment worktrees left behind. A run whose record file has no `Phase 4 decision:` line was interrupted before step 3 of the Phase 3 tail: it picks up at the first phase the record file does not show finished, and step 3 decides Phase 4 when the run reaches it. Otherwise it finishes Phase 4: a `Phase 4 decision: ran` line with no "Phase 4 -- find-the-bug" section after it, or a `Phase 4 second pass: ran` line with no "second pass" subsection, means that pass never returned, so re-dispatch it before anything else. A run that then finds no `Phase 5 decision:` line runs Phase 5. One that finds the line re-dispatches whichever of the two lanes has no subsection in the Phase 5 section yet. A pass or lane re-dispatched when the record file already holds `Batch sent` appends `Batch owed` first: its findings need a batch to go in. It reads back the labels of each filed draft "Follow-up drafts" says to read back. Only then does it send a batch, and only when one is owed: the record file has no `Batch sent` line yet, or its last `Batch owed` line comes after its last `Batch sent` line. Otherwise the batch already went out and the run is waiting on answers.

When Phase 5 is done, return to step 5 of the Phase 3 tail, which sends the batch.

---

## Project-specific overrides

Projects may place a `.claude/skills/gauntlet/SKILL.md` in their own repo to override this skill -- different sub-agent set, different file conventions, different gate command, different severity bands. When such a file exists, it wins entirely -- do not try to merge.
