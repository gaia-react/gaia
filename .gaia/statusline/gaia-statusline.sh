#!/bin/bash
# GAIA project-scoped statusline.
#
# Reads JSON from stdin (Claude Code convention), prints a single line.
# Left side is delegated; right side is the GAIA nudges, read from the
# TTL-cached refresher and fitted to COLUMNS: full reasons first, then bare
# command names, then the lowest-priority nudges collapsed to an icon and
# count, then a `+N` for however many still do not fit.
#
# Left-side resolution (first match wins):
#   1. User has `statusLine.command` in `~/.claude/settings.json` → run that
#      (so the adopter's existing global statusline appears unchanged).
#   2. Fallback → bare "Claude Code" label.
#
# Right side in linked worktrees: the one blocking, per-clone nudge
# (`/setup-gaia`) still renders from every tree, so the statusline does not go
# dark. The rest of the right side is a task queue for the main checkout, and
# a linked worktree cannot act on any of it, so it is gated out there. Every
# right-side segment still reads SHARED state -- the update-check cache, the
# debt count and the setup marker are all scope "shared" in
# `.gaia/state-registry.json`, one physical copy under the main checkout's
# `.gaia/local` -- which is exactly why the setup nudge is correct from a
# worktree: the answer it reads is main's answer.
# A flow that genuinely must run on the main checkout refuses out loud when it
# is invoked, which is where the harder guarantee belongs.
#
# The hot path stays no-network: no network calls, no `pnpm` calls. It is no
# longer under 50ms, and that target is retired rather than quietly missed:
# resolving the main checkout root canonically (`gaia_resolve_main_root`, a
# handful of `git` invocations behind an env scrub) costs more than the
# hand-rolled `git rev-parse` forks it replaces, and that is the right trade
# at this size. Making the resolver itself cheaper would return most of it
# and is worth doing, but it is the resolver library's change to make, not
# this consumer's.
# A background refresher (.gaia/scripts/check-updates.sh) writes the cache.
#
# Partial failures are silent; a broken statusline disappears in Claude Code,
# which is the worst UX. Do NOT add `set -e`.

# Resolve script directory so the resolver library is found regardless of
# caller cwd. This is the script's INSTALL path, which is not necessarily the
# session's checkout; the state paths below are anchored on the resolved main
# root instead.
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

# Sets cols and left_visible; called only where a right side is about to be
# composed (the setup-gaia branch and the nudges-present branch), so a render
# with no right side pays no pipeline for it. Compose reads the values these
# leave behind. `awk`'s END block reports the LAST line's length (the row the
# right side actually joins) rather than one number per line, and `n+0`
# forces a plain digit even on empty input.
measure_left() {
  cols="${COLUMNS:-120}"
  left_visible=$(printf '%b' "$left" | sed 's/\x1b\[[0-9;]*m//g' | awk '{n=length} END{print n+0}')
  case "$left_visible" in
    ''|*[!0-9]*) left_visible=0 ;;
  esac
}

