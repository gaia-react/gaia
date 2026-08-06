#!/bin/bash
# GAIA SessionStart update checker.
#
# Writes .gaia/local/cache/shared/update-check.json with:
#   - outdatedCount  (actionable updates from `gaia update-deps run`, which
#                     applies the ESLint 9.x cap and the minimumReleaseAge
#                     cooldown, so it never counts updates the skill skips)
#   - gaiaCurrent    (from .gaia/VERSION)
#   - gaiaLatest     (from `gh release list` or curl GitHub API)
#   - gaiaHasUpdate  (semver comparison)
#   - hardenCandidateCount (recurring code-review findings ready to harden)
#   - hardenUnclassifiedCount (classless recurring findings over threshold;
#                     a seed-a-class-or-investigate signal, never a candidate)
#   - auditNudge / auditNudgeReason / auditLastAppliedAt / auditMemoryCount /
#                  auditMemoryBaseline (knowledge-audit drift signals)
#   - checkedAt      (Unix epoch seconds)
#
# TTL is 6 hours (21600s). Re-runs within the TTL exit immediately so the
# SessionStart hook can fire this in the background without paying the cost
# on every session.
#
# Partial failures are tolerated; exit 0 even if some fields could not be
# refreshed. Do NOT add `set -e`.

TTL=21600

# Knowledge-audit nudge thresholds. Tunable starting values:
#   - AUDIT_DRIFT_DAYS: days since the last `applied` audit before signal (a) fires.
#   - AUDIT_MEMORY_DELTA: memory entries gained since the last `applied` audit
#                         before signal (a) fires.
#   - AUDIT_HOT_BUDGET / AUDIT_CLAUDEMD_BUDGET: auto-load word budgets for
#     wiki/hot.md and root CLAUDE.md (signal b).
#   - AUDIT_RULE_BUDGET: max lines for any .claude/rules/*.md (signal b).
AUDIT_DRIFT_DAYS=30
AUDIT_MEMORY_DELTA=10
AUDIT_HOT_BUDGET=200
AUDIT_CLAUDEMD_BUDGET=400
AUDIT_RULE_BUDGET=200

# Resolve project root (parent of .gaia/) so the script works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"

