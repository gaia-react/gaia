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
# except the named sets below, which deliberate roster changes move. The
# arms are the authority on how many; deliberately no count in this sentence
# or in the test name, because a count rots the next time a set is added, and
# the rotted number reads as an assertion nobody has checked:
#
#   .github/workflows/<single-segment>.yml|.yaml -> code-audit-github-workflows
#   .github/actions/**/*.yml|*.yaml               -> code-audit-github-workflows
#   .gaia/cli/templates/workflows/code-review-audit.yml.tmpl -> ownerless
#   .gaia/cli/{package.json,pnpm-lock.yaml,pnpm-workspace.yaml,tsconfig*.json,
#              *.config.ts,*.config.mjs}          -> code-audit-maintainer-node
#   .claude/skills/**/*.md                        -> code-audit-maintainer-prose
#   .husky/**                                     -> code-audit-maintainer-shell
#
# The remaining sets are the ownerless-path triage, and their direction is the
# whole content of that change: every row they move goes from `-` to a member,
# and no row moves between members. Those arms assert that direction rather than
# describing it, by matching only when the `before` column reads `-`. One row
# inside them does not move at all: `.gaia/audit-ci.yml` was already granted to
# the shell member explicitly, and `.gaia/*.yml` generalizes that grant rather
# than adding one, so it reads `code-audit-maintainer-shell` on both sides and
# carries its own arm.
#
#   .playwright/**                                -> code-audit-frontend
#   the root tooling that decides what runs        -> code-audit-frontend
#     (Dockerfile, .npmrc, .nvmrc, .node-version, .lintstagedrc.json,
#      .prettierignore, .env.example)
#   .gaia/scripts/**/*.mjs                         -> code-audit-maintainer-node
#   the distribution and governance surface        -> code-audit-maintainer-shell
#     (.gaia/*.yml, .gaia/*.json, .gaia/scripts/token-rates.json,
#      .gaia/release-exclude, .claude/settings.json, .github/CODEOWNERS)
#   .claude/agents/*/**                            -> code-audit-maintainer-prose
#     (the Code Audit Team's own review lenses, which dispatched nobody)
#
# This is stable and does not rot: the test iterates FIXTURE ROWS, so a file
# added to the repo later neither breaks it nor silently escapes it. It is a
# genuine regression pin on the routing change, not a snapshot that needs
# feeding.
#
# Assertion style: .claude/rules/bats-assertions.md. The `[[ =~ ]]` uses
# below are branch conditionals that pick an `expected` value, never the
# pass/fail signal itself; the actual assertion is the final
# `[ "$fail" -eq 0 ]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCOPE_LIB="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  FIXTURE="$THIS_DIR/fixtures/audit-routing-before.tsv"
}

@test "routing parity: every fixture row resolves to the same owner, except the named sets" {
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
    elif [[ "$path" =~ ^\.gaia/cli/(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|tsconfig[^/]*\.json|[^/]*\.config\.ts|[^/]*\.config\.mjs)$ ]]; then
      expected="code-audit-maintainer-node"
    elif [[ "$path" =~ ^\.claude/skills/.*\.md$ ]]; then
      expected="code-audit-maintainer-prose"
    elif [[ "$path" =~ ^\.husky/ ]]; then
      expected="code-audit-maintainer-shell"
    # The four ownerless-triage arms below are guarded on `before = -` rather
    # than on the path alone, so the header's claim about their DIRECTION is
    # asserted instead of narrated. A future change that moved one of these
    # rows from one member to another would no longer match its arm, fall to
    # the `else` below, and be reported as a mismatch. `.gaia/audit-ci.yml` is
    # the one row inside these sets that legitimately does not move, so it gets
    # its own literal arm ahead of them.
    elif [ "$path" = ".gaia/audit-ci.yml" ]; then
      expected="code-audit-maintainer-shell"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.playwright/ ]]; then
      expected="code-audit-frontend"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^(Dockerfile|\.npmrc|\.nvmrc|\.node-version|\.lintstagedrc\.json|\.prettierignore|\.env\.example)$ ]]; then
      expected="code-audit-frontend"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.gaia/scripts/.*\.mjs$ ]]; then
      expected="code-audit-maintainer-node"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^(\.gaia/[^/]*\.(yml|json)|\.gaia/scripts/token-rates\.json|\.gaia/release-exclude|\.claude/settings\.json|\.github/CODEOWNERS)$ ]]; then
      expected="code-audit-maintainer-shell"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.claude/agents/[^/]+/ ]]; then
      expected="code-audit-maintainer-prose"
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
