#!/usr/bin/env bats
# audit-scope-routing-parity.bats: the before/after routing-parity proof
# (UAT-017) for the Code Audit Team ownership classifier.
#
# fixtures/audit-routing-before.tsv is `<path><TAB><owner|->`, one row per
# tracked file, generated ONCE against the classifier and roster as they
# existed before this change (reconstructed from git history) and committed.
# It is never regenerated: the whole point is that it records the prior
# state. This suite classifies every fixture path with the CURRENT
# classifier and asserts each row resolves to the same owner as before,
# except six named sets that deliberate roster changes move:
#
#   .github/workflows/<single-segment>.yml|.yaml -> code-audit-github-workflows
#   .github/actions/**/*.yml|*.yaml               -> code-audit-github-workflows
#   .gaia/cli/templates/workflows/code-review-audit.yml.tmpl -> ownerless
#   .gaia/cli/{package.json,pnpm-lock.yaml,tsconfig*.json}   -> code-audit-maintainer-node
#   .claude/skills/**/*.md                        -> code-audit-maintainer-prose
#   .husky/**                                     -> code-audit-maintainer-shell
#
# This is stable and does not rot: the test iterates FIXTURE ROWS, so a file
# added to the repo later neither breaks it nor silently escapes it. It is a
# genuine regression pin on the routing change, not a snapshot that needs
# feeding.
#
# Assertion style (`.claude/rules/bats-assertions.md`): macOS bash 3.2 does
# not fail a bats @test on a false bare `[[ ... ]]` that is not the test's
# last command. The `[[ =~ ]]` uses below are branch conditionals that pick
# an `expected` value, never the pass/fail signal itself; the actual
# assertion is the final `[ "$fail" -eq 0 ]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCOPE_LIB="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  FIXTURE="$THIS_DIR/fixtures/audit-routing-before.tsv"
}

@test "routing parity: every fixture row resolves to the same owner, except the six named sets" {
  [ -f "$FIXTURE" ]

  # shellcheck source=/dev/null
  . "$SCOPE_LIB"
  audit_scope_init "$REPO_ROOT"

  # Classify every fixture path with the CURRENT classifier in one batch pass
  # (the batch predicate forks zero processes per path), then join the
  # before/after columns by line position: both sides iterate the fixture's
  # paths in the same order, so a plain `paste` aligns them correctly.
  after_owners="$(cut -f1 "$FIXTURE" | audit_owners_for_paths | cut -f2)"

  fail=0
  rows=0
  while IFS=$'\t' read -r path before after; do
    [ -n "$path" ] || continue
    rows=$((rows + 1))

    if [[ "$path" =~ ^\.github/workflows/[^/]*\.ya?ml$ ]]; then
      expected="code-audit-github-workflows"
    elif [[ "$path" =~ ^\.github/actions/.*\.ya?ml$ ]]; then
      expected="code-audit-github-workflows"
    elif [ "$path" = ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" ]; then
      expected="-"
    elif [[ "$path" =~ ^\.gaia/cli/(package\.json|pnpm-lock\.yaml|tsconfig[^/]*\.json)$ ]]; then
      expected="code-audit-maintainer-node"
    elif [[ "$path" =~ ^\.claude/skills/.*\.md$ ]]; then
      expected="code-audit-maintainer-prose"
    elif [[ "$path" =~ ^\.husky/ ]]; then
      expected="code-audit-maintainer-shell"
    else
      expected="$before"
    fi

    if [ "$after" != "$expected" ]; then
      echo "ROUTING MISMATCH: $path  before=$before  after=$after  expected=$expected" >&2
      fail=$((fail + 1))
    fi
  done < <(paste "$FIXTURE" <(printf '%s\n' "$after_owners"))

  [ "$rows" -gt 0 ]
  [ "$fail" -eq 0 ]
}
