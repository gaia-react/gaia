#!/bin/bash
# GAIA project-scoped statusline.
#
# Reads JSON from stdin (Claude Code convention), prints a single line.
# Left side is delegated; right side is the GAIA addons (outdated packages,
# GAIA release available) read from the TTL-cached refresher.
#
# Left-side resolution (first match wins):
#   1. User has `statusLine.command` in `~/.claude/settings.json` → run that
#      (so the adopter's existing global statusline appears unchanged).
#   2. Fallback → bare "Claude Code" label.
#
# Right side in linked worktrees: the one blocking, per-clone nudge
# (`/setup-gaia`) still renders from every tree, so the statusline does not go
# dark on the case this comment used to worry about. The rest of the right
# side is a task queue for the main checkout, and a linked worktree cannot act
# on any of it, so it is gated out there. Every right-side segment still reads
# SHARED state -- the update-check cache, the debt count and the setup marker
# are all scope "shared" in `.gaia/state-registry.json`, one physical copy
# under the main checkout's `.gaia/local` -- which is exactly why the setup
# nudge is correct from a worktree: the answer it reads is main's answer.
# A flow that genuinely must run on the main checkout refuses out loud when it
# is invoked, which is where the harder guarantee belongs.
#
# So this script resolves the MAIN checkout root from the SESSION's directory
# and reads shared state there, rather than from its own install path: a
# maintainer wrapper execs this script from the main checkout while the session
# runs in a linked worktree, so the install path answers for the wrong checkout.
#
# The hot path stays no-network: no network calls, no `pnpm` calls. It is no
# longer under 50ms, and that target is retired rather than quietly missed.
# Measured on an M-series Mac under bash 3.2, 20 runs: 31ms before, 56ms after,
# of which one `gaia_resolve_main_root` call is ~38ms (it runs five `git`
# invocations behind an env scrub, where the two hand-rolled `git rev-parse`
# forks it replaces cost ~9ms together). That is the price of one canonical
# answer to "where is main" instead of a seventeenth hand-rolled derivation of
# it, paid once per render, and it is the right trade at this size. Making the
# resolver itself cheaper would return most of it and is worth doing, but it is
# the resolver library's change to make, not this consumer's.
# A background refresher (.gaia/scripts/check-updates.sh) writes the cache.
#
# Partial failures are silent; a broken statusline disappears in Claude Code,
# which is the worst UX. Do NOT add `set -e`.

# Resolve script directory so the resolver library is found regardless of
# caller cwd. This is the script's INSTALL path, which is not necessarily the
# session's checkout (see the wrapper case above); the state paths below are
# anchored on the resolved main root instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"

# Read JSON input once.
input=$(cat)

# ---------- Left side (delegated) ----------
left=""
if [ "$GAIA_STATUSLINE_NESTED" != "1" ]; then
  user_cmd=""
  if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
    user_cmd=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
  fi
  # Skip if it points back at this wrapper (avoid recursion).
  case "$user_cmd" in
    *gaia-statusline.sh*) user_cmd="" ;;
  esac
  if [ -n "$user_cmd" ]; then
    left=$(printf '%s' "$input" | GAIA_STATUSLINE_NESTED=1 bash -c "$user_cmd" 2>/dev/null)
  fi
fi

[ -z "$left" ] && left="Claude Code"

# ---------- Where this session's state lives ----------
# Every path below is anchored on the MAIN checkout, resolved from the
# SESSION's directory (carried on the StatusLine payload) through the one
# canonical resolver. Not from this script's install path: a maintainer
# wrapper execs the shipped script from the main checkout while the session
# runs in a linked worktree, so the install path answers for the wrong
# checkout. All three state files are registry scope "shared", so main is
# where they physically live for every tree, provisioned or not.
#
# Resolver failure degrades silently, this consumer's documented disposition:
# fall back to this script's own checkout. A tree git cannot resolve has no
# linked worktrees either, so the install path is the only checkout there --
# which keeps a scaffolded-but-not-yet-`git init` project rendering.
session_dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "$session_dir" ] || session_dir="$PROJECT_ROOT"

