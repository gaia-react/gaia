# shellcheck shell=bash
#
# Context-reading writer for the GAIA statusline. Sourced by
# gaia-statusline.sh as "$GAIA_DIRECTORY/statusline/context-reading.sh"; defines one
# function and runs nothing at source time.
#
# Why it exists: only the statusline receives the main session's context
# reading (stdin session_id and context_window), so it writes the per-session
# file the audit-loop bound hook reads. The path, file shape and atomic write
# live in the shared threshold lib (scripts/context-checkpoint-lib.sh); this
# file only normalizes the stdin values into the shape the lib accepts and
# calls it.
#
# Silent by design, like the rest of the statusline: a failure never prints and
# never stops the render, and a render whose stdin lacks session_id or
# context_window writes nothing.

# gaia_statusline_write_context <main-root> <session_id> <used_percentage> <window_size> <used_tokens>
# used_tokens is pinned by the caller as the percentage-derived value, never
# total_input_tokens. Returns 0 when a file was written, 1 otherwise.
gaia_statusline_write_context() {
  local root="${1:-}" session_id="${2:-}" used_percentage="${3:-}" window="${4:-}" tokens="${5:-}" now fraction
  command -v gaia_context_write >/dev/null 2>&1 || return 1
  [ -n "$root" ] && [ -n "$session_id" ] && [ -n "$used_percentage" ] && [ -n "$window" ] && [ -n "$tokens" ] || return 1
  gaia_context_is_session_id "$session_id" || return 1
  # The lib accepts at most six decimals; a longer fraction is truncated, not refused.
  case "$used_percentage" in
    *.*) fraction="${used_percentage#*.}"; used_percentage="${used_percentage%%.*}.${fraction:0:6}" ;;
  esac
  now="${EPOCHSECONDS:-}"
  [ -n "$now" ] || now=$(date +%s 2>/dev/null) || return 1
  gaia_context_write "$root" "$session_id" "$used_percentage" "$tokens" "$window" "$now" 2>/dev/null
}
