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
# Every Code Audit Team marker is keyed to a member's own content digest, not
# the whole tree. There is no carry-forward clearance machinery: the spawn
# oracle's filter is a plain digest-marker-presence check (a member is
# skipped iff its own valid current-digest earned marker already exists).
#
# Assertion style (bash-3.2 safe, per .claude/rules/bats-assertions.md):
# exact/empty/status checks use POSIX `[ ... ]`; substring checks use
# `grep -qF ... <<<"$output" || return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../resolve-audit-spawn.sh"
  RESOLVER_SRC="$THIS_DIR/../resolve-audit-members.sh"
  LIB_DIR="$THIS_DIR/../../../.claude/hooks/lib"
  [ -x "$SCRIPT" ] || skip "resolve-audit-spawn.sh not executable"
  [ -x "$RESOLVER_SRC" ] || skip "resolve-audit-members.sh not executable"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.claude/hooks/lib"

  # An untracked VERSION, so the marker fixtures below have a literal to
  # match; untracked so it never enters the diff under test.
  printf '1.6.1\n' > "$SANDBOX/.gaia/VERSION"

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

  # The copied resolver (and this copied oracle, when the sandbox's OWN
  # $SCRIPT-equivalent runs) resolves its libs relative to ITSELF
  # ($SANDBOX/.claude/hooks/lib/), not the real repo, so the sandbox needs its
  # own copy of the shared ownership classifier + digest engine + clearance
  # reader alongside it. Untracked, so none of it ever appears in the diff
  # under test either.
  cp "$LIB_DIR/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$LIB_DIR/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"
  cp "$LIB_DIR/audit-clearance.sh" "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"
  cp "$LIB_DIR/audit-digest.sh" "$SANDBOX/.claude/hooks/lib/audit-digest.sh"
}

# Run the oracle with cwd inside the sandbox so its own
# `git rev-parse --show-toplevel` lookup hits the fixture. Args pass through.
# stderr is dropped: only stdout is the contract. Tests that assert on stderr
# redirect it themselves via `run bash -c`.
run_oracle() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" 2>/dev/null )
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

# --- Digest-marker-presence fixtures ----------------------------------------

tree_sha() { git -C "$SANDBOX" rev-parse "HEAD^{tree}"; }
commit_sha() { git -C "$SANDBOX" rev-parse HEAD; }
resolve_members() { ( cd "$SANDBOX" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null ); }
# SC2069: deliberate capture-stderr / discard-stdout order (2>&1 then 1>/dev/null); sibling oracle_stdout on the next line is the mirror image.
# shellcheck disable=SC2069
oracle_stderr() { ( cd "$SANDBOX" && "$SCRIPT" "$@" 2>&1 1>/dev/null ); }
oracle_stdout() { ( cd "$SANDBOX" && "$SCRIPT" "$@" 2>/dev/null ); }

# MEMBER's real content digest for the SANDBOX's current HEAD, via the real
# digest engine (never hand-derived), so fixtures stay in lockstep with
# whatever the oracle itself would compute.
member_digest_for() {
  local member="$1"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$LIB_DIR/audit-digest.sh" "$SANDBOX" "$member"
}

# Write a writer-shaped EARNED clearance marker for MEMBER, keyed to MEMBER's
# own content digest at the sandbox's current HEAD (schema 3). Frontend gets
# a sidecar:true body field (no sidecar file is required by the oracle, only
# by the merge gate's own C4 check).
write_marker() {
  local member="$1" digest sha tree infix sidecar
  digest="$(member_digest_for "$member")"
  sha="$(commit_sha)"
  tree="$(tree_sha)"
  if [ "$member" = "code-audit-frontend" ]; then infix=""; sidecar="true"; else infix=".$member"; sidecar="false"; fi
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf '{"version":"1.6.1","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-07-14T10:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" \
    > "$SANDBOX/.gaia/local/audit/${digest}${infix}.ok"
}

# A PATH whose dir carries every binary these scripts need EXCEPT jq
# (including a sha256 tool, so the digest engine itself still works and only
# the jq-gated clearance reader is disabled), so `command -v jq` fails and the
# digest-marker-presence filter disables itself.
path_without_jq() {
  local d="$BATS_TEST_TMPDIR/nojq-bin" b p
  mkdir -p "$d"
  for b in env bash sh git awk sed grep sort head tail tr cat cut wc dirname basename mktemp date rm mkdir printf test expr shasum sha256sum; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/$b"
  done
  printf '%s' "$d"
}

# --- Freshness-advisory fixtures --------------------------------------------
#
# The sandbox has no `origin` remote; the local remote-tracking ref alone is
# what the oracle reads, so these helpers write it directly.

