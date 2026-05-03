#!/usr/bin/env bash
# Smoke 01: meaningful change should produce a wiki update on /wiki-sync.
set -euo pipefail

TMP=$(mktemp -d -t gaia-smoke-01-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

# Minimal GAIA scaffold: just enough to exercise the hooks
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services .claude/hooks .claude/commands app/services

# Copy the hooks from the gaia repo into the smoke fixture
GAIA_REPO="${GAIA_REPO:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-stop-safety-net.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/commands/wiki-sync.md" .claude/commands/

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
      {"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/wiki-stop-safety-net.sh"}]}
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

# Add a meaningful change: new service
cat > app/services/Gemini.ts <<'EOF'
// New Gemini integration service
export class GeminiService {
  async generate(prompt: string) { return "mocked"; }
}
EOF
git add app/services/Gemini.ts
git commit --quiet -m "feat: add Gemini service for image generation"

# Capture HEAD before claude runs. /wiki-sync advances state to the SHA it
# evaluated (the pre-sync HEAD), then commits the wiki updates as a new commit
# on top — so post-sync state == pre_claude_head, not current HEAD.
pre_claude_head=$(git rev-parse HEAD)

# Now run claude -p with /wiki-sync
output=$(claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /wiki-sync. Report what was done." 2>&1)

# Assertions
echo "$output" | grep -q "Gemini" || { echo "FAIL: Gemini not mentioned in /wiki-sync output"; exit 1; }
[ -f wiki/services/Gemini.md ] || { echo "FAIL: wiki/services/Gemini.md not created"; exit 1; }

# State should have advanced to the SHA we wanted evaluated
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA ($new_state vs $pre_claude_head)"; exit 1; }

# wiki/log.md should have an entry
grep -q "WORTHY" wiki/log.md || { echo "FAIL: wiki/log.md missing WORTHY entry"; exit 1; }

echo "PASS: 01-meaningful-change"
