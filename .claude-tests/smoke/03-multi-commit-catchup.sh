#!/usr/bin/env bash
# Smoke 03: 5 accumulated commits should all be processed by a single /wiki-sync run.
# Mixed worthiness: 2 features, 1 fix, 1 typo, 1 dep bump.
set -euo pipefail

TMP=$(mktemp -d -t gaia-smoke-03-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

GAIA_REPO="${GAIA_REPO:-/Users/stevensacks/Development/gaia-react/gaia}"
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services wiki/components wiki/dependencies .claude/hooks .claude/commands app/services app/components
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-stop-safety-net.sh" .claude/hooks/
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

## Services
## Components
## Dependencies
EOF

cat > README.md <<'EOF'
GAIA test fixture
EOF

cat > package.json <<'EOF'
{
  "name": "gaia-smoke-03",
  "version": "0.0.0",
  "dependencies": {
    "react": "18.2.0"
  }
}
EOF

git add .
git commit --quiet -m "init"
init_sha=$(git rev-parse HEAD)

cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$init_sha","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
git add wiki/.state.json
git commit --quiet -m "init state"

# Commit 1: feature — new service
cat > app/services/Stripe.ts <<'EOF'
// Stripe payment service
export class StripeService {
  async charge(amount: number) { return { id: "ch_mock" }; }
}
EOF
git add app/services/Stripe.ts
git commit --quiet -m "feat: add Stripe payment service"

# Commit 2: feature — new component
cat > app/components/PaymentForm.tsx <<'EOF'
// Payment form component
export const PaymentForm = () => {
  return null;
};
EOF
git add app/components/PaymentForm.tsx
git commit --quiet -m "feat: add PaymentForm component"

# Commit 3: bug fix in service
cat > app/services/Stripe.ts <<'EOF'
// Stripe payment service
export class StripeService {
  async charge(amount: number) {
    if (amount <= 0) throw new Error("amount must be positive");
    return { id: "ch_mock" };
  }
}
EOF
git add app/services/Stripe.ts
git commit --quiet -m "fix: validate amount in StripeService.charge"

# Commit 4: typo only
sed -i.bak 's/test fixture/test harness/' README.md
rm README.md.bak
git add README.md
git commit --quiet -m "docs: tweak README wording"

# Commit 5: dep bump
sed -i.bak 's/"react": "18.2.0"/"react": "18.3.1"/' package.json
rm package.json.bak
git add package.json
git commit --quiet -m "chore(deps): bump react to 18.3.1"

# Sanity: 5 commits between init_sha and HEAD
drift=$(git rev-list --count "$init_sha"..HEAD)
[ "$drift" = "5" ] || { echo "FAIL: expected 5 drifted commits, got $drift"; exit 1; }

claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /wiki-sync. Report what was done." > /dev/null 2>&1

# Assertions
[ -f wiki/log.md ] || { echo "FAIL: wiki/log.md not created"; exit 1; }

# Log should have at least 5 entries (one per commit). Count short-SHA-looking lines.
log_entries=$(grep -cE '\b[0-9a-f]{7,40}\b' wiki/log.md || true)
[ "$log_entries" -ge 5 ] || { echo "FAIL: wiki/log.md has $log_entries entries, expected >= 5"; exit 1; }

# At least one wiki page must have been written for the worthy commits
worthy_pages=$(find wiki -type f -name '*.md' ! -name 'index.md' ! -name 'log.md' | wc -l | tr -d ' ')
[ "$worthy_pages" -ge 1 ] || { echo "FAIL: no wiki pages written for the worthy commits"; exit 1; }

# At least one SKIP entry expected (the typo)
grep -q "SKIP" wiki/log.md || { echo "FAIL: wiki/log.md missing SKIP entry for typo commit"; exit 1; }

# State should advance to HEAD
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
head=$(git rev-parse HEAD)
[ "$new_state" = "$head" ] || { echo "FAIL: state did not advance to HEAD ($new_state vs $head)"; exit 1; }

echo "PASS: 03-multi-commit-catchup"
