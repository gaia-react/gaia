#!/bin/bash
# PostToolUse Task hook: emit telemetry events for engineer-returns
# (uat_pass / needs_context_returned / blocked_returned) and
# code-review-audit findings (code_review_audit_finding).
#
# Reads the agent's structured-trailer block (YAML between fenced `---`
# lines) from the Task tool's output and dispatches `gaia telemetry emit`
# invocations idempotently — content-derived ULID `event_id` handles
# double emission with agent-inline emits (UAT-024/025/023).
#
# v1.0.0 ships the parser as a stub: silently no-ops on parse failure or
# absent trailer. Real-world emit volume from this hook is zero until
# agent skills (Sequel #1 onwards) author the trailer block.
#
# Always exits 0 — telemetry must never block the user's flow.

set -uo pipefail

LOG=/tmp/gaia-telemetry-hook.log

# Read hook input JSON from stdin
input=$(cat 2>/dev/null) || exit 0
[ -z "$input" ] && exit 0

# Bail fast on irrelevant tool invocations
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Task" ] || exit 0

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
[ -z "$subagent_type" ] && exit 0

output=$(printf '%s' "$input" | jq -r '.tool_response.output // empty' 2>/dev/null)
[ -z "$output" ] && exit 0

# Extract the first YAML-fence block (between two `---` lines) from the agent output.
trailer=$(printf '%s\n' "$output" | awk '
  /^---[[:space:]]*$/ {
    if (in_block) { exit }
    in_block = 1
    next
  }
  in_block { print }
' 2>/dev/null)
[ -z "$trailer" ] && exit 0

# Extract a top-level scalar value from the trailer YAML.
# Usage: trailer_scalar <key>
trailer_scalar() {
  printf '%s\n' "$trailer" | awk -v k="$1" '
    $0 ~ "^"k"[[:space:]]*:" {
      sub("^"k"[[:space:]]*:[[:space:]]*", "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' 2>/dev/null
}

emit_log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# Engineer-return path: Senior / Junior / Lead returning DONE / NEEDS_CONTEXT / BLOCKED.
# Audit-finding path: code-review-audit subagent returning findings.

# Branch on subagent_type. The audit agent is named code-review-audit.
case "$subagent_type" in
  code-review-audit)
    # Findings array — JSON-encoded inside the trailer as `findings_json: <json>`.
    # The trailer parser is best-effort; if `findings_json` is missing or invalid,
    # this branch silently no-ops (UAT-023 stays inert until the agent emits the
    # trailer; the parser itself is the contract).
    findings_json=$(trailer_scalar "findings_json")
    pr_number=$(trailer_scalar "pr_number")
    [ -z "$findings_json" ] && exit 0

    # Validate findings_json parses; bail silently if not.
    printf '%s' "$findings_json" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

    count=$(printf '%s' "$findings_json" | jq 'length' 2>/dev/null)
    [ -z "$count" ] && exit 0

    i=0
    while [ "$i" -lt "$count" ]; do
      finding=$(printf '%s' "$findings_json" | jq -c ".[$i]" 2>/dev/null)
      [ -z "$finding" ] && { i=$((i + 1)); continue; }

      finding_class=$(printf '%s' "$finding" | jq -r '.finding_class // empty' 2>/dev/null)
      severity=$(printf '%s' "$finding" | jq -r '.severity // empty' 2>/dev/null)
      area_tags=$(printf '%s' "$finding" | jq -r '(.area_tags // []) | join(",")' 2>/dev/null)

      if [ -n "$finding_class" ] && [ -n "$severity" ]; then
        .gaia/cli/gaia telemetry emit code_review_audit_finding \
          --pr-number "${pr_number:-0}" \
          --finding-class "$finding_class" \
          --severity "$severity" \
          --area-tags "$area_tags" \
          --auditor-type "code-review-audit" \
          --agent-type "Reviewer" \
          2>>"$LOG" || emit_log "code_review_audit_finding emit failed"
      fi

      i=$((i + 1))
    done
    ;;
  *)
    # Engineer-return path. Agent type is dispatch-bound; default to Senior
    # absent an explicit `agent_type:` line in the trailer.
    agent_type=$(trailer_scalar "agent_type")
    [ -z "$agent_type" ] && agent_type="Senior"

    # uat_passes — JSON array on a single line: `uat_passes_json: [{...},{...}]`.
    uat_passes_json=$(trailer_scalar "uat_passes_json")
    if [ -n "$uat_passes_json" ] && \
       printf '%s' "$uat_passes_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      count=$(printf '%s' "$uat_passes_json" | jq 'length' 2>/dev/null)
      i=0
      while [ "${count:-0}" -gt 0 ] && [ "$i" -lt "$count" ]; do
        entry=$(printf '%s' "$uat_passes_json" | jq -c ".[$i]" 2>/dev/null)
        [ -z "$entry" ] && { i=$((i + 1)); continue; }

        uat_id=$(printf '%s' "$entry" | jq -r '.uat_id // empty' 2>/dev/null)
        spec_id=$(printf '%s' "$entry" | jq -r '.spec_id // empty' 2>/dev/null)
        task_id=$(printf '%s' "$entry" | jq -r '.task_id // empty' 2>/dev/null)
        attempts=$(printf '%s' "$entry" | jq -r '.attempts // 1' 2>/dev/null)
        area_tags=$(printf '%s' "$entry" | jq -r '(.area_tags // []) | join(",")' 2>/dev/null)

        if [ -n "$uat_id" ] && [ -n "$spec_id" ] && [ -n "$task_id" ]; then
          .gaia/cli/gaia telemetry emit uat_pass \
            --uat-id "$uat_id" \
            --spec-id "$spec_id" \
            --task-id "$task_id" \
            --attempts "$attempts" \
            --area-tags "$area_tags" \
            --agent-type "$agent_type" \
            2>>"$LOG" || emit_log "uat_pass emit failed for $uat_id"
        fi

        i=$((i + 1))
      done
    fi

    # needs_context_returned — single object: `needs_context_json: {...}` or null.
    needs_context_json=$(trailer_scalar "needs_context_json")
    if [ -n "$needs_context_json" ] && [ "$needs_context_json" != "null" ] && \
       printf '%s' "$needs_context_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      class=$(printf '%s' "$needs_context_json" | jq -r '.context_request_class // empty' 2>/dev/null)
      spec_id=$(printf '%s' "$needs_context_json" | jq -r '.spec_id // empty' 2>/dev/null)
      task_id=$(printf '%s' "$needs_context_json" | jq -r '.task_id // empty' 2>/dev/null)
      area_tags=$(printf '%s' "$needs_context_json" | jq -r '(.area_tags // []) | join(",")' 2>/dev/null)

      if [ -n "$class" ]; then
        .gaia/cli/gaia telemetry emit needs_context_returned \
          --context-request-class "$class" \
          --spec-id "${spec_id:-}" \
          --task-id "${task_id:-}" \
          --area-tags "$area_tags" \
          --agent-type "$agent_type" \
          2>>"$LOG" || emit_log "needs_context_returned emit failed"
      fi
    fi

    # blocked_returned — single object: `blocked_json: {...}` or null.
    blocked_json=$(trailer_scalar "blocked_json")
    if [ -n "$blocked_json" ] && [ "$blocked_json" != "null" ] && \
       printf '%s' "$blocked_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      classification=$(printf '%s' "$blocked_json" | jq -r '.classification // empty' 2>/dev/null)
      spec_id=$(printf '%s' "$blocked_json" | jq -r '.spec_id // empty' 2>/dev/null)
      task_id=$(printf '%s' "$blocked_json" | jq -r '.task_id // empty' 2>/dev/null)
      area_tags=$(printf '%s' "$blocked_json" | jq -r '(.area_tags // []) | join(",")' 2>/dev/null)

      if [ -n "$classification" ]; then
        .gaia/cli/gaia telemetry emit blocked_returned \
          --classification "$classification" \
          --spec-id "${spec_id:-}" \
          --task-id "${task_id:-}" \
          --area-tags "$area_tags" \
          --agent-type "$agent_type" \
          2>>"$LOG" || emit_log "blocked_returned emit failed"
      fi
    fi
    ;;
esac

exit 0
