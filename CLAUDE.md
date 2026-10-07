# rules-that-bend

This repo is the `bendyworks` Claude Code plugin marketplace: the skills,
guidance files, and CLIs other people install and run. Contributor mechanics
-- how changes ship, the checks to run before a PR, how to write and
dry-run a skill -- live in [CONTRIBUTING.md](CONTRIBUTING.md). Read it before
opening a PR; this file carries only what a session working here needs in
order to behave correctly.

It was formerly `bendyworks/claude-skills`. Never create a repository by
that name in the bendyworks org: GitHub redirects it here only while the
name is free, and existing installers fetch the marketplace through that
redirect.

## Goals

Every issue, rule, and skill here is weighed against these goals. A good
idea that serves none of them is put to the maintainer as a question,
saying so, and is not filed or built until the maintainer answers.

1. **An elegant, efficient open source project.** A reader can copy one
   skill or one guidance file without taking the rest, learn from how it
   is written, and judge the maintainer's work by it. A skill someone can
   read in one sitting is worth more than one that covers every case.
2. **Fast checks.** The full suite runs in under three minutes, and a
   gauntlet run is short enough that nobody plans around it. A test or a
   check that slows either one has to be worth the time it adds to every
   later story.
3. **A shrinking issue list.** More issues close than open. A follow-up
   is filed with care and implemented straight away, in the story that
   found it or directly after. An idea not worth doing soon is dropped,
   not filed.
4. **Less, where less is better.** Work that cost more than it gave is
   found, then simplified or removed. Removing something is an ordinary
   outcome of a story.

## How the work is divided

The maintainer and a session write the issue and the plan together. The
session then implements the plan alone: it makes the development
decisions, writes and squashes the commits, and writes the pull request,
title and body included. The maintainer reviews that pull request
closely, and the review is where the session's decisions get overruled.

A session's question about a development detail works against this
division. So does a pull request the maintainer has to rewrite before
reviewing it: the pull request is the session's deliverable, and its
quality is judged as such.

## Deploy-on-Merge Mode

This project uses Deploy-on-Merge Mode: merging to the default branch is the
production deploy, with no later step that could still fail or be skipped.

The plugin carries no version field, so the merged commit is what installers
get. An installer running `/plugin marketplace update bendyworks` later is
adoption, not a deploy step that could fail, so nothing stands between a merge
and the change being live.

Merging here is the maintainer's, not a session's: this project declares no
Session-Merge Mode, so a session prepares a PR and hands it off. That matters
more here than on most repos, because the merge it would be claiming is the
production deploy above.

The `checks.yml` workflow that runs on pushes to `main` is not a step in the
way: it verifies what installers already have and cannot withhold a commit
from them, so a red run there is a bug to fix, not a deploy that failed.

## Tracker

GitHub Issues is this repo's tracker of record. GitHub issues here are called
RTB-NNN: RTB-NNN is issue #NNN.

Older references say CS-NNN, the key from when this repo was named
claude-skills. CS-NNN is GitHub issue #NNN, never a Linear ID. Names that
already say CS keep it. Nothing new is named with CS, whatever the issue's
number: new branches, plan files, and pull request titles use RTB, and so does
new work on an issue that shipped under CS.

## Everything here is public

This repo is public and its history is permanent. No client names, other
projects' tracker IDs (use the neutral `ABC-NNN` form), personal email
addresses, or absolute home-directory paths -- in code, prose, commits, or PR
descriptions. This repo's own `RTB-NNN`, the older `CS-NNN`, and `#NNN` are
fine in commits, PR titles, and PR descriptions; shipped skills and guidance
still use placeholders.
CONTRIBUTING.md has the full rule and the checks that enforce the mechanical
half of it.

Skills and guidance stay installer-generic: they are read by people with no
access to our machines or our private notes, so they must not reference
personal skills, private CLAUDE.md files, or anything a reader outside
Bendyworks could not act on.
