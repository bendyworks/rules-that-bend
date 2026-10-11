# Contributing

These skills are working tools, not polished products. They encode how we
actually work, they evolve as we learn, and rough edges are expected.
Improvements of any size are welcome -- a typo fix, a sharper trigger
description, a whole new audit lane in gauntlet.

## How changes ship

- All changes land through pull requests against `main`.
- **Merged means shipped.** The plugin has no version field, so every
  commit on `main` is immediately installable by everyone via
  `/plugin marketplace update bendyworks`. Review accordingly. This is
  what [CLAUDE.md](CLAUDE.md) declares as Deploy-on-Merge Mode.
- Maintainer: Stephen Anderson (@bendycode) merges. If a PR sits for more
  than a few days, nudge him.
- **Announce guidance changes.** A substantive change to a `guidance/`
  file changes how a consuming teammate's Claude behaves on their next
  `git pull` or vendoring refresh -- silently, if nobody tells them. The
  PR description for such a change must say what behavior changes and
  why, in wording a consuming team can relay to its own channel. The
  description's why paragraph is the place for it, with no section of
  its own. Typo and formatting fixes are exempt.

## Before you open a PR

1. Run the local checks CI will run:

   ```bash
   bash scripts/check-identifiers.sh
   claude plugin validate .
   ```

2. **No client or personal identifiers.** Use the neutral `ABC-NNN` form
   for tracker-ID examples, `teammate@example.com` for emails, and
   `${CLAUDE_PLUGIN_ROOT}` or relative paths instead of absolute
   home-directory paths. CI enforces the patterns; you are responsible
   for anything a pattern can't catch (a client's name in prose, a
   real-world anecdote that identifies a project).
3. **Test the skill you changed.** Invoke it through Claude Code against
   a real (or toy) project and confirm the changed behavior. The
   "Dry-running a skill" section below has the mechanics that make this
   cheap; for a new skill it is the whole test plan.
4. No trailing whitespace, no emdashes (use `--`).

## Dry-running a skill

The cheapest faithful test of a skill is a headless Claude session run
against a real project, with the plugin loaded from your working tree.

**Invocation.** Run from the target project's directory and point
`--plugin-dir` at your clone of this repo. Headless (`-p`) sessions
cannot answer permission prompts, so pre-approve the tools the skill
needs and no more.

```bash
cd path/to/target-project
claude --plugin-dir path/to/rules-that-bend \
  --setting-sources project --model sonnet \
  -p "Invoke the <name> skill from the bendyworks plugin on the current
      branch, following it exactly. Report what it produces." \
  --allowedTools "Bash(git diff *),Bash(git log *),Read,Grep,Glob"
```

Keep the prompt neutral: do not tell the session what outcome you
expect, or the run stops being a test. Decide the expected answer
beforehand from your own reading of the project's state, then grade the
output against it.

