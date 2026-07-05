#!/usr/bin/env bash
# title-normalize.sh: shared ledger-title truncation rule (dual-mode).
#
# Sourced: defines gaia_normalize_title (and the GAIA_TITLE_MAX bound) with no
#   side effects; nothing reaches stdout at source time, even with a
#   non-empty caller $1 (the executed-only path below is guarded by the
#   "am I the entry point" idiom, not by inspecting $1, so a sourcing
#   consumer's own positional args never leak a stray line onto its stdout).
#     . title-normalize.sh
#     title="$(gaia_normalize_title "$raw")"
#
# Executed directly: reads raw text from $1 if given, else stdin, and prints
#   the normalized title to stdout (a filter, so it composes in a pipeline).
#     printf '%s' "$raw" | bash title-normalize.sh
#
# Rule: collapse whitespace -> first sentence (first ".", "!", or "?"
# immediately followed by a space or end-of-text; colons/commas are not
# terminators; no terminator -> the whole collapsed string) -> return as-is if
# <= GAIA_TITLE_MAX chars, else the longest word-safe prefix (cut at the last
# space at or before GAIA_TITLE_MAX) + "...", else (no interior space in that
# window) a hard cut at GAIA_TITLE_MAX chars + "...". Empty input -> empty
# output. The ellipsis is the ASCII string "..." (not "…"), and character
# counts use "${#s}" (an acceptable proxy given titles are ASCII-dominant).
#
# Idempotent on its own output: re-running an already-normalized over-bound
# title (one that already ends in "..." and is within GAIA_TITLE_MAX + 3
# chars) would otherwise re-see its own trailing "..." as sentence
# terminators and re-truncate, so that case is short-circuited as a fixed
# point right after whitespace-collapse, before the sentence scan runs.

GAIA_TITLE_MAX=120

# First sentence of $1: the substring up to and including the first ".",
# "!", or "?" immediately followed by a space or end-of-text; the whole
# string if no such terminator exists.
_gaia_title_first_sentence() {
  local s="$1"
  local len=${#s}
  local i=0
  local c next_i nc

  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    case "$c" in
      "."|"!"|"?")
        next_i=$((i + 1))
        if [ "$next_i" -ge "$len" ]; then
          printf '%s' "${s:0:$next_i}"
          return 0
        fi
        nc="${s:$next_i:1}"
        if [ "$nc" = " " ]; then
          printf '%s' "${s:0:$next_i}"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done

  printf '%s' "$s"
}

gaia_normalize_title() {
  local raw="${1-}"
  local collapsed sentence prefix trimmed

  collapsed="$(printf '%s' "$raw" | tr '\n\t' '  ' | tr -s ' ')"
  collapsed="${collapsed# }"
  collapsed="${collapsed% }"

  # Fixed point: an already-normalized over-bound title round-trips
  # unchanged instead of re-seeing its own trailing "..." as a terminator.
  if [ "${collapsed%...}" != "$collapsed" ] && [ "${#collapsed}" -le "$((GAIA_TITLE_MAX + 3))" ]; then
    printf '%s\n' "$collapsed"
    return 0
  fi

  sentence="$(_gaia_title_first_sentence "$collapsed")"

  if [ "${#sentence}" -le "$GAIA_TITLE_MAX" ]; then
    printf '%s\n' "$sentence"
    return 0
  fi

  prefix="${sentence:0:$GAIA_TITLE_MAX}"
  trimmed="${prefix% *}"
  if [ "$trimmed" != "$prefix" ]; then
    printf '%s...\n' "$trimmed"
  else
    printf '%s...\n' "$prefix"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ge 1 ]; then
    gaia_normalize_title "$1"
  else
    gaia_normalize_title "$(cat)"
  fi
fi
