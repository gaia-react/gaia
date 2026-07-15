#!/usr/bin/env bash
# audit-dispositions.sh: the shared disposition-ledger logic for the Code Audit
# Team. Sourced, never executed; does no work at source time.
#
# One implementation, two consumers: the deterministic backstop hook
# (.claude/hooks/audit-disposition-check.sh) and the minting authority
# (.claude/hooks/pr-merge-audit-check.sh). The authority re-runs the filed-key
# verification on HEAD's carried-into sidecar, which the sibling hook cannot be
# relied on to do (its execution order against the authority is not a contract),
# so the check lives here where both share it.
#
#   disposition_offenders <sidecar>
#       Prints one offender line per unmet disposition on stdout; empty output
#       (and exit 0) means clean. FAIL-OPEN everywhere it cannot prove an
#       inconsistency: no sidecar, unparseable sidecar, backend "absent", or any
#       gh/tooling failure. Blocks ONLY on a confirmed present-backend
#       filed-but-missing key or a pending(definitive) entry.
#
#   disposition_merge <anchor-sidecar> <head-sidecar>
#       Merges the anchor's disposition record INTO head's, in place. HEAD's
#       fresh entry always wins on a key collision (a carried entry may only ADD
#       keys); the strictest backend wins (a non-"absent" side is never silenced
#       by an "absent" one).
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

# --- disposition_merge <anchor-sidecar> <head-sidecar> -----------------------
#
# Merges the anchor's disposition record INTO head's, writing head in place
# (atomically: temp file + mv). Contract, not the implementer's choice, because
# merge-conflict resolution inside a gate cannot be left to the implementer:
#
#   - On a key collision, HEAD's fresh entry always wins; a carried entry may
#     only ADD keys (a carry can never downgrade a live finding).
#   - The strictest backend wins: if either side is non-"absent", the merged
#     backend is the non-"absent" one, so a carried entry recorded under a
#     reachable backend is never silenced by an "absent" short-circuit inherited
#     from a sibling's write.
#
# A missing head sidecar is treated as an empty record, so the merge writes the
# anchor's findings through (all keys are new). A missing/unparseable anchor
# sidecar is a no-op. Fail-safe: any error leaves head untouched.
disposition_merge() {
  local anchor="$1" head="$2"
  local anchor_json head_json merged tmp

  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$anchor" ] && [ -n "$head" ] || return 0
  [ -f "$anchor" ] || return 0
  anchor_json=$(jq -e . "$anchor" 2>/dev/null) || return 0

  if [ -f "$head" ]; then
    head_json=$(jq -e . "$head" 2>/dev/null) || head_json='{}'
  else
    head_json='{}'
  fi

  merged=$(printf '%s\n%s\n' "$anchor_json" "$head_json" | jq -s '
    .[0] as $anchor | .[1] as $head |
    ($head.findings // []) as $hf |
    ([ $hf[] | .key ]) as $hkeys |
    ($anchor.findings // []) as $af |
    ($af | map(select((.key as $k | $hkeys | index($k)) | not))) as $newf |
    ($head.backend // "absent") as $hb |
    ($anchor.backend // "absent") as $ab |
    (if $hb != "absent" then $hb elif $ab != "absent" then $ab else "absent" end) as $backend |
    $head | .findings = ($hf + $newf) | .backend = $backend
  ' 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0

  mkdir -p "$(dirname "$head")" 2>/dev/null || true
  tmp=$(mktemp "$(dirname "$head")/.audit-dispositions.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$merged" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$head" 2>/dev/null || { rm -f "$tmp"; return 0; }
  return 0
}
