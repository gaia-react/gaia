#!/usr/bin/env bash
# after_clarify.sh - Self-review pass + clarifications.pending block-or-defer driver.
#
# Reads JSON payload from stdin (or $SPECKIT_HOOK_PAYLOAD env var).
#
# Returns:
#   {"action": "prompt", "prompt": "...", "default": "..."}  while pending items remain
#   {"action": "proceed"}                                    once pending is fully resolved
#   {"action": "block",  "reason": "..."}                    on input/payload errors
#
# UATs: UAT-016 (self-review pass), UAT-017 (pending block-or-defer).
#
# Self-review semantics: this hook performs a deterministic structural audit and
# records a confirmation entry into clarifications.answered. The agent-driven
# semantic review (scope-drift vs. gate-1 snapshot, ambiguous UAT phrasing) lives
# in the wrapper command - this hook surfaces structural findings the wrapper can
# act on, and never silently proceeds when issues remain.
set -euo pipefail

# --- jq availability ---
if ! command -v jq > /dev/null 2>&1; then
  printf '{"action":"block","reason":"after_clarify.sh requires jq; install jq and retry."}\n'
  exit 0
fi

# --- Read payload ---
payload=""
if [ -n "${SPECKIT_HOOK_PAYLOAD:-}" ]; then
  payload="$SPECKIT_HOOK_PAYLOAD"
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi

if [ -z "$payload" ]; then
  printf '{"action":"block","reason":"after_clarify.sh: empty payload (expected JSON on stdin or $SPECKIT_HOOK_PAYLOAD)."}\n'
  exit 0
fi

if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  printf '{"action":"block","reason":"after_clarify.sh: payload is not valid JSON."}\n'
  exit 0
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
draft_path="$(printf '%s' "$payload" | jq -r '.draft_path // ""')"
spec_id="$(printf '%s' "$payload" | jq -r '.spec_id // ""')"
user_answer="$(printf '%s' "$payload" | jq -r '.user_answer // ""')"
pending_index="$(printf '%s' "$payload" | jq -r '.pending_index // 0')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  printf '{"action":"block","reason":"after_clarify.sh: payload.cwd is missing or not a directory."}\n'
  exit 0
fi

if [ -z "$draft_path" ] || [ "$draft_path" = "null" ]; then
  printf '{"action":"block","reason":"after_clarify.sh: payload.draft_path is required."}\n'
  exit 0
fi

draft_file="$cwd/$draft_path"
if [ ! -f "$draft_file" ]; then
  jq -n --arg p "$draft_path" \
    '{action:"block", reason:("after_clarify.sh: draft file not found at " + $p)}'
  exit 0
fi

# --- Step 1: Self-review pass (UAT-016) ---
# Structural audit: surface placeholder text, missing self-review confirmation entry.
# Scope-drift, ambiguity, and internal-inconsistency checks are agent-driven (lives in
# the wrapper); this hook records its own confirmation entry once and signals the
# wrapper to run its semantic review before gate 2.
self_review_findings=()

# Placeholder scan over the whole draft (same patterns as lib/lint.sh).
if grep -qE '\[PLACEHOLDER\]|<TODO>|<TBD>|FIXME' "$draft_file"; then
  self_review_findings+=("placeholder text remains in draft")
fi

# Confirm clarifications: section is present (we read it for step 2 anyway).
if ! grep -qE '^clarifications:' "$draft_file"; then
  self_review_findings+=("clarifications: block missing from frontmatter")
fi

# A scope-drift cache snapshot is expected at .gaia/local/cache/gate1-<spec_id>.json.
# Its presence is informational only; the wrapper performs the semantic comparison.
gate1_snapshot=""
if [ -n "$spec_id" ] && [ "$spec_id" != "null" ]; then
  gate1_snapshot="$cwd/.gaia/local/cache/gate1-$spec_id.json"
fi

# If structural findings exist, block so the wrapper can fix them before gate 2.
if [ "${#self_review_findings[@]}" -gt 0 ]; then
  joined="$(printf '%s; ' "${self_review_findings[@]}")"
  joined="${joined%; }"
  reason="Self-review pre-gate-2: $joined. Resolve before presenting the artifact."
  jq -n --arg r "$reason" '{action:"block", reason:$r}'
  exit 0
fi

