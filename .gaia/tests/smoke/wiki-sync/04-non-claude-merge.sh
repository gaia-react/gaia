#!/usr/bin/env bash
# Smoke 04: a commit made outside Claude (plain shell `git commit`) must still
# be detected on the next Claude session via the UserPromptSubmit drift-check hook.
# This is the regression test for the original bug where wiki-update-evaluator.sh
# missed commits made outside Claude.
set -euo pipefail

TMP=$(mktemp -d -t gaia-smoke-04-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

GAIA_REPO="${GAIA_REPO:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/modules .claude/hooks .claude/commands app/modules
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-session-stop.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/commands/wiki-sync.md" .claude/commands/

cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/wiki-drift-check.sh"}]}
    ]
  }
}
EOF

cat > wiki/index.md <<'EOF'
# Wiki Index

## Modules
EOF

git add .
git commit --quiet -m "init"
init_sha=$(git rev-parse HEAD)

# State file points at init commit. Drift starts at 1 (the state-init commit
# itself, which is wiki/.state.json-only and would be SKIP-classified). After
# the shell commit below, drift = 2. The test's intent is "drift > 0 surfaces
# a reminder", not a specific count.
cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$init_sha","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
git add wiki/.state.json
git commit --quiet -m "init state"

# Now make a commit via plain shell — no Claude in the loop at all
cat > app/modules/Auth.ts <<'EOF'
// Auth module — added via shell, NOT via Claude
export class AuthModule {
  login(user: string) { return { token: "mock" }; }
}
EOF
git add app/modules/Auth.ts
git commit --quiet -m "feat: add Auth module (shell-side commit)"

# Sanity: drift should be > 0 (drift hook only cares about non-zero)
state_sha=$(jq -r '.last_evaluated_sha' wiki/.state.json)
drift=$(git rev-list --count "$state_sha"..HEAD)
[ "$drift" -ge "1" ] || { echo "FAIL: expected drift >= 1 after shell commit, got $drift"; exit 1; }

# Run claude -p with a generic prompt — drift-check should fire on first prompt
# and mention drift / wiki-sync.
first_output=$(claude -p --model sonnet --permission-mode bypassPermissions \
  "What's the status of this repo?" 2>&1 || true)

if ! echo "$first_output" | grep -qiE "drift|wiki-sync|wiki state|commits ahead|behind"; then
  echo "FAIL: first prompt output did not surface drift/wiki-sync. Output was:"
  echo "$first_output"
  exit 1
fi

# Now actually run /wiki-sync to catch up
pre_claude_head=$(git rev-parse HEAD)
claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /wiki-sync. Report what was done." > /dev/null 2>&1

# Assertions: state advanced to the evaluated SHA + log entry written
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA after /wiki-sync ($new_state vs $pre_claude_head)"; exit 1; }

[ -f wiki/log.md ] || { echo "FAIL: wiki/log.md not created"; exit 1; }
grep -qE "Auth|auth" wiki/log.md || { echo "FAIL: wiki/log.md does not reference the Auth shell-side commit"; exit 1; }

echo "PASS: 04-non-claude-merge"