# cache/shared/ is registry scope `shared`: one physical copy per clone, which
# the statusline reads by resolving the main checkout. This script's own
# location answers "which tree am I in", never "where does shared state live",
# so a copy running inside a worktree must ask the resolver the same question
# the reader asks. Degrade-to-local rather than fail (D-5.3-c), matching
# .gaia/statusline/gaia-statusline.sh: with no resolver to ask, the local root
# is the honest answer and the refresher still refreshes.
#
# STATE_ROOT anchors machine-local STATE only. Everything this script measures
# out of the checkout itself -- wiki/hot.md, CLAUDE.md, .claude/rules/*.md, the
# Serena language drift, and the two CLI invocations below -- stays on
# PROJECT_ROOT, because those are tracked files that legitimately differ per
# branch. Repointing them wholesale would make this refresher report a fact
# about a tree nobody is in.
if [ -f "$GAIA_DIR/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/scripts/main-root-lib.sh" 2>/dev/null || true
fi
STATE_ROOT=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  STATE_ROOT="$(gaia_resolve_main_root "$PROJECT_ROOT" 2>/dev/null || true)"
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="$PROJECT_ROOT"

CACHE_DIR="$STATE_ROOT/.gaia/local/cache/shared"
CACHE_FILE="$CACHE_DIR/update-check.json"
VERSION_FILE="$GAIA_DIR/VERSION"

# Source the Serena language-drift library (Phase 1). Guarded so a missing
# library never breaks the refresher.
SERENA_LIB="$GAIA_DIR/scripts/lib/serena-lang.sh"
# shellcheck source=.gaia/scripts/lib/serena-lang.sh
[ -f "$SERENA_LIB" ] && . "$SERENA_LIB"

now=$(date +%s)

# Read previous cache values (used as fallbacks on partial failure).
prev_checked_at=0
prev_outdated_count=0
prev_gaia_latest=""
prev_harden_count=0
prev_harden_unclassified=0
prev_audit_last_applied_at=0
prev_audit_memory_count=0
prev_audit_memory_baseline=0
prev_audit_drift_baseline='{}'
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  prev_checked_at=$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
  # No prev_ seed for gaiaCurrent or gaiaHasUpdate, unlike their siblings here:
  # gaiaCurrent is read from the local .gaia/VERSION file (authoritative; a stale
  # cached value would be worse than none), and gaiaHasUpdate is derived from
  # gaia_current + gaia_latest, both of which already carry their own fallbacks.
  prev_gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
  prev_harden_count=$(jq -r '.hardenCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_harden_unclassified=$(jq -r '.hardenUnclassifiedCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_last_applied_at=$(jq -r '.auditLastAppliedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_count=$(jq -r '.auditMemoryCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_baseline=$(jq -r '.auditMemoryBaseline // 0' "$CACHE_FILE" 2>/dev/null)
  # Read once and validate that value, so the guard and the assignment cannot
  # disagree about what was read.
  drift_baseline_read=$(jq -c '.auditDriftBaseline // {}' "$CACHE_FILE" 2>/dev/null)
  case "$drift_baseline_read" in
    '{'*) prev_audit_drift_baseline="$drift_baseline_read" ;;
  esac
  case "$prev_checked_at" in
    ''|*[!0-9]*) prev_checked_at=0 ;;
  esac
  case "$prev_audit_last_applied_at" in
    ''|*[!0-9]*) prev_audit_last_applied_at=0 ;;
  esac
  case "$prev_audit_memory_count" in
    ''|*[!0-9]*) prev_audit_memory_count=0 ;;
  esac
  case "$prev_audit_memory_baseline" in
    ''|*[!0-9]*) prev_audit_memory_baseline=0 ;;
  esac
fi

# TTL gate.
age=$((now - prev_checked_at))
if [ "$age" -lt "$TTL" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# ---------- outdatedCount ----------
# Count only the updates /update-deps will actually apply. The `update-deps
# run` primitive runs the same Phase 1-3 filtering the skill does; the ESLint
# 9.x cap and the minimumReleaseAge cooldown (pnpm 11 rejects lockfile entries
# younger than the cooldown, so the flow skips them). Counting its emitted plan
# (wave members that are genuine upgrades) keeps the nudge from prodding for
# updates that would be skipped. Falls back to the previous cached count on any
# failure: missing binary, network error, parse error.
outdated_count="$prev_outdated_count"
GAIA_BIN="$GAIA_DIR/cli/gaia"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  updates_tmp="$(mktemp "$CACHE_DIR/.updates.XXXXXX" 2>/dev/null)"
  if [ -n "$updates_tmp" ]; then
    if (cd "$PROJECT_ROOT" && "$GAIA_BIN" update-deps run --emit-updates "$updates_tmp") >/dev/null 2>&1 && [ -s "$updates_tmp" ]; then
      # Prefer the payload's `actionable_count`: it already excludes packages
      # the human snoozed via /update-deps (the gitignored decline ledger) and
      # counts only genuine upgrades. Older payloads without the field fall back
      # to the inline recount, keeping the statusline backward-safe.
      parsed=$(jq '
        if (.actionable_count | type) == "number" then .actionable_count
        else
          ([.wave_a[]?, (.wave_b[]?.packages[]?)]
           | map(select(.current != .latest))
           | length)
        end
      ' "$updates_tmp" 2>/dev/null)
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) outdated_count="$parsed" ;;
      esac
    fi
    rm -f "$updates_tmp" 2>/dev/null
  fi
fi
case "$outdated_count" in
  ''|*[!0-9]*) outdated_count=0 ;;
esac

