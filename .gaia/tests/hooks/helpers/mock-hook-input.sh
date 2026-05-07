#!/usr/bin/env bash
# Emit synthetic Claude Code hook-input JSON for testing.
# Usage:
#   mock-hook-input.sh user-prompt-submit <session_id> [prompt]
#   mock-hook-input.sh post-tool-use <session_id> <tool_name> <command>
#   mock-hook-input.sh stop <session_id>
set -euo pipefail

event="${1:?event required}"
session_id="${2:?session_id required}"

case "$event" in
  user-prompt-submit)
    prompt="${3:-test prompt}"
    jq -n --arg sid "$session_id" --arg p "$prompt" \
      '{session_id: $sid, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "UserPromptSubmit", prompt: $p}'
    ;;
  post-tool-use)
    tool="${3:?tool_name required}"
    cmd="${4:?command required}"
    jq -n --arg sid "$session_id" --arg t "$tool" --arg c "$cmd" \
      '{session_id: $sid, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "PostToolUse", tool_name: $t, tool_input: {command: $c}, tool_response: {stdout: "", stderr: "", interrupted: false}}'
    ;;
  stop)
    jq -n --arg sid "$session_id" \
      '{session_id: $sid, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "Stop", stop_hook_active: false}'
    ;;
  *)
    echo "unknown event: $event" >&2
    exit 1
    ;;
esac
