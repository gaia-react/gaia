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
#   - hardenNudgeReason (the composed text the /gaia-harden segment renders;
#                     the two counts above keep being written even though the
#                     statusline no longer reads them directly, so a cache
#                     written before this field existed still has a value to
#                     seed the reason from on the first post-upgrade refresh)
#   - residueCandidateCount (keyed audit residue aged 30+ days, ready to
#                     triage via /gaia-residue)
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
AUDIT_CLAUDEMD_BUDGET=500
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
# The review snapshot lives at registry scope "shared", same anchor as the
# cache: one physical copy per clone, under the main checkout.
HARDEN_SNAPSHOT_FILE="$STATE_ROOT/.gaia/local/harden/reviewed.json"

# Source the Serena language-drift library (Phase 1). Guarded so a missing
# library never breaks the refresher.
SERENA_LIB="$GAIA_DIR/scripts/lib/serena-lang.sh"
# shellcheck source=.gaia/scripts/lib/serena-lang.sh
[ -f "$SERENA_LIB" ] && . "$SERENA_LIB"

# Today's harden-nudge count text: shared by the no-snapshot composition
# below and the upgrade-window seed for a cache written before
# hardenNudgeReason existed, so the two cannot drift out of step with each
# other. gaia-statusline.sh keeps its own copy of this composition for its
# legacy-cache fallback; harden-nudge-reason.bats pins both surfaces to the
# same rendered text.
harden_count_reason() {
  local count="$1" unclassified="$2" reason="" noun
  if [ "$count" -gt 0 ] 2>/dev/null; then
    noun="recurring patterns"
    [ "$count" -eq 1 ] && noun="recurring pattern"
    reason=$(printf '%d %s' "$count" "$noun")
  fi
  if [ "$unclassified" -gt 0 ] 2>/dev/null; then
    [ -n "$reason" ] && reason="${reason}, "
    reason=$(printf '%s%d unclassified' "$reason" "$unclassified")
  fi
  printf '%s' "$reason"
}

now=$(date +%s)

# Read previous cache values (used as fallbacks on partial failure).
prev_checked_at=0
prev_outdated_count=0
prev_gaia_latest=""
prev_harden_count=0
prev_harden_unclassified=0
prev_harden_reason=""
prev_residue_count=0
prev_audit_last_applied_at=0
prev_audit_memory_count=0
prev_audit_memory_baseline=0
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
  # A cache written before hardenNudgeReason existed (the upgrade window) has
  # no key to read, so seed it from the counts it does carry with today's
  # composition, never "": otherwise the first refresh after an upgrade that
  # fails to read harden-tally would write an empty reason and silently drop a
  # nudge the old cache was showing.
  if jq -e 'has("hardenNudgeReason")' "$CACHE_FILE" >/dev/null 2>&1; then
    prev_harden_reason=$(jq -r '.hardenNudgeReason // ""' "$CACHE_FILE" 2>/dev/null)
  else
    prev_harden_reason=$(harden_count_reason "$prev_harden_count" "$prev_harden_unclassified")
  fi
  prev_residue_count=$(jq -r '.residueCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_last_applied_at=$(jq -r '.auditLastAppliedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_count=$(jq -r '.auditMemoryCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_baseline=$(jq -r '.auditMemoryBaseline // 0' "$CACHE_FILE" 2>/dev/null)
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

# Race token: the review snapshot's own reviewed_at, read here (past the TTL
# gate, since only a refresh needs it) and again right before the cache
# write. Plain string equality only (a completed review clears the cache
# directly, this is not the clock the TTL gate uses), empty on an absent,
# unparseable, or field-missing snapshot.
snapshot_token_t0=""
if [ -f "$HARDEN_SNAPSHOT_FILE" ] && command -v jq >/dev/null 2>&1; then
  snapshot_token_t0="$(jq -r '.reviewed_at // empty' "$HARDEN_SNAPSHOT_FILE" 2>/dev/null)"
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# Single-flight lock. The statusline fires this script on every render, and
# the TTL gate above reads `checkedAt`, which is only written when a run
# finishes, so without a lock every render during a run launches another full
# run, each paging the merged-PR window through gh. `mkdir` is the atomic
# test-and-set. A lock older than LOCK_STALE_MINUTES belongs to a run that was
# killed before its EXIT trap fired, or one stalled on the network (nothing
# here carries a timeout); it is renamed aside and retaken, so a crash cannot
# block every future refresh. Held or lost: exit 0 and leave the cache to the
# run that holds it.
#
# The staleness probe and the rename are separate steps: two contenders can
# see the same stale lock, and by the time the slower one renames, the faster
# one has already retaken a live lock in its place. So the staleness is
# re-checked on the renamed directory (a rename keeps its mtime), and a live
# lock is handed back. The owner file covers the other half: a stalled holder
# whose lock was reclaimed removes the lock on exit only while it still holds
# it, never a successor's.
#
# Honest limit: a stalled holder keeps running after its lock is reclaimed,
# and a hand-back that loses to a third contender leaves that contender
# running beside the faster one. Each costs one duplicate refresh, whose cache
# write is an atomic mv. And a contender that renames a lock aside in the
# instant between its taker's mkdir and owner write hands it back ownerless,
# so no run releases it and refreshes wait out LOCK_STALE_MINUTES.
LOCK_DIR="$CACHE_DIR/.update-check.lock"
LOCK_STALE_MINUTES=10
lock_is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]
}
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if lock_is_stale "$LOCK_DIR" && mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
    if ! lock_is_stale "$LOCK_DIR.stale.$$"; then
      mv "$LOCK_DIR.stale.$$" "$LOCK_DIR" 2>/dev/null
      exit 0
    fi
    rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/owner" 2>/dev/null
