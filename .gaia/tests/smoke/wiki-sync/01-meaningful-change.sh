#!/usr/bin/env bash
# Smoke 01: meaningful change should produce a wiki update on /gaia wiki sync.
set -euo pipefail

TMP=$(mktemp -d -t gaia-smoke-01-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

# Minimal GAIA scaffold: just enough to exercise the hooks
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services .claude/hooks .claude/skills/gaia/references/wiki app/services

# Copy the hooks + gaia wiki skill structure from the gaia repo into the smoke fixture
GAIA_REPO="${GAIA_REPO:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-session-stop.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/skills/gaia/SKILL.md" .claude/skills/gaia/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki.md" .claude/skills/gaia/references/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki/sync.md" .claude/skills/gaia/references/wiki/

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
# on top — so post-sync state == pre_claude_head, not current HEAD.
pre_claude_head=$(git rev-parse HEAD)

# Now run claude -p with /gaia wiki sync
output=$(claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /gaia wiki sync. Report what was done." 2>&1)

# Assertions
echo "$output" | grep -q "Gemini" || { echo "FAIL: Gemini not mentioned in /gaia wiki sync output"; exit 1; }
[ -f wiki/services/Gemini.md ] || { echo "FAIL: wiki/services/Gemini.md not created"; exit 1; }

# State should have advanced to the SHA we wanted evaluated
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA ($new_state vs $pre_claude_head)"; exit 1; }

# wiki/log.md should have an entry
grep -q "WORTHY" wiki/log.md || { echo "FAIL: wiki/log.md missing WORTHY entry"; exit 1; }

echo "PASS: 01-meaningful-change"
