#!/usr/bin/env bash
# Smoke 01: meaningful change should produce a wiki update on /gaia-wiki sync.
set -euo pipefail

# Resolve GAIA_REPO from the script's own location BEFORE the cd below.
# Resolving it after `cd "$TMP"` makes the `git -C "$(dirname ...)"` fallback
# resolve a relative BASH_SOURCE against the temp dir, dying before any
# assertion runs and masking the real failure. The subshell pwd promotes the
# script dir to an absolute path so a relative invocation still works.
GAIA_REPO="${GAIA_REPO:-$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)}"

TMP=$(mktemp -d -t gaia-smoke-01-XXXXXX)
# On any non-zero exit, surface the captured claude session output before
# cleanup so a failure is diagnosable instead of a silent blackhole.
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -f "$TMP/claude-sync.log" ]; then echo "----- claude sync session output (captured) -----"; cat "$TMP/claude-sync.log"; fi; rm -rf "$TMP"' EXIT

cd "$TMP"

# Minimal GAIA scaffold: just enough to exercise the hooks
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services .claude/hooks .claude/skills/gaia-wiki .claude/skills/gaia/references/wiki .gaia/cli app/services

# Copy the hooks + gaia wiki skill structure from the gaia repo into the smoke fixture
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-session-stop.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/skills/gaia-wiki/SKILL.md" .claude/skills/gaia-wiki/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki.md" .claude/skills/gaia/references/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki/sync.md" .claude/skills/gaia/references/wiki/
# The sync playbook (Steps 1-9) shells out to .gaia/cli/gaia for every state
# read, commit classification, log write, and land. Without the bundled CLI the
# subagent has no deterministic oracle and bails at Step 1, so provision it.
cp "$GAIA_REPO/.gaia/cli/gaia" .gaia/cli/gaia
chmod +x .gaia/cli/gaia

# Minimal settings.json that wires the hooks
cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/wiki-drift-check.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/wiki-commit-nudge.sh"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/wiki-session-stop.sh"}]}
    ]
  }
}
EOF

# Create wiki/index.md so wiki-sync knows what exists
cat > wiki/index.md <<'EOF'
# Wiki Index

## Services
EOF

# Initial commit
git add .
git commit --quiet -m "init"
init_sha=$(git rev-parse HEAD)

# Initialize state file at init commit
cat > wiki/.state.json <<EOF
{
  "version": 1,
  "last_evaluated_sha": "$init_sha",
  "last_evaluated_at": "2026-01-01T00:00:00Z"
}
EOF
git add wiki/.state.json
git commit --quiet -m "init state"

# Add a meaningful change: new service with a body-mentioned invariant.
# Under the post-Serena rubric, services-only commits are SKIP unless the
# body carries durable knowledge (trade-off / invariant / gotcha / workaround).
# The "Invariant:" line is what flips this commit to WORTHY.
cat > app/services/Gemini.ts <<'EOF'
// New Gemini integration service
export class GeminiService {
  async generate(prompt: string) { return "mocked"; }
}
EOF
git add app/services/Gemini.ts
git commit --quiet -F - <<'EOF'
feat: add Gemini service for image generation

Invariant: Gemini's REST API requires the GAIA_PROJECT_ID header on
every request. Without it billing falls back to a free quota that caps
at 100 calls/day, which silently breaks production. The service wrapper
enforces the header at construction so requests fail fast on misconfig.
EOF

# Capture HEAD before claude runs. Sync advances state to the SHA it
# evaluated (the pre-sync HEAD), then commits the wiki updates as a new commit
# on top; so post-sync state == pre_claude_head, not current HEAD.
pre_claude_head=$(git rev-parse HEAD)

# Now run claude -p with /gaia-wiki sync
output=$(claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /gaia-wiki sync. Report what was done." 2>&1 | tee "$TMP/claude-sync.log")

# Assertions
echo "$output" | grep -q "Gemini" || { echo "FAIL: Gemini not mentioned in /gaia-wiki sync output"; exit 1; }
[ -f wiki/services/Gemini.md ] || { echo "FAIL: wiki/services/Gemini.md not created"; exit 1; }

# State should have advanced to the SHA we wanted evaluated
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA ($new_state vs $pre_claude_head)"; exit 1; }

# wiki/log.md should have an entry
grep -q "WORTHY" wiki/log.md || { echo "FAIL: wiki/log.md missing WORTHY entry"; exit 1; }

echo "PASS: 01-meaningful-change"
