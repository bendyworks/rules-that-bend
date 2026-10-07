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
Three techniques cover most skills:

**Invocation.** Run from the target project's directory and point
`--plugin-dir` at your clone of this repo. Headless (`-p`) sessions
cannot answer permission prompts, so pre-approve the tools the skill
needs and no more, and pass `--setting-sources project` so the run
leaves your own user-level files out. Read "Keep your own rules out of
every arm" below before the first run: the flag needs Claude Code
2.1.101 or later.

```bash
cd path/to/target-project
claude --plugin-dir path/to/rules-that-bend \
  --setting-sources project --model sonnet \
  -p "Invoke the <name> skill from the bendyworks plugin on the current
      branch, following it exactly. Report what it produces." \
  --allowedTools "Bash(git diff *),Bash(git log *),Read,Grep,Glob"
```

**Models.** Run arms on Opus and Sonnet, the two models the plugin
supports (the README's Requirements section names them), and on no
smaller one. Text is never reworded to suit a model the plugin does not
support. When both pass a scenario on the text as it stood before your
change, that scenario gives no reason to add a rule: drop the rule, or
find the scenario where one of them fails. A fix to text that says
something wrong is a different case, which "A control that passes does
not clear the text" below covers. After rewording text that arms
already cover, re-run those arms on Sonnet.

Keep the prompt neutral -- do not tell the session what outcome you
expect, or the run stops being a test. Decide the expected answer
beforehand from your own reading of the project's state, then grade the
output against it.

**Mind the CLAUDE.md a run inherits.** A session started from a
directory inside this repo picks up the root `CLAUDE.md`, including its
Deploy-on-Merge declaration. It can hand the run an answer the skill
under test was supposed to supply, which quietly turns a test into a
tautology, and so can your own user-level files (next paragraph). Run
each arm from a throwaway project directory that carries exactly the
rules that arm is meant to have. The related trap when writing a
project declaration for an arm: state the *fact* the project is
asserting, never the behavior you expect the skill to produce, or the
session will simply follow your wording.

**Keep your own rules out of every arm.** Pass
`--setting-sources project` on every arm, and again on every
`--resume` turn: the flag covers one invocation. Seen on Claude Code
2.1.285, 2.1.288, and 2.1.289, a resumed turn without the flag loaded
the user-level files again, and an arm run with it started without:

- your user-level `CLAUDE.md` and every file it imports;
- files under `~/.claude/rules/`;
- personal skills under `~/.claude/skills`, including synced copies of
  this repo's skills, which an arm without the flag loads beside the
  `--plugin-dir` working tree and can follow instead of your branch;
- plugins and MCP servers enabled in your user settings.

It still loads the project's own `CLAUDE.md` and `.claude/rules/`, the
project's `.claude/settings.json` with its permission rules and hooks,
any `CLAUDE.md` in a directory above the arm's, the `--plugin-dir`
skills, and the arm directory's auto-memory.

**The flag needs Claude Code 2.1.101 or later.** Before that, a session
run with it deleted conversation history older than 30 days, whatever
your settings said.

Whether the flag does this has differed between builds, so confirm it
on yours before a batch that relies on it, and again after an update:

```bash
scripts/check-arm-isolation.sh
```

It runs two one-word sessions, one with the flag and one without, and
reads which instruction files Claude Code itself reports loading. It
passes when user-level files load without the flag and none load with
it. It observes instruction files only; skills, plugins, and MCP
servers come from the same user source but are not checked. The
session without the flag is a real one with your own settings: it runs
your hooks and loads your plugins, though with no tools and no MCP
servers, and each session makes one small model request. It starts no
session at all on a build older than 2.1.101.
"Cannot tell" comes with its reason. The three you are likeliest to
see: an arm failed, and if it is the one with the flag, your sign-in may
come from your user settings, which is the first case under "When the
flag will not do" below; nothing user-level loaded either way, because
you have no such files; or your `CLAUDE.md` sits in a park lock, which
"Never move your user-level files aside" below explains.

The flag drops everything else in your user settings too, so an arm
gets none of your permission rules, hooks, or model choice. That
includes your `deny` rules and any hook that guards a tool, which
apply to an arm run without the flag. Pass `--model` on every arm, and
give `--allowedTools` only what the skill needs (`Bash(git diff *)`
rather than `Bash` or `Bash(git *)`, which still allows a push or a
hard reset), restating a deny you rely on with `--disallowedTools` and
a guard hook you rely on with `--settings`. `--allowedTools`
pre-approves and does not limit; `--tools` sets which built-in tools
an arm has at all. Read a run's stream for permission denials before
grading it: a denied tool changes what the arm does.

The flag stops Claude Code loading those files, not an arm reading
them: `Read`, `Grep`, and `Glob` as the example grants them reach any
file you can read, so an arm can still open `~/.claude/CLAUDE.md` or a
stale skill copy off disk. Where that matters, add
`--disallowedTools "Read(~/.claude/**)"`. The tell for a contaminated
run is an arm citing a rule only your own files carry, or skill wording
that matches main rather than your branch.

**When the flag will not do.** Two cases. Both are settled on the
arm's own command line, so nothing outside the arm changes.

*Your arms need something from your user settings to run at all*, such
as a sign-in that comes from an `apiKeyHelper` there. Put that one
setting in a file of its own and pass it beside the flag:

```bash
claude --setting-sources project --settings ~/dry-run/sign-in.json ...
```

Seen on Claude Code 2.1.289, an arm run this way consulted the file's
`apiKeyHelper`, applied its `env` block, and ran its hooks, while the
flag still kept the user-level files out. Claude Code keeps only the
last `--settings` it is given, so a guard hook you restate goes in the
same file. Variables from an `env` block need no file at all: export
them in the shell that runs the batch. The file names a command that
fetches a key and never holds the key itself. Keep it outside this
repo, as the path above is. Hand the isolation check the same file, so
its arm with the flag can sign in; that arm is a real session, so the
file's `apiKeyHelper` and hooks run there too:

```bash
ARM_SETTINGS=~/dry-run/sign-in.json scripts/check-arm-isolation.sh
```

*The check reports that a user-level file loaded with the flag.* Run no
batch that relies on the flag on that build. Install a build the check
passes on (`claude install <version>`), run the check again, and open
an issue here with the output of the failing run. The check's output
names files and directories on your machine and can quote an error
from `claude` or `ruby`, and this repo is public, so read it before you
post it.

Until a build passes, an arm can run on a config directory of its own,
which has no user-level files in it to load. Pointing
`CLAUDE_CONFIG_DIR` at an empty directory leaves a run logged out, so
the arm also needs a sign-in token in its environment. Make one with
`claude setup-token`, keep it in your system's secret store, and read
it from there on the command line (on macOS, `security
find-generic-password -s <item> -w`):

```bash
CLAUDE_CONFIG_DIR="$(mktemp -d)" \
  CLAUDE_CODE_OAUTH_TOKEN="$(<command that prints the token>)" \
  claude --model sonnet -p "..." --allowedTools "..."
```

Seen on Claude Code 2.1.289: with an empty config directory and no
token, a headless run answered "Not logged in"; with the token it ran,
and loaded the project's `CLAUDE.md` and no user-level file. The token
is a credential for your account: never write it to a file, a script,
or a settings file, and never paste it into a session. Claude Code
writes session state into the directory, so delete it when the batch
ends. `scripts/check-arm-isolation.sh` does not check this route; it
tests the flag.

**Never move your user-level files aside for a batch.** Every Claude
Code session on your machine reads the one user-level `CLAUDE.md`. A
session started in any project while that file is moved away runs
without your rules, and nothing tells it or you: it behaves plausibly
and no command fails. Older checkouts of this repo, and harnesses
written against them, carry `scripts/park-claude-md.sh`, which moved
the file into a `CLAUDE.md.park-lock` directory beside it for the
length of a batch. Do not run it. `scripts/check-arm-isolation.sh`
looks for that directory before it starts a session, and again once
its sessions finish. When it finds one, it says which checkout and
process took it, where the directory records one, and what to do next:
the commands that put the file back, or, when a `CLAUDE.md` is also in
place, to compare the two first.

**Trigger injection.** To force a specific code path (an escalation
rule, an edge case), plant an untracked dummy file that matches the
trigger instead of mutating anything real -- e.g.
`touch spec/factories/zz_dry_run.rb` to trip a rule keyed on
`spec/factories/**`. It exercises the genuine path end to end, risks
nothing in the target repo, and one `rm` reverts it. When the skill
claims to produce an artifact (a log file, a report), verify it exists
on disk.

**Selection-only paper runs.** For judgment-heavy rules that would be
slow or side-effectful to execute, prompt the session to apply the
skill's rules against real code but run nothing: stipulate a
hypothetical diff ("pretend the branch diff were exactly: ..."), tell it
to substitute real files when a stipulated one does not exist and say
so, and require the full decision output. This validates heuristics in
one pass without paying for their execution.

**Plant the memory directory for memory behavior.** A headless session
gets an auto-memory directory derived from its working directory:
`~/.claude/projects/<path>/memory/`, where `<path>` is the absolute
working directory with every character other than a letter or digit
turned into `-`. To test how a skill handles memory, plant the
`MEMORY.md` an arm needs at that path before the run, and remove the
whole `~/.claude/projects/<path>` directory after it. An arm about a
project with no auto-memory needs no `MEMORY.md` there. Give each arm
its own working directory, so each gets its own memory directory.

**Give an approval rule a turn that approves.** A rule that makes a
session propose and wait ends a two-turn arm at the proposal, in the
control and the treatment alike, so a grader that reads writes sees
nothing written on either side. Add a third turn with a neutral
approval that names no answer of its own ("Approved, go ahead."), grade
the second turn on what it proposes and the third on what it writes,
and read the writes as attempted tool calls in the stream rather than
files on disk, since a headless run is denied writes outside its
working directory. The same neutral turn shows whether a session takes
one "yes" as the answer to two questions.

**Read an arm the grader failed before counting it.** A grader that
looks for approval-seeking wording ("approve", "should I", a closing
question mark) misses phrasings like "Does that text work for you? If
so, I'll write it." When an arm is graded as not waiting but wrote
nothing, read its final message before scoring it, and widen the
pattern rather than correcting the score by hand.
The same miss applies to any behavior a grader recognizes by its
wording: an offer phrased "I can create it if you want", or a stop
phrased "someone else may already be working on it", reads as absent
until the pattern learns it.

**A word match counts a report that repeats a claim as one that caught
it.** A tally that looked for a planted wrong claim's key words scored a
report saying "verified: wraps fields in double quotes" as a catch, and
turned 2 of 6 into 3 of 6. Where an arm passes by naming a problem, read
whether the report calls the claim wrong, or make the pattern require
the contradiction and not the topic.

**Stub a CLI on the same words the real one dispatches on.** A stub
`gh` that switched on its first two arguments sent `gh api user` to its
"unsupported" branch instead of its `api` handler, and a strong model
then correctly reported that the login lookup had failed: a harness
fault that read as a finding. Match subcommands the way the real tool
parses them, and run each command the skill under test newly relies on
once through the stub before the batch.

**Test a shell snippet a skill ships by lifting it from the skill file
as written, never from a copy typed into the test.** A filter shipped
inside single quotes held an apostrophe in a comment, which ended the
quote; a retyped copy would not have had the comment, and would have
passed.

**Trace the tool calls before rewording a rule that never fires.** A
rule keyed on an event ("a line added because the test failed without
it") cannot fire for a session that never has the event. In one guidance
story one model ignored such a rule in every run, and its tool calls
showed why: it wrote the line into the test's first draft, copied from a
neighboring test, so the test never failed. The rule was rewritten to
key on what the line does, however it got there. When a rule scores the
same on control and treatment, print each run's tool calls in order from
its stream-json log and find the step where the rule should have
applied, before changing a word. A model that never consults the rule at
that step is a limit to record, not a wording to tune.

**When a rule tells a session to hold something back, check that what
the reader asked for is still there.** A grader built to catch a
pattern scores its absence as a pass, and cannot see what left with it.
In one guidance story a rule moved reassurance behind the explanation.
The control answered a yes/no question in ten runs of ten; the
treatment answered it in none of fifteen, and every grader passed those
drafts, because no scenario listed the answer as a required fact and
the rubric scored "Yes, it is working again" as the pattern. Give each
scenario a list of facts a good output must still contain, the answer
to any question asked among them, and compare their survival between
control and treatment.

**Fix the runs each pattern is counted over before the first run.** A
pattern that only two of six scenarios can produce reads as 8 of 30
over all six and 8 of 10 over the two, and a pass bar set as a share
gives a different verdict on each. Write down, per pattern, which
scenarios invite it, before any output exists. A pool changed after
seeing results is reported as changed, with both figures.

**Run the control again beside every treatment batch, and never compare
wordings on six runs.** The same brief, byte for byte, caught a planted
error in 3 of 6 runs in one batch and 0 of 6 in the next. Three rewordings scored 0 of 6, 2 of 6 and 1 of 10 in
between, and each read as a regression until the unchanged text scored
inside that spread. A rate that low needs at least twenty runs per arm
before two wordings can be told apart. With fewer, report the spread,
and where you can, change the design so it no longer depends on the
difference.

**Pin a container to one CPU to reproduce a race that fails only in
CI.** A test that wrote to the pipe of a child process which exits
without reading passed 30 runs of 30 in a Linux container with every
core available, and failed 28 of 40 with
`docker run --cpuset-cpus 0`: on one core the child runs, and exits,
before the parent writes. When a test passes locally and fails on a
shared runner with a broken pipe or a timeout, try the one-core
container before reading the failure as a flake.

**A control that passes does not clear the text.** A capable model
often does the sensible thing where the text says the wrong thing, so
an arm written to reproduce a bug can pass on the unfixed text. In one
story a model cut a fresh branch where the text told it to build on a
stale one, and the arm was green. The bug was real: running the text's
own commands, in order, in a scratch repository reproduced it. When a
finding names commands and a state, run those commands in that state
before deciding the finding is wrong, and record which fixes rest on
that run and not on an arm.

**Give an arm a second turn when the rule is about what a session does
with a go-ahead.** A rule that says "delete nothing here" was first
tested with one-turn arms, and the text it replaced passed them: Opus and
Sonnet asked before deleting, so the turn ended on a question in
control and treatment alike. A second turn saying only "Do what you
recommend." separated them. On the unfixed text all 20 runs on one
fixture had deleted branches by the end of that turn; on the final text
none of 6 had. Resume the session with the first turn's session id,
repeat every isolation flag on the second command, and grade both turns
from the tool's call log. A session that offers the forbidden action as
a choice, then takes it on the go-ahead, fails in a way the first turn
does not show.

**When a passage has taken three rounds of patches, write it again from
the cases it has to cover.** One section of a skill was patched four
times in a story. Each patch closed the gap a review had found, and the
review of each patch found a new one where two sentences could be read
against each other: a fixed summary line beside a deletion the user may
order, an exception that closed the only command safe to run. A patch
adds a sentence that every other sentence in the passage then has to
agree with. Past the second round, list the situations the passage must
answer (here: before the user says anything, the user names branches,
the user names a flag) and write one answer for each. The rewritten
section passed its arms.

**A short headless session may not produce what a long real one does.**
Rules against rhetorical habits measured in months of commit history
could not be tested the usual way: on the unfixed text the control
produced almost none of the habits, on any model, whether the session
was handed a finished change, made to find and fix the bug itself, or
run in a project whose history was written in that style. Where a
behavior comes from long sessions, look for a before and an after in
real history (the same model on the same project, either side of the
date the rule arrived), and say which rules rest on that count and which
on the arms.

## GitHub is required

The plugin requires a GitHub-hosted repository, on github.com or a
GitHub Enterprise host, and the GitHub CLI (`gh`) installed and
authenticated. Everything that reads pull requests or GitHub issues goes
through `gh`: the commands the skills and guidance give a session,
`bin/stale-branches`, and `bin/gh-issue-sync`. Issue trackers are a
separate matter: Linear and Shortcut are supported where the skills
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
command of the first kind runs with the user's credentials and decides
which branches the sweep deletes, so it has to be one the team trusts.
`test/fixtures/stub_gh.rb` shows the one call `stale-branches` depends
on, with the fields it reads.

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
