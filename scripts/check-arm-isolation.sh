#!/usr/bin/env bash
# Check that `--setting-sources project` keeps user-level instruction
# files out of a headless dry-run arm on this machine's Claude Code.
# Whether it does has differed between builds, so run this before a
# batch that relies on the flag, and again after an update.
#
# Usage:
#   scripts/check-arm-isolation.sh
#
#   CLAUDE_BIN    the claude to check (default: claude on PATH)
#   TMPDIR        where the scratch directory goes (default: /tmp)
#
# It starts two one-word sessions from a scratch directory, one with the
# flag and one without, and has Claude Code itself report each
# instruction file it loads, through an InstructionsLoaded hook passed
# on the command line. Nothing depends on what a model says. The arms
# run with no built-in tools and no MCP servers from your configuration.
# Session saving and auto-memory are off, so Claude Code leaves nothing
# in the config directory.
#
# Each arm makes one small model request. The arm without the flag is a
# real session with your own settings: it sends your user-level
# CLAUDE.md and rules to the model, applies your `env` block and
# `apiKeyHelper`, loads your plugins, and runs your hooks, which may
# write files of their own. The arm with the flag gets none of those,
# so a sign-in that comes from your user settings fails there.
#
# Exit status:
#   0  the flag isolates: user-level files loaded without it, none with
#   1  a user-level file loaded with the flag, so an arm run with it on
#      this build reads your own rules; CONTRIBUTING.md says what to do
#   2  cannot tell, and the message says why: among other reasons, claude
#      is older than 2.1.101, an arm failed, or nothing user-level
#      loaded even without the flag
#
# The arm without the flag is what makes a pass mean something: with the
# user-level files absent, an arm loads none either way.
# A rules file scoped with `paths:` loads only when a session reads a
# matching file, so it is not seen here; it comes from the same
# user-level source as the files that are.
# No -e: every failure here is checked by hand, wait must hand back each
# arm's status, and a grep that matches nothing is an answer, not an
# error.
set -uo pipefail

say() { echo "check-arm-isolation: $*"; }
cannot_tell() { say "cannot tell: $*" >&2; exit 2; }

