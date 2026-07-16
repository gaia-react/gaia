#!/usr/bin/env bash
# audit-dispositions.sh: the shared disposition-ledger logic for the Code Audit
# Team. Sourced, never executed; does no work at source time.
#
# The disposition-ledger sidecar is keyed to the frontend member's content
# digest (<frontend-digest>.dispositions.json), valid iff the frontend earned
# marker for that digest is valid. Two functions, two callers each:
#
#   disposition_offenders <sidecar>
#       Prints one offender line per unmet disposition on stdout; empty output
#       (and exit 0) means clean. FAIL-OPEN everywhere it cannot prove an
#       inconsistency: no sidecar, unparseable sidecar, backend "absent", or any
#       gh/tooling failure. Blocks ONLY on a confirmed present-backend
#       filed-but-missing key or a pending(definitive) entry. Called by both
#       the deterministic backstop hook (.claude/hooks/audit-disposition-check.sh)
#       and the merge gate (.claude/hooks/pr-merge-audit-check.sh) to re-verify
#       the current sidecar's claims.
#
#   disposition_seed_forward <prev-sidecar> <new-sidecar>
#       Unions every still-open entry (`filed`, or `pending` with
#       `pending_reason` "definitive") from <prev-sidecar> into <new-sidecar>,
#       in place. A fresh incremental audit does not re-encounter a prior
#       out-of-scope finding, so a digest rotation alone would silently drop a
#       still-open receipt; the code-audit-frontend agent calls this when it
#       writes the sidecar for a new frontend digest, seeding it from the
#       immediately-prior frontend digest's sidecar so the receipt survives the
#       rotation. HEAD's fresh entry always wins on a key collision (a seeded
#       entry may only ADD keys). A plain still-open union: no anchor
#       selection, no ancestry, no backend precedence.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# --- disposition_offenders <sidecar> -----------------------------------------
#
# The sidecar `key` is the dedup-key INNER content `v1 class=… path=… line=…`
# WITHOUT the `<!-- gaia-debt-key: … -->` wrapper; a filed issue body carries
# the wrapped form. A match reconstructs the WRAPPED form and tests the issue
# body for it as a SUBSTRING (the trailing ` -->` prevents a `line=4` key
# digit-prefix-matching a sibling `line=42 -->` issue), never whole-line
# equality. A CLOSED matching issue is a SATISFIED disposition, not an offender.
disposition_offenders() {
  local sidecar="$1"
  local backend offenders="" pending_keys filed_keys issues_json gh_ok k key needle present

  command -v jq >/dev/null 2>&1 || return 0

  # No sidecar / unparseable / backend "absent" -> fail-open (nothing to verify).
  [ -f "$sidecar" ] || return 0
  jq -e . "$sidecar" >/dev/null 2>&1 || return 0
  backend=$(jq -r '.backend // ""' "$sidecar" 2>/dev/null || true)
  [ "$backend" = "absent" ] && return 0

  # (a) pending(definitive): a genuinely-missing disposition. A local sidecar
  # fact, so deny regardless of backend reachability.
  pending_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "pending"
         and (.pending_reason // "") == "definitive")
    | (.key // "(no key)")' "$sidecar" 2>/dev/null || true)
  if [ -n "$pending_keys" ]; then
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      offenders="${offenders}pending(definitive): ${k}
"
    done <<EOF
$pending_keys
EOF
  fi

  # (b) filed entries: each key must resolve to a tech-debt issue, OPEN or
  # CLOSED, on a REACHABLE backend. Only query when there is a filed entry.
  filed_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "filed")
    | (.key // empty)' "$sidecar" 2>/dev/null || true)

  if [ -n "$filed_keys" ]; then
    issues_json=""
    gh_ok=0
    if command -v gh >/dev/null 2>&1; then
      if issues_json=$(gh issue list --label tech-debt --state all \
          --json number,body --limit 1000 2>/dev/null) \
         && printf '%s' "$issues_json" | jq -e . >/dev/null 2>&1; then
        gh_ok=1
      fi
    fi

    if [ "$gh_ok" -eq 1 ]; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        needle="<!-- gaia-debt-key: ${key} -->"
        present=$(printf '%s' "$issues_json" \
          | jq -r --arg k "$needle" 'any(.[]?; (.body // "") | contains($k))' \
              2>/dev/null || true)
        if [ "$present" != "true" ]; then
          offenders="${offenders}filed-but-missing: ${key}
"
        fi
      done <<EOF
$filed_keys
EOF
    fi
    # gh_ok == 0 -> backend unreachable/transient: fail open, no filed offenders.
  fi

  [ -n "$offenders" ] && printf '%s' "$offenders"
  return 0
}

# --- disposition_seed_forward <prev-sidecar> <new-sidecar> -------------------
#
# Unions every still-open entry from <prev-sidecar> into <new-sidecar>, writing
# <new-sidecar> in place (atomically: temp file + mv). "Still-open" is the SAME
# predicate the janitor's open-receipt keep-arm applies:
#
#   .disposition == "filed"
#   OR (.disposition == "pending" AND .pending_reason == "definitive")
#
# On a key collision, HEAD's fresh entry in <new-sidecar> always wins; a seeded
# entry may only ADD keys, never overwrite one already present. A plain
# still-open union: no anchor selection, no ancestry walk, no backend
# precedence logic.
#
# A missing <new-sidecar> is treated as an empty record, so still-open entries
# write through (all keys are new). A missing/unparseable <prev-sidecar>, an
# absent jq, or any error is a no-op that leaves <new-sidecar> untouched.
disposition_seed_forward() {
  local prev="$1" new="$2"
  local prev_json new_json merged tmp

  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$prev" ] && [ -n "$new" ] || return 0
  [ -f "$prev" ] || return 0
  prev_json=$(jq -e . "$prev" 2>/dev/null) || return 0

  if [ -f "$new" ]; then
    new_json=$(jq -e . "$new" 2>/dev/null) || new_json='{}'
  else
    new_json='{}'
  fi

  merged=$(printf '%s\n%s\n' "$prev_json" "$new_json" | jq -s '
    .[0] as $prev | .[1] as $new |
    ($new.findings // []) as $nf |
    ([ $nf[] | .key ]) as $nkeys |
    ($prev.findings // []) as $pf |
    ([ $pf[] | select(
        (.disposition // "") == "filed"
        or ((.disposition // "") == "pending" and (.pending_reason // "") == "definitive")
      )
    ]) as $still_open |
    ($still_open | map(select((.key as $k | $nkeys | index($k)) | not))) as $seeded |
    $new | .findings = ($nf + $seeded)
  ' 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0

  mkdir -p "$(dirname "$new")" 2>/dev/null || true
  tmp=$(mktemp "$(dirname "$new")/.audit-dispositions.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$merged" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$new" 2>/dev/null || { rm -f "$tmp"; return 0; }
  return 0
}