trap '[ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

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

# ---------- hardenCandidateCount / hardenUnclassifiedCount / hardenNudgeReason ----------
# Recurring-finding tally for the policy-memory loop. `harden-tally` reads the
# rolling 90-day merged-PR window via gh, counts distinct PRs per finding_class
# at any severity (severity_max is a running-max ranking signal, not an
# eligibility gate), drops promoted/suppressed classes, and emits
# candidate_count plus a separate `unclassified` recurrence signal (non-null
# only at/above the recurrence threshold). Runs in this same TTL pass; network
# is non-fatal (gh failure yields candidate_count 0 and unclassified null).
# Falls back to the previous cached counts on any failure: missing binary,
# network error, parse error.
#
# hardenNudgeReason is the text the statusline actually renders; the two
# counts above keep being written for the upgrade-window seed (see
# prev_harden_reason). Without a review snapshot (snapshot_present not true:
# no snapshot yet, or a pre-SPEC/mock binary), the reason is today's count
# text via harden_count_reason. With one, it names the trigger events
# harden-tally reports: schema_change, the new_class count, one
# "<last path segment of finding_class> rising" per rising_class in
# triggers[] order (the segment stripped to [A-Za-z0-9._-], since class
# names come from PR comments any author can write), then "unclassified
# rising"; empty when triggers is empty.
#
# snapshot_present and snapshot_reviewed_at are read from the tally JSON; the
# race check below (arm b) needs this run's own values to catch harden-tally's
# own snapshot reading disagreeing with the file the script re-reads before
# the write, a mismatch arm (a) cannot see because both of the script's own
# reads of that file agree with each other.
harden_count="$prev_harden_count"
unclassified_count="$prev_harden_unclassified"
harden_reason="$prev_harden_reason"
snapshot_present="false"
snapshot_reviewed_at=""
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  tally_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" harden-tally 2>/dev/null)"
  if [ -n "$tally_json" ]; then
    parsed=$(printf '%s' "$tally_json" | jq -r '.candidate_count // empty' 2>/dev/null)
    unclassified_parsed=$(printf '%s' "$tally_json" | jq -r '.unclassified.distinct_pr_count // 0' 2>/dev/null)
    snapshot_present=$(printf '%s' "$tally_json" | jq -r '.snapshot_present // false' 2>/dev/null)
    snapshot_reviewed_at=$(printf '%s' "$tally_json" | jq -r '.snapshot_reviewed_at // empty' 2>/dev/null)
    case "$parsed" in
      ''|*[!0-9]*) ;;
      *) harden_count="$parsed" ;;
    esac
    case "$unclassified_parsed" in
      ''|*[!0-9]*) ;;
      *) unclassified_count="$unclassified_parsed" ;;
    esac
    if [ "$snapshot_present" = "true" ]; then
      harden_reason=$(printf '%s' "$tally_json" | jq -r '
        [.triggers[]?] as $triggers
        | ($triggers | map(select(.type=="new_class")) | length) as $newk
        | [
            (if ($triggers | any(.type=="schema_change")) then "tally changed" else empty end),
            (if $newk > 0 then (if $newk == 1 then "1 new pattern" else "\($newk) new patterns" end) else empty end),
            ($triggers[] | select(.type=="rising_class") | (.finding_class | split("/") | last | gsub("[^A-Za-z0-9._-]"; "") | if . == "" then "a pattern" else . end) + " rising"),
            (if ($triggers | any(.type=="rising_unclassified")) then "unclassified rising" else empty end)
          ]
        | join(", ")
      ' 2>/dev/null)
    else
      harden_reason=$(harden_count_reason "$harden_count" "$unclassified_count")
    fi
  fi
fi
case "$harden_count" in
  ''|*[!0-9]*) harden_count=0 ;;