# ---------- hardenCandidateCount / hardenUnclassifiedCount ----------
# Recurring-finding tally for the policy-memory loop. `harden-tally` reads the
# rolling 90-day merged-PR window via gh, counts distinct PRs per finding_class
# at any severity (severity_max is a running-max ranking signal, not an
# eligibility gate), drops promoted/suppressed classes, and emits
# candidate_count plus a separate `unclassified` recurrence signal (non-null
# only at/above the recurrence threshold) and a gh_ok flag. Runs in this same
# TTL pass; network is non-fatal: on a gh/network failure harden-tally exits 0
# emitting candidate_count 0, unclassified null, and gh_ok false, so this
# consumer honors gh_ok and keeps the previous cached counts rather than
# resetting the nudges to 0. Falls back to the previous cached counts on any
# failure: missing binary, gh/network error (gh_ok false), parse error.
harden_count="$prev_harden_count"
unclassified_count="$prev_harden_unclassified"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  tally_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" harden-tally 2>/dev/null)"
  if [ -n "$tally_json" ]; then
    parsed=$(printf '%s' "$tally_json" | jq -r '.candidate_count // empty' 2>/dev/null)
    unclassified_parsed=$(printf '%s' "$tally_json" | jq -r '.unclassified.distinct_pr_count // 0' 2>/dev/null)
    gh_ok=$(printf '%s' "$tally_json" | jq -r '.gh_ok // false' 2>/dev/null)
    if [ "$gh_ok" = "true" ]; then
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) harden_count="$parsed" ;;
      esac
      case "$unclassified_parsed" in
        ''|*[!0-9]*) ;;
        *) unclassified_count="$unclassified_parsed" ;;
      esac
    fi
  fi
fi
case "$harden_count" in
  ''|*[!0-9]*) harden_count=0 ;;
esac
case "$unclassified_count" in
  ''|*[!0-9]*) unclassified_count=0 ;;
esac

# ---------- auditNudge ----------
# Three conservative knowledge-audit drift signals, computed here (never on the
# statusline hot path) into one verbatim reason string + the raw counters the
# debounce needs. All local file IO; missing dirs/files fall back to prev/zero,
# never fatal. Priority when several fire: draft-pending > new-memories >
# staleness > project drift (keeps the segment to one line).
#
# Last-audit anchor: the newest .gaia/local/audit/KNOWLEDGE-*.md whose frontmatter
# `status:` is `applied` (gitignored, machine-local). Its mtime is "last audit on
# this machine". The newest whose `status:` is `draft` sets the resume signal.
audit_last_applied_at="$prev_audit_last_applied_at"
audit_memory_count="$prev_audit_memory_count"
audit_memory_baseline="$prev_audit_memory_baseline"
audit_nudge=false
audit_nudge_reason=""

# (a) Memory entry count proxy: number of *.md files under the machine-local
# memory dir (same derivation /gaia-audit uses).
#
# Keyed by the tree's path SPELLING, so unlike everything else under
# .gaia/local this one is not reached through the worktree's shared-state
# symlink -- a worktree gets a genuinely different directory, and a freshly
# created worktree path has almost no memory history. Anchoring it to the main
# checkout keeps this a fact about the clone, which is what the shared cache it
# feeds is read as.
MEMORY_DIR="$HOME/.claude/projects/${STATE_ROOT//\//-}/memory"
if [ -d "$MEMORY_DIR" ]; then
  mem_count=$(find "$MEMORY_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$mem_count" in
    ''|*[!0-9]*) ;;
    *) audit_memory_count="$mem_count" ;;
  esac
fi

# Newest `applied` audit report → its mtime is the last-audit timestamp.
applied_at=0
draft_pending=false
AUDIT_DIR="$STATE_ROOT/.gaia/local/audit"
if [ -d "$AUDIT_DIR" ]; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    fm_status=$(sed -n '1,/^---[[:space:]]*$/p' "$f" 2>/dev/null \
      | grep -m1 -E '^status:[[:space:]]*' 2>/dev/null \
      | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')
    if [ "$fm_status" = "applied" ] || [ "$fm_status" = "applied-partial" ]; then
      if [ "$applied_at" -eq 0 ] 2>/dev/null; then
        m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
        case "$m" in
          ''|*[!0-9]*) ;;
          *) applied_at="$m" ;;
        esac
      fi
    elif [ "$fm_status" = "draft" ]; then
      draft_pending=true
    fi
  done < <(ls -t "$AUDIT_DIR"/KNOWLEDGE-*.md 2>/dev/null)