**Models.** Run arms on Opus and Sonnet, the two models the plugin
supports (the README's Requirements section names them), and on no
smaller one. After rewording text that arms already cover, re-run those
arms on Sonnet.

**When the control passes on both models, the rule does not ship.** The
control is the same arm run on the text as it stood before your change.
Drop the rule, or find the scenario where one model fails. Two kinds of
change ship on other evidence, and the pull request says which:

- *Text that says something wrong.* A capable model often does the
  sensible thing where the text tells it otherwise, so the control
  passes. Run the text's own commands, in order, in a scratch repository
  in the state the finding names. The fix rests on that run.
- *A behavior only long real sessions show.* A short headless session
  may never produce it. Count it in real history: the same model on the
  same project, either side of the date the rule arrived.

The pull request states, for each rule it adds, the control's score on
each model.

**Run the control again beside every treatment batch.** The same text,
byte for byte, caught a planted error in 3 of 6 runs in one batch and 0
of 6 in the next. Two wordings cannot be told apart on fewer than twenty
runs per arm; with fewer, report the spread.

**Give each arm a throwaway project directory that carries exactly the
rules it is meant to have.** A session started inside this repo picks up
the root `CLAUDE.md`, its Deploy-on-Merge declaration included, and a
`CLAUDE.md` in any directory above the arm's loads too. Either can hand
the run the answer the skill was supposed to supply. When writing a
project declaration for an arm, state the fact the project asserts,
never the behavior you expect from the skill.

**Keep your own rules out of every arm.** Pass
`--setting-sources project` on every arm, and again on every `--resume`
turn: the flag covers one invocation. An arm run with it starts without
your user-level `CLAUDE.md` and the files it imports, the files under
`~/.claude/rules/`, personal skills under `~/.claude/skills` (synced
copies of this repo's skills among them, which an arm could follow
instead of your branch), and the plugins and MCP servers in your user
settings. It still loads the project's `CLAUDE.md`, `.claude/rules/` and
`.claude/settings.json`, the `--plugin-dir` skills, and the arm
directory's auto-memory.

The flag needs Claude Code 2.1.101 or later: before that, a session run
with it deleted conversation history older than 30 days. Whether it
isolates has differed between builds, so confirm it on yours before a
batch, and again after an update:

```bash
scripts/check-arm-isolation.sh
```

It runs two one-word sessions, one with the flag and one without (a real
session on your own settings), and reads which instruction files Claude
Code reports loading. "Cannot tell" comes with its reason. When it
reports that a user-level file loaded with the flag, run no batch on
that build: install one the check passes on (`claude install <version>`)
and open an issue here with the output. Read the output first, since it
names files on your machine and this repo is public.

The flag drops your permission rules, hooks, and model choice too. Pass
`--model` on every arm, and give `--allowedTools` only what the skill
needs (`Bash(git diff *)`, never `Bash(git *)`, which allows a push or a
hard reset), restating a deny you rely on with `--disallowedTools`.
`--allowedTools` pre-approves and does not limit; `--tools` sets which
built-in tools an arm has at all. Read a run's stream for permission
denials before grading it. The flag stops Claude Code loading your
files, not an arm reading them, so where that matters add
`--disallowedTools "Read(~/.claude/**)"`. The tell for a contaminated
run is an arm citing a rule only your own files carry, or skill wording
that matches main and not your branch.

**Trigger injection.** To force a specific code path (an escalation
rule, an edge case), plant an untracked dummy file that matches the
trigger instead of mutating anything real -- e.g.
`touch spec/factories/zz_dry_run.rb` to trip a rule keyed on
`spec/factories/**`. When the skill claims to produce an artifact (a
log file, a report), verify it exists on disk.

**Selection-only paper runs.** For judgment-heavy rules that would be
slow or side-effectful to execute, prompt the session to apply the
skill's rules against real code but run nothing: stipulate a
hypothetical diff ("pretend the branch diff were exactly: ..."), tell it
to substitute real files when a stipulated one does not exist and say
so, and require the full decision output.

**Plant the memory directory for memory behavior.** A headless session
gets an auto-memory directory derived from its working directory:
`~/.claude/projects/<path>/memory/`, where `<path>` is the absolute
working directory with every character other than a letter or digit
turned into `-`. To test how a skill handles memory, plant the
`MEMORY.md` an arm needs at that path before the run, and remove the
whole `~/.claude/projects/<path>` directory after it.

**Give an arm a further turn when the rule is about an approval or a
go-ahead.** A rule that makes a session propose and wait, or that
forbids an action, ends a one-turn arm on a question in the control and
the treatment alike. Resume the session with its session id and a
neutral turn that names no answer of its own ("Approved, go ahead.", "Do
what you recommend."), repeat every isolation flag on that command, and
grade each turn. Read the writes as attempted tool calls in the stream,
since a headless run is denied writes outside its working directory.

**Read what a grader scored before counting it.** A grader that
recognizes a behavior by its wording misses other phrasings ("Does that
text work for you? If so, I'll write it."). When an arm is graded as not
waiting but wrote nothing, read its final message, and widen the pattern
instead of correcting the score by hand. A word match counts a report
that repeats a planted claim ("verified: wraps fields in double quotes")
as one that caught it, so make the pattern require the contradiction.
And a grader built to catch a pattern scores its absence as a pass: give
each scenario a list of facts a good output must still contain, the
answer to any question asked among them.

## GitHub is required

The plugin requires a GitHub-hosted repository, on github.com or a
GitHub Enterprise host, and the GitHub CLI (`gh`) installed and
authenticated. Everything that reads pull requests or GitHub issues goes
through `gh`: the commands the skills and guidance give a session and
`bin/gh-issue-sync`. Issue trackers are a separate matter: Linear and
Shortcut are supported where the skills
name them, and a project tracked there still needs GitHub for its pull
requests.

**Write a skill, a guidance file, or a tool for GitHub alone, and never
add text saying what a rule means on another host.** That text cannot
be tested here, and once it exists every later rule has to say what it
means there too. A rule about where text is bound, such as the
public-destinations guidance, is a different matter: the destination is
not always the project's own repository.

[`gh-calls.txt`](gh-calls.txt) lists every `gh` command the project
runs or tells a session to run. Support for another host arrives one of
two ways: as a `gh`-compatible command for that host that answers those
commands, or as a change that adds an equivalent beside each call. A
command of the first kind runs with the user's credentials, so it has
to be one the team trusts.

`test/gh_calls_test.rb` compares the list with the commands named under
`skills/`, `guidance/`, and `bin/`, in both directions. Name a new `gh`
command there and the test fails until the list has it; remove the last
use of one and it fails until the line goes. A tool under `bin/` builds
its `gh` arguments as a list the comparison cannot read, so it declares
its calls in a `GH_CALLS` constant, and its runner refuses a call the
constant lacks.

## Writing a new skill

A skill is a folder under `skills/<name>/` with a `SKILL.md` and any
supporting files (scripts, templates). Start from this frontmatter:

```markdown
---
name: my-skill
description: One or two sentences saying what the skill does, then "Use
  when the user ..." with the concrete phrasings that should trigger it.
---

# My skill

Numbered, imperative instructions Claude can follow without you in the
room. Prefer bundled scripts over prose for anything mechanical.
```

The `description` is the API: it is all Claude sees when deciding whether
to invoke the skill, so spend your effort there. Name the trigger phrases
users actually say. Skills that reference each other should say "the
<name> skill (bundled in this plugin)" rather than a bare `/name`, so the
reference survives plugin namespacing.

A skill whose steps all act on the checkout's own repository (its
branches, `gh-issue-sync`, a closing keyword) should refuse work that
names another repository, with a question to the user, rather than
thread `--repo` through each step. Threading it covers only the steps
someone remembered to update: one attempt carried `--repo` to three
writes and missed three more, and `gh api` rejects the flag outright.
A refusal at the first step stays correct as steps are added.

Executables go in `bin/` (added to PATH when the plugin is enabled) and
must not require configuration beyond documented environment variables.
Err on the side of keeping them stdlib-only Ruby (no gems, no Gemfile)
so installers need nothing beyond a Ruby on their PATH. When a helper has logic worth
testing (see `bin/gh-issue-sync`), structure it as a pure module whose
functions raise a custom error, plus a thin CLI class that talks to the
outside world and rescues to `abort`, dispatched behind
`if $PROGRAM_NAME == __FILE__` -- the test file under `test/` can then
`load` the bin file without executing the CLI, and CI runs it with a
bare `ruby test/<name>_test.rb`. Shared test scaffolding for
CLI-invoking tests lives in `test/cli_test_case.rb`; its header
comment explains the naming that keeps it outside CI's
`test/*_test.rb` glob. Subclasses name their entry point in
`dispatch_cli` and any per-CLI safety refusal in
`guard_cli_invocation`; `run_cli` is owned by the base class and
refuses to be overridden, so no suite can dispatch around its own
guard.

**A test that a tool refuses a command puts a refusing stand-in for
that command on PATH, and asks for something harmless.** The test
proves the refusal by asking for what should be refused, so with the
refusal missing it runs what it asked for. One such test called a
tool's `gh` runner with `repo delete` and named no stand-in: with the
check removed, it started the developer's signed-in `gh`. Name the
program in `shimmed_commands`, which fails the test on any call that
reaches it, and pick a read-only command for the refused call.

A CLI whose work IS the shelling out (see `bin/stale-branches`) splits
the same way, one level further in: the pure module holds the
decisions that are a function of gathered facts, a command class is
the only code that shells out, and the CLI class is argv and printing.
That seam is what lets the decision table be tested without a
repository and the shell-level traps -- the ones that cost this repo
the defects `bin/stale-branches` was extracted to prevent -- be tested
against real throwaway ones. Fixtures that build such a repository
live in `test/fixtures/`, outside the `test/*_test.rb` glob for the
same reason as the scaffolding; `test/fixtures/repo_builder.rb`
documents the three properties that keep a build inside the directory
it created.

**A test that needs a fixture repository takes a copy of one, and
never builds one.** A build runs a few hundred git commands and takes
one to four seconds; `Fixtures::BranchRepo.with_copy(label)` builds the
fixture once per run and hands each caller a copy in a few hundredths
of a second. Before fixtures were copied, `test/stale_branches_test.rb`
built one per test and ran for over seven minutes. To write a new
`stale-branches` test:

- Ask first whether the test needs a repository. A verdict that is a
  function of gathered facts is tested against the pure module with no
  repository, the way `ProtectionTest` is.
- Where it does, take the copy through `with_flat_fixture` or
  `with_gitflow_fixture`. The copy belongs to
  the test, which may move HEAD, add a remote or delete branches in it.
- Where it needs a repository no fixture builds, change the copy inside
  the test. Add a branch to a fixture only when a row of its oracle
  table needs one, since every test then pays for it in each sweep.
- Call `build` only to test the builder itself. A test in the file
  fails when any other class does.

`ruby test/stale_branches_test.rb -v` prints each test's time. The full
suite is meant to run in under three minutes ([CLAUDE.md](CLAUDE.md),
Goals), so measure before and after adding a test that sweeps.

A skill can also ship **templates**: files it copies into the project
it is working on rather than running itself (see
`skills/parallel-checkouts/templates/`). They live in the skill's own
`templates/` directory, never in `bin/`, because `bin/` is what
installers get on their PATH, and a template means nothing outside
the project it was copied into. A template is written for that
project's runtime, not this repository's: the parallel-checkouts
stack scripts are bash 3.2 (macOS's `/bin/bash`), because the project
receiving them may have no Ruby on the host, and its teammates run
them without this plugin installed. Each script template carries a
`<skill> template v<N> (bendyworks/rules-that-bend)` comment on its
first line (after any shebang), so a later session can tell a copied
file from its template. Copies made before the repository's rename
name it by its former slug, `bendyworks/claude-skills`; a header naming
either slug marks the same template, and only `v<N>` tracks content.
`test/repository_name_test.rb` checks every template's header. Test a
template from a file under `test/`, the way the receiving project
uses it: a script copied into a throwaway directory and run there, or
code a framework loads evaluated against a stand-in for that
framework.

Coverage measurement is opt-in and test-only; the stdlib-only posture
above is about the CLIs' runtime and is unaffected. Requiring
`test/cli_test_case.rb` first is the convention every test file
follows, and it is also what turns coverage on: it loads
`test/coverage_helper.rb`, which starts SimpleCov only when the
`COVERAGE` env var is set to a non-empty value (install SimpleCov
once; when it is missing the helper aborts naming the exact pinned
install command, then e.g. `COVERAGE=1 ruby test/linear_test.rb`).
Delete `coverage/.resultset.json` and its `.lock` before a measuring
run: SimpleCov merges per-process results within a time window, so
leftovers from an earlier session can leak into or silently shrink
the union. Delete those two rather than all of `coverage/`, which
would also remove `.last_run.json` and disable any coverage-drop
gate. Read uncovered lines from the merged union -- this repo's
`coverage/coverage.json` -- never from `coverage/.resultset.json`,
which is per-process raw data. CI runs the test
loop with coverage on, uploads `coverage/` on every run that gets
that far, and then asserts every `bin/` CLI appears in the artifact
with covered lines.

When adding a mode to an existing CLI, place it by this convention: a
new mode of one resource rides a flag on that resource's subcommand
(like `gh-issue-sync section --delete`), while an operation with its
own gate semantics gets its own subcommand even when it shares an
implementation (like `checklist` vs `reconcile`, whose difference is
the refuse-unless-finalized gate).

## Proposing without building

Open an issue with the "New skill proposal" template. A rough sketch of
the trigger phrases and the workflow is enough to start the conversation.

## Issue priorities

An open issue carries one `priority:` label. Each level says what
happens, and to whom, if the issue waits:

| Label | Applies when | Label description |
| --- | --- | --- |
| `priority: high` | Someone following shipped text gets a wrong or harmful result, `main` is red, or work in flight is blocked. Waiting costs somebody now. | Shipped text misleads someone now, main is red, or work in flight is blocked |
| `priority: medium` | Nothing breaks, but the cost recurs with every story until it is fixed: a correction a developer keeps making by hand, a prompt a session keeps getting wrong. | Nothing breaks, but the cost recurs with every story until it is fixed |
| `priority: low` | Waiting costs nothing that grows: a cleanup, a consolidation of two passages that agree, a lesson from one story. | Waiting costs nothing that grows: a cleanup, a consolidation, a one-off lesson |
| `priority: untriaged` | Nobody has weighed the issue yet. It says nothing about how much the issue matters. | Nobody has weighed this yet; says nothing about how much it matters |

GitHub caps a label's description at 100 characters, so the third
column is the short form the labels page shows.

- **Whoever files an issue proposes a level with a one-line reason, and
  the maintainer confirms or changes it.** Propose high, medium, or
  low, never `priority: untriaged`. A filer who cannot apply labels
  writes the proposal in the issue body.
- **The maintainer applies `priority: untriaged` when choosing not to
  judge an issue yet.** An issue filed with no priority label counts
  as untriaged until it has one.
- **Changing a priority swaps the label**, removing the old one in the
  same command:

  ```bash
  gh issue edit NNN --remove-label "priority: untriaged" --add-label "priority: medium"
  ```

- **To list the open issues that need a priority**, which are those
  with no priority label and, as an error to correct, those with more
  than one:

  ```bash
  gh issue list --state open --limit 500 --json number,labels \
    --jq '.[] | select([.labels[].name | select(ascii_downcase | startswith("priority:"))] | length != 1) | .number'
  ```

  The command reads at most 500 issues; raise `--limit` if the
  repository ever has more open.
