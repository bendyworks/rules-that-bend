# Commit Message Style

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Commit messages follow one shape, adapted from
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): Title Case Outcome Description

The WHAT and the HOW, in as many paragraphs as needed.

BREAKING CHANGE: what breaks, when something does
Refs: ABC-123
Co-authored-by: Name <email>
```

Treat the description -- the part after the prefix -- as a **title**,
not a sentence. It answers WHY: the user-visible outcome or the reason
the change exists, in the most succinct, instantly understandable form.
It should be skim-readable in `git log --oneline`. Quickly
understandable beats grammatically complete; some excellent
descriptions are just two words.

## The type(scope) prefix

- `type` names the mechanism category: `feat`, `fix`, `build`, `chore`,
  `ci`, `docs`, `style`, `refactor`, `perf`, `test`, or `revert`
  (see Reverts below).
- `scope` is optional: a short app-area noun in parentheses, e.g.
  `feat(marketplace):`. Keep scope names consistent within a project;
  drifting spellings (`marketplace` one week, `mktpl` the next) quietly
  erode the pattern's parseability.
- The prefix is the recommended default, not a hard requirement; a
  plain Title Case title is still acceptable. Be honest about the
  tradeoff, though: the structure's payoffs -- changelog generation,
  release automation, lint gates -- only accrue where a project carries
  the prefix on every commit. A team that wants that tooling should
  mandate the prefix in its own project rules.

## Descriptions

- Write for a teammate who knows the product but wasn't in the weeds
  of this change. Prefer the WHY / real-world outcome over the WHAT /
  code mechanism.
- Prefer Title Case noun phrases or a leading OUTCOME verb (`Limit`,
  `Prevent`, `Stop`, `Speed up`) over mechanism verbs (`Add`,
  `Update`, `Move`). The type already carries the mechanism category,
  which frees the description to carry the point of the change. In an
  unprefixed title, an outcome verb like `Fix` or `Prevent` does the
  type's job.
  - Strong: `feat(marketplace): Limit Public Search to Intended Fields`
  - Weak: `feat(marketplace): Add ransackable_attributes allowlists`

  **The test for a leading verb: it names what a user or operator
  gets, not what was done to the code.** `Tighten`, `Lock`, `Harden`,
  `Cover`, and `Guard` fail it the way `Add` and `Update` do: each
  says the code was changed and not what anyone gets. The outcome
  verbs above pass it. `Pin` stays for a spec that pins existing
  output, where the pinned output is the outcome. A change with no
  such outcome (a test, a build or dependency change, a pure
  refactor) takes a noun phrase naming what it covers or changes:
  `test(refunds): Second Partial Refund Over the Total`, or the
  `refactor` example below.
- Don't build the description on a slogan form: "One <Noun> for ..."
  (`One Home for the Tax Rate`) or a contrast (`Derived, Not
  Stored`). Name the outcome:
  `fix(pricing): Invoice Charges the Cart's Tax Rate`.
- Don't repeat the type as the description's leading verb.
  - Redundant: `fix(reports): Fix Broken CSV Export`
  - Better: `fix(reports): Broken CSV Export for Embedded Commas`

  The same logic makes `refactor` legitimate as a type even though it
  is a poor description verb: `refactor(billing): Shared Late Fee
  Calculation` says what the cleanup achieved; the prefix already
  says it was a refactor. `revert` works the same way: the type says
  a commit was undone, freeing the description to name what the tree
  is back to (see Reverts).
- Don't stack library jargon or internal nouns in the description. If
  a technical term is genuinely needed, it goes in the body; the
  description stays plain.
- No file lists, mechanism dumps, or "and also fix X" tail clauses. If
  the description needs an "and", it should usually be two commits; if
  the change genuinely can't be split, the description still names the
  single user-facing outcome and the body explains the rest.
- Keep the whole first line to roughly 72 characters; an unprefixed
  title should fit a tighter ~60-character skim target. A description
  that can't fit is a smell that the scope is too long or the commit
  too big.
- Read it aloud before committing: if a teammate couldn't tell what
  changed and why it matters, rewrite it.

## Bodies

