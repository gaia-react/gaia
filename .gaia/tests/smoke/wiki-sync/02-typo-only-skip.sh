#!/usr/bin/env bash
# Smoke 02: typo-only commit should be SKIPPED by /gaia-wiki sync.
set -euo pipefail

# Resolve GAIA_REPO from the script's own location BEFORE the cd below.
# Resolving it after `cd "$TMP"` makes the `git -C "$(dirname ...)"` fallback
# resolve a relative BASH_SOURCE against the temp dir, dying before any
# assertion runs and masking the real failure. The subshell pwd promotes the
# script dir to an absolute path so a relative invocation still works.
GAIA_REPO="${GAIA_REPO:-$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)}"

TMP=$(mktemp -d -t gaia-smoke-02-XXXXXX)
# On any non-zero exit, surface the captured claude session output before
# cleanup so a failure is diagnosable instead of a silent blackhole.
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -f "$TMP/claude-sync.log" ]; then echo "----- claude sync session output (captured) -----"; cat "$TMP/claude-sync.log"; fi; rm -rf "$TMP"' EXIT

cd "$TMP"

# (Same scaffold as 01; extract to a helper if duplication grows annoying)
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services .claude/hooks .claude/skills/gaia-wiki .claude/skills/gaia/references/wiki .gaia/cli
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

cat > .claude/settings.json <<'EOF'
{"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":".claude/hooks/wiki-drift-check.sh"}]}]}}
EOF

cat > wiki/index.md <<'EOF'
# Wiki Index
EOF
cat > README.md <<'EOF'
GAIA test fixutre
EOF

git add .
git commit --quiet -m "init"
init_sha=$(git rev-parse HEAD)

cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$init_sha","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
git add wiki/.state.json
git commit --quiet -m "init state"

# Typo-only change
sed -i.bak 's/fixutre/fixture/' README.md
rm README.md.bak
git add README.md
git commit --quiet -m "fix: typo in README"

before_files=$(find wiki -type f | wc -l | tr -d ' ')
pre_claude_head=$(git rev-parse HEAD)

claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /gaia-wiki sync. Report what was done." > "$TMP/claude-sync.log" 2>&1

after_files=$(find wiki -type f | wc -l | tr -d ' ')

# wiki should have ZERO new files (typo doesn't warrant a wiki page)
# wiki/log.md may have been newly created; that's fine, it's the log
[ "$after_files" -le "$((before_files + 1))" ] || { echo "FAIL: wiki gained more than 1 file (log only) for a typo commit"; exit 1; }

# log should mention SKIP
[ -f wiki/log.md ] || { echo "FAIL: wiki/log.md not created"; exit 1; }
grep -q "SKIP" wiki/log.md || { echo "FAIL: wiki/log.md missing SKIP entry"; exit 1; }

# State should advance to the evaluated SHA (pre-sync HEAD), even on skip-only runs
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA ($new_state vs $pre_claude_head)"; exit 1; }

echo "PASS: 02-typo-only-skip"
