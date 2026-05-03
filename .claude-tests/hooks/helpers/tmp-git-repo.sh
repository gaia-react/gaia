#!/usr/bin/env bash
# Create a tmp git repo for hook testing. Prints the repo path on stdout.
# Usage:
#   tmp-git-repo.sh                   # empty repo, one initial commit
#   tmp-git-repo.sh --commits N       # N additional commits with synthetic content
#   tmp-git-repo.sh --with-state SHA  # write wiki/.state.json with the given SHA
set -euo pipefail

dir=$(mktemp -d -t gaia-hook-test-XXXXXX)
cd "$dir"

git init --quiet --initial-branch=main
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

mkdir -p wiki
echo "# wiki" > wiki/index.md
git add wiki/index.md
git commit --quiet -m "init"

extra_commits=0
state_sha=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commits) extra_commits="$2"; shift 2 ;;
    --with-state) state_sha="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ "$extra_commits" -gt 0 ]]; then
  for i in $(seq 1 "$extra_commits"); do
    echo "line $i" >> README.md
    git add README.md
    git commit --quiet -m "commit $i"
  done
fi

if [[ -n "$state_sha" ]]; then
  cat > wiki/.state.json <<EOF
{
  "version": 1,
  "last_evaluated_sha": "$state_sha",
  "last_evaluated_at": "2026-01-01T00:00:00Z"
}
EOF
  git add wiki/.state.json
  git commit --quiet -m "init state"
fi

# .claude/ scaffold for marker writes
mkdir -p .claude

echo "$dir"
