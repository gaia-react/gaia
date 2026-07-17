#!/usr/bin/env bats
# Tests for `.gaia/scripts/resolve-audit-members.sh` (the Code Audit Team
# dispatch resolver: diff → dispatched member set).
#
# Each test runs the script in an isolated `git init`'d temp dir whose HEAD
# sits on a FEATURE branch off `main`, so the merge-base diff carries the
# branch's own committed files (mirrors resolve-audit-base.bats and
# pr-merge-audit-check.bats). The resolver reads the roster from the working
# tree's `.gaia/audit-ci.yml`, so a test's config need not be committed; only
# the CHANGED files it asserts on are committed.
#
# Assertion style (bash-3.2 safe, per .claude/rules/bats-assertions.md):
# exact/empty/status checks use POSIX `[ ... ]`; substring checks use
# `grep -qF ... <<<"$output" || return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../resolve-audit-members.sh"
  [ -x "$SCRIPT" ] || skip "resolve-audit-members.sh not executable"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the feature branch diverges from here so the
  # merge-base diff is non-empty.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "init"
  git -C "$SANDBOX" checkout --quiet -b feature
}

# Run the resolver with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture. Args pass through.
run_resolver() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# Stage one or more changed files (created with placeholder content).
stage() {
  local p
  for p in "$@"; do
    mkdir -p "$SANDBOX/$(dirname "$p")"
    printf 'x\n' > "$SANDBOX/$p"
    git -C "$SANDBOX" add "$p"
  done
}

commit() {
  git -C "$SANDBOX" commit --quiet -m "$1"
}

# The full shipped roster (frontend default + the two maintainer-only members
# inside the release markers).
write_full_roster() {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
      - ".github/workflows/**"
      - "package.json"
      - "pnpm-lock.yaml"
      - "pnpm-workspace.yaml"
      - "tsconfig*.json"
      - "*.config.ts"
      - "*.config.mts"
      - "*.config.mjs"
      - "*.config.cjs"
      - "*.config.js"
    scope: adopter
    push_fixes: true
    default: true
  # gaia:maintainer-only:start
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/**/*.sh"
      - ".gaia/**/*.bats"
      - ".claude/hooks/**/*.sh"
      - ".specify/extensions/gaia/lib/*.sh"
      - ".github/**/*.sh"
      - ".github/**/*.bats"
    scope: maintainer-only
    push_fixes: false
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**"
    scope: maintainer-only
    push_fixes: false
  # gaia:maintainer-only:end
YAML
}

# The adopter roster: the maintainer-only members stripped, frontend only.
# Mirrors what an adopter clone carries after the release scrub.
write_adopter_roster() {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
    scope: adopter
    push_fixes: true
    default: true
YAML
}

# ---------------------------------------------------------------------------
# 1. app-only diff → frontend only
# ---------------------------------------------------------------------------

@test "app-only diff dispatches code-audit-frontend only" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 2. app + .gaia/**/*.sh diff → frontend + maintainer-shell (deduped, sorted)
# ---------------------------------------------------------------------------

