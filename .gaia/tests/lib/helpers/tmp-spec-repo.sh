#!/usr/bin/env bash
# Create a tmp git repo seeded for SPEC-ledger lib testing. Prints the repo
# path on stdout; the caller cd's into it. Modeled on
# .gaia/tests/hooks/helpers/tmp-git-repo.sh.
#
# Inside the tmp repo:
#   - git init (main), test identity, commit.gpgsign false
#   - .gaia/local/specs, .gaia/local/cache, .specify/extensions/gaia/lib dirs
#   - a minimal valid ledger .gaia/specs.json: { "version": 1, "specs": [] }
#   - copies (NOT symlinks) of the three scripts under test from the real
#     repo so ${BASH_SOURCE[0]}-relative sourcing inside the scripts resolves
#     to the tmp lib dir and finds the sibling with-ledger-lock.sh
#   - one initial commit so require_git / rev-parse --git-dir succeeds
#
# Flags (repeatable, order-independent):
#   --seed-draft SPEC-NNN       append a ledger row status:"draft"
#   --seed-inprogress SPEC-NNN  append a ledger row status:"in-progress"
#   --seed-file SPEC-NNN        write .gaia/local/specs/SPEC-NNN.md with
#                               status: in-progress frontmatter and NO ledger
#                               row (the legacy fallback case)
set -euo pipefail

# Real repo containing this helper: the helper lives at
# .gaia/tests/lib/helpers/ inside the real repo working tree.
_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_repo="$(git -C "$_helper_dir" rev-parse --show-toplevel)"
real_lib="${real_repo}/.specify/extensions/gaia/lib"

dir="$(mktemp -d -t gaia-spec-lib-test-XXXXXX)"
cd "$dir"

git init --quiet --initial-branch=main
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

mkdir -p .gaia/local/specs .gaia/local/cache .specify/extensions/gaia/lib

printf '{\n  "version": 1,\n  "specs": []\n}\n' > .gaia/specs.json

# Copy (not symlink) so the scripts' ${BASH_SOURCE[0]}-relative source of
# with-ledger-lock.sh resolves to this tmp lib dir.
for s in spec-allocator.sh ledger-update.sh with-ledger-lock.sh; do
  cp "${real_lib}/${s}" ".specify/extensions/gaia/lib/${s}"
  chmod +x ".specify/extensions/gaia/lib/${s}"
done

# Apply seed flags before the initial commit so the seeded state is committed
# (require_git only needs a git-dir; committing keeps the tree clean).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-draft)
      id="$2"; shift 2
      tmp="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "draft"}]' \
        .gaia/specs.json > "$tmp"
      mv "$tmp" .gaia/specs.json
      ;;
    --seed-inprogress)
      id="$2"; shift 2
      tmp="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "in-progress"}]' \
        .gaia/specs.json > "$tmp"
      mv "$tmp" .gaia/specs.json
      ;;
    --seed-file)
      id="$2"; shift 2
      cat > ".gaia/local/specs/${id}.md" <<EOF
---
spec_id: ${id}
status: in-progress
---

# ${id}
EOF
      ;;
    *)
      echo "tmp-spec-repo.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

git add -A
git commit --quiet -m "init"

echo "$dir"