fi
# Advance the last-applied anchor (and reset the memory baseline to the count at
# that audit) only when a newer applied report appears. This is the debounce:
# running an audit writes a fresh applied report, moving the anchor forward and
# resetting the baseline, which clears signal (a).
if [ "$applied_at" -gt "$audit_last_applied_at" ] 2>/dev/null; then
  audit_last_applied_at="$applied_at"
  audit_memory_baseline="$audit_memory_count"
fi

# (a) Per-machine drift, two independent arms, each surfacing its own label:
#   - mem_drift:  memory grew by >= AUDIT_MEMORY_DELTA since the last applied audit
#   - time_drift: >= AUDIT_DRIFT_DAYS elapsed since the last applied audit
# The fire thresholds (>= 10 memories, >= 30 days) guarantee both counts are
# plural, so the reason strings below carry no singular form.
mem_delta=$((audit_memory_count - audit_memory_baseline))
drift_secs=$((AUDIT_DRIFT_DAYS * 86400))
mem_drift=false
time_drift=false
days_since=0
if [ "$mem_delta" -ge "$AUDIT_MEMORY_DELTA" ] 2>/dev/null; then
  mem_drift=true
fi
if [ "$audit_last_applied_at" -gt 0 ] 2>/dev/null \
  && [ "$((now - audit_last_applied_at))" -ge "$drift_secs" ] 2>/dev/null; then
  time_drift=true
  days_since=$(( (now - audit_last_applied_at) / 86400 ))
fi

# (b) Project drift: any committed auto-load file over budget. Budget-only, no
# committed marker; clears for everyone once a dev fixes + commits.
#
# Unlike the three arms above, this one is a live measurement rather than a
# debounce keyed to whether an audit ran, so completing an audit does not clear
# it. When the audit's answer is to FILE the over-budget file as tech-debt
# rather than trim it, the condition is already tracked in the debt channel and
# the nudge is asking for work that is queued. Suppress it in exactly that case:
# a path carrying an open `tech-debt` issue is the debt indicator's to report.
#
# The suppression key is shared state (an open issue, visible to everyone), so a
# machine-local audit run cannot silence a repo-wide condition for other devs.
covered_paths=""
if command -v jq >/dev/null 2>&1; then
  covered_paths=$(jq -r '.coveredPaths[]? // empty' "$STATE_ROOT/.gaia/local/debt/count.json" 2>/dev/null)
fi

# Growth guard: suppression must not hide a file that keeps growing. The size
# observed when a path was first suppressed lives in this script's own cache, so
# there is no new state file to register. Machine-local is sound for this
# specific value because it only ever UN-suppresses -- a baseline can add a
# nudge and can never remove one, which is the property the shared-state rule
# above exists to protect.
#
# This cache has other writers, and they matter here. /update-deps and
# /update-gaia rewrite it wholesale from an enumerated preserve list, so both
# must name this field. Unlike serenaLangDrift, which the next refresh
# recomputes from source, a baseline is a HISTORICAL OBSERVATION: drop it and
# the next run re-seeds at the file's current, larger size, disarming this guard
# with nothing to show for it. /gaia-audit's post-flight is safe by contrast,
# it updates single fields in place rather than rewriting the object.
drift_baseline_next=""

# drifts <repo-relative path> <measured> <budget>
# Returns 0 when the file is over budget AND not suppressed. Every suppressed
# path is recorded in drift_baseline_next, which becomes the next cache value;
# a path that stops being covered is simply not recorded, so its stale baseline
# drops rather than being inherited by a later re-filing.
drifts() {
  local path="$1" measured="$2" budget="$3" baseline=""
  [ "$measured" -gt "$budget" ] 2>/dev/null || return 1
  printf '%s\n' "$covered_paths" | grep -qxF -- "$path" || return 0
  baseline=$(printf '%s' "$prev_audit_drift_baseline" | jq -r --arg p "$path" '.[$p] // empty' 2>/dev/null)
  case "$baseline" in
    ''|*[!0-9]*) baseline="$measured" ;;
  esac
  drift_baseline_next="${drift_baseline_next}${baseline} ${path}
