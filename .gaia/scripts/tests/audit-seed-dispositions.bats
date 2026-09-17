#!/usr/bin/env bats
#
# audit-seed-dispositions.sh: the literal-path entry point the default member
# runs to seed its disposition-ledger sidecar forward from the prior frontend
# digest's sidecar. The union itself is disposition_seed_forward's contract,
# pinned in .gaia/tests/hooks/audit-disposition-check.bats; these probes pin
# the script around it (confinement, digest validation, the empty-prior no-op)
# and, separately, that the fence the member definition carries runs as
# written in a fresh shell, which is the one thing no other suite executes.
#
# Run under bash 5 (.claude/rules/bats-assertions.md): `source
# .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/audit-seed-dispositions.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIR" rev-parse --show-toplevel)"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; every seed probe here would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  PREV="$(printf 'a%.0s' $(seq 64))"
  NEW="$(printf 'b%.0s' $(seq 64))"
}

# make_tree <name>: a directory carrying the script and the library it sources
# at their real repo-relative paths, since the script refuses a --root that is
# not the tree it sits in.
make_tree() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/.gaia/scripts" "$dir/.gaia/local/audit" "$dir/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/audit-seed-dispositions.sh" "$dir/.gaia/scripts/"
  chmod +x "$dir/.gaia/scripts/audit-seed-dispositions.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-dispositions.sh" "$dir/.claude/hooks/lib/"
  printf '%s' "$(cd "$dir" && pwd -P)"
}

# write_prev <tree>: a prior sidecar carrying one still-open and one closed entry.
write_prev() {
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed","issue_number":7},{"key":"W1","disposition":"waived"}]}' \
    > "$1/.gaia/local/audit/$PREV.dispositions.json"
}

write_new() {
  printf '%s\n' '{"schema":1,"backend":"github","findings":[]}' > "$1/.gaia/local/audit/$NEW.dispositions.json"
}

# ---------- the script ----------------------------------------------------------

@test "a filed entry in the prior sidecar is seeded into the new one" {
  local tree
  tree="$(make_tree seeds)"
  write_prev "$tree"
  write_new "$tree"
  run --separate-stderr "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest "$NEW"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[] | select(.key=="K1") | .issue_number' "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "7" ]
  [ "$(jq -r '[.findings[] | select(.key=="W1")] | length' "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "0" ]
}

@test "an empty prior digest is a no-op at status 0 that leaves the new sidecar byte-identical" {
  local tree before
  tree="$(make_tree empty-prior)"
  write_new "$tree"
  before="$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")"
  run --separate-stderr "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest '' --new-digest "$NEW"
  [ "$status" -eq 0 ]
  [ "$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "$before" ]
}

@test "a prior digest with no sidecar on disk is a no-op at status 0" {
  local tree before
  tree="$(make_tree missing-prior)"
  write_new "$tree"
  before="$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")"
  run --separate-stderr "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest "$NEW"
  [ "$status" -eq 0 ]
  [ "$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "$before" ]
}

@test "refuses a --root that is not the tree the script sits in" {
  local tree other
  tree="$(make_tree self)"
  other="$(make_tree other)"
  write_prev "$other"
  write_new "$other"
  run --separate-stderr "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$other" --prev-digest "$PREV" --new-digest "$NEW"
  [ "$status" -eq 2 ]
  grep -qF -- 'the tree this script belongs to' <<<"$stderr"
  [ "$(jq -r '.findings | length' "$other/.gaia/local/audit/$NEW.dispositions.json")" = "0" ]
}

@test "refuses an empty --root instead of resolving the ambient directory" {
  local tree
  tree="$(make_tree empty-root)"
  run --separate-stderr bash -c 'cd "$1" && "$1/.gaia/scripts/audit-seed-dispositions.sh" --root "" --prev-digest "$2" --new-digest "$3"' _ "$tree" "$PREV" "$NEW"
  [ "$status" -eq 2 ]
  grep -qF -- '--root is empty' <<<"$stderr"
}

