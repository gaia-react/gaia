#!/usr/bin/env bats
# Tests for `.gaia/scripts/resolve-audit-spawn.sh` (the Code Audit Team SPAWN
# oracle: diff -> members to proactively spawn before `gh pr merge`).
#
# Each test runs the script in an isolated `git init`'d temp dir whose HEAD
# sits on a FEATURE branch off `main`, so the merge-base diff carries the
# branch's own committed files (mirrors resolve-audit-members.bats and
# pr-merge-audit-check.bats). Unlike resolve-audit-members.bats, this script
# shells out to resolve-audit-members.sh at
# "$repo_root/.gaia/scripts/resolve-audit-members.sh", so the sandbox needs
# BOTH scripts copied in (mirrors how pr-merge-audit-check.bats:59-61 copies
# the resolver into its temp repo).
#
# The roster file (.gaia/audit-ci.yml) is written UNTRACKED so it never
# enters the diff under test.
#
# Assertion style (bash-3.2 safe, per .claude/rules/bats-assertions.md):
# exact/empty/status checks use POSIX `[ ... ]`; substring checks use
# `grep -qF ... <<<"$output" || return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../resolve-audit-spawn.sh"
  RESOLVER_SRC="$THIS_DIR/../resolve-audit-members.sh"
  [ -x "$SCRIPT" ] || skip "resolve-audit-spawn.sh not executable"
  [ -x "$RESOLVER_SRC" ] || skip "resolve-audit-members.sh not executable"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/scripts"

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

  # Both scripts, untracked, so neither ever appears in the diff under test.
  cp "$RESOLVER_SRC" "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
}

