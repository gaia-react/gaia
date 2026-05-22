## Symptom

The hook at .claude/hooks/wiki-session-stop.sh failed with a permission error. The environment showed a GITHUB_TOKEN and also had an ANTHROPIC_API_KEY in the environment. The file other-tool.json was also present.

## Classification

class: hook
evidence: "hook" + .claude/hooks/wiki-session-stop.sh

## Capture

gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:

- .claude/settings.json: present, hooks keys: PreToolUse, PostToolUse, Stop
- wiki-session-stop.sh: filename only
  GITHUB_TOKEN=<redacted>
  ANTHROPIC_API_KEY=<redacted>

## Reproduction context

The user was running a wiki-sync when the PostToolUse hook misfired. The hook script at .claude/hooks/wiki-session-stop.sh exited with code 1. Environment variables GITHUB_TOKEN and ANTHROPIC_API_KEY were present in the shell environment at time of failure.