"
  # Compare against the ORIGINAL baseline and never advance it: a nudge that
  # fired once on growth and then went quiet would hide a file still growing.
  [ "$measured" -gt "$baseline" ] 2>/dev/null && return 0
  return 1
}

project_drift=false
hot_words=$(wc -w < "$PROJECT_ROOT/wiki/hot.md" 2>/dev/null | tr -d '[:space:]')
case "$hot_words" in
  ''|*[!0-9]*) hot_words=0 ;;
esac
if drifts "wiki/hot.md" "$hot_words" "$AUDIT_HOT_BUDGET"; then
  project_drift=true
fi
claudemd_words=$(wc -w < "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null | tr -d '[:space:]')
case "$claudemd_words" in
  ''|*[!0-9]*) claudemd_words=0 ;;
esac
if drifts "CLAUDE.md" "$claudemd_words" "$AUDIT_CLAUDEMD_BUDGET"; then
  project_drift=true
fi
# No early exit on the first over-budget rule file: the scan has to reach every
# covered file to record its baseline. Stopping at the first drifting file would
# leave a covered file later in the glob unmeasured, so its baseline would only
# be taken once the earlier file is fixed, at whatever size it had grown to by
# then, which is the growth guard reading a number it never observed.
for rule in "$PROJECT_ROOT"/.claude/rules/*.md; do
  [ -f "$rule" ] || continue
  rule_lines=$(wc -l < "$rule" 2>/dev/null | tr -d '[:space:]')
  case "$rule_lines" in
    ''|*[!0-9]*) continue ;;
  esac
  if drifts "${rule#"$PROJECT_ROOT"/}" "$rule_lines" "$AUDIT_RULE_BUDGET"; then
    project_drift=true
  fi
done

# Fold the surviving baselines back into a JSON object for the cache write.
audit_drift_baseline='{}'
if command -v jq >/dev/null 2>&1; then
  audit_drift_baseline=$(printf '%s' "$drift_baseline_next" | jq -R -s '
    split("\n") | map(select(length > 0))
    | map(capture("^(?<n>[0-9]+) (?<p>.*)$"))
    | map({(.p): (.n | tonumber)}) | add // {}' 2>/dev/null)
  case "$audit_drift_baseline" in
    '{'*) ;;
    *) audit_drift_baseline='{}' ;;
  esac
fi

# Pick the single highest-priority reason. The two machine-drift arms each get
# a self-describing label; when both fire, the concrete new-memory count wins.
if [ "$draft_pending" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="resume draft"
elif [ "$mem_drift" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="$mem_delta new memories"
elif [ "$time_drift" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="$days_since days since review"
elif [ "$project_drift" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="over budget"
fi

case "$audit_last_applied_at" in
  ''|*[!0-9]*) audit_last_applied_at=0 ;;
esac
case "$audit_memory_count" in
  ''|*[!0-9]*) audit_memory_count=0 ;;
esac
case "$audit_memory_baseline" in
  ''|*[!0-9]*) audit_memory_baseline=0 ;;
esac

# ---------- serenaLangDrift ----------
# Serena language-drift tokens: git-tracked high-signal manifests present but
# absent from Serena's effective configured languages. Computed by the shared
# lib (bash + jq + POSIX text tools; no yq). Empty array when Serena is not
# registered, .serena/project.yml is absent, or there is no drift. The no-jq
# write branch below hardcodes [] since the lib requires jq.
serena_lang_drift_json="[]"
if command -v jq >/dev/null 2>&1 && command -v serena_lang_drift >/dev/null 2>&1; then
  computed="$(serena_lang_drift "$PROJECT_ROOT" 2>/dev/null)"
  case "$computed" in
    '['*']') serena_lang_drift_json="$computed" ;;
  esac
fi

# ---------- gaiaCurrent ----------
gaia_current=""
if [ -f "$VERSION_FILE" ]; then
  gaia_current=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)
fi

# ---------- gaiaLatest ----------
gaia_latest=""
if command -v gh >/dev/null 2>&1; then
  gaia_latest=$(gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)
fi
if [ -z "$gaia_latest" ] && command -v curl >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  else
    # Last-resort: grep the tag_name out of the JSON without jq.
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
fi
# Strip leading 'v'.
gaia_latest="${gaia_latest#v}"
# Fall back to previous value if both fetchers failed (don't blank it).
if [ -z "$gaia_latest" ]; then
  gaia_latest="$prev_gaia_latest"
fi

# ---------- gaiaHasUpdate ----------
gaia_has_update=false
if [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] && [ "$gaia_current" != "$gaia_latest" ]; then
  highest=$(printf '%s\n%s\n' "$gaia_current" "$gaia_latest" | sort -V | tail -1)
  if [ "$highest" = "$gaia_latest" ]; then
    gaia_has_update=true
  fi
fi

# ---------- Write cache atomically ----------
tmp_file="$(mktemp "$CACHE_DIR/.update-check.XXXXXX" 2>/dev/null)"
if [ -z "$tmp_file" ]; then
  tmp_file="$CACHE_FILE.tmp.$$"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson checkedAt "$now" \
    --argjson outdatedCount "$outdated_count" \
    --arg gaiaCurrent "$gaia_current" \
    --arg gaiaLatest "$gaia_latest" \
    --argjson gaiaHasUpdate "$gaia_has_update" \
    --argjson hardenCandidateCount "$harden_count" \
    --argjson hardenUnclassifiedCount "$unclassified_count" \
    --argjson auditNudge "$audit_nudge" \
    --arg auditNudgeReason "$audit_nudge_reason" \
    --argjson auditLastAppliedAt "$audit_last_applied_at" \
    --argjson auditMemoryCount "$audit_memory_count" \
    --argjson auditMemoryBaseline "$audit_memory_baseline" \
    --argjson serenaLangDrift "$serena_lang_drift_json" \
    --argjson auditDriftBaseline "$audit_drift_baseline" \
    '{checkedAt: $checkedAt, outdatedCount: $outdatedCount, gaiaCurrent: $gaiaCurrent, gaiaLatest: $gaiaLatest, gaiaHasUpdate: $gaiaHasUpdate, hardenCandidateCount: $hardenCandidateCount, hardenUnclassifiedCount: $hardenUnclassifiedCount, auditNudge: $auditNudge, auditNudgeReason: $auditNudgeReason, auditLastAppliedAt: $auditLastAppliedAt, auditMemoryCount: $auditMemoryCount, auditMemoryBaseline: $auditMemoryBaseline, serenaLangDrift: $serenaLangDrift, auditDriftBaseline: $auditDriftBaseline}' \
    > "$tmp_file" 2>/dev/null
else
  # jq not available; emit valid JSON via printf. auditDriftBaseline is empty
  # for the same reason serenaLangDrift is: deriving it requires jq, and with
  # no jq there is no coveredPaths list to suppress against either.
  printf '{"checkedAt":%s,"outdatedCount":%s,"gaiaCurrent":"%s","gaiaLatest":"%s","gaiaHasUpdate":%s,"hardenCandidateCount":%s,"hardenUnclassifiedCount":%s,"auditNudge":%s,"auditNudgeReason":"%s","auditLastAppliedAt":%s,"auditMemoryCount":%s,"auditMemoryBaseline":%s,"serenaLangDrift":[],"auditDriftBaseline":{}}\n' \
    "$now" "$outdated_count" "$gaia_current" "$gaia_latest" "$gaia_has_update" "$harden_count" "$unclassified_count" "$audit_nudge" "$audit_nudge_reason" "$audit_last_applied_at" "$audit_memory_count" "$audit_memory_baseline" \
    > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

exit 0