# ---------- Where this session's state lives ----------
# Every path below is anchored on the MAIN checkout, resolved from the
# SESSION's directory (carried on the StatusLine payload) through the one
# canonical resolver. Not from this script's install path: a maintainer
# wrapper execs the shipped script from the main checkout while the session
# runs in a linked worktree, so the install path answers for the wrong
# checkout. Every state file is registry scope "shared", so main is
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
right_width=0
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
# release-excluded, so no adopter machine has it, mid-init or otherwise, which
# is what makes its presence mean "this repo is GAIA itself".
# Tracked-ness cannot serve: create-gaia commits the whole
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
    measure_left
    setup_text='Run /setup-gaia (Required)'
    right=$'\033[01;35m'"$setup_text"$'\033[00m'
    right_width=${#setup_text}
  elif [ "$IS_WORKTREE" = "true" ]; then
    : # linked worktree, setup complete: the rest is a main-checkout task
      # queue, nothing to build; right stays empty and falls through to the
      # left-side-only path below.
  else
    # Nudge slots, indexed by render priority rather than by where each one
    # is armed below: update-gaia 0, gaia-serena-sync 1, update-deps 2,
    # gaia-audit 3, gaia-harden 4, gaia-debt 5, gaia-residue 6. The
    # update-check-derived nudges stay gated on $CACHE_FILE; the debt nudge is
    # gated independently on $DEBT_CACHE so it still renders when
    # update-check.json is absent, which is why debt (5) is armed after
    # residue (6) in source order but renders before it. The width-tiered
    # renderer below reads every slot once both blocks have run.
    nudge_color=()
    nudge_short=()
    nudge_full=()
    nudge_icon=()
    nudge_count=()
    nudge_set() {
      nudge_color[$1]="$2"
      nudge_short[$1]="$3"
      nudge_full[$1]="$4"
      nudge_icon[$1]="$5"
      nudge_count[$1]="$6"
    }
    if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
      outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
      gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
      gaia_latest=$(jq -r '.gaiaLatest // empty' "$CACHE_FILE" 2>/dev/null)
      # One spawn for both reads: a leading 1 or 0 says whether the key exists,
      # and the rest is the reason itself.
      harden_reason_raw=$(jq -r 'if has("hardenNudgeReason") then "1" + ((.hardenNudgeReason // "") | tostring) else "0" end' "$CACHE_FILE" 2>/dev/null)
      has_harden_reason="${harden_reason_raw:0:1}"
      # A cached reason is untrusted: harden-tally's finding_class segments and
      # the review snapshot both originate in PR text any author controls, so
      # strip control bytes (escape sequences, newlines) before this reaches a
      # terminal, even though the refresher's own composition already
      # constrains the class-name segment it builds the reason from.
      harden_reason="$(printf '%s' "${harden_reason_raw#?}" | tr -d '\000-\037\177')"
      audit_nudge=$(jq -r '.auditNudge // false' "$CACHE_FILE" 2>/dev/null)
      audit_reason=$(jq -r '.auditNudgeReason // empty' "$CACHE_FILE" 2>/dev/null)
      serena_drift=$(jq -r '(.serenaLangDrift // []) | join(", ")' "$CACHE_FILE" 2>/dev/null)

      if [ "$gaia_has_update" = "true" ] && [ -n "$gaia_latest" ]; then
        printf -v full 'Run /update-gaia (GAIA %s available)' "$gaia_latest"
        nudge_set 0 '01;36' 'Run /update-gaia' "$full" '🌍' ''
      fi
      if [ -n "$outdated_count" ] && [ "$outdated_count" -gt 0 ] 2>/dev/null; then
        printf -v full 'Run /update-deps (%d outdated)' "$outdated_count"
        nudge_set 2 '01;33' 'Run /update-deps' "$full" '📦' "$outdated_count"
      fi
      # Both signals are discharged by the same bare `/gaia-harden` run, and no
      # argument selects between them, so they stack into one segment's reason
      # parameter rather than into a second segment naming the same command.
      # Same shape as the /gaia-audit segment below, which folds its reason in
      # the same way. This reads the refresher's own cached composition only:
      # it never reads the review snapshot itself. A cache written before
      # hardenNudgeReason existed has no key to read, so it falls back to
      # composing today's count text the same way the refresher's own
      # upgrade-window seed does.
      if [ "$has_harden_reason" = "1" ]; then
        if [ -n "$harden_reason" ]; then
          printf -v full 'Run /gaia-harden (%s)' "$harden_reason"
          nudge_set 4 '01;35' 'Run /gaia-harden' "$full" '🔨' ''
        fi
      else
        harden_count=$(jq -r '.hardenCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
        harden_unclassified=$(jq -r '.hardenUnclassifiedCount // 0' "$CACHE_FILE" 2>/dev/null)
        fallback_reason=""
        if [ -n "$harden_count" ] && [ "$harden_count" -gt 0 ] 2>/dev/null; then
          harden_noun="recurring patterns"
          [ "$harden_count" -eq 1 ] && harden_noun="recurring pattern"
          fallback_reason=$(printf '%d %s' "$harden_count" "$harden_noun")
        fi
        if [ -n "$harden_unclassified" ] && [ "$harden_unclassified" -gt 0 ] 2>/dev/null; then
          [ -n "$fallback_reason" ] && fallback_reason="${fallback_reason}, "
          fallback_reason=$(printf '%s%d unclassified' "$fallback_reason" "$harden_unclassified")
        fi
        if [ -n "$fallback_reason" ]; then
          printf -v full 'Run /gaia-harden (%s)' "$fallback_reason"
          nudge_set 4 '01;35' 'Run /gaia-harden' "$full" '🔨' ''
        fi
      fi
      if [ "$audit_nudge" = "true" ]; then
        if [ -n "$audit_reason" ]; then
          printf -v full 'Run /gaia-audit (%s)' "$audit_reason"
          nudge_set 3 '01;32' 'Run /gaia-audit' "$full" '🔎' ''
        else
          nudge_set 3 '01;32' 'Run /gaia-audit' 'Run /gaia-audit' '🔎' ''
        fi
      fi
      if [ -n "$serena_drift" ]; then
        printf -v full 'Run /gaia-serena-sync (Serena missing: %s)' "$serena_drift"
        nudge_set 1 '01;31' 'Run /gaia-serena-sync' "$full" '🔭' ''
      fi
      # Residue nudge: renders once at least RESIDUE_NUDGE_THRESHOLD keyed
      # candidates have aged past 30 days (the age dial lives in the tally,
      # computed pre-cap over the full post-suppression population) and
      # clears once the count falls back below it. Both dials are calibrated
      # against a corpus younger than one quarter and are re-measured after
      # two.
      RESIDUE_NUDGE_THRESHOLD=5
      residue_count=$(jq -r '.residueCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
      case "$residue_count" in
        ''|*[!0-9]*) residue_count=0 ;;
      esac
      if [ "$residue_count" -ge "$RESIDUE_NUDGE_THRESHOLD" ] 2>/dev/null; then
        residue_suffix="s"
        [ "$residue_count" -eq 1 ] && residue_suffix=""
        printf -v full 'Run /gaia-residue (%d aged residual%s)' "$residue_count" "$residue_suffix"
        nudge_set 6 '01;37' 'Run /gaia-residue' "$full" '🧹' "$residue_count"
      fi
    fi
    # Debt-backlog nudge, read from the pinned debt cache. Independent of
    # update-check.json so it renders whenever an open tech-debt count exists.
    if [ -f "$DEBT_CACHE" ] && command -v jq >/dev/null 2>&1; then
      debt_count=$(jq -r '.openCount // 0' "$DEBT_CACHE" 2>/dev/null)
      if [ -n "$debt_count" ] && [ "$debt_count" -gt 0 ] 2>/dev/null; then
        debt_noun="issues"
        [ "$debt_count" -eq 1 ] && debt_noun="issue"
        printf -v full 'Run /gaia-debt (%d %s)' "$debt_count" "$debt_noun"
        nudge_set 5 '01;34' 'Run /gaia-debt' "$full" '💸' "$debt_count"
      fi
    fi

    # Compact the sparse priority slots into dense, priority-ordered arrays;
    # a gap between slots is a nudge that did not arm this render. `${!arr[@]}`
    # walks an indexed array's set keys in ascending order, which is what
    # makes the slot numbers double as the render order.
    dense_color=()
    dense_short=()
    dense_full=()
    dense_icon=()
    dense_count=()
    for slot in "${!nudge_short[@]}"; do
      dense_color+=("${nudge_color[$slot]}")
      dense_short+=("${nudge_short[$slot]}")
      dense_full+=("${nudge_full[$slot]}")
      dense_icon+=("${nudge_icon[$slot]}")
      dense_count+=("${nudge_count[$slot]}")
    done
    n="${#dense_short[@]}"

    if [ "$n" -gt 0 ]; then
      measure_left
      # avail reserves the 2-column minimum gap Compose keeps between the
      # two sides.
      avail=$((cols - left_visible - 2))

      full_width=0
      short_width=0
      for ((i = 0; i < n; i++)); do
        full_width=$((full_width + ${#dense_full[$i]}))
        short_width=$((short_width + ${#dense_short[$i]}))
      done
      full_width=$((full_width + 2 * (n - 1)))
      short_width=$((short_width + 2 * (n - 1)))

      tier=""
      if [ "$full_width" -le "$avail" ]; then
        tier="full"
        right_width="$full_width"
      elif [ "$short_width" -le "$avail" ]; then
        tier="short"
        right_width="$short_width"
      else
        # The first k nudges (highest priority) keep their bare command text;
        # the rest collapse to an icon and count. Each icon costs 2 columns
        # (never measured with awk, which counts bytes and cannot see a
        # terminal's wide-glyph rendering), joined by a single space, with a
        # two-space gap between the text group and the icon group. Widest k
        # that fits wins, so the fewest nudges lose their text form.
        for ((k = n - 1; k >= 0; k--)); do
          w=0
          for ((i = 0; i < k; i++)); do
            w=$((w + ${#dense_short[$i]}))
          done
          if [ "$k" -gt 0 ]; then
            w=$((w + 2 * (k - 1) + 2))
          fi
          for ((i = k; i < n; i++)); do
            w=$((w + 2 + ${#dense_count[$i]}))
          done
          w=$((w + (n - k - 1)))
          if [ "$w" -le "$avail" ]; then
            tier="collapse"
            collapse_k="$k"
            right_width="$w"
            break
          fi
        done
      fi

      if [ -z "$tier" ]; then
        # Even every nudge as an icon does not fit: keep the first m
        # (highest priority) as icons and name how many more are hidden with
        # a trailing `+<n-m>`, so a nudge never disappears without saying so.
        # m=0 always renders, even past avail, rather than emitting nothing.
        for ((m = n - 1; m >= 0; m--)); do
          w=0
          for ((i = 0; i < m; i++)); do
            w=$((w + 3 + ${#dense_count[$i]}))
          done
          plus="+$((n - m))"
          w=$((w + ${#plus}))
          if [ "$w" -le "$avail" ] || [ "$m" -eq 0 ]; then
            tier="hidden"
            hidden_m="$m"
            right_width="$w"
            break
          fi
        done
      fi

      case "$tier" in
        full)
          right=$'\033['"${dense_color[0]}"'m'"${dense_full[0]}"$'\033[00m'
          for ((i = 1; i < n; i++)); do
            right="${right}  "$'\033['"${dense_color[$i]}"'m'"${dense_full[$i]}"$'\033[00m'
          done
          ;;
        short)
          right=$'\033['"${dense_color[0]}"'m'"${dense_short[0]}"$'\033[00m'
          for ((i = 1; i < n; i++)); do
            right="${right}  "$'\033['"${dense_color[$i]}"'m'"${dense_short[$i]}"$'\033[00m'
          done
          ;;
        collapse)
          right=""
          for ((i = 0; i < collapse_k; i++)); do
            [ -n "$right" ] && right="${right}  "
            right="${right}"$'\033['"${dense_color[$i]}"'m'"${dense_short[$i]}"$'\033[00m'
          done
          [ "$collapse_k" -gt 0 ] && right="${right}  "
          for ((i = collapse_k; i < n; i++)); do
            [ "$i" -gt "$collapse_k" ] && right="${right} "
            right="${right}${dense_icon[$i]}${dense_count[$i]}"
          done
          ;;
        hidden)
          right=""
          for ((i = 0; i < hidden_m; i++)); do
            right="${right}${dense_icon[$i]}${dense_count[$i]} "
          done
          right="${right}+$((n - hidden_m))"
          ;;
      esac
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

pad=$((cols - left_visible - right_width))
if [ "$pad" -lt 2 ]; then
  pad=2
fi
spaces=$(printf '%*s' "$pad" '')
printf '%b%s%s' "$left" "$spaces" "$right"