@test "refuses a digest that is not 64 lowercase hex, so no path is built from it" {
  local tree
  tree="$(make_tree bad-digest)"
  write_prev "$tree"
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest '../../escape'
  [ "$status" -eq 2 ]
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest '../x' --new-digest "$NEW"
  [ "$status" -eq 2 ]
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest ''
  [ "$status" -eq 2 ]
}

@test "a missing disposition library exits 2 and names it, rather than seeding nothing at status 0" {
  local tree
  tree="$(make_tree no-lib)"
  write_prev "$tree"
  write_new "$tree"
  rm "$tree/.claude/hooks/lib/audit-dispositions.sh"
  run --separate-stderr "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest "$NEW"
  [ "$status" -eq 2 ]
  grep -qF -- 'disposition library missing' <<<"$stderr"
}

@test "usage errors exit 2" {
  local tree
  tree="$(make_tree usage)"
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --prev-digest "$PREV" --new-digest "$NEW"
  [ "$status" -eq 2 ]
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV"
  [ "$status" -eq 2 ]
  run "$tree/.gaia/scripts/audit-seed-dispositions.sh" --root "$tree" --prev-digest "$PREV" --new-digest "$NEW" --bogus
  [ "$status" -eq 2 ]
}

# ---------- the member definition's fence, run as written -----------------------
#
# extract_seed_fence <agent-file>: the one ```bash fence inside the
# "**Seed-forward.**" paragraph run that is not the prior-digest computation.
# Exits 1 on zero or more than one, so a definition that drops the seed or
# grows a second one reds here rather than contributing an empty program.
extract_seed_fence() {
  awk '
    /^\*\*Seed-forward\.\*\*/     { region = 1; next }
    region && /^Knip, react-doctor/ { region = 0 }
    region && /^```bash$/          { infence = 1; buf = ""; next }
    region && /^```$/              { if (infence && buf !~ /audit-member-digest\.sh/) { printf "%s", buf; found++ } ; infence = 0; next }
    region && infence              { buf = buf $0 "\n" }
    END                            { if (found != 1) exit 1 }
  ' "$1"
}

@test "the default member's seed-forward fence runs as written in a fresh shell and seeds a filed entry" {
  local tree fence program
  tree="$(make_tree fence)"
  write_prev "$tree"
  write_new "$tree"
  fence="$(extract_seed_fence "$REPO_ROOT/.claude/agents/code-audit-frontend.md")" || {
    echo "expected exactly one seed fence in the Seed-forward paragraph of code-audit-frontend.md" >&2
    return 1
  }
  program="${fence//<root>/$tree}"
  program="${program//<prev_frontend_digest>/$PREV}"
  program="${program//<new_frontend_digest>/$NEW}"
  # A fresh shell outside any tree: nothing is sourced, as in a member's own
  # Bash call.
  run --separate-stderr env -i PATH="$PATH" HOME="$HOME" bash -c "cd / && ${program}"
  [ "$status" -eq 0 ] || {
    printf 'seed fence exited %s: %s\n' "$status" "$stderr" >&2
    return 1
  }
  [ "$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "filed" ]
}

@test "the default member's seed-forward fence is a no-op at status 0 when the prior digest printed nothing" {
  local tree fence program before
  tree="$(make_tree fence-empty)"
  write_new "$tree"
  before="$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")"
  fence="$(extract_seed_fence "$REPO_ROOT/.claude/agents/code-audit-frontend.md")" || return 1
  program="${fence//<root>/$tree}"
  program="${program//<prev_frontend_digest>/}"
  program="${program//<new_frontend_digest>/$NEW}"
  run --separate-stderr env -i PATH="$PATH" HOME="$HOME" bash -c "cd / && ${program}"
  [ "$status" -eq 0 ]
  [ "$(cat "$tree/.gaia/local/audit/$NEW.dispositions.json")" = "$before" ]
}