esac
case "$unclassified_count" in
  ''|*[!0-9]*) unclassified_count=0 ;;
esac

# ---------- residueCandidateCount ----------
# Aged-residue tally for the /gaia-residue nudge.
# `residue-tally --count-only` is mandatory here: the refresher must never
# do head-object resolution, which costs 8.6-15.5s per
# fetch and grows the object store from 7.4MB to 66MB over fourteen fetches;
# a refresher that resolves is the failure this flag exists to prevent. It
# emits `aged_candidate_count` (survivors whose age_days >= 30, computed over
# the full post-suppression population before the cap) and a `gh_ok` flag.
# On a gh/network failure it exits 0 emitting aged_candidate_count 0 and
# gh_ok false, so this consumer honors gh_ok and keeps the previous cached
# count rather than resetting the nudge to 0. `count_approximate` is always
# true in --count-only mode (a coordinate-only suppression match, not a
# resolved-content bind); it is informational for a human reading the
# tally's own JSON, never branched on here, and never written to this cache.
# Falls back to the previous cached count on any failure: missing binary,
# gh/network error (gh_ok false), parse error.
residue_count="$prev_residue_count"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  residue_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" residue-tally --count-only 2>/dev/null)"
  if [ -n "$residue_json" ]; then
    parsed=$(printf '%s' "$residue_json" | jq -r '.aged_candidate_count // empty' 2>/dev/null)
    gh_ok=$(printf '%s' "$residue_json" | jq -r '.gh_ok // false' 2>/dev/null)
    if [ "$gh_ok" = "true" ]; then
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) residue_count="$parsed" ;;
      esac
    fi
  fi
fi
case "$residue_count" in
  ''|*[!0-9]*) residue_count=0 ;;
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
project_drift=false
hot_words=$(wc -w < "$PROJECT_ROOT/wiki/hot.md" 2>/dev/null | tr -d '[:space:]')
case "$hot_words" in
  ''|*[!0-9]*) hot_words=0 ;;
esac
if [ "$hot_words" -gt "$AUDIT_HOT_BUDGET" ] 2>/dev/null; then
  project_drift=true
fi
claudemd_words=$(wc -w < "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null | tr -d '[:space:]')
case "$claudemd_words" in
  ''|*[!0-9]*) claudemd_words=0 ;;
esac
if [ "$claudemd_words" -gt "$AUDIT_CLAUDEMD_BUDGET" ] 2>/dev/null; then
  project_drift=true