if [ -f "$GAIA_DIR/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/scripts/main-root-lib.sh" 2>/dev/null || true
fi
STATE_ROOT=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  STATE_ROOT="$(gaia_resolve_main_root "$session_dir" 2>/dev/null || true)"
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="$PROJECT_ROOT"

# Whether this session is on a linked worktree, resolved once. Failure
# direction: render. "No" and "indeterminate" (git unavailable, predicate
# unresolvable) both read "false", and an unsourced library fails the
# command -v guard -- all three keep the right side rendering, same as today.
IS_WORKTREE="false"
if command -v gaia_is_linked_worktree >/dev/null 2>&1; then
  if gaia_is_linked_worktree "$session_dir"; then
    IS_WORKTREE="true"
  fi
fi

CACHE_FILE="$STATE_ROOT/.gaia/local/cache/shared/update-check.json"
DEBT_CACHE="$STATE_ROOT/.gaia/local/debt/count.json"
CHECK_SCRIPT="$STATE_ROOT/.gaia/scripts/check-updates.sh"
DEBT_REFRESH_SCRIPT="$STATE_ROOT/.gaia/scripts/debt-count-refresh.sh"

# ---------- Right side from cache ----------
# Per-clone setup gate: when .gaia/local/setup-state.json is missing or its
# completed_at is null, the right side shows ONLY `Run /setup-gaia`; the other
# indicators are suppressed until the developer has run through the per-clone
# setup at least once. The setup file is gitignored and shared across the
# clone's trees, so an unset-up clone reads as unset-up from every one of them
# -- which is correct: it is a blocking condition wherever the session sits.
#
# Exception: when .claude/commands/gaia-init.md exists, this is a fresh
# create-gaia project mid-init. /setup-gaia is not applicable until
# /gaia-init finishes (which deletes that file). Suppress all right-side
# indicators during that window.
right=""
mid_init=0
if [ -f "$STATE_ROOT/.claude/commands/gaia-init.md" ]; then
  mid_init=1
fi
# gaia:maintainer-only:start
# Except in GAIA's own source repo, where that command file is a tracked
# product artifact: it ships to adopters, so it always exists here and
# /gaia-init never runs to delete it. Without the exception below, the gate
# above suppresses this repo's right side permanently and the maintainer sees
# none of their own nudges.
#
# The discriminator is `.gaia/cli/src`, the CLI's TypeScript source. It is
# release-excluded, so no adopter machine has it, mid-init or otherwise, and it
# is already the marker `.claude/rules/gaia-folder.md` uses for "this repo is
# GAIA itself". Tracked-ness cannot serve: create-gaia commits the whole
# scaffold before it launches /gaia-init, so the command file is tracked
# mid-init too.
#
# Anchored on STATE_ROOT like the gate file above it, so the question it asks
# is "is the MAIN checkout the source repo", which is the same answer from
# every linked worktree.
#
# The release tarball strips this block, so an adopter's copy carries the plain
# gate above and nothing else.
if [ -d "$STATE_ROOT/.gaia/cli/src" ]; then
  mid_init=0
fi
# gaia:maintainer-only:end
if [ "$mid_init" -eq 1 ]; then
  : # /gaia-init in progress, no right-side indicators
else
  SETUP_STATE_FILE="$STATE_ROOT/.gaia/local/setup-state.json"
  setup_complete="false"
  if [ -f "$SETUP_STATE_FILE" ]; then
    if command -v jq >/dev/null 2>&1; then
      if [ "$(jq -r '.completed_at // "null"' "$SETUP_STATE_FILE" 2>/dev/null)" != "null" ]; then
        setup_complete="true"
      fi
    else
      # Fallback: a complete state has a non-null completed_at value.
      if grep -q '"completed_at"[[:space:]]*:[[:space:]]*"' "$SETUP_STATE_FILE" 2>/dev/null; then
        setup_complete="true"
      fi
    fi
  fi

  if [ "$setup_complete" != "true" ]; then
    right="$(printf '\033[01;35mRun /setup-gaia (Required)\033[00m')"
  elif [ "$IS_WORKTREE" = "true" ]; then
    : # linked worktree, setup complete: the rest is a main-checkout task
      # queue, nothing to build; right stays empty and falls through to the
      # left-side-only path below.
  else
    # Declare the segment array once for the whole setup-complete path. The
    # update-check-derived segments stay gated on $CACHE_FILE; the debt
    # segment is gated independently on $DEBT_CACHE, so it still renders when
    # update-check.json is absent. The join runs once after both blocks.
    segments=()
    if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
      outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
      gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
      gaia_latest=$(jq -r '.gaiaLatest // empty' "$CACHE_FILE" 2>/dev/null)
      harden_count=$(jq -r '.hardenCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
      harden_unclassified=$(jq -r '.hardenUnclassifiedCount // 0' "$CACHE_FILE" 2>/dev/null)
      audit_nudge=$(jq -r '.auditNudge // false' "$CACHE_FILE" 2>/dev/null)
      audit_reason=$(jq -r '.auditNudgeReason // empty' "$CACHE_FILE" 2>/dev/null)
      serena_drift=$(jq -r '(.serenaLangDrift // []) | join(", ")' "$CACHE_FILE" 2>/dev/null)

      if [ "$gaia_has_update" = "true" ] && [ -n "$gaia_latest" ]; then
        segments+=("$(printf '\033[01;36mRun /update-gaia (GAIA %s available)\033[00m' "$gaia_latest")")
      fi
      if [ -n "$outdated_count" ] && [ "$outdated_count" -gt 0 ] 2>/dev/null; then
        segments+=("$(printf '\033[01;33mRun /update-deps (%d outdated)\033[00m' "$outdated_count")")
      fi
      if [ -n "$harden_count" ] && [ "$harden_count" -gt 0 ] 2>/dev/null; then
        harden_noun="recurring patterns"
        [ "$harden_count" -eq 1 ] && harden_noun="recurring pattern"
        segments+=("$(printf '\033[01;35mRun /gaia-harden (%d %s)\033[00m' "$harden_count" "$harden_noun")")
      fi
      if [ -n "$harden_unclassified" ] && [ "$harden_unclassified" -gt 0 ] 2>/dev/null; then
        segments+=("$(printf '\033[01;35mRun /gaia-harden (%d unclassified recurring)\033[00m' "$harden_unclassified")")
      fi
      if [ "$audit_nudge" = "true" ]; then
        if [ -n "$audit_reason" ]; then
          segments+=("$(printf '\033[01;32mRun /gaia-audit (%s)\033[00m' "$audit_reason")")
        else
          segments+=("$(printf '\033[01;32mRun /gaia-audit\033[00m')")
        fi
      fi
      if [ -n "$serena_drift" ]; then
        segments+=("$(printf '\033[01;31mRun /gaia-serena-sync (Serena missing: %s)\033[00m' "$serena_drift")")
      fi
    fi
    # Debt-backlog nudge, read from the pinned debt cache. Independent of
    # update-check.json so it renders whenever an open tech-debt count exists.
    if [ -f "$DEBT_CACHE" ] && command -v jq >/dev/null 2>&1; then
      debt_count=$(jq -r '.openCount // 0' "$DEBT_CACHE" 2>/dev/null)
      if [ -n "$debt_count" ] && [ "$debt_count" -gt 0 ] 2>/dev/null; then
        debt_noun="issues"
        [ "$debt_count" -eq 1 ] && debt_noun="issue"
        segments+=("$(printf '\033[01;34mRun /gaia-debt (%d %s)\033[00m' "$debt_count" "$debt_noun")")
      fi
    fi
    if [ "${#segments[@]}" -gt 0 ]; then
      right="${segments[0]}"
      for ((i=1; i<${#segments[@]}; i++)); do
        right="${right}  ${segments[$i]}"
      done
    fi
  fi
fi

# Fire the background refreshers; never block. Both are run from the MAIN
# checkout's copy, so both write the one shared cache this script has just
# read. Firing a worktree's own copy would refresh a cache nobody reads: each
# refresher derives its paths from its own install path, so the worktree's
# copy writes the worktree's `.gaia/local` -- and a segment fed by a cache that
# never refreshes is the silent death this script's shape exists to end, one
# hop further along.
#
# Gated on IS_WORKTREE independently of the mid-init if/else above (that
# block's outermost fi already closed): a linked worktree cannot act on
# either refresher's output, so neither fires from one. Main's own next
# render fires both past the TTL; no compensating fire is needed.

# The update-check refresher.
if [ -x "$CHECK_SCRIPT" ] && [ "$IS_WORKTREE" != "true" ]; then
  (cd "$STATE_ROOT" && nohup bash "$CHECK_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

# The independent debt-count refresher. Detached so the hot path stays
# no-network (the count above is read from the pinned cache only).
if [ -x "$DEBT_REFRESH_SCRIPT" ] && [ "$IS_WORKTREE" != "true" ]; then
  (cd "$STATE_ROOT" && nohup bash "$DEBT_REFRESH_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

# ---------- Compose with right-alignment ----------
if [ -z "$right" ]; then
  printf '%b' "$left"
  exit 0
fi

cols="${COLUMNS:-120}"
left_visible=$(printf '%b' "$left" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print length}')
right_visible=$(printf '%b' "$right" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print length}')
pad=$((cols - left_visible - right_visible))
if [ "$pad" -lt 2 ]; then
  pad=2
fi
spaces=$(printf '%*s' "$pad" '')
printf '%b%s%b' "$left" "$spaces" "$right"
