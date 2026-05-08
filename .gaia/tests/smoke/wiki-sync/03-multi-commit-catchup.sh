#!/usr/bin/env bash
# Smoke 03: 5 accumulated commits should all be processed by a single /gaia wiki sync run.
# Mixed worthiness: 2 features, 1 fix, 1 typo, 1 dep bump.
set -euo pipefail

TMP=$(mktemp -d -t gaia-smoke-03-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"

GAIA_REPO="${GAIA_REPO:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
git init --quiet --initial-branch=main
git config user.email "smoke@example.com"
git config user.name "Smoke"
git config commit.gpgsign false

mkdir -p wiki/services wiki/components wiki/dependencies .claude/hooks .claude/skills/gaia/references/wiki app/services app/components
cp "$GAIA_REPO/.claude/hooks/wiki-drift-check.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-commit-nudge.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/hooks/wiki-session-stop.sh" .claude/hooks/
cp "$GAIA_REPO/.claude/skills/gaia/SKILL.md" .claude/skills/gaia/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki.md" .claude/skills/gaia/references/
cp "$GAIA_REPO/.claude/skills/gaia/references/wiki/sync.md" .claude/skills/gaia/references/wiki/

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

# Commit 3: bug fix in service, body carries an invariant.
# Under the post-Serena rubric, services-only commits are SKIP unless the
# body mentions a trade-off / invariant / gotcha / workaround. The
# "Invariant:" line below is what flips this commit to WORTHY — it's the
# only one in the batch that should produce a wiki page.
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
git commit --quiet -F - <<'EOF'
fix: validate amount in StripeService.charge

Invariant: charge amounts must be > 0. Prior tests caught a $0 ghost
charge that the Stripe sandbox accepted silently and counted toward
the dispute window — production would have hit the same path.
EOF

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

# Sanity: 6 drifted commits — the "init state" commit + 5 feature commits.
# init_sha was captured before "init state" was written, so drift counts both.
drift=$(git rev-list --count "$init_sha"..HEAD)
[ "$drift" = "6" ] || { echo "FAIL: expected 6 drifted commits, got $drift"; exit 1; }

pre_claude_head=$(git rev-parse HEAD)

claude -p --model sonnet --permission-mode bypassPermissions \
  "Run /gaia wiki sync. Report what was done." > /dev/null 2>&1

# Assertions
[ -f wiki/log.md ] || { echo "FAIL: wiki/log.md not created"; exit 1; }

# Log should have at least 5 entries (one per drifted commit, minus possible
# fold of the wiki-only "init state" commit).
log_entries=$(grep -cE '\b[0-9a-f]{7,40}\b' wiki/log.md || true)
[ "$log_entries" -ge 5 ] || { echo "FAIL: wiki/log.md has $log_entries entries, expected >= 5"; exit 1; }

# At least one wiki page must have been written for the worthy commits
worthy_pages=$(find wiki -type f -name '*.md' ! -name 'index.md' ! -name 'log.md' | wc -l | tr -d ' ')
[ "$worthy_pages" -ge 1 ] || { echo "FAIL: no wiki pages written for the worthy commits"; exit 1; }

# At least one SKIP entry expected (the typo, plus the Serena-inventory ones)
grep -q "SKIP" wiki/log.md || { echo "FAIL: wiki/log.md missing SKIP entry"; exit 1; }

# Post-Serena rubric: commits 1 and 2 (Stripe service add, PaymentForm
# component add) carry no decision body, so they should land as
# `SKIP: Serena handles inventory — ...`. The literal substring
# "Serena handles inventory" is the greppable marker the wiki-sync
# playbook guarantees for this skip class.
grep -q "Serena handles inventory" wiki/log.md || { echo "FAIL: wiki/log.md missing Serena-policy SKIP marker for inventory-class commits"; exit 1; }

# State should advance to the evaluated SHA (pre-sync HEAD)
new_state=$(jq -r '.last_evaluated_sha' wiki/.state.json)
[ "$new_state" = "$pre_claude_head" ] || { echo "FAIL: state did not advance to evaluated SHA ($new_state vs $pre_claude_head)"; exit 1; }

echo "PASS: 03-multi-commit-catchup"