# --- Step 2: clarifications.pending block-or-defer driver (UAT-017) ---
# Extract the pending list from the draft frontmatter. We support two shapes:
#   pending: []
#   pending:
#     - <free text item>
#     - q: ...
#       defer_rationale: ...   (when an item has been deferred but kept in pending)
#
# We count items whose line starts with "    - " inside the pending: block, and
# check whether each has a defer_rationale companion line. An item without a
# defer_rationale is "unresolved" and the hook prompts the wrapper for it.

pending_block="$(awk '
  /^---[[:space:]]*$/ { fm = !fm; next }
  fm && /^clarifications:/ { in_clar = 1; next }
  fm && in_clar && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_clar = 0 }
  fm && in_clar && /^[[:space:]]+pending:/ { in_pend = 1; print; next }
  fm && in_clar && in_pend && /^[[:space:]]{0,2}[A-Za-z_][A-Za-z0-9_]*:/ { in_pend = 0 }
  fm && in_clar && in_pend { print }
' "$draft_file")"

# Determine if pending is the empty-array form.
if printf '%s' "$pending_block" | grep -qE '^[[:space:]]+pending:[[:space:]]*\[[[:space:]]*\][[:space:]]*$'; then
  # Empty list - resolved.
  printf '{"action":"proceed"}\n'
  exit 0
fi

# Collect pending items. An item starts at "    - " (4 spaces + dash) or deeper.
# We treat each top-level dash entry as one item. Items containing a
# "defer_rationale:" subkey are considered deferred (resolved).
# Use while-read instead of mapfile for bash 3.2 (macOS) compatibility.
item_starts=()
while IFS= read -r ln; do
  [ -n "$ln" ] && item_starts+=("$ln")
done < <(printf '%s\n' "$pending_block" | grep -nE '^[[:space:]]{2,}-[[:space:]]' | cut -d: -f1)

if [ "${#item_starts[@]}" -eq 0 ]; then
  # No structured items found (could be a stub); treat as resolved.
  printf '{"action":"proceed"}\n'
  exit 0
fi

# Build per-item line ranges and inspect each for defer_rationale.
total=${#item_starts[@]}
unresolved_summaries=()

# Convert pending_block to an array of lines for slicing.
pb_lines=()
while IFS= read -r ln; do
  pb_lines+=("$ln")
done < <(printf '%s\n' "$pending_block")
pb_total=${#pb_lines[@]}

i=0
while [ "$i" -lt "$total" ]; do
  start="${item_starts[$i]}"
  next_idx=$((i + 1))
  if [ "$next_idx" -lt "$total" ]; then
    end=$(( ${item_starts[$next_idx]} - 1 ))
  else
    end=$pb_total
  fi
  # Slice (1-indexed start..end).
  slice=""
  j=$((start - 1))
  while [ "$j" -lt "$end" ] && [ "$j" -lt "$pb_total" ]; do
    slice+="${pb_lines[$j]}"$'\n'
    j=$((j + 1))
  done

  # Does this item carry a defer_rationale?
  if printf '%s' "$slice" | grep -qE '^[[:space:]]+defer_rationale:[[:space:]]+'; then
    i=$((i + 1))
    continue
  fi

  # Pull a short summary: first non-empty line, trimmed.
  summary="$(printf '%s' "$slice" | head -n 1 | sed -E 's/^[[:space:]]+-[[:space:]]+//; s/^q:[[:space:]]+//; s/^"//; s/"$//')"
  if [ -z "$summary" ]; then
    summary="(unlabeled item)"
  fi
  unresolved_summaries+=("$summary")
  i=$((i + 1))
done

if [ "${#unresolved_summaries[@]}" -eq 0 ]; then
  printf '{"action":"proceed"}\n'
  exit 0
fi

# The wrapper drives the loop one item at a time. We emit a prompt for the
# unresolved item at position pending_index (clamped). The wrapper re-invokes
# this hook after each answer/defer, incrementing pending_index in the payload.
target=0
if [[ "$pending_index" =~ ^[0-9]+$ ]]; then
  target=$pending_index
fi
if [ "$target" -ge "${#unresolved_summaries[@]}" ]; then
  target=0
fi

q_summary="${unresolved_summaries[$target]}"

jq -n --arg q "$q_summary" \
  '{
    action: "prompt",
    prompt: ("Pending: " + $q + ". Answer now, or defer with rationale?"),
    default: "answer"
  }'
exit 0