- After the blank line, cover the WHAT and the HOW: which files and
  mechanisms changed, the technical details, and any non-obvious
  tradeoffs. Multiple paragraphs are fine. When the point of the
  change rests on in-repo machinery (e.g. a guard spec), spend a
  sentence or two saying what that machinery does before describing
  how the change alters it -- a body that only makes sense after
  opening the file it references has not carried its weight in
  `git log`.
- Keep the body focused on the permanent record: motivation,
  mechanism, tradeoffs. The strongest motivation names the concrete
  cost or risk of leaving the code as it was: "the email and the
  statement now share one fee calculation" states a fact, while
  "before this change, the email quoted a higher late fee than the
  statement charged" names the cost that justifies the commit. A risk
  is named as what the code requires or allows: "a change to the late
  fee had to be made in both the email and the statement". For a
  change that adds something new, the user-visible outcome is
  motivation enough.
- The commit is the reader's "after": behavior it contains takes
  present tense ("the report now pages at 100 rows"), and the
  behavior it replaces carries a label ("before this change, it
  loaded every row"), never a calendar word like "today". The
  writing-about-change guidance covers the rest.
- Reviewer pointers ("start with file X", "the key test to scrutinize
  is Y") and out-of-scope notes ("filed as ABC-123", "deferred to the
  next PR") belong in the PR description instead. Commits live in
  `git log` forever and are read in many contexts; PR-scoped guidance
  decays badly when separated from its PR. The footer's `Refs:` names
  the one issue this commit serves; cross-references to any other
  issue stay at the PR level.
- **How the problem was found belongs in the PR description too**
  (or the tracker issue, where a project has no pull requests).
  Never name the review pass, tool, bot, or review round that caught
  it ("flagged by the automated review", "found in the second review
  pass"), and never thank one. A lint rule or check the commit is
  about is its subject, and is named.
- For word choice throughout the message, follow the Plain language
  rules in the code-comments guidance.

### Defaults to avoid

A body can follow every rule above and still read as machine-written:
the same few rhetorical moves turn up in commit after commit, and a
reader who recognizes them starts skimming.

- **At most one ", so" join per paragraph, and at most one dash used
  as punctuation (" -- " or an em dash) per body.** A chain of them
  walks each paragraph to its worst consequence ("..., so the total
  was wrong, so a customer could be overcharged"). Say the
  consequence once in the message, where it is the point, and end the
  other paragraphs on what the code does.
- **Use a contrast only for a distinction the reader needs.** "The
  header uses the office date, not the UTC date" says which of two
  real options the code takes. "Proven rather than assumed" and
  "checked, not guessed" set the change against something no one
  proposed.
- **Never close on a guarantee without its mechanism.** "So the two
  can no longer disagree" gives a reader nothing to check. "Both now
  call `LateFee.cents`" does, and needs no guarantee after it.
- **No verdict sentence and no maxim.** A sentence of two to five
  words that judges the one before it ("It did not.", "That is
  wrong.") and a general saying as a paragraph's last line ("A
  receipt that needs explaining is not a receipt.") add emphasis and
  no information.
- **No irony about what the code was for:** "the one case the guard
  exists to catch", "the document a receipt exists to match". Say
  what the code did.
- **No imagined people or events:** "a future maintainer", "a
  well-meaning cleanup", a "would have" sentence about a case that
  did not happen, "Left alone, ...". Describe what the code does and
  what happened. A risk named the way Bodies describes is not an
  imagined event.
- **Don't make "nothing" or "nobody" the subject.** "Nothing enforced
  that" becomes what was missing: "neither caller checked the
  amount".

## Footers

Footers are git trailers -- `Token: value` lines after a blank line
following the body (a value may wrap onto continuation lines):

- `Refs: <issue-id>` names the tracker issue the commit serves, in
  that tracker's native form: `Refs: ABC-123`, `Refs: SC-123`,
  `Refs: #123`. Use `Refs:` rather than `Fixes`/`Closes` -- GitHub
  closes the referenced issue the moment a `Fixes`/`Closes` commit
  reaches the default branch, so reserve those for the rare commit
  where auto-close is the intent.
- `BREAKING CHANGE: <description>` (uppercase, per the spec) marks a
  breaking change. The spec also offers a `!` shorthand
  (`feat(api)!:`), but prefer the explicit footer: with a bare `!` and
  no footer, the spec routes the breaking-change description into the
  first line, displacing the outcome phrase.
- `Co-authored-by: Name <email>` credits co-authors, one trailer
  line per person (GitHub's documented spelling of the trailer).
- `Reverts: <sha>` names a reverted commit, one trailer line per
  commit, the same one-line-per-value form as `Co-authored-by:`.
  Use the full 40-character SHA -- short SHAs go ambiguous as a
  repo grows -- and read the trailers back with
  `git log --format='%(trailers:key=Reverts,valueonly)'`. The
  policy for revert commits lives in Reverts below.

## Reverts

A revert follows the same shape as any other commit, with type
`revert`, as the spec's
[FAQ answer on reverts](https://www.conventionalcommits.org/en/v1.0.0/#how-does-conventional-commits-handle-revert-commits)
recommends (the footer token here is `Reverts:`, not the FAQ's
`Refs:`):

```
revert: Full-Field Public Search

Rolling back the allowlist tightening: it broke saved searches for
existing marketplace users.

This reverts commit 676104e3e5f38e34b04e4f56581df8d6f6ef7a01.

Reverts: 676104e3e5f38e34b04e4f56581df8d6f6ef7a01
Refs: #123
```

- The description names the restored outcome -- what the tree is
  back to -- never the reverted commit's title, which is what git's
  default `Revert "<old title>"` carries and names only what was
  undone. Prefer a bare noun phrase; an outcome verb is fine when
  it does not repeat the type (see Descriptions). In an unprefixed
  title, a leading `Revert` or `Restore` does the type's job.
- Keep git's generated "This reverts commit <sha>." sentence in the
  body and write the why-prose around it. conventional-changelog's
  revert detection (the conventionalcommits preset) needs both that
  sentence and an unscoped `revert:` start to the first line -- a
  scope like `revert(marketplace):` silently turns detection off,
  so keep revert headers unscoped where that tooling matters.
- Revert commit-by-commit by default: `git revert A B C` produces
  one commit per SHA, each with its own generated sentence. A
  single commit carrying several `Reverts:` lines is the exception
  for commits that were one logical change (per Practices); git's
  `revert --no-commit` generates no message for it, so each "This
  reverts commit <sha>." sentence is written by hand.
- `Refs:` names the motivating issue when one exists -- the
  incident or bug that forced the revert.
- A generated revert message that is already pushed (GitHub's
  Revert button, a scripted rollback) stays as-is: pushed history
  is not rewritten for message shape (see Practices).

## Practices

- Prefer more, smaller, targeted commits over fewer, larger ones; each
  commit represents one logical change. A commit that seems to need
  two types is the same smell wearing a prefix: split it.
- If you cannot name a cost or risk of leaving the code as it was, the
  change may not deserve a commit at all. Preparatory commits are the
  exception: a seam or an extraction is justified by the change it
  enables, not by the status quo.
- Generated messages are exempt from this shape: merge commits and
  bot commits keep their generators' formats, which are themselves
  conventions other tooling and readers rely on (`git log
  --merges`, bot changelogs). Reverts are not exempt (see Reverts).
- Never amend or rewrite pushed commits without an explicit request.
- **A pushed commit message cannot be edited without rewriting
  history, so check the visibility of the repository it is going to
  before writing it** (`gh repo view <owner>/<repo> --json
  visibility`). Unless the answer is `PRIVATE`, keep out anything that
  identifies a private source: names, other projects' tracker IDs,
  links, and figures that sit beside any of those. The project's own
  `Refs:` ID stays. The public-destinations guidance carries the full
  rule.

## Enforcing the prefix in CI

A team that mandates the prefix can enforce it in CI with a
dependency-free workflow check; the copyable, tested snippet and its
variants (squash-merge title lint, Dependabot prefixes, branch
protection) live in
[enforcing-commit-prefix.md](enforcing-commit-prefix.md), a setup
reference for humans that needs no session import.