fi
for rule in "$PROJECT_ROOT"/.claude/rules/*.md; do
  [ -f "$rule" ] || continue
  rule_lines=$(wc -l < "$rule" 2>/dev/null | tr -d '[:space:]')
  case "$rule_lines" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$rule_lines" -gt "$AUDIT_RULE_BUDGET" ] 2>/dev/null; then
    project_drift=true
    break
  fi
done

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

# ---------- harden reason race check ----------
# A completed review clears hardenNudgeReason in the cache directly (the
# /gaia-audit precedent), so a refresh already in flight when that happens
# must not overwrite the clear with a reason computed against the superseded
# snapshot. Re-read the snapshot's reviewed_at now and compare it, by plain
# string equality only, against two prior readings. Arm (a): the script's own
# startup read, catching a review landing between the script's two reads of
# the file. Arm (b): harden-tally's own read of the snapshot, catching that
# read disagreeing with the file the script re-reads here even when the
# script's two reads agree with each other, e.g. a resolver or root mismatch
# between the CLI and the script. Either mismatch: discard the reason and
# zero checkedAt rather than trust it. Only these two fields change on a
# race; every other field is written as computed. Honest limit: this
# compares reads taken at different times, so a review landing between the
# re-read below and the mv is not seen, and costs one stale render until the
# next refresh.
snapshot_token_now=""
if [ -f "$HARDEN_SNAPSHOT_FILE" ] && command -v jq >/dev/null 2>&1; then
  snapshot_token_now="$(jq -r '.reviewed_at // empty' "$HARDEN_SNAPSHOT_FILE" 2>/dev/null)"
fi
checked_at_out="$now"
if [ "$snapshot_token_now" != "$snapshot_token_t0" ] \
  || { [ "$snapshot_present" = "true" ] && [ "$snapshot_token_now" != "$snapshot_reviewed_at" ]; }; then
  harden_reason=""
  checked_at_out=0
fi

# ---------- Write cache atomically ----------
tmp_file="$(mktemp "$CACHE_DIR/.update-check.XXXXXX" 2>/dev/null)"
if [ -z "$tmp_file" ]; then
  tmp_file="$CACHE_FILE.tmp.$$"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson checkedAt "$checked_at_out" \
    --argjson outdatedCount "$outdated_count" \
    --arg gaiaCurrent "$gaia_current" \
    --arg gaiaLatest "$gaia_latest" \
    --argjson gaiaHasUpdate "$gaia_has_update" \
    --argjson hardenCandidateCount "$harden_count" \
    --argjson hardenUnclassifiedCount "$unclassified_count" \
    --arg hardenNudgeReason "$harden_reason" \
    --argjson residueCandidateCount "$residue_count" \
    --argjson auditNudge "$audit_nudge" \
    --arg auditNudgeReason "$audit_nudge_reason" \
    --argjson auditLastAppliedAt "$audit_last_applied_at" \
    --argjson auditMemoryCount "$audit_memory_count" \
    --argjson auditMemoryBaseline "$audit_memory_baseline" \
    --argjson serenaLangDrift "$serena_lang_drift_json" \
    '{checkedAt: $checkedAt, outdatedCount: $outdatedCount, gaiaCurrent: $gaiaCurrent, gaiaLatest: $gaiaLatest, gaiaHasUpdate: $gaiaHasUpdate, hardenCandidateCount: $hardenCandidateCount, hardenUnclassifiedCount: $hardenUnclassifiedCount, hardenNudgeReason: $hardenNudgeReason, residueCandidateCount: $residueCandidateCount, auditNudge: $auditNudge, auditNudgeReason: $auditNudgeReason, auditLastAppliedAt: $auditLastAppliedAt, auditMemoryCount: $auditMemoryCount, auditMemoryBaseline: $auditMemoryBaseline, serenaLangDrift: $serenaLangDrift}' \
    > "$tmp_file" 2>/dev/null
else
  # jq not available; emit valid JSON via printf. serenaLangDrift is empty:
  # deriving it requires jq.
  # harden_reason is always the empty string on this path: both places that
  # compute it (the tally-driven composition above and the cache seed at
  # startup) require jq themselves, so neither branch ever runs without it.
  # Nothing here needs escaping.
  printf '{"checkedAt":%s,"outdatedCount":%s,"gaiaCurrent":"%s","gaiaLatest":"%s","gaiaHasUpdate":%s,"hardenCandidateCount":%s,"hardenUnclassifiedCount":%s,"hardenNudgeReason":"%s","residueCandidateCount":%s,"auditNudge":%s,"auditNudgeReason":"%s","auditLastAppliedAt":%s,"auditMemoryCount":%s,"auditMemoryBaseline":%s,"serenaLangDrift":[]}\n' \
    "$checked_at_out" "$outdated_count" "$gaia_current" "$gaia_latest" "$gaia_has_update" "$harden_count" "$unclassified_count" "$harden_reason" "$residue_count" "$audit_nudge" "$audit_nudge_reason" "$audit_last_applied_at" "$audit_memory_count" "$audit_memory_baseline" \
    > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

exit 0
