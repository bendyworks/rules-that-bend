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
#   ARM_SETTINGS  a settings file the arm with the flag also gets, for a
#                 sign-in that comes from your user settings (an
#                 `apiKeyHelper`), which the flag leaves out. Give it
#                 the file your batch passes its arms with --settings.
#                 That arm is a real session on those settings, so
#                 the file's `apiKeyHelper` and hooks run. Needs ruby.
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
# write files of their own.
#
# Exit status:
#   0  the flag isolates: user-level files loaded without it, none with
#   1  a user-level file loaded with the flag, so an arm run with it on
#      this build reads your own rules; CONTRIBUTING.md says what to do
#   2  cannot tell, and the message says why: among other reasons, claude
#      is older than 2.1.101, an arm failed, or nothing user-level loaded
#      even without the flag
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

CLAUDE="${CLAUDE_BIN:-claude}"
origin="$PWD"

say() { echo "check-arm-isolation: $*"; }
cannot_tell() { say "cannot tell: $*" >&2; exit 2; }

[ "$#" -eq 0 ] || { say "usage: $0" >&2; exit 2; }
resolved="$(command -v -- "$CLAUDE")" || cannot_tell "$CLAUDE is not installed or not on PATH."
# Looked up once and made absolute, so the version guard below and the
# arms run one file. They run from the scratch directory, where a
# relative path, or a bare name found through a relative PATH entry,
# would point nowhere or at another claude. A bare word back from
# command -v is a shell function or builtin, which has no path to keep.
case "$resolved" in
  /*) CLAUDE="$resolved" ;;
  */*) CLAUDE="$PWD/$resolved" ;;
  *) cannot_tell "$CLAUDE is a shell function or builtin here, not a file. Set CLAUDE_BIN to the path of claude." ;;
esac

# The home directory without a trailing slash, which would keep it from
# matching the front of any path not built from $HOME itself.
home_dir() {
  local home="${HOME:-}"
  while [ "${home%/}" != "$home" ]; do home="${home%/}"; done
  printf '%s' "$home"
}

# Copies stdin with a leading home directory written as ~, so a report
# pasted into an issue carries no home-directory path.
tilde() {
  local line home
  home="$(home_dir)"
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

# Checked before anything is created, and made absolute because the
# arms run from the scratch directory.
arm_settings="${ARM_SETTINGS:-}"
if [ -n "$arm_settings" ]; then
  { [ -f "$arm_settings" ] && [ -r "$arm_settings" ]; } ||
    cannot_tell "could not read the ARM_SETTINGS file $(printf '%s\n' "$arm_settings" | tilde), so no session was started."
  case "$arm_settings" in /*) ;; *) arm_settings="$PWD/$arm_settings" ;; esac
  command -v ruby >/dev/null ||
    cannot_tell "ARM_SETTINGS needs ruby, to merge the file with the hook this check passes its arms, and ruby is not on PATH. No session was started."
fi

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

# A TMPDIR that starts with a dash would be read by mktemp as an option.
tmp="${TMPDIR:-/tmp}"
case "$tmp" in -*) tmp="./$tmp" ;; esac
scratch="$(mktemp -d "$tmp/check-arm-isolation.XXXXXX")" || { scratch=; cannot_tell "could not create a scratch directory in $tmp."; }
# Made absolute because the arms run from inside it, where a relative
# TMPDIR would point somewhere else.
absolute="$(CDPATH= cd -- "$scratch" && pwd -P)" || cannot_tell "could not enter $scratch."
scratch="$absolute"
# The path goes into the hook's shell command inside single quotes, and
# that command into a JSON string. A single quote ends the shell word,
# and a double quote, backslash, or control character breaks the JSON.
# A path with a control character is not printed back to the terminal.
case "$scratch" in
  *[[:cntrl:]]*) cannot_tell "the scratch path under TMPDIR has a control character in it, which the hook command cannot carry. Set TMPDIR to a path without one." ;;
  *[\'\"\\]*) cannot_tell "the scratch path $scratch has a quote or backslash in it, which the hook command cannot carry. Set TMPDIR to a path without one." ;;
esac
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
# A part too long for the shell to compare as a number would make the
# comparison below fail open, so it counts as unreadable too.
case "$number" in
  *[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) number= ;;
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
# Claude Code keeps only the last --settings it is given, so the file
# cannot ride beside the logging hook as a second one. The hook is added
# to the file's own settings and the arm gets the two as one file, in
# the scratch directory, which only this user can read: a process's
# arguments show in ps to everyone, and the file may hold what should
# not, so it is written for this user alone. ruby runs from the
# directory the check was started in, where a version manager picks the
# ruby the user expects, and exits 3 for a file that is wrong, so a ruby
# that will not run is told apart. A JSON error is never shown: its
# message can quote the file.
if [ -n "$arm_settings" ]; then
  merged="$scratch/flagged-settings.json"
  (umask 077 && { cd "$origin" 2>/dev/null || true; } && ruby -rjson -e '
    logging = JSON.parse(ARGV[1]).dig("hooks", "InstructionsLoaded")
    begin
      given = JSON.parse(File.read(ARGV[0]))
      hooks = given.is_a?(Hash) ? given.fetch("hooks", {}) : nil
      loads = hooks.is_a?(Hash) ? hooks.fetch("InstructionsLoaded", []) : nil
      exit 3 unless loads.is_a?(Array)
      merged = JSON.generate(given.merge("hooks" => hooks.merge("InstructionsLoaded" => logging + loads)))
    rescue JSON::JSONError, EncodingError, SystemCallError
      exit 3
    end
    File.write(ARGV[2], merged)
    ' "$arm_settings" "$flagged_settings" "$merged") 2> "$scratch/merge.err"
  merge_status=$?
  case "$merge_status" in
    0) flagged_settings="$merged" ;;
    3) cannot_tell "the ARM_SETTINGS file $(printf '%s\n' "$arm_settings" | tilde) cannot be used, so no session was started. It must be a JSON object, and its hooks, when it has any, an object whose InstructionsLoaded is a list." ;;
    *)
      {
        say "cannot tell: ruby could not merge the ARM_SETTINGS file with the hook this check passes its arms (it exited $merge_status), so no session was started:"
        indented "$scratch/merge.err"
      } >&2
      exit 2
      ;;
  esac
fi

# Runs one arm named $1 on the settings in $2, JSON or a file's path,
# with any further arguments added. exec makes the background job
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
if [ "$flagged_status" -ne 0 ] && [ -z "$arm_settings" ]; then
  say "the arm with the flag failed and the one without it did not. If your sign-in comes from your user settings, which the flag leaves out, put it in a settings file and set ARM_SETTINGS to that file." >&2
fi
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
    say "run no batch that relies on the flag on this build; see \"When the flag will not do\" in CONTRIBUTING.md."
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