# Advance the sandbox's `origin/main` N commits past `main`, leaving HEAD (on
# `feature`) behind by exactly N. Built with plumbing over main's own tree
# rather than checkouts, so the working tree, the branch under test, and the
# merge-base diff are all untouched: only the remote-tracking ref moves.
advance_origin_main() {
  local n="$1" i=1 parent tree
  parent="$(git -C "$SANDBOX" rev-parse main)"
  tree="$(git -C "$SANDBOX" rev-parse 'main^{tree}')"
  while [ "$i" -le "$n" ]; do
    parent="$(git -C "$SANDBOX" commit-tree "$tree" -p "$parent" -m "main $i")"
    i=$((i + 1))
  done
  git -C "$SANDBOX" update-ref refs/remotes/origin/main "$parent"
}

# Point `origin/main` at `main` exactly: HEAD is ahead of it and behind by 0.
sync_origin_main() {
  local sha
  sha="$(git -C "$SANDBOX" rev-parse main)"
  git -C "$SANDBOX" update-ref refs/remotes/origin/main "$sha"
}

# Snapshot every file in the audit pool (name + content hash), to prove the
# oracle mints nothing.
pool_snapshot() {
  local dir="$SANDBOX/.gaia/local/audit"
  [ -d "$dir" ] || { printf '<no-pool>'; return 0; }
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; shasum "$f" 2>/dev/null; done )
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
  # SC2069: deliberate; capture stderr, discard stdout (2>&1 then 1>/dev/null).
  # shellcheck disable=SC2069
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

# ---------------------------------------------------------------------------
# The digest-marker-presence filter (C1/C2, UAT-016). The oracle drops a
# member whose valid CURRENT-digest earned marker is already present, MINTS
# NOTHING, and is a simple presence check: no anchor selection, no delta, no
# ancestry.
# ---------------------------------------------------------------------------

@test "UAT-016: a member whose valid current-digest marker is present is skipped from the spawn list" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  # A NON-machinery shell fix, outside the frontend's remit: the frontend
  # digest is unchanged, so its marker still validates.
  stage .gaia/scripts/token-tally.sh; commit "fix"

  # CONTROL: the whole-branch diff dispatches BOTH members.
  members="$(resolve_members)"
  grep -qxF "code-audit-frontend" <<<"$members" || return 1
  grep -qxF "code-audit-maintainer-shell" <<<"$members" || return 1

  run run_oracle
  [ "$status" -eq 0 ]
  grep -qxF "code-audit-maintainer-shell" <<<"$output" || return 1
  grep -qxF "code-audit-frontend" <<<"$output" && return 1
  return 0
}

@test "UAT-016: a shell marker skips the shell member across an app-only fix; the frontend member is still spawned" {
  write_full_roster
  stage .gaia/scripts/foo.sh; commit "chore"
  write_marker code-audit-maintainer-shell
  stage app/y.ts; commit "feat"

  members="$(resolve_members)"
  grep -qxF "code-audit-frontend" <<<"$members" || return 1
  grep -qxF "code-audit-maintainer-shell" <<<"$members" || return 1

  run run_oracle
  [ "$status" -eq 0 ]
  grep -qxF "code-audit-frontend" <<<"$output" || return 1
  grep -qxF "code-audit-maintainer-shell" <<<"$output" && return 1
  return 0
}

@test "an attacker-controlled --base ref mints NO clearance artifact anywhere" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  # A scratch pool with a decoy file; the oracle must leave it byte-identical.
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf 'decoy\n' > "$SANDBOX/.gaia/local/audit/decoy"
  before="$(pool_snapshot)"
  run run_oracle --base HEAD~1
  [ "$status" -eq 0 ]
  after="$(pool_snapshot)"
  [ "$before" = "$after" ]
}

@test "mints-nothing: a normal filtering run creates no file under the pool" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"
  before="$(pool_snapshot)"
  run run_oracle
  [ "$status" -eq 0 ]
  after="$(pool_snapshot)"
  [ "$before" = "$after" ]
}

@test "a malformed marker for a member does not skip it from the spawn list" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"
  # The shell member's marker file exists but is not writer-shaped (garbage
  # JSON), so clearance_member_cleared rejects it and the member is not
  # skipped.
  shell_digest="$(member_digest_for code-audit-maintainer-shell)"
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf 'not json {\n' > "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok"

  run run_oracle
  [ "$status" -eq 0 ]
  grep -qxF "code-audit-maintainer-shell" <<<"$output" || return 1
  grep -qxF "code-audit-frontend" <<<"$output" && return 1
  return 0
}

