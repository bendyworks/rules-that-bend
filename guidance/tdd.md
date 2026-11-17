# Test-Driven Development by Default

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Implement changes test-first whenever the change is testable. The order
is non-negotiable: spec first, run it RED, then production code, then
run it GREEN. Every new spec must be observed failing on the pre-change
codebase before any production change makes it pass. If you have not
watched the spec be RED, you have not done TDD, no matter how confident
you are that the change is correct.

The cycle:

1. **Write the spec first.** Describe the desired behavior in a failing
   test before writing any production code. Phrase it in timeless
   terms, not as "the bug we're fixing".
2. **Run the spec and watch it fail.** A meaningful failure (wrong
   return value, missing method, wrong DOM state) confirms the spec
   exercises the intended code path. A spec that passes before the
   production change won't catch the regression later. This step
   happens BEFORE step 3, not retroactively.
3. **Write the production code.** The smallest change that makes the
   spec pass.
4. **Run the spec and watch it pass.**

If the production change and the spec both already exist and the spec
was never observed RED, verify retroactively. Both options below touch
working-tree state, so get the developer's explicit go-ahead first:

- stash or revert the production change, confirm the spec fails,
  restore the change, confirm it passes; or
- run the spec against the pre-change commit (main or HEAD~), confirm
  it fails there, then re-run on the branch and confirm it passes.

Commit the branch's work before either option. A checkout that
overwrites the working tree discards uncommitted changes with nothing
to recover them from: `git checkout <ref> -- <path>` writes over them
with no reflog entry, and restoring afterward with `git checkout HEAD
-- <path>` returns the files to the last commit rather than to the
state they were in. Committing first also makes that restore exact,
which is what turns the technique from risky into routine.

Specs that have never been observed RED are presumed broken until
proven otherwise. A common temptation to skip the retroactive check is
fixing findings from a code-review pass after the fact; it applies
there exactly as everywhere else.

Why watch-it-fail is non-negotiable: a spec that "looks right" and a
production change that "looks right" can each pass on their own merits
while testing the wrong thing. The RED run proves the spec depends
on the production behavior, not on something incidental (a setup
callback, a default value, an unrelated migration). Skip it and you
can ship code that's untested in spirit, even when CI is green.
The verification-habits guidance has the question to ask of a setup
step that prepares state for the code under test.

When TDD doesn't fit:

- Pure refactors with no behavior change (the existing specs are the
  safety net; green after the refactor means done).
- Spike or exploratory code intended to be thrown away.
- Trivial config or string-only changes.
- Documentation, comments, README updates, apart from the spec a
  behavior kept on purpose needs (below).

Otherwise, default to test-first. If you find yourself writing
production code before the spec, stop and back up.

## A behavior kept on purpose gets its spec when it is decided

**When someone decides to keep a behavior that a reader would take for
a bug, the change that records the decision adds a spec pinning it,
even when no production behavior changes.** A decision that lives only
in a plan, a thread, or a pull request leaves the code reading like a
missing check, and the next reader, a person or a tool, reports it as
one. What counts:

- one path allows what its sibling paths refuse, such as an import that
  keeps a row the signup form would reject;
- a boundary left open on purpose;
- an error left unraised on purpose.

A decision that matches none of these needs no spec of its own. The
code-comments guidance covers the comment that goes beside one that
does.

Such a spec passes on the pre-change code by design, so a deliberate
break stands in for the red run. With the spec passing, add the check a
reader would expect, run the spec where the tests load the edited code,
and see it fail; when it stays green, change the spec or move the check
onto the path the spec exercises until it does. Then remove exactly the
lines you added, by editing them out rather than with a git command
that resets the file, and run the spec again to see it pass before
committing it. The break touches nothing but your own lines, so it
needs no go-ahead.
