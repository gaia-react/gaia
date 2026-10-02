#!/bin/bash
# GAIA project-scoped statusline.
#
# Reads JSON from stdin (Claude Code convention), prints a single line.
# Left side is delegated; right side is the GAIA nudges, read from the
# TTL-cached refresher and fitted to COLUMNS. Each nudge has its own Large,
# Medium and Small form, then an icon, then a `+N` for however many still do
# not fit; the lowest-priority nudge still at its current size shrinks first,
# so a higher-priority nudge is never at a later size step than a
# lower-priority one (a nudge with no Medium form, such as /gaia-audit,
# shows its Small text at that step).
#
# Left-side resolution (first match wins):
#   1. User has `statusLine.command` in `~/.claude/settings.json` → run that
#      (so the adopter's existing global statusline appears unchanged).
#   2. No global command → the default left side (project, branch with a
#      linked-worktree marker, model and effort, a colored context bar).
#   3. Last resort, when that cannot render → bare "Claude Code" label.
#
# Every render also writes the session's context reading for the audit-loop
# bound hook (see context-reading.sh), whatever the left side is.
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


# Sets cols and left_visible; called only where a right side is about to be
# composed (the setup-gaia branch and the nudges-present branch), so a render
# with no right side pays no pipeline for it. Compose reads the values these
# leave behind. `awk`'s END block reports the LAST line's length (the row the
# right side actually joins) rather than one number per line, and `n+0`
# forces a plain digit even on empty input.
#
# `LC_ALL=C` makes every awk (BWK, gawk, mawk) count bytes rather than
# characters, even under a UTF-8 locale where BSD awk otherwise miscounts a
# multi-byte glyph as more than one column and gawk raises an invalid-range
# error on the byte-range gsub below. Deleting every UTF-8 continuation byte
# (`\200`-`\277`) first leaves exactly one byte per character; a 4-byte lead
# byte (`\360`-`\364`, emoji and other astral-plane glyphs) is counted a
# second time (`w`) to match its 2-column render. Known limit: a 3-byte
# glyph (CJK) still counts one column but renders two.
measure_left() {
  cols="${COLUMNS:-120}"
  left_visible=$(printf '%b' "$left" | sed 's/\x1b\[[0-9;]*m//g' | LC_ALL=C awk '{w = gsub(/[\360-\364]/, "&"); gsub(/[\200-\277]/, ""); n = length + w} END {print n+0}')
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
# One jq call extracts every stdin field this script uses (session directory,
# the context reading, model and effort); fields are joined by a control
# character no value contains. `used_tokens` is pinned as
# round(used_percentage / 100 * context_window_size), never the payload's
# total_input_tokens, which counts something else. The percentage is rounded to
# six decimals so the writer's validation accepts it; a field that is absent or
# the wrong type comes out empty. Silent on jq failure: every field then reads
# empty, nothing is written, and the render continues.
session_id=""
session_dir=""
ctx_pct=""
ctx_window=""
ctx_tokens=""
model_name=""
effort_level=""
fields=$(printf '%s' "$input" | jq -r '
  def str: if type == "string" then gsub("[\u0000-\u001f]"; "") else "" end;
  (.context_window | if type == "object" then . else {} end) as $c
  | (if ($c.used_percentage | type) == "number" and $c.used_percentage >= 0 and $c.used_percentage <= 999
     then ($c.used_percentage * 1000000 | round) / 1000000 else null end) as $pct
  | (if ($c.context_window_size | type) == "number" and $c.context_window_size >= 1 and $c.context_window_size <= 999999999999
     then ($c.context_window_size | floor) else null end) as $win
  | [ (.session_id | str),
      ((.workspace.current_dir // .cwd) | str),
      (if $pct != null and $win != null then ($pct | if . < 0.001 then "0" else tostring end) else "" end),
      (if $pct != null and $win != null then ($win | tostring) else "" end),
      (if $pct != null and $win != null then ($pct / 100 * $win | round | tostring) else "" end),
      (.model.display_name | str),
      (.effort.level | str) ]
  | join("\u001f")' 2>/dev/null) || fields=""
IFS=$'\037' read -r session_id session_dir ctx_pct ctx_window ctx_tokens model_name effort_level <<<"$fields"
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

# ---------- Context reading (written on every render) ----------
# The audit-loop bound hook reads the main session's context from a file only
# this script can produce, so the write comes first: before the left side,
# before any early exit, and regardless of IS_WORKTREE, GAIA_STATUSLINE_NESTED
# or the setup-gaia gating below. A sibling that is absent (an older checkout)
# or a write that fails never prints and never stops the render. The lib is
# sourced as "$GAIA_DIR/scripts/...", not from SCRIPT_DIR: a maintainer wrapper
# execs a patched copy that sits in a different directory.
if [ -f "$GAIA_DIR/scripts/context-checkpoint-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/scripts/context-checkpoint-lib.sh" 2>/dev/null || true
fi
if [ -f "$GAIA_DIR/statusline/context-reading.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/statusline/context-reading.sh" 2>/dev/null || true
fi
if command -v gaia_statusline_write_context >/dev/null 2>&1; then
  gaia_statusline_write_context "$STATE_ROOT" "$session_id" "$ctx_pct" "$ctx_window" "$ctx_tokens" >/dev/null 2>&1 || true
fi

# ---------- Left side ----------
# First match wins: the user's own global `statusLine.command`, then the ported
# default (project, branch, model and effort, context bar), then the bare label.
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

if [ -z "$left" ] && [ -f "$GAIA_DIR/statusline/left-side.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/statusline/left-side.sh" 2>/dev/null || true
  if command -v gaia_statusline_left >/dev/null 2>&1; then
    if gaia_statusline_left "$STATE_ROOT" "$session_dir" "$IS_WORKTREE" "$model_name" "$effort_level" "$ctx_pct" "$ctx_window" "$ctx_tokens" 2>/dev/null; then
      left="$_GAIA_SL_LEFT"
    fi
  fi
fi

[ -z "$left" ] && left="Claude Code"

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
    # gaia-audit 3, gaia-harden 4, gaia-debt 5, gaia-residue 6, gaia-wiki 7. The
    # update-check-derived nudges stay gated on $CACHE_FILE; the debt nudge is
    # gated independently on $DEBT_CACHE so it still renders when
    # update-check.json is absent, which is why debt (5) is armed after
    # residue (6) in source order but renders before it.
    #
    # Each slot carries its Large text, its bare Small command, and `mid`,
    # the Medium form's parenthetical content; an empty mid means the nudge
    # has no Medium size (its Large shrinks straight to Small). The renderer
    # below reads every slot once both blocks have run, sizes each nudge
    # independently (Large, then Medium, then Small, then icon, then folded
    # into the trailing `+N`), and shows an icon's mid as its count only when
    # mid is all digits.
    nudge_color=()
    nudge_small=()
    nudge_large=()
    nudge_mid=()
    nudge_icon=()
    nudge_set() {
      nudge_color[$1]="$2"
      nudge_small[$1]="$3"
      nudge_large[$1]="$4"
      nudge_mid[$1]="$5"
      nudge_icon[$1]="$6"
    }
    if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
      outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
      gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
      gaia_latest=$(jq -r '.gaiaLatest // empty' "$CACHE_FILE" 2>/dev/null)
      # One spawn for three reads: a digit-string candidate count, a comma,
      # then a leading 1 or 0 saying whether hardenNudgeReason exists,
      # followed by the reason itself.
      harden_all=$(jq -r '((.hardenCandidateCount // 0) | if type == "number" then (floor | tostring) else "0" end) + "," + (if has("hardenNudgeReason") then "1" + ((.hardenNudgeReason // "") | tostring) else "0" end)' "$CACHE_FILE" 2>/dev/null)
      harden_count="${harden_all%%,*}"
      harden_reason_raw="${harden_all#*,}"
      case "$harden_count" in
        ''|*[!0-9]*) harden_count=0 ;;
      esac
      # The Medium/icon form for /gaia-harden; empty when there is no
      # candidate count, so the segment goes straight to Small.
      harden_mid=""
      [ "$harden_count" -gt 0 ] 2>/dev/null && harden_mid="$harden_count"
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
        nudge_set 0 '01;36' 'Run /update-gaia' "$full" "$gaia_latest" '🌍'
      fi
      if [ -n "$outdated_count" ] && [ "$outdated_count" -gt 0 ] 2>/dev/null; then
        printf -v full 'Run /update-deps (%d outdated)' "$outdated_count"
        nudge_set 2 '01;33' 'Run /update-deps' "$full" "$outdated_count" '📦'
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
          nudge_set 4 '01;35' 'Run /gaia-harden' "$full" "$harden_mid" '🔨'
        fi
      else
        harden_unclassified=$(jq -r '.hardenUnclassifiedCount // 0' "$CACHE_FILE" 2>/dev/null)
        fallback_reason=""
        if [ "$harden_count" -gt 0 ] 2>/dev/null; then
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
          nudge_set 4 '01;35' 'Run /gaia-harden' "$full" "$harden_mid" '🔨'
        fi
      fi
      if [ "$audit_nudge" = "true" ]; then
        if [ -n "$audit_reason" ]; then
          printf -v full 'Run /gaia-audit (%s)' "$audit_reason"
          nudge_set 3 '01;32' 'Run /gaia-audit' "$full" '' '🔎'
        else
          nudge_set 3 '01;32' 'Run /gaia-audit' 'Run /gaia-audit' '' '🔎'
        fi
      fi
      if [ -n "$serena_drift" ]; then
        printf -v full 'Run /gaia-serena-sync (Serena missing: %s)' "$serena_drift"
        # Language count from the already-joined string: commas plus one.
        serena_commas="${serena_drift//[!,]/}"
        serena_n=$(( ${#serena_commas} + 1 ))
        nudge_set 1 '01;31' 'Run /gaia-serena-sync' "$full" "$serena_n" '🔭'
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
        nudge_set 6 '01;37' 'Run /gaia-residue' "$full" "$residue_count" '🧹'
      fi
      # Wiki nudge: renders once the wiki trails HEAD by at least
      # WIKI_NUDGE_THRESHOLD non-bookkeeping commits. A maintainer constant,
      # deliberately not adopter-configurable. Reads only the count the
      # refresher cached; no repository query runs on this render path.
      WIKI_NUDGE_THRESHOLD=20
      wiki_drift_count=$(jq -r '.wikiDriftCount // 0' "$CACHE_FILE" 2>/dev/null)
      case "$wiki_drift_count" in
        ''|*[!0-9]*) wiki_drift_count=0 ;;
      esac
      if [ "$wiki_drift_count" -ge "$WIKI_NUDGE_THRESHOLD" ] 2>/dev/null; then
        # 01;96 (bright cyan) is the one color no other slot or the setup
        # segment uses.
        nudge_set 7 '01;96' 'Run /gaia-wiki' "Run /gaia-wiki ($wiki_drift_count commits behind)" "$wiki_drift_count" '🧠'
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
        nudge_set 5 '01;34' 'Run /gaia-debt' "$full" "$debt_count" '💸'
      fi
    fi

    # Compact the sparse priority slots into dense, priority-ordered arrays;
    # a gap between slots is a nudge that did not arm this render. `${!arr[@]}`
    # walks an indexed array's set keys in ascending order, which is what
    # makes the slot numbers double as the render order. dense_iconcount is
    # derived in the same pass: a nudge's mid is shown on its icon only when
    # it is all digits (update-gaia's version mid stays bare).
    dense_color=()
    dense_small=()
    dense_large=()
    dense_mid=()
    dense_icon=()
    dense_iconcount=()
    for slot in "${!nudge_small[@]}"; do
      dense_color+=("${nudge_color[$slot]}")
      dense_small+=("${nudge_small[$slot]}")
      dense_large+=("${nudge_large[$slot]}")
      dense_mid+=("${nudge_mid[$slot]}")
      dense_icon+=("${nudge_icon[$slot]}")
      case "${nudge_mid[$slot]}" in
        ''|*[!0-9]*) dense_iconcount+=("") ;;
        *) dense_iconcount+=("${nudge_mid[$slot]}") ;;
      esac
    done
    n="${#dense_small[@]}"

    if [ "$n" -gt 0 ]; then
      measure_left
      # avail reserves the 2-column minimum gap Compose keeps between the
      # two sides.
      avail=$((cols - left_visible - 2))

      # Per-nudge size: 0 Large, 1 Medium, 2 Small, 3 icon, 4 hidden (folded
      # into the trailing `+N`). All start Large.
      lvl=()
      for ((i = 0; i < n; i++)); do
        lvl[i]=0
      done

      # Sets right_width, hidden_count, and right (composed inline, since
      # only the last call before the shrink loop below breaks is ever
      # printed) from the current $lvl values. A visible segment is 2
      # columns from its neighbor, except two adjacent icons, or an icon
      # next to the trailing `+N`, which are 1 (an icon already reads as a
      # unit with what immediately follows it). An icon's width is hardcoded
      # rather than measured off its text: a single emoji is one character
      # to bash's `${#...}` but renders two columns wide.
      measure() {
        right_width=0
        hidden_count=0
        right=""
        local i len text icon_form last=-1
        for ((i = 0; i < n; i++)); do
          if [ "${lvl[$i]}" -eq 4 ]; then
            hidden_count=$((hidden_count + 1))
            continue
          fi
          case "${lvl[$i]}" in
            0) text="${dense_large[$i]}"; icon_form=0 ;;
            1)
              if [ -n "${dense_mid[$i]}" ]; then
                text="${dense_small[$i]} (${dense_mid[$i]})"
              else
                text="${dense_small[$i]}"
              fi
              icon_form=0
              ;;
            2) text="${dense_small[$i]}"; icon_form=0 ;;
            3) text="${dense_icon[$i]}${dense_iconcount[$i]}"; icon_form=1 ;;
          esac
          if [ "$icon_form" -eq 1 ]; then
            len=$((2 + ${#dense_iconcount[$i]}))
          else
            len=${#text}
          fi
          if [ "$last" -ge 0 ]; then
            if [ "${lvl[$last]}" -eq 3 ] && [ "$icon_form" -eq 1 ]; then
              right_width=$((right_width + 1))
              right="${right} "
            else
              right_width=$((right_width + 2))
              right="${right}  "
            fi
          fi
          right_width=$((right_width + len))
          if [ "$icon_form" -eq 1 ]; then
            right="${right}${text}"
          else
            right="${right}"$'\033['"${dense_color[$i]}"'m'"${text}"$'\033[00m'
          fi
          last=$i
        done
        if [ "$hidden_count" -gt 0 ]; then
          if [ "$last" -ge 0 ]; then
            right_width=$((right_width + 1))
            right="${right} "
          fi
          right_width=$((right_width + 1 + ${#hidden_count}))
          right="${right}+${hidden_count}"
        fi
      }

      # Shrink the lowest-priority nudge still at the current size, one step
      # at a time: every nudge to Medium bottom-up, then Medium to Small
      # bottom-up, then Small to icon bottom-up, then icon to hidden
      # bottom-up. s caps at 4n (every nudge through every step), the point
      # at which every nudge is hidden and `+N` renders alone, even past
      # avail, rather than emitting nothing. The measure() call right before
      # the break leaves `right` and `right_width` set to what gets printed.
      s=0
      while :; do
        measure
        if [ "$right_width" -le "$avail" ] || [ "$s" -ge $((4 * n)) ]; then
          break
        fi
        lvl[n - 1 - s % n]=$((s / n + 1))
        s=$((s + 1))
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

pad=$((cols - left_visible - right_width))
if [ "$pad" -lt 2 ]; then
  pad=2
fi
spaces=$(printf '%*s' "$pad" '')
printf '%b%s%s' "$left" "$spaces" "$right"
