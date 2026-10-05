# Client Messages

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

A message to the people who use or run the app (a client's staff, a
stakeholder, a teammate outside the codebase) is read by someone who
cannot see the code and has to act on what it says. Asked to be warm
or informal, a session reaches for the same few moves in every
message, and a reader who gets several a week learns to skim them.
This file names those moves. It prescribes no greeting, sign-off, or
voice; those are each developer's own.

## Say it; never announce it

**Start the message, and each paragraph in it, on its content.**

- No opener that grades the reader's message: "Good catch", "Great
  question", "Thanks for flagging this", "You're right". Answer it.
  When the reader's guess was wrong, say so plainly near the top:
  "The new importer isn't the cause."
- No sentence whose only job is to say a point is coming: "One thing
  to decide first:", "Quick heads up:", "Here's what happened:",
  "I found a separate issue you should know about:". Start with the
  point.
- No sentence that counts the items before giving them: "Two
  options:", "A couple of things", "There are two ways to do this".
  Give the items.

## Mechanism before reassurance

**Say what happened before saying how much it matters.** "Good news",
"nothing to worry about", or "no one was affected" ahead of the
explanation asks the reader to take a verdict on trust, and reads as
managing them.

**The fault is the placement, never the content: a message still says
what the problem did not touch and whether the reader has anything to
do.** "No invoice went out with the wrong total" and "you don't need
to do anything" are facts the reader needs. State them after the
cause, as plainly as the rest.

- Before: "Good news, nothing was lost! The nightly export ..."
- After: "The nightly export stopped at row 400 when a customer name
  contained a tab. I've fixed that and rerun it, and all 912 rows are
  in the file now. No invoice went out with the wrong total."

## A finding is a finding

**Report a problem found beyond the request the way the request
itself is reported: what it is, who it affects, whether it is fixed.**
Leave out the story of the search: "while I was in there", "while
digging into this", "I also went back through".

## Ask, and let the question stand

**When the message needs an answer, the question is its last sentence
before any sign-off.** Nothing follows it: no "either works for me",
no "happy to go whichever way", no reassurance.

**End where the information ends.** No "Let me know if you have any
questions", "happy to help", "no rush", or "I'll keep you posted". A
commitment with a date is information and stays: "The notes fix will
be deployed on March 14." The writing-about-change guidance covers
tense for a message about a change, shipped or not.

## Words to cut

As softeners and intensifiers: just, actually, really, real, exactly,
genuinely, quietly, silently, "the whole point", "on my end", "on
your end", "on our side". Each sentence says the same thing without
them.
