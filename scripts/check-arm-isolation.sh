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
# Session saving and auto-memory are off, which is what keeps a
# single-turn session from leaving a session-history folder in the
# config directory. Once the arms finish, or the check is stopped while
# they run, it looks for theirs there. One it finds is listed and
# removed, whatever the verdict, and costs a passing check its pass.
# It does not look when the scratch path is one of three kinds it
# cannot name a folder for; a line after the pass line says so.
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
#      is older than 2.1.101, an arm failed, nothing user-level loaded
#      even without the flag, or the user-level CLAUDE.md is parked
#   3  the flag isolates, and an arm left a session-history folder in
#      the config directory; the message says what that means for a
#      batch
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

# Prints $1 in double quotes for a command the reader will paste, with
# a leading home directory written as $HOME for the same reason.
quoted() {
  local home
  home="$(home_dir)"
  if [ -n "$home" ]; then
    case "$1" in "$home"/*) printf '"$HOME%s"' "${1#"$home"}"; return ;; esac
  fi
  printf '"%s"' "$1"
}

# Whether $1 holds a character a terminal acts on instead of showing: a
# control character, or one that reorders the text around it. Matched
# byte by byte in the C locale, so the answer is the same whatever the
# caller's locale is and whether or not it is installed: the ASCII
# controls, then the UTF-8 forms of U+0080 to U+009F, U+202A to U+202E,
# and U+2066 to U+2069. Other text outside ASCII, a name with an accent
# in it, say, is left alone.
acts_on_a_terminal() {
  local LC_ALL=C
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
    *$'\xc2'[$'\x80'-$'\x9f']*) return 0 ;;
    *$'\xe2\x80'[$'\xaa'-$'\xae']*) return 0 ;;
    *$'\xe2\x81'[$'\xa6'-$'\xa9']*) return 0 ;;
  esac
  return 1
}

# Whether $1 can go inside those double quotes, where a quote ends the
# word, and $, a backtick, a backslash, or an interactive shell's ! is
# expanded by the shell the command is pasted into.
pasteable() {
  ! acts_on_a_terminal "$1" || return 1
  case "$1" in *[\"\$\`\\!]*) return 1 ;; esac
}

# Prints the path $1 for a message, home directory as ~. A path a
# terminal would act on is not printed back to it; its last part is
# named instead. Only a path under the config directory can be one, and
# those end in a fixed file name.
shown() {
  if acts_on_a_terminal "$1"; then
    printf '%s in the config directory' "${1##*/}"
  else
    printf '%s\n' "$1" | tilde
  fi
}

