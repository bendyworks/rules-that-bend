# Private Material Stays Out of Public Destinations

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

**Before the first commit message, pull request, issue, comment, or
code comment bound for a repository, and before the first push to it,
run `gh repo view <owner>/<repo> --json visibility` (or the equivalent
on a host that is not GitHub) and read the answer.** Name the
destination in the command (on a GitHub Enterprise host,
`<host>/<owner>/<repo>`): a bare `gh repo view` reads whichever
repository `gh` resolves for the checkout, and the destination is not
always that one (an issue about one project can be bound for another).
One lookup per destination is enough. Before each push, read the
messages of the commits about to go: an unpushed message can still be
fixed with an amend or a reword. Whoever can read the repository can
read its branch names, committed files, wiki, discussions, and release
notes, so the answer covers those too. A gist is not covered by it: a
secret gist is readable by anyone who has its link, so write any gist
as for a public destination.

- **Visibility is a property of the destination, never of its owner.**
  A developer's own public repository is not an exception, and neither
  is one they are the sole contributor to. `INTERNAL` means every
  member of the enterprise can read it, across all its organizations:
  treat it as public unless the material belongs to that enterprise.
- **Where the destination is public, nothing that identifies a private
  source goes in:** no names of clients, employers, or their projects,
  no names of those organizations' people or accounts, no links to
  private repositories, no issue or pull request numbers from them, no
  other project's tracker IDs, no URLs into its tracker or other
  private pages, no internal hostnames. Whether the session thinks of
  the source as a "client" is beside the point; what matters is that
  the reader of the public text was never given access to it. The
  destination project's own references are fine: its issue and pull
  request numbers, and a bare issue ID from its own tracker
  (`Refs: ABC-123`), though not a private tracker's titles or URLs.
- **Figures count, not only names.** "400 merged pull requests, 380 of
  them merged by their own author" is someone's operational data as
  soon as a name sits beside it. Write "one repository we measured" and
  keep the number, or keep neither.
- **A private destination is safe only for material its readers
  already have access to.** One client's names and figures stay out of
  another client's private repository, however private it is.
- **Unknown is public.** When the visibility cannot be established (a
  host with no such lookup, a lookup that fails), write as for a public
  destination and tell the developer it was not confirmed.
- **Private today is not private forever.** A repository that is later
  opened takes its commit history, issues, pull requests, and comments
  with it. When the developer has said a private repository may go
  public, write everything bound for it as for a public one.

The check comes first because the costs are lopsided. It is one
command at the start of the work. Afterwards, a pull request body can
be edited and its earlier revisions deleted, but a pushed commit
message can only be fixed by rewriting history, and on a stacked chain
the bottom commit is contained in every branch above it, so the rewrite
cascades through the stack and re-triggers each branch's review and CI.

## When private material is already public

**On finding private material already published, stop and tell the
developer what leaked and where, before any other action on the pull
request, issue, or branch that holds it -- even when the request in
hand is unrelated.** Marking a draft ready notifies more readers, and a
squash merge copies the title and body into a commit message, so
neither goes ahead. Never quietly edit the text away: an ordinary edit
leaves the earlier text in the edit history, which anyone who can read
the repository can open. This takes precedence over the pull-requests
guidance's rule for revising a draft's title or body. Keep the leaked
text out of whatever the fix itself publishes (a commit subject, a
replacement comment). The developer decides the remedy, and on GitHub
it differs by what was written:

- **A comment:** delete it and post a clean one, or edit it and then
  delete each earlier revision from its edit history.
- **An issue or pull request body:** edit it, then delete each earlier
  revision from its edit history.
- **A title:** the old one stays in the timeline as a rename event. A
  repository admin can delete an issue and it can be refiled; a pull
  request cannot be deleted.
- **A commit message, a code comment, or other committed text:**
  rewrite history and force-push; for a code comment or other
  committed text, a commit that only removes it still shows it in its
  own diff. The old commit stays reachable by its hash and through any
  pull request that references it until GitHub Support agrees to purge
  it, and in every fork and clone regardless.

Say what no remedy reaches: notifications already sent carry the
original text, and so does anything copied or indexed in the meantime.