# Run the oracle with cwd inside the sandbox so its own
# `git rev-parse --show-toplevel` lookup hits the fixture. Args pass through.
run_oracle() {
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
# inside the release markers), UNTRACKED so it never enters the diff under
# test. Without this file the resolver falls back to its own built-in
# roster, which also carries the specialized members; writing it explicitly
# here keeps the fixture self-documenting.
write_full_roster() {
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
YAML
}

# ---------------------------------------------------------------------------
# 1. app-only diff -> code-audit-frontend
# ---------------------------------------------------------------------------

@test "app-only diff spawns code-audit-frontend" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 2. framework shell only -> the shell member only, no frontend
# ---------------------------------------------------------------------------

@test "framework shell diff spawns the shell member only, not frontend" {
  write_full_roster
  stage .gaia/scripts/y.sh
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
  grep -qF -- "code-audit-frontend" <<<"$output" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# 3. framework CLI TypeScript -> the node member only
# ---------------------------------------------------------------------------

@test "framework CLI TypeScript diff spawns the node member only" {
  write_full_roster
  stage .gaia/cli/src/foo.ts
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-node" ]
}

# ---------------------------------------------------------------------------
# 4. app + framework shell -> both names, sorted, verbatim passthrough
# ---------------------------------------------------------------------------

@test "app + framework shell diff spawns both, sorted" {
  write_full_roster
  stage app/x.tsx .gaia/scripts/y.sh
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  expected="code-audit-frontend
code-audit-maintainer-shell"
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# 5. wiki + .claude + root *.md only -> empty
# ---------------------------------------------------------------------------

@test "wiki + .claude + root markdown only diff spawns nobody" {
  write_full_roster
  stage wiki/concepts/Foo.md .claude/rules/bar.md README.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 6. root Dockerfile (ownerless in-scope) -> code-audit-frontend
# ---------------------------------------------------------------------------

@test "root Dockerfile (ownerless in-scope) spawns code-audit-frontend" {
  write_full_roster
  stage Dockerfile
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 7. public/logo.svg (ownerless in-scope, nested) -> code-audit-frontend
# ---------------------------------------------------------------------------

@test "nested ownerless public asset spawns code-audit-frontend" {
  write_full_roster
  stage public/logo.svg
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 8. wiki/x.md + root Dockerfile (mixed out-of-scope + ownerless) ->
#    code-audit-frontend (fail-closed on ANY in-scope path)
# ---------------------------------------------------------------------------

@test "mixed out-of-scope + ownerless diff fails closed to code-audit-frontend" {
  write_full_roster
  stage wiki/x.md Dockerfile
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 9. root tsconfig.json (auditable-base, via the resolver) ->
#    code-audit-frontend
# ---------------------------------------------------------------------------

@test "root tsconfig.json spawns code-audit-frontend via the resolver" {
  write_full_roster
  stage tsconfig.json
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 10. --base is genuinely honored: commit A = app/x.tsx, commit B = wiki/y.md.
#     Run with --base HEAD~1 -> only commit B is in the diff -> empty.
# ---------------------------------------------------------------------------

@test "--base is honored: overriding to HEAD~1 isolates the wiki-only commit" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  stage wiki/y.md
  commit "docs"
  run run_oracle --base HEAD~1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 10b. Same two commits, but commit B = root Dockerfile; --base HEAD~1
#      proves the ownerless probe honors --base too, not just the resolver
#      delegation.
# ---------------------------------------------------------------------------

@test "--base is honored by the ownerless probe too" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  stage Dockerfile
  commit "chore"
  run run_oracle --base HEAD~1
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 11. --help exits 0 with usage
# ---------------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run run_oracle --help
  [ "$status" -eq 0 ]
  grep -qF -- "Usage: resolve-audit-spawn.sh" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# 12. unknown flag: exit 0, stdout is exactly code-audit-frontend
#     (fail-closed), warning on stderr.
# ---------------------------------------------------------------------------

@test "unknown flag fails closed to code-audit-frontend with a stderr warning" {
  # bats' `run` merges stdout+stderr into $output by default, so the stdout
  # assertion below redirects stderr away (mirrors
  # resolve-audit-members.bats's equivalent case); the stderr content itself
  # is checked in the next test.
  run bash -c '( cd "$1" && "$2" --bogus 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "unknown flag prints a warning to stderr" {
  stderr_out="$( ( cd "$SANDBOX" && "$SCRIPT" --bogus ) 2>&1 1>/dev/null )"
  grep -qF -- "resolve-audit-spawn" <<<"$stderr_out" || return 1
}

# ---------------------------------------------------------------------------
# 13. not in a git repo -> exit 0, stdout EMPTY
# ---------------------------------------------------------------------------

@test "not in a git repo exits 0 with empty stdout" {
  notrepo="$BATS_TEST_TMPDIR/notrepo"
  mkdir -p "$notrepo"
  run bash -c 'cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null' _ "$notrepo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 14. resolver removed from the sandbox, diff is app/x.tsx -> ownerless
#     probe fires -> code-audit-frontend
# ---------------------------------------------------------------------------

@test "resolver absent falls to the ownerless probe (in-scope path)" {
  write_full_roster
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage app/x.tsx
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# ---------------------------------------------------------------------------
# 15. resolver removed, diff is wiki/x.md only -> empty
# ---------------------------------------------------------------------------

@test "resolver absent falls to the ownerless probe (out-of-scope path)" {
  write_full_roster
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage wiki/x.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 16. resolver present but exec bit cleared, diff is .gaia/scripts/y.sh ->
#     the [ -x ] guard falls to the ownerless probe; .gaia/* is out-of-scope
#     allowlisted, so nothing is owed (M2 mirror test).
# ---------------------------------------------------------------------------

@test "resolver present without exec bit falls to the ownerless probe" {
  write_full_roster
  chmod -x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage .gaia/scripts/y.sh
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--base with no <ref> fails closed to code-audit-frontend, never 'nobody owed'" {
  # The trap this locks: `--base` with a missing argument used to exit 0 with
  # EMPTY stdout, and empty stdout is not an error channel here -- the output
  # contract defines it as "no member is owed". So a mangled query told the
  # caller to spawn nobody while the merge deny-hook still demanded markers,
  # which is the silent-bypass class the oracle exists to eliminate. It must
  # answer exactly like the unknown-flag arm.
  run bash -c '( cd "$1" && "$2" --base 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "--base with an unquoted empty ref fails closed (the realistic caller mangle)" {
  # How this is actually reached in the wild: `--base $REF` with REF unset or
  # empty, unquoted, so the ref word vanishes before the script ever sees it.
  run bash -c '( cd "$1" && REF="" && "$2" --base $REF 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "--base with no <ref> prints a fail-closed warning to stderr" {
  run bash -c '( cd "$1" && "$2" --base 2>&1 >/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF -- "--base requires a <ref> argument" <<<"$output"
  grep -qF -- "failing closed" <<<"$output"
}

@test "--base with a QUOTED empty ref fails closed (arity check alone would miss it)" {
  # `--base "$REF"` with REF unset: the empty word SURVIVES quoting, so $#==2 and
  # the arity guard does not fire. Without the `[ -z "$2" ]` companion the script
  # would set BASE_OVERRIDE="" and silently answer from a base the caller never
  # asked for. Same operator error as the unquoted mangle; same fail-closed answer.
  run bash -c '( cd "$1" && REF="" && "$2" --base "$REF" 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}