# Older checkouts of this repository, and harnesses written against
# them, carry a script that parks the user-level CLAUDE.md: moves it
# into a lock directory beside itself for the length of a batch. While
# it sits there neither arm loads it, and an arm started for this check
# would be one more session running without the user's rules, so a lock
# is reported before any arm starts, and again once they finish, for a
# park that began meanwhile. Nothing here moves the file: whether its
# holder is still running is for the reader to judge.
config="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
# Made absolute so the commands printed below mean the same thing in
# whatever directory they are pasted.
case "$config" in /*) ;; *) config="$PWD/$config" ;; esac
# The arms run from the scratch directory, where a relative
# CLAUDE_CONFIG_DIR would name some other directory than this one.
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || export CLAUDE_CONFIG_DIR="$config"
live="$config/CLAUDE.md"
lock="$config/CLAUDE.md.park-lock"
parked="$lock/CLAUDE.md"
exists() { [ -e "$1" ] || [ -L "$1" ]; }

# The value of field $1 in the lock's owner record, or nothing when the
# value has anything but printable ASCII in it: any process could have
# written the record, and what it holds is printed to a terminal, where
# a control sequence acts and other scripts' characters can reorder a
# line or pass for a quote. Read and matched in the C locale, where the
# range means those bytes whatever the caller's language, and where sed
# does not stop at a byte that is not valid text. The locale is set
# here and in the checks that need it, each for its own match alone.
owner_field() {
  local value LC_ALL=C
  value="$(LC_ALL=C sed -n "s/^$1=//p" "$lock/owner" 2>/dev/null | head -n 1)"
  case "$value" in *[!\ -~]*) return 0 ;; esac
  printf '%s' "$value"
}

# Whether $1 is a process ID: digits and nothing else.
all_digits() {
  local LC_ALL=C
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

# Whether $1 is a start time as ps prints it in the C locale, the form
# the park script records: "Sun Oct  4 12:00:00 2026".
start_time_shaped() {
  local LC_ALL=C
  case "$1" in
    [A-Z][a-z][a-z]\ [A-Z][a-z][a-z]\ [\ 0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ [0-9][0-9][0-9][0-9]) return 0 ;;
  esac
  return 1
}

# Reports the lock and exits 2. $1 is "before" when no arm has started,
# and "during" when the lock was found after the arms ran.
report_park_lock() {
  local holder who from started restore
  {
    # A harness that parked by renaming CLAUDE.md would leave the
    # user's only copy under this name, so nothing here says to delete
    # it or to move it over a CLAUDE.md that is in place. A link is
    # different: removing one never removes what it points at.
    if [ ! -d "$lock" ] && [ ! -L "$lock" ]; then
      if [ "$1" = during ]; then
        say "cannot tell: $(shown "$lock") appeared while the check ran, so what its arms loaded proves nothing."
      else
        say "cannot tell: $(shown "$lock") is in the way, so no session was started."
      fi
      say "No command is printed for it, since nothing here knows what it holds. If a dry-run batch is running on this machine, wait for it to finish."
      if [ ! -f "$lock" ]; then
        # Reading a named pipe would wait for a writer.
        say "It is neither a file, a directory, nor a link. Look at it with ls -l, and remove it if nothing needs it."
      elif exists "$live"; then
        say "It is a file, where a park script makes a directory. A CLAUDE.md is also in place at $(shown "$live"): if this file is another copy of your rules, compare the two and keep what you need before you remove it."
      else
        say "It is a file, where a park script makes a directory. Read it, and if it is your CLAUDE.md, move it back to $(shown "$live") yourself. Otherwise remove it."
      fi
      exit 2
    fi
    if [ "$1" = during ]; then
      say "cannot tell: a park lock at $(shown "$lock") appeared while the check ran, so what its arms loaded proves nothing."
    elif exists "$parked"; then
      say "cannot tell: the user-level CLAUDE.md is parked in $(shown "$lock"), so no session was started."
    else
      say "cannot tell: a park lock at $(shown "$lock") holds no parked file, and the check cannot say what a batch that finds it will do, so no session was started."
    fi
    # The reader acts on the sentence the record is printed in, so each
    # field is printed only in the form the park script writes it: a
    # number, the absolute path of a directory that is there to look
    # at, and a start time as ps gives it in the C locale. The path
    # goes in quotes, as something read from a file.
    holder="$(owner_field pid)"
    if all_digits "$holder"; then
      who="process $holder"
      from="$(owner_field checkout)"
      case "$from" in
        *\"*) ;;
        /*) [ ! -d "$from" ] || who="checkout \"$(shown "$from")\", $who" ;;
      esac
      # The start time tells the holder from a later process that was
      # given the same ID.
      started="$(owner_field started)"
      if start_time_shaped "$started"; then who="$who, started $started"; else started=; fi
      say "A park script from an older checkout of this repository took the lock: $who. If process $holder is still running${started:+ and started then}, wait for it to finish, then run this check again."
    else
      say "The lock holds no record of what parked it. If a dry-run batch is running on this machine, wait for it to finish, then run this check again."
    fi
    restore=
    if exists "$parked" && exists "$live"; then
      say "a CLAUDE.md is also in place at $(shown "$live"). Compare it with the parked copy, keep what you need, delete the parked copy, then clear the lock:"
    elif exists "$parked"; then
      say "Otherwise put the file back and clear the lock:"
      restore=1
    else
      say "Otherwise clear the lock:"
    fi
    if ! pasteable "$lock"; then
      say "The config directory's path has a character double quotes cannot carry, so no command is printed. By hand: ${restore:+move CLAUDE.md out of the lock directory into the config directory, }delete owner and owner.tmp from the lock directory, and remove the lock directory."
    else
      [ -z "$restore" ] || echo "  mv -n $(quoted "$parked") $(quoted "$live")"
      if [ -d "$lock" ] && [ ! -L "$lock" ]; then
        # owner.tmp is what the park script leaves when it is killed
        # while recording itself.
        echo "  rm -f $(quoted "$lock/owner") $(quoted "$lock/owner.tmp")"
        echo "  rmdir $(quoted "$lock")"
        say "If rmdir says the directory is not empty, look at anything else in it, remove that, and run rmdir again."
      else
        # rmdir cannot remove a link.
        echo "  rm -f $(quoted "$lock")"
      fi
    fi
  } >&2
  exit 2
}
! exists "$lock" || report_park_lock before

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

# Looks for the session-history folder the arms left, and removes it.
# Claude Code names the folder for a session's working directory: the
# path with every character other than a letter or digit turned into a
# dash. Three kinds of scratch path are not looked for, and a line
# after the pass line says which applied:
#   - one with characters outside ASCII, whose name cannot be worked
#     out here;
#   - one whose name comes to 200 characters or more, since Claude
#     Code cuts a long name and adds a suffix of its own;
#   - one inside a git repository, where the memory directory goes
#     under the repository root's name, which is a real project's, and
#     a folder under the scratch path's own name tells half the story.
# A folder with the whole name can only be these arms', since the
# scratch directory is new. What it held is kept in a variable, so the
# report needs nothing from the scratch directory. A signal can stop
# the function partway, so the exit trap may run it a second time: it
# is marked as done only at its end, and a second run that finds the
# folder gone records the first run's removal.
left=
left_held=
left_removed=
looked=
unchecked=
arms_started=
stopped=
look_for_left_folder() {
  local LC_ALL=C arm_directory="$scratch/arm" encoded
  [ -n "$scratch" ] || return 0
  # The name is worked out by the shell itself. A command that failed
  # to run would hand back an empty name, and the folder looked for
  # and removed would then be the projects directory. The name of an
  # absolute path ending /arm begins with a dash and ends -arm, and
  # nothing is looked for under any other.
  encoded="${arm_directory//[^A-Za-z0-9]/-}"
  case "$arm_directory" in
    *[!\ -~]*) unchecked="the scratch path has characters outside ASCII, so the folder's name cannot be worked out" ;;
  esac
  if [ -n "$unchecked" ]; then
    :
  elif [ "${#encoded}" -ge 200 ]; then
    unchecked="the scratch path gives a folder name of 200 characters or more, which Claude Code may cut short"
  elif [ "${encoded#-}" = "$encoded" ] || [ "${encoded%-arm}" = "$encoded" ]; then
    unchecked="the folder's name could not be worked out from the scratch path"
  elif git -C "$arm_directory" rev-parse --show-toplevel > /dev/null 2>&1; then
    unchecked="the scratch directory is inside a git repository, and Claude Code names a memory directory for the repository"
  elif exists "$config/projects/$encoded"; then
    left="$config/projects/$encoded"
    if [ -d "$left" ] && [ ! -L "$left" ]; then
      # -q prints a question mark for a character a terminal would act on.
      left_held="$(LC_ALL=C ls -Aq "$left" 2> /dev/null)" || left_held="(it could not be listed)"
      [ -n "$left_held" ] || left_held="(nothing)"
    else
      left_held="(it is not a directory)"
    fi
    rm -rf "$left" 2> /dev/null
    exists "$left" || left_removed=yes
  elif [ -n "$left" ]; then
    left_removed=yes
  fi
  looked=yes
}

# Says where the folder an arm left was, what it held, and whether it
# is still there. Prints nothing when no arm left one. The arm without
# the flag is a session on the user's own settings, and the two arms
# share a directory, so a folder cannot be laid at either arm's door.
# Arms that were stopped partway show nothing about the two switches.
left_folder_report() {
  [ -n "$left" ] || return 0
  if [ -n "$stopped" ]; then
    say "the check was stopped while its arms ran, and they had made a session-history folder in the config directory, at $(shown "$left"), holding:"
  else
    say "an arm left a session-history folder in the config directory, at $(shown "$left"), holding:"
  fi
  printf '%s\n' "$left_held" | sed 's/^/  /'
  if [ -z "$stopped" ]; then
    say "The arms run with --no-session-persistence and CLAUDE_CODE_DISABLE_AUTO_MEMORY=1, which together keep a single-turn arm from leaving one, so on $version they may not. The arm without the flag also runs your own hooks and plugins, and one of those writing there looks the same from here."
  fi
  if [ -n "$left_removed" ]; then
    say "The folder is removed.${stopped:+ Run the check again for a verdict.}"
    [ -n "$stopped" ] || say "If a batch's arms leave folders on this build too, keep their working directories under a directory made by bin/dry-run-cleanup new, and sweep it when the batch ends."
  else
    say "The folder could not be removed. It is this check's and nothing needs it: delete it yourself."
  fi
}

# Waits for the arms the trap has just told to stop, and after five
# seconds stops outright any that have not gone, so a check that is
# interrupted ends even when an arm ignores the first signal. It asks
# after each arm by its process ID ten times a second.
await_stopped_arms() {
  local arm tenths=0 running=yes
  while [ -n "$running" ] && [ "$tenths" -lt 50 ]; do
    running=
    for arm in "$plain_pid" "$flagged_pid"; do
      [ -z "$arm" ] || ! kill -0 "$arm" 2> /dev/null || running=yes
    done
    [ -z "$running" ] || sleep 0.1
    tenths=$((tenths + 1))
  done
  [ -n "$running" ] || return 0
  for arm in "$plain_pid" "$flagged_pid"; do
    [ -z "$arm" ] || ! kill -0 "$arm" 2> /dev/null || kill -9 "$arm" 2> /dev/null
  done
}

# The arms are stopped before the scratch directory goes, so a check
# that is interrupted leaves no session running. A check stopped while
# its arms ran has not looked for their folder yet, so it looks here,
# once the arms it stopped are gone. The scratch directory goes before
# the report is printed: a report nothing reads can end the script on
# the spot. Each process ID is cleared once its arm has been waited
# for, since it can be reused.
scratch=
plain_pid=
flagged_pid=
cleanup() {
  # A second signal would end the script partway through this, with
  # the scratch directory and any folder the arms made still there.
  trap '' INT TERM HUP
  # Only an arm that had not finished was stopped partway.
  [ -z "$plain_pid$flagged_pid" ] || stopped=yes
  [ -z "$plain_pid" ] || kill "$plain_pid" 2>/dev/null
  [ -z "$flagged_pid" ] || kill "$flagged_pid" 2>/dev/null
  if [ -n "$arms_started" ] && [ -z "$looked" ]; then
    await_stopped_arms
    look_for_left_folder
  fi
  [ -z "$scratch" ] || rm -rf "$scratch"
  left_folder_report >&9
}
# A signal can arrive while a command whose own stderr is silenced is
# running, and the trap then starts with that redirection still in
# force. The report goes to this copy of the script's stderr.
exec 9>&2
trap cleanup EXIT
# A message written to a pipe nothing reads would otherwise end the
# script before the trap had removed the scratch directory.
trap '' PIPE

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
  trap - PIPE
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 exec "$CLAUDE" -p "Reply with the single word ready." \
    --model haiku --tools "" --strict-mcp-config --no-session-persistence --settings "$settings" "$@" \
    > /dev/null 2> "$scratch/$name.err" < /dev/null 9>&-
}

# The two arms run side by side, so a user-level file that appears or
# goes partway through is far likelier to be there for both or for
# neither.
# bash's own report of an arm killed by a signal is silenced; the status
# says as much.
arms_started=yes
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
look_for_left_folder
! exists "$lock" || report_park_lock during

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

if [ -n "$left" ]; then
  say "--setting-sources project isolates an arm on $version, and the check gives no pass, for the folder reported below." >&2
  exit 3
fi

say "--setting-sources project isolates an arm on $version: $(printf '%s\n' "$plain_files" | wc -l | tr -d ' ') user-level instruction file(s) loaded without the flag, none with it."
[ -z "$unchecked" ] || say "not checked for a session-history folder an arm may have left: $unchecked. Set TMPDIR to a short, plain ASCII path outside any git repository to check that too."
# A message nothing read fails to print, and the last command's status
# would otherwise be the script's.
exit 0