@test "jq absent disables the digest-marker-presence filter; both members named" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"

  nojq="$(path_without_jq)"
  out="$( cd "$SANDBOX" && PATH="$nojq" "$SCRIPT" 2>/dev/null )"
  # Filter disabled (clearance_member_cleared requires jq) -> no filtering ->
  # BOTH members named.
  grep -qxF "code-audit-frontend" <<<"$out" || return 1
  grep -qxF "code-audit-maintainer-shell" <<<"$out" || return 1
}

@test "every dispatched member already holding a valid current-digest marker spawns nobody" {
  write_full_roster
  # T1 carries app/ AND an in-scope ownerless Dockerfile; the frontend digest
  # folds the Dockerfile in, so ONE marker covers both.
  stage app/x.tsx Dockerfile; commit "feat"
  write_marker code-audit-frontend
  # A wiki-only follow-up commit rotates no digest.
  stage wiki/x.md; commit "docs"

  # CONTROL: the resolver still dispatches the frontend member.
  members="$(resolve_members)"
  grep -qxF "code-audit-frontend" <<<"$members" || return 1

  run run_oracle
  [ "$status" -eq 0 ]
  # Empty stdout: the frontend's marker is skipped. The ownerless probe is
  # UNREACHABLE even though the whole diff carries a Dockerfile that would
  # make it emit frontend. (Empty output already rules out "code-audit-
  # frontend" being present; no separate grep needed.)
  [ -z "$output" ]
}

@test "control: an unresolvable base still fails closed to a non-empty frontend" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  run run_oracle --base does-not-exist-ref
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "control: an unreadable roster (non-executable resolver) fails closed to frontend" {
  write_full_roster
  chmod -x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage app/x.tsx; commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "--no-carry-forward emits the unfiltered dispatch set byte-for-byte (skips the digest-marker-presence filter)" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"

  # Without the flag the frontend's valid marker skips it.
  filtered="$(oracle_stdout)"
  grep -qxF "code-audit-frontend" <<<"$filtered" && return 1

  # With --no-carry-forward the output equals the raw dispatch resolver output.
  raw="$(resolve_members)"
  unfiltered="$(oracle_stdout --no-carry-forward)"
  [ "$unfiltered" = "$raw" ]
  grep -qxF "code-audit-frontend" <<<"$unfiltered" || return 1
}

# ---------------------------------------------------------------------------
# The behind-origin/main freshness advisory. A branch that drifts behind main
# during a long run audits clean, then needs a rebase to merge, and the rebase
# rotates the digests of every member owning a file main touched, burning the
# whole audit round. The advisory is stderr-only: it must never alter the
# member set on stdout and never alter the exit status.
# ---------------------------------------------------------------------------

@test "behind origin/main warns on stderr naming the commit count" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  advance_origin_main 3
  err="$(oracle_stderr)"
  grep -qF -- "resolve-audit-spawn: branch is 3 commits behind origin/main" <<<"$err" || return 1
  grep -qF -- "rebase before dispatching" <<<"$err" || return 1
}

@test "the freshness warning fires on the --no-carry-forward path too" {
  # The flag the frontend member's own self-skip probe uses, so it is a real
  # dispatch-adjacent surface and owes the same advisory.
  write_full_roster
  stage app/x.tsx
  commit "feat"
  advance_origin_main 4
  err="$(oracle_stderr --no-carry-forward)"
  grep -qF -- "resolve-audit-spawn: branch is 4 commits behind origin/main" <<<"$err" || return 1
}

@test "the freshness warning leaves stdout byte-for-byte unchanged" {
  write_full_roster
  stage app/x.tsx .gaia/scripts/y.sh
  commit "feat"
  before="$(oracle_stdout)"
  advance_origin_main 2
  after="$(oracle_stdout)"
  [ "$after" = "$before" ]
  expected="code-audit-frontend
code-audit-maintainer-shell"
  [ "$after" = "$expected" ]
}

@test "the freshness warning leaves an empty spawn set empty and exits 0" {
  write_full_roster
  stage wiki/x.md
  commit "docs"
  advance_origin_main 1
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the freshness warning never changes the exit status" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  advance_origin_main 5
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "not behind origin/main emits no freshness warning" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  # HEAD is ahead of origin/main by the feature commit, behind by nothing.
  sync_origin_main
  run run_oracle
  [ "$status" -eq 0 ]
  err="$(oracle_stderr)"
  grep -qF -- "behind origin/main" <<<"$err" && return 1
  return 0
}

@test "an unresolvable origin/main emits no freshness warning" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  # The sandbox has no `origin` remote and no remote-tracking ref at all,
  # which is the adopter-clone / different-default-branch shape.
  git -C "$SANDBOX" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 && return 1
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  err="$(oracle_stderr)"
  grep -qF -- "behind origin/main" <<<"$err" && return 1
  return 0
}
