#!/usr/bin/env bash
# Sourced by wiki-session-start.sh and wiki-session-stop.sh. Sets no shell
# options and has no top-level side effects, so it is safe under a caller's
# `set -euo pipefail` and its ERR trap.

# gaia_wiki_dirty_fingerprint ROOT: print one hash of ROOT's uncommitted wiki/ content, or nothing when it is clean.
#
# The watched set leaves out the files that change without a content edit:
# hot.md (the hook's own refresh target), log.md and .state.json (written by
# tooling), and the editor's .obsidian/ state. Content, not just path, enters
# the hash, so a further edit to a page that was already dirty is a new state.
# Untracked paths come from ls-files, which emits them in sorted order, so the
# material is stable between runs.
gaia_wiki_dirty_fingerprint() {
  local root="$1" base untracked_path
  local -a untracked_paths=()
  local -a watched=(
    wiki/ ':(exclude)wiki/hot.md' ':(exclude)wiki/log.md'
    ':(exclude)wiki/.state.json' ':(exclude)wiki/.obsidian'
  )

  if git -C "$root" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    base=HEAD
  else
    base=$(git -C "$root" hash-object -t tree /dev/null 2>/dev/null) || return 0
  fi

  # NUL-delimited so a non-ASCII or newline-bearing name is neither quoted nor split.
  while IFS= read -r -d '' untracked_path; do
    untracked_paths+=("$untracked_path")
  done < <(git -C "$root" ls-files --others --exclude-standard -z -- "${watched[@]+"${watched[@]}"}" 2>/dev/null)

  if [ "${#untracked_paths[@]}" -eq 0 ] && git -C "$root" diff "$base" --quiet --no-ext-diff -- \
    "${watched[@]+"${watched[@]}"}" >/dev/null 2>&1; then
    return 0
  fi

  # The material is streamed, never captured in a variable: --binary diffs can
  # carry NUL bytes, which a bash variable silently drops.
  {
    git -C "$root" diff "$base" --no-ext-diff --no-color --binary -- \
      "${watched[@]+"${watched[@]}"}" 2>/dev/null || true
    for untracked_path in "${untracked_paths[@]+"${untracked_paths[@]}"}"; do
      printf '%s %s\n' "$untracked_path" \
        "$(git -C "$root" hash-object -- "$root/$untracked_path" 2>/dev/null || true)"
    done
  } | git -C "$root" hash-object --stdin 2>/dev/null || true
  return 0
}