@test "app + .gaia shell diff dispatches frontend and maintainer-shell, sorted" {
  write_full_roster
  stage app/x.tsx .gaia/scripts/y.sh
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  expected="code-audit-frontend
code-audit-maintainer-shell"
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# 3. .gaia/**/*.sh only → maintainer-shell only
# ---------------------------------------------------------------------------

@test ".gaia shell-only diff dispatches maintainer-shell only" {
  write_full_roster
  stage .gaia/scripts/y.sh
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 4. .claude/hooks/lib/*.sh → maintainer-shell (nested ** under hooks)
# ---------------------------------------------------------------------------

@test "nested .claude/hooks/lib shell file dispatches maintainer-shell" {
  write_full_roster
  stage .claude/hooks/lib/z.sh
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 5. .gaia/cli/src/*.ts → maintainer-node
# ---------------------------------------------------------------------------

@test ".gaia/cli/src TypeScript dispatches maintainer-node" {
  write_full_roster
  stage .gaia/cli/src/foo.ts
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-node" ]
}

# ---------------------------------------------------------------------------
# 6. Framework CONFIG/DATA only (.gaia/audit-ci.yml, VERSION, manifest) → empty
# ---------------------------------------------------------------------------

@test "framework config/data only diff dispatches nothing (out of scope)" {
  write_full_roster
  # Commit the config change plus VERSION + manifest so all three land in the
  # diff; none is claimed by a specialized member or the auditable-base set.
  stage .gaia/VERSION .gaia/manifest.json
  git -C "$SANDBOX" add .gaia/audit-ci.yml
  commit "chore: config"
  run run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 7. .github/workflows/*.yml only → frontend (default catch-all)
# ---------------------------------------------------------------------------

@test ".github/workflows yaml dispatches frontend via the default catch-all" {
  write_full_roster
  stage .github/workflows/release.yml
  commit "ci"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 8. Root build-config files (tsconfig*.json, *.config.ts) → frontend
# ---------------------------------------------------------------------------

@test "root tsconfig and *.config.ts dispatch frontend (default's own declared root globs)" {
  write_full_roster
  stage tsconfig.json vite.config.ts
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 9. wiki/docs-only diff → empty
# ---------------------------------------------------------------------------

@test "wiki and docs only diff dispatches nothing (out of scope)" {
  write_full_roster
  stage wiki/concepts/Foo.md docs/guide.md
  commit "docs"
  run run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 10. .github/x.sh (top-level under .github) → maintainer-shell
#     Glob-semantics decision: `.github/**/*.sh`'s `**/` collapses to zero
#     segments, so a shell script directly under `.github/` is matched.
# ---------------------------------------------------------------------------

@test "top-level .github shell script matches .github shell glob (zero-segment **)" {
  write_full_roster
  stage .github/x.sh
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 11. .specify/extensions/gaia/lib/*.sh matches direct children only
# ---------------------------------------------------------------------------

@test ".specify lib glob matches a direct-child shell file but not a nested one" {
  write_full_roster
  # Only the direct child matches the single-* glob; the nested file has no
  # owner and is out of the auditable-base set, so the sole member is shell.
  stage .specify/extensions/gaia/lib/foo.sh .specify/extensions/gaia/lib/sub/bar.sh
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 12. Adopter roster (maintainer entries removed) + .gaia/cli/src → empty
#     Proves the resolver never emits a member the roster does not define.
# ---------------------------------------------------------------------------

@test "adopter roster never dispatches a maintainer member for framework source" {
  write_adopter_roster
  stage .gaia/cli/src/foo.ts
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 13. Missing auditors: key → built-in default roster (app → frontend)
# ---------------------------------------------------------------------------

@test "missing auditors key falls back to the built-in default roster" {
  # A config with other knobs but no `auditors:` block.
  printf 'gate_label: null\npush_fixes: true\n' > "$SANDBOX/.gaia/audit-ci.yml"
  stage app/x.tsx
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 14. Built-in default roster still dispatches the maintainer members
#     (the in-tree script carries them; only the release scrub removes them).
# ---------------------------------------------------------------------------

@test "built-in default roster dispatches maintainer-node for framework source" {
  # No config file at all → the script's built-in roster applies.
  rm -f "$SANDBOX/.gaia/audit-ci.yml"
  stage .gaia/cli/src/foo.ts
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-node" ]
}

# ---------------------------------------------------------------------------
# 15. Novel member (extensibility): a fabricated roster member is dispatched
#     purely from its config entry, proving generic roster iteration.
# ---------------------------------------------------------------------------

@test "a novel roster member is dispatched for its own glob (generic iteration)" {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
    default: true
  - name: code-audit-example
    globs:
      - "examples/**"
    scope: adopter
    push_fixes: true
YAML
  stage examples/widget.ts
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-example" ]
}

# ---------------------------------------------------------------------------
# 16. --base <ref> override
# ---------------------------------------------------------------------------

@test "--base <ref> overrides the diff base" {
  write_full_roster
  stage app/a.tsx
  commit "feat"
  run run_resolver --base main
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 17. --help exits 0 without crashing
# ---------------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run run_resolver --help
  [ "$status" -eq 0 ]
  grep -qF "Usage: resolve-audit-members.sh" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# 18. Unknown flag exits 0 with empty stdout (fail-safe for consumers)
# ---------------------------------------------------------------------------

@test "unknown flag exits 0 with empty stdout" {
  run bash -c '( cd "$1" && "$2" --bogus 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 19. Empty diff (feature == main) → empty stdout, exit 0
# ---------------------------------------------------------------------------

@test "empty diff dispatches nothing and exits 0" {
  write_full_roster
  # No commits past the base: merge-base(HEAD, main) == HEAD → empty diff.
  run run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 20. Not in a git repo → empty stdout, exit 0
# ---------------------------------------------------------------------------

@test "not in a git repo exits 0 with empty stdout" {
  notrepo="$BATS_TEST_TMPDIR/notrepo"
  mkdir -p "$notrepo"
  run bash -c 'cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null' _ "$notrepo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 21. Bats-only diff under .gaia/ → maintainer-shell
#     The suites guarding the framework's own bash are owned, not out of scope:
#     a commit that weakens, skips, or deletes one is gated like any other
#     shell change. Both bats trees under .gaia/ are covered by the one
#     `.gaia/**/*.bats` glob.
# ---------------------------------------------------------------------------

@test "bats-only diff under .gaia dispatches maintainer-shell" {
  write_full_roster
  stage .gaia/scripts/tests/resolve-audit-members.bats .gaia/tests/hooks/session-stop.bats
  commit "test"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 22. Bats-only diff under .github/ → maintainer-shell
#     `.github/**/*.bats` mirrors the `.github/**/*.sh` glob: the suites that
#     test the CI-side shell are owned by the member that owns that shell.
# ---------------------------------------------------------------------------

@test "bats-only diff under .github dispatches maintainer-shell" {
  write_full_roster
  stage .github/audit/tests/post-audit-status.bats
  commit "test"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 23. Built-in default roster also owns the bats suites.
#     Pins the SECOND literal copy of the roster (the one inside the script).
#     Without a bats glob there, a bats-only diff on a clone carrying no
#     audit-ci.yml resolves to an empty member set and rides the merge gate's
#     out-of-scope bypass.
# ---------------------------------------------------------------------------

@test "built-in default roster dispatches maintainer-shell for a bats-only diff" {
  # No config file at all → the script's built-in roster applies.
  rm -f "$SANDBOX/.gaia/audit-ci.yml"
  stage .gaia/scripts/tests/token-tally.bats
  commit "test"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
}

# ---------------------------------------------------------------------------
# 24. An adopter clone (maintainer entries scrubbed) never dispatches a
#     maintainer member for a bats file, and the suites are not in the default
#     member's auditable-base set, so the diff is correctly out of scope there.
# ---------------------------------------------------------------------------

@test "adopter roster dispatches nothing for a bats-only diff" {
  write_adopter_roster
  stage .gaia/scripts/tests/token-tally.bats
  commit "test"
  run run_resolver
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
