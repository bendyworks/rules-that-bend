# Verification Habits

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Plausibility is not verification. An AI session produces fluent,
confident-sounding claims by default; these habits exist so that
confidence is earned empirically before it lands in code, comments,
or anything other people will read.

## Verify before asserting a fix is needed

Before asserting code is broken ("X was removed from library Y",
"call Z will fail") and editing to fix it, verify the claim
empirically: read the installed library source, run or compile the
code path, build the assets. Don't rely on general knowledge of a
library's version history. Confident-sounding "orphaned call site"
findings are often dead code or simply wrong.

## Never write unverified facts about people

Never write a person's name, title, or attribution into any
deliverable (README, CONTRIBUTING, commits, PR bodies, tracker
issues, drafted messages) without verifying it against an
authoritative source: `gh api users/<login>`, `git config user.name`,
git log authorship, the tracker's user record, or asking the
developer. If unverified, use the handle or an explicit placeholder
(`<Name>`) and say it needs filling in. A fluent, plausible-sounding
full name is exactly how a fabricated one slips through.

## Check schemas and signatures before use

- Before using a database column, verify it exists with the exact
  name and type expected -- read the schema, don't assume. Sibling
  names are the classic trap: `archived` vs `archived_at`,
  `message_id` vs an integration-specific ID column.
- Before calling a method, check whether it is a class method or an
  instance method, and verify its return value. Handle both success
  and failure cases.

## Look up identifiers; never complete them

Never write a full commit SHA, issue number, URL, or other identifier
you have not just read from its source. A short SHA expanded by hand
looks exactly like a real one and names nothing: run
`git rev-parse <short>` for the full form. An identifier recalled from
earlier in the session gets the same lookup before it lands in a
commit, a record file, or a message.

## Setup reproduces production; it never repairs the test

**A setup step that prepares state for the code under test, beyond the
input it works on, gets one question before it stays: when this code
runs in production, what guarantees this state, and can it have changed
since?** Such a step creates a directory the code writes into, builds or
refreshes a cache it reads, sets a variable it requires, or runs
something that has to come first. The question applies however the
step got there: added because the test failed without it, written in
advance because you could see the test would fail, or copied from a
neighboring test. When setup does something the code under test should
do itself, the test measures the harness: it passes, and it keeps
passing after the code breaks.

- **The code under test should, or nothing does:** the step hides a bug.
- **Something set it once:** it can go stale, so the step hides a bug
  too. A cache built at install time and the default branch `git clone`
  records were each right once, and nothing keeps them right.
- **Something else does, every time the code runs** (the environment
  the service starts in, the framework, a step the user always takes
  first): the step reproduces production. Keep it, with a comment naming
  what guarantees the state. Name only a guarantee you have found in the
  project or its framework; when you cannot find one, ask the developer.

**Never keep a step that hides a bug: fix the code when it is part of
the current story, and otherwise stop and tell the developer, with the
failing test left uncommitted.**

Setup that builds the input the code works on (records, input files,
arguments) needs none of this, though a step that then refreshes or
corrects that input does. Neither do the controls that make a test
isolated and repeatable: stubs, a frozen clock, seeded randomness, a
test delivery mode, database cleaning. Those have no production
counterpart to ask about.

## A planned check closes only by running

When a plan names a specific check -- a browser walkthrough, a console
query on staging, a manual QA step -- it closes only when the check runs
and passes, whether the session ran it or the developer says they did. A
run that fails is a finding to fix, not a closed check. Evidence
gathered another way is reported beside it, and the check stays listed
as outstanding until then. A check the developer drops is reported as
dropped at their direction, never as passed. The browser-checks guidance
covers a check that needs a signed-in browser.