[ "$#" -eq 0 ] || { say "usage: $0" >&2; exit 2; }
# Looked up once, so the version guard below and the arms run one file.
# The arms run from the scratch directory, where a relative path points
# nowhere, and a shell function or builtin comes back as a bare word the
# guard would run and exec would not.
CLAUDE="$(command -v -- "${CLAUDE_BIN:-claude}")" || cannot_tell "${CLAUDE_BIN:-claude} is not installed or not on PATH."
case "$CLAUDE" in
  /*) ;;
  *) cannot_tell "${CLAUDE_BIN:-claude} resolves to $CLAUDE, not to a file's absolute path. Set CLAUDE_BIN to the absolute path of claude." ;;
esac

# Copies stdin with a leading home directory written as ~, so a report
# pasted into an issue carries no home-directory path. A HOME ending in
# a slash would match the front of no path.
tilde() {
  local line home="${HOME:-}"
  home="${home%/}"
  while IFS= read -r line; do
    if [ -n "$home" ]; then
      case "$line" in "$home"/*) line="~${line#"$home"}" ;; esac
    fi
    printf '%s\n' "$line"
  done
}

# Copies the error output saved in file $1, indented, or says there was
# none.
indented() {
  if [ -s "$1" ]; then sed 's/^/  /' "$1"; else echo "  (no error output)"; fi
}

# The arms are stopped before the scratch directory goes, so a check
# that is interrupted leaves no session running. Each process ID is
# cleared once its arm has been waited for, since it can be reused.
scratch=
plain_pid=
flagged_pid=
cleanup() {
  [ -z "$plain_pid" ] || kill "$plain_pid" 2>/dev/null
  [ -z "$flagged_pid" ] || kill "$flagged_pid" 2>/dev/null
  [ -z "$scratch" ] || rm -rf "$scratch"
}
trap cleanup EXIT

scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-arm-isolation.XXXXXX")" || { scratch=; cannot_tell "could not create a scratch directory in ${TMPDIR:-/tmp}."; }
# Made absolute because the arms run from inside it, where a relative
# TMPDIR would point somewhere else.
absolute="$(CDPATH= cd -- "$scratch" && pwd -P)" || cannot_tell "could not enter $scratch."
scratch="$absolute"
mkdir "$scratch/arm" && cd "$scratch/arm" || cannot_tell "could not enter $scratch/arm."

# Before 2.1.101 a session run without the user setting source deleted
# conversation history older than 30 days, whatever the user's settings
# said, and the flagged arm is such a session. So no arm starts until
# the version is known to be past that. It is read from the directory
# the arms run in, since a launcher can pick a build by directory.
# Anything but three plain numbers, with or without a leading v, counts
# as unreadable, a pre-release suffix included: refusing a build that
# would have been safe costs a message, and the other mistake costs
# history.
version="$("$CLAUDE" --version 2>/dev/null | head -n 1)" || version=
number="${version%% *}"
number="${number#v}"
case "$number" in
  *[!0-9.]* | *.*.*.* | *..* | .* | *.) number= ;;
  *.*.*) ;;
  *) number= ;;
esac
[ -n "$number" ] || cannot_tell "could not read a version from $CLAUDE --version (it printed: ${version:-nothing}), so no session was started."
IFS=. read -r major minor patch <<EOF
$number
EOF
if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && { [ "$minor" -lt 1 ] || { [ "$minor" -eq 1 ] && [ "$patch" -lt 101 ]; }; }; }; then
  cannot_tell "Claude Code $number is older than 2.1.101. Before that, a session run with --setting-sources project deleted conversation history older than 30 days, so no session was started. Update Claude Code first."
fi

# A project file for both arms to report loading. Without one, an arm
# that kept every user-level file out would report nothing at all, which
# is also what a hook that never fired looks like.
echo "# check-arm-isolation scratch project" > CLAUDE.md || cannot_tell "could not write $scratch/arm/CLAUDE.md."

# Settings that log each instruction file the arm named $1 loads to
# $scratch/$1.log, one JSON object a line. awk 1 copies the hook's input
# and ends it with a newline, in one write for a payload this small, so
# two hooks running at once cannot share a line.
logging_settings() {
  printf '%s' "{\"hooks\":{\"InstructionsLoaded\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"awk 1 >> '$scratch/$1.log'\"}]}]}}"
}

plain_settings="$(logging_settings plain)"
flagged_settings="$(logging_settings flagged)"

# Runs one arm named $1 on the JSON settings in $2, with any further
# arguments added. exec makes the background job
# claude itself, so its process ID is the one to stop.
arm() {
  local name="$1" settings="$2"
  shift 2
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 exec "$CLAUDE" -p "Reply with the single word ready." \
    --model haiku --tools "" --strict-mcp-config --no-session-persistence --settings "$settings" "$@" \
    > /dev/null 2> "$scratch/$name.err" < /dev/null
}

# The two arms run side by side, so a user-level file that appears or
# goes partway through is far likelier to be there for both or for
# neither.
# bash's own report of an arm killed by a signal is silenced; the status
# says as much.
arm plain "$plain_settings" &
plain_pid=$!
arm flagged "$flagged_settings" --setting-sources project &
flagged_pid=$!
wait "$plain_pid" 2>/dev/null
plain_status=$?
plain_pid=
wait "$flagged_pid" 2>/dev/null
flagged_status=$?
flagged_pid=

# Says which arm ($1, in words) failed with status $2, and shows what
# arm $3 wrote to stderr beneath it.
arm_failed() {
  {
    say "cannot tell: the arm $1 exited $2:"
    indented "$scratch/$3.err"
  } >&2
  exit 2
}
[ "$plain_status" -eq 0 ] || arm_failed "without the flag" "$plain_status" plain
[ "$flagged_status" -eq 0 ] || arm_failed "with the flag" "$flagged_status" flagged

# The paths of the files of kind $1 (User or Project) in arm $2's log,
# as the log writes them. The pattern steps over an escaped quote, so a
# path with a quote in it is not cut short.
loaded() {
  [ -f "$scratch/$2.log" ] || return 0
  grep -E "\"memory_type\": ?\"$1\"" "$scratch/$2.log" |
    sed -n -E 's/.*"file_path": *"(([^"\\]|\\.)*)".*/\1/p'
}

plain_files="$(loaded User plain)"
leaked="$(loaded User flagged)"

if [ -n "$leaked" ]; then
  {
    say "--setting-sources project does not isolate an arm on $version. These user-level files loaded with it:"
    printf '%s\n' "$leaked" | tilde | sed 's/^/  /'
    say "run no batch that relies on the flag on this build; see \"Dry-running a skill\" in CONTRIBUTING.md."
  } >&2
  exit 1
fi

# Checked after the leak, so a leak is reported however little else the
# flagged arm said.
if [ -z "$(loaded Project flagged)" ]; then
  cannot_tell "the arm with the flag did not report loading its own project file, so the hook may not fire under the flag on $version, and its silence about user-level files proves nothing."
fi

if [ -z "$(loaded Project plain)" ]; then
  cannot_tell "the arm without the flag did not report loading its own project file, so the hook did not fire there; hooks may be turned off in your user settings."
fi

if [ -z "$plain_files" ]; then
  cannot_tell "no user-level instruction file loaded even without the flag. This machine has none for the flag to keep out, so the check has nothing to tell by."
fi

say "--setting-sources project isolates an arm on $version: $(printf '%s\n' "$plain_files" | wc -l | tr -d ' ') user-level instruction file(s) loaded without the flag, none with it."
