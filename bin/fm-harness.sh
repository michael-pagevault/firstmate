#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model [<id>]   print the effective MODEL for a
#                                        secondmate: a per-secondmate pin from
#                                        config/secondmate-pins/<id> when <id> is
#                                        given and pins a model, otherwise the
#                                        optional MODEL token from
#                                        config/secondmate-harness, or empty when
#                                        neither is present.
#        fm-harness.sh secondmate-effort [<id>]  print the effective EFFORT the
#                                        same way (per-secondmate pin first, then
#                                        the config/secondmate-harness token).
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# config/secondmate-pins/<id> is an optional per-secondmate override: one
# "<key> <value>" per line with key "model" or "effort", '#' comments and blank
# lines skipped, the first occurrence of each key winning. A pinned axis overrides
# the matching config/secondmate-harness token for that one secondmate; an absent
# or malformed pin leaves the global fallback in force. This file is the PRIMARY's
# own config, like config/secondmate-harness, and is never inherited into a
# secondmate home. Passing no <id> reads the global fallback only (backward-compat).
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before ancestry detection as an explicit precedence rule.
  # Claude, Pi, Grok, and Cursor set verified markers of their own; codex,
  # opencode, Kimi, and Muse are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  # Cursor is checked BEFORE claude, deliberately. cursor-agent does NOT clear
  # an inherited CLAUDECODE, so a cursor worker launched from a claude primary
  # carries BOTH markers and whichever is tested first wins. Cursor's own
  # markers are unambiguous when present, so ordering them first is what makes
  # the verdict correct; bin/fm-spawn.sh additionally clears the foreign markers
  # at the launch boundary. Both are kept: the launch sanitization only covers
  # sessions fm-spawn started, while this ordering also covers a cursor session
  # a human started by hand. Verified live on cursor-agent 2026.08.11-e8db854:
  # CURSOR_INVOKED_AS=cursor-agent is set on the agent process itself, and
  # CURSOR_AGENT=1 is set for the child/tool processes this script runs as.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok set GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so the marker
  # is unambiguous WHEN PRESENT - but it is not guaranteed present. A grok 1.0.0
  # hook process carries GROK_HOOK_EVENT, GROK_HOOK_NAME, GROK_SESSION_ID, and
  # GROK_WORKSPACE_ROOT with no GROK_AGENT at all (verified from the live process
  # environment of a wedged grok 1.0.0 Stop hook, 2026-08-07). Treat this marker as
  # a fast path only; the ancestry walk below is what actually guarantees grok is
  # identified, and any rule that must be RELIABLE under grok has to test the hook
  # markers too (see .claude/settings.json Stop entries, docs/turnend-guard.md).
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # muse (Muse Code) publishes no harness-identity marker of its own. The only
  # MUSE_* variable it is documented to hand a child is MUSE_CURRENT_SESSION_LOG,
  # a per-session log PATH rather than an identity, and its export to tool
  # subprocesses is unverified (verified: muse 0.1.0-R708.1), so muse is detected
  # by ancestry alone below. Do NOT promote MUSE_CURRENT_SESSION_LOG to a marker
  # without verifying it reaches children AND that it cannot survive in a
  # multiplexer's stored environment, which is the precedence hazard above.
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args argv0
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    if fm_cursor_process_matches "$comm" '' "$argv0"; then
      echo cursor
      return
    fi
    case "$(basename -- "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
      muse|muse-bin-*) echo muse; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the validated per-secondmate pin for one axis ($1=model|effort) of
# secondmate $2 from config/secondmate-pins/<id>, or nothing when the id is unsafe,
# the file is absent, the axis is not pinned, or the pinned value is malformed. A
# malformed value warns to stderr and yields nothing so the caller falls back to
# the config/secondmate-harness token. The id is refused when it carries a path
# separator or is "." / ".." so a pin lookup can never escape the pins directory.
secondmate_pin_field() {
  local field=$1 id=$2 file line k v
  [ -n "$field" ] && [ -n "$id" ] || return 0
  case "$id" in
    .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  file="$CONFIG/secondmate-pins/$id"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    k=${line%%[[:space:]]*}
    [ "$k" = "$field" ] || continue
    v=${line#"$k"}
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    # A pinned value is one token: an empty value or embedded whitespace is
    # malformed, so warn and defer to the global fallback rather than pass a
    # broken value downstream.
    case "$v" in
      ''|*[[:space:]]*)
        printf 'warning: config/secondmate-pins/%s %s value is malformed; ignoring and using config/secondmate-harness\n' "$id" "$field" >&2
        return 0
        ;;
    esac
    if [ "$field" = effort ]; then
      case "$v" in
        low|medium|high|xhigh|max) ;;
        *)
          printf 'warning: config/secondmate-pins/%s effort value %s is not one of low, medium, high, xhigh, max; ignoring and using config/secondmate-harness\n' "$id" "$v" >&2
          return 0
          ;;
      esac
    fi
    printf '%s\n' "$v"
    return 0
  done < "$file"
  return 0
}

# Print the effective secondmate model: a per-secondmate pin from
# config/secondmate-pins/<id> when an id is given and pins a model, otherwise the
# optional model token (2nd field) from config/secondmate-harness, or empty when
# the harness token is absent/"default" (harness-only file, same as today) or when
# no model token is present.
resolve_secondmate_model() {
  local id=${1:-} pin sm
  if [ -n "$id" ]; then
    pin=$(secondmate_pin_field model "$id")
    [ -z "$pin" ] || { printf '%s\n' "$pin"; return 0; }
  fi
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the effective secondmate effort the same way: a per-secondmate pin first,
# then the optional effort token (3rd field) from config/secondmate-harness.
resolve_secondmate_effort() {
  local id=${1:-} pin sm
  if [ -n "$id" ]; then
    pin=$(secondmate_pin_field effort "$id")
    [ -z "$pin" ] || { printf '%s\n' "$pin"; return 0; }
  fi
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model "${2:-}" ;;
  secondmate-effort) resolve_secondmate_effort "${2:-}" ;;
  *) detect_own ;;
esac
