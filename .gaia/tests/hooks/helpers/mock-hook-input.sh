#!/usr/bin/env bash
# Emit synthetic Claude Code hook-input JSON for testing.
# Usage:
#   mock-hook-input.sh user-prompt-submit <session_id> [prompt]
#   mock-hook-input.sh pre-tool-use <session_id> <tool_name> <command>
#   mock-hook-input.sh post-tool-use <session_id> <tool_name> <command> [stdout]
#   mock-hook-input.sh stop <session_id>
set -euo pipefail

event="${1:?event required}"
session_id="${2:?session_id required}"

case "$event" in
  user-prompt-submit)
    prompt="${3:-test prompt}"
    jq -n --arg session_id "$session_id" --arg prompt "$prompt" \
      '{session_id: $session_id, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "UserPromptSubmit", prompt: $prompt}'
    ;;
  pre-tool-use)
    tool="${3:?tool_name required}"
    command="${4:?command required}"
    jq -n --arg session_id "$session_id" --arg tool_name "$tool" --arg command "$command" \
      '{session_id: $session_id, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "PreToolUse", tool_name: $tool_name, tool_input: {command: $command}}'
    ;;
  post-tool-use)
    tool="${3:?tool_name required}"
    command="${4:?command required}"
    tool_stdout="${5:-}"
    jq -n --arg session_id "$session_id" --arg tool_name "$tool" --arg command "$command" --arg stdout_text "$tool_stdout" \
      '{session_id: $session_id, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "PostToolUse", tool_name: $tool_name, tool_input: {command: $command}, tool_response: {stdout: $stdout_text, stderr: "", interrupted: false}}'
    ;;
  stop)
    jq -n --arg session_id "$session_id" \
      '{session_id: $session_id, transcript_path: "/tmp/transcript.jsonl", cwd: ".", hook_event_name: "Stop", stop_hook_active: false}'
    ;;
  *)
    echo "unknown event: $event" >&2
    exit 1
    ;;
esac
