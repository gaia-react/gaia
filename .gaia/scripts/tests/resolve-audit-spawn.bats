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
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

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

# --- Re-spawn breadcrumb ledger fixtures ------------------------------------
#
# The ledger the digest-marker filter appends to on its active path
# (.gaia/local/telemetry/audit-respawn.jsonl), and the fixtures needed to
# exercise it: a way to control which sibling audit-respawn-lib.sh the
# oracle sees, and a way to make a peer-merge rotation genuinely rotate a
# digest rather than reuse main's tree.

# The ledger's path under the sandbox, matching gaia_respawn_ledger_path's
# own contract.
ledger_path() {
  printf '%s/.gaia/local/telemetry/audit-respawn.jsonl' "$SANDBOX"
}

# The ledger's lines, one per line; empty (prints nothing) when the ledger
# file does not exist yet.
ledger_lines() {
  local f
  f="$(ledger_path)"
  [ -f "$f" ] || return 0
  cat "$f"
}

# Copies the REAL oracle ($SCRIPT) into the sandbox's OWN .gaia/scripts/ and
# runs that copy from the sandbox, so its ${BASH_SOURCE[0]}-relative sibling
# lookups (both _lib_dir and the re-spawn lib) resolve inside the sandbox
# instead of the real repository. Every other test in this file runs the
# real repo's oracle via $SCRIPT / run_oracle unmodified: this helper exists
# only for the lib-absent / lib-defective tests below, the sole cases that
# need to control the sandbox's own sibling audit-respawn-lib.sh. Do not add
# a setup() copy of that lib for the general suite; it would be dead weight,
# since $SCRIPT (real repo path) never resolves siblings from the sandbox.
run_sandbox_oracle() {
  cp "$SCRIPT" "$SANDBOX/.gaia/scripts/resolve-audit-spawn.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-spawn.sh"
  ( cd "$SANDBOX" && ./.gaia/scripts/resolve-audit-spawn.sh "$@" 2>/dev/null )
}

# stderr-capturing sibling of run_sandbox_oracle, for the lib-absent /
# lib-defective tests that need to prove the `command -v gaia_respawn_record`
# guard is load-bearing: without it, an absent lib makes the oracle attempt
# to invoke a nonexistent command, which leaks a "command not found"
# diagnostic onto real stderr even though `|| true` keeps stdout and the
# exit status untouched. run_sandbox_oracle itself discards stderr, so it
# cannot see this leak; this helper exists to catch exactly that.
# SC2069: deliberate capture-stderr / discard-stdout order, mirrors
# oracle_stderr above.
# shellcheck disable=SC2069
run_sandbox_oracle_stderr() {
  cp "$SCRIPT" "$SANDBOX/.gaia/scripts/resolve-audit-spawn.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-spawn.sh"
  ( cd "$SANDBOX" && ./.gaia/scripts/resolve-audit-spawn.sh 2>&1 1>/dev/null )
}

# A PATH whose dir carries every binary these scripts need EXCEPT a sha256
# tool (both sha256sum AND shasum absent; jq stays present), so the digest
# engine's own fail-closed guard fires and the digest batch never loads,
# while the jq-gated clearance reader stays reachable in principle. This is
# the "sha256-tool arm" the digest-batch-unavailable criterion needs: the
# degrade must be reached without deleting any lib.
path_without_sha256() {
  local d="$BATS_TEST_TMPDIR/nosha-bin" b p
  mkdir -p "$d"
  for b in env bash sh git awk sed grep sort head tail tr cat cut wc dirname basename mktemp date rm mkdir printf test expr jq; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/$b"
  done
  printf '%s' "$d"
}

# Advances origin/main by ONE commit that actually changes PATH's content to
# CONTENT: a real content diff on origin/main, not `advance_origin_main`'s
# reused main^{tree}. Built via a throwaway GIT_INDEX_FILE seeded from
# main's tree, so the sandbox's real index and its checked-out `feature`
# working tree are both untouched; only the remote-tracking ref moves, and
# the caller merges it into `feature` explicitly to make the merge-base move
# too. Needed because `advance_origin_main` alone rotates no member's
# digest (its synthetic commits carry no content change) and so cannot, on
# its own, produce the peer-merge signal this ledger measures.
advance_origin_main_with_change() {
  local path="$1" content="$2" parent idx blob new_tree new_commit
  parent="$(git -C "$SANDBOX" rev-parse main)"
  idx="$BATS_TEST_TMPDIR/tmp-index-$RANDOM"
  GIT_INDEX_FILE="$idx" git -C "$SANDBOX" read-tree main
  blob="$(printf '%s\n' "$content" | git -C "$SANDBOX" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$SANDBOX" update-index --add --cacheinfo "100644,${blob},${path}"
  new_tree="$(GIT_INDEX_FILE="$idx" git -C "$SANDBOX" write-tree)"
  rm -f "$idx"
  new_commit="$(git -C "$SANDBOX" commit-tree "$new_tree" -p "$parent" -m "origin change to $path")"
  git -C "$SANDBOX" update-ref refs/remotes/origin/main "$new_commit"
}

# 1. app-only diff -> code-audit-frontend

@test "app-only diff spawns code-audit-frontend" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 2. framework shell only -> the shell member only, no frontend

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

# 3. framework CLI TypeScript -> the node member only

@test "framework CLI TypeScript diff spawns the node member only" {
  write_full_roster
  stage .gaia/cli/src/foo.ts
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-node" ]
}

# 4. app + framework shell -> both names, sorted, verbatim passthrough

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

# 5. wiki + .claude + root *.md only -> empty

@test "wiki + .claude + root markdown only diff spawns nobody" {
  write_full_roster
  stage wiki/concepts/Foo.md .claude/rules/bar.md README.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# 6. root Dockerfile (ownerless in-scope) -> code-audit-frontend

@test "root Dockerfile (ownerless in-scope) spawns code-audit-frontend" {
  write_full_roster
  stage Dockerfile
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 7. public/logo.svg (allowlisted, nested) -> empty. No member declares a lens
#    over a static asset, and the roster's `unowned:` block says so; naming one
#    made it certify a file outside its own remit. Test 6 above is the row that
#    keeps this from reading as "the probe stopped dispatching": a root file
#    that is in scope and ownerless still fails closed to the default member.

@test "nested ownerless public asset spawns nobody" {
  write_full_roster
  stage public/logo.svg
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# 7b. The root bookkeeping literals the allowlist carries beside public/.

@test "root bookkeeping files spawn nobody" {
  write_full_roster
  stage .gitignore LICENSE .editorconfig
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# 8. wiki/x.md + root Dockerfile (mixed out-of-scope + ownerless) ->
#    code-audit-frontend (fail-closed on ANY in-scope path)

@test "mixed out-of-scope + ownerless diff fails closed to code-audit-frontend" {
  write_full_roster
  stage wiki/x.md Dockerfile
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 9. root tsconfig.json (auditable-base, via the resolver) ->
#    code-audit-frontend

@test "root tsconfig.json spawns code-audit-frontend via the resolver" {
  write_full_roster
  stage tsconfig.json
  commit "chore"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 10. --base is genuinely honored: commit A = app/x.tsx, commit B = wiki/y.md.
#     Run with --base HEAD~1 -> only commit B is in the diff -> empty.

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

# 10b. Same two commits, but commit B = root Dockerfile; --base HEAD~1
#      proves the ownerless probe honors --base too, not just the resolver
#      delegation.

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

# 11. --help exits 0 with usage

@test "--help exits 0 and prints usage" {
  run run_oracle --help
  [ "$status" -eq 0 ]
  grep -qF -- "Usage: resolve-audit-spawn.sh" <<<"$output" || return 1
}

# 12. unknown flag: exit 0, stdout is exactly code-audit-frontend
#     (fail-closed), warning on stderr.

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

# 13. not in a git repo -> exit 0, stdout is exactly code-audit-frontend
#     (fail-closed), diagnostic on stderr. The merge deny-hook denies when its
#     own member query cannot be answered, so answering "nobody owed" here
#     would name a spawn set that gate rejects.

@test "not in a git repo fails closed to code-audit-frontend" {
  notrepo="$BATS_TEST_TMPDIR/notrepo"
  mkdir -p "$notrepo"
  run bash -c 'cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null' _ "$notrepo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "not in a git repo prints a diagnostic to stderr" {
  notrepo="$BATS_TEST_TMPDIR/notrepo"
  mkdir -p "$notrepo"
  # SC2069: deliberate; capture stderr, discard stdout (2>&1 then 1>/dev/null).
  # shellcheck disable=SC2069
  stderr_out="$( ( cd "$notrepo" && GIT_CEILING_DIRECTORIES="$notrepo" "$SCRIPT" ) 2>&1 1>/dev/null )"
  grep -qF -- "resolve-audit-spawn" <<<"$stderr_out" || return 1
}

# 14. resolver removed from the sandbox, diff is app/x.tsx -> ownerless
#     probe fires -> code-audit-frontend

@test "a dispatch resolver that CANNOT answer fails closed to code-audit-frontend" {
  # Absent and failed are different states. Absent falls to the ownerless
  # probe (next test); a non-zero exit means the resolver could not resolve the
  # audited root, so the probe would answer from the same root it declined on.
  # The diff below is entirely out of scope, so the probe would print NOTHING:
  # only the fail-closed arm can produce the default member here.
  write_full_roster
  printf '#!/usr/bin/env bash\nexit 2\n' > "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage wiki/x.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "resolver absent falls to the ownerless probe (in-scope path)" {
  write_full_roster
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage app/x.tsx
  commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 15. resolver removed, diff is wiki/x.md only -> empty

@test "resolver absent falls to the ownerless probe (out-of-scope path)" {
  write_full_roster
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage wiki/x.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# 15b. resolver removed, diff is a non-ASCII out-of-scope path -> still empty
#
# The probe's own `changed` derivation reads `git diff --name-only`, which
# C-quotes any path carrying non-ASCII or control bytes under git's default
# core.quotePath. The quoted token is not what the allowlist matches, so the
# loop treats an out-of-scope path as in-scope and spawns the default member
# that nothing owes. That direction is fail-closed, an unnecessary spawn rather
# than a missed audit, which is why the derivation reads `--name-only -z`
# rather than why it must.
#
# This test exists because the sibling copy of that derivation in
# resolve-audit-members.sh has its own regression test and this one had none:
# two copies of one shape with asymmetric protection is the drift class the
# `-z` change was made to close, so leaving it untested reproduced that class
# one file over.

@test "the ownerless probe recognizes a non-ASCII out-of-scope path rather than quoting it" {
  write_full_roster
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  stage wiki/règle.md
  commit "docs"
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Non-vacuity: git really does quote THIS path under the pre-fix spelling. A
  # fixture whose name turned out to be plain ASCII would pass the assertion
  # above while proving nothing about quoting. `core.quotePath` is pinned rather
  # than inherited: it is the DEFAULT this probe asserts about, and a maintainer
  # who turns it off in ~/.gitconfig would otherwise get a red here against a
  # tree with nothing wrong with it.
  local base quoted
  base="$(git -C "$SANDBOX" merge-base HEAD main)"
  quoted="$(git -C "$SANDBOX" -c core.quotePath=true diff --name-only "${base}...HEAD")"
  grep -qF '"' <<<"$quoted" || {
    printf 'the pre-fix spelling did not quote %s, so this fixture proves nothing\n' "$quoted"
    return 1
  }
}

# 16. resolver present but exec bit cleared, diff is .gaia/scripts/y.sh ->
#     the [ -x ] guard falls to the ownerless probe; .gaia/* is out-of-scope
#     allowlisted, so nothing is owed (M2 mirror test).

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

# The digest-marker-presence filter (C1/C2, UAT-016). The oracle drops a
# member whose valid CURRENT-digest earned marker is already present, MINTS
# NOTHING, and is a simple presence check: no anchor selection, no delta, no
# ancestry.

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

# The pair to the control above, and the whole point of separating them: git
# answers BOTH states with an empty string, so a probe that reads only the
# string cannot tell "the base did not resolve" from "the base resolved and the
# range is empty". The control must stay fail-closed while this one names
# nobody; a regression that re-merges the two states greens one and reds the
# other, never both.

@test "a resolvable base with a genuinely empty diff spawns nobody" {
  # setup() leaves `feature` at the same commit as `main`, so
  # merge-base(HEAD, main) resolves to HEAD itself and the three-dot range is
  # legitimately empty: a resolved base, not an unresolved one.
  write_full_roster
  run run_oracle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--base carries the empty-range answer too: a resolvable ref names nobody, an unresolvable one does not" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  # HEAD...HEAD is empty and resolvable, so the probe names nobody...
  run run_oracle --base HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # ...while the same flag carrying a ref that does not resolve still fails
  # closed. Both halves run here rather than leaning on the control above,
  # because what this row is about is the two answers differing on the ONE
  # code path --base reaches.
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

# The behind-origin/main freshness advisory. A branch that drifts behind main
# during a long run audits clean, then needs a rebase to merge, and the rebase
# rotates the digests of every member owning a file main touched, burning the
# whole audit round. The advisory is stderr-only: it must never alter the
# member set on stdout and never alter the exit status.

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

# The re-spawn breadcrumb ledger. The digest-marker filter already computes,
# per considered member, both halves of the question this ledger measures
# (the member's content digest and whether a valid current-digest marker
# cleared it); these tests exercise the append it now performs alongside
# that decision. The oracle's own dispatch decision, exit status, and stdout
# must stay exactly as proven by every test above -- these tests add
# coverage for the ledger's own shape and fail-open behavior, never for a
# changed dispatch answer.

@test "UAT-001: the ledger holds exactly one line per considered member, mixing cleared and uncleared" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"

  # CONTROL: the whole-branch diff dispatches both members, matching the
  # UAT-016 fixture this reuses.
  members="$(resolve_members)"
  expected_count="$(printf '%s\n' "$members" | grep -c .)"

  run run_oracle
  [ "$status" -eq 0 ]

  actual_count="$(ledger_lines | grep -c .)"
  [ "$actual_count" -eq "$expected_count" ]

  actual_members="$(ledger_lines | jq -r .member | LC_ALL=C sort -u)"
  expected_members="$(printf '%s\n' "$members" | LC_ALL=C sort -u)"
  [ "$actual_members" = "$expected_members" ]

  grep -qF '"member":"code-audit-frontend"' <<<"$(ledger_lines)" || return 1
  grep -qF '"member":"code-audit-maintainer-shell"' <<<"$(ledger_lines)" || return 1
}

@test "each ledger line parses under jq and carries exactly the frozen key order" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"
  run run_oracle
  [ "$status" -eq 0 ]

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e . >/dev/null || return 1
    keys="$(printf '%s' "$line" | jq -r 'keys_unsorted | join(",")')"
    [ "$keys" = "schema,ts,branch,head,merge_base,member,digest,cleared" ] || return 1
  done <<<"$(ledger_lines)"
}

@test "digest in the ledger equals the member's real digest from the digest engine" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"
  run run_oracle
  [ "$status" -eq 0 ]

  frontend_digest="$(member_digest_for code-audit-frontend)"
  shell_digest="$(member_digest_for code-audit-maintainer-shell)"

  rec_frontend="$(ledger_lines | grep '"member":"code-audit-frontend"')"
  rec_shell="$(ledger_lines | grep '"member":"code-audit-maintainer-shell"')"

  [ "$(printf '%s' "$rec_frontend" | jq -r .digest)" = "$frontend_digest" ]
  [ "$(printf '%s' "$rec_shell" | jq -r .digest)" = "$shell_digest" ]
}

@test "cleared is true for a member holding a valid marker, false for a malformed one" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"
  # The shell member's marker file exists but is not writer-shaped (garbage
  # JSON), the same malformed-marker fixture shape the dispatch tests above
  # use.
  shell_digest="$(member_digest_for code-audit-maintainer-shell)"
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf 'not json {\n' > "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok"

  run run_oracle
  [ "$status" -eq 0 ]

  rec_frontend="$(ledger_lines | grep '"member":"code-audit-frontend"')"
  rec_shell="$(ledger_lines | grep '"member":"code-audit-maintainer-shell"')"

  [ "$(printf '%s' "$rec_frontend" | jq -r .cleared)" = "true" ]
  [ "$(printf '%s' "$rec_shell" | jq -r .cleared)" = "false" ]
}

@test "head and branch in the ledger match the fixture's real HEAD and branch name" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  run run_oracle
  [ "$status" -eq 0 ]

  real_head="$(git -C "$SANDBOX" rev-parse HEAD)"
  real_branch="$(git -C "$SANDBOX" symbolic-ref --short HEAD)"

  rec="$(ledger_lines | tail -1)"
  [ "$(printf '%s' "$rec" | jq -r .head)" = "$real_head" ]
  [ "$(printf '%s' "$rec" | jq -r .branch)" = "$real_branch" ]
}

@test "UAT-002: peer-merge rotation - merge_base moves, digest rotates, and clearance is lost across the pair" {
  write_full_roster
  stage .gaia/scripts/y.sh; commit "chore"
  write_marker code-audit-maintainer-shell
  sync_origin_main

  run run_oracle
  before="$(ledger_lines | tail -1)"
  before_mb="$(printf '%s' "$before" | jq -r .merge_base)"

  # origin/main gains a REAL content change to a file the shell member owns.
  advance_origin_main_with_change .gaia/scripts/peer-owned.sh "peer change"
  git -C "$SANDBOX" merge --quiet --no-edit refs/remotes/origin/main
  after_mb_check="$(git -C "$SANDBOX" merge-base HEAD refs/remotes/origin/main)"
  # The merge-base must have actually moved before the record is trusted.
  [ "$after_mb_check" != "$before_mb" ] || return 1

  run run_oracle
  after="$(ledger_lines | grep '"member":"code-audit-maintainer-shell"' | tail -1)"

  before_digest="$(printf '%s' "$before" | jq -r .digest)"
  after_digest="$(printf '%s' "$after" | jq -r .digest)"
  after_mb="$(printf '%s' "$after" | jq -r .merge_base)"
  before_cleared="$(printf '%s' "$before" | jq -r .cleared)"
  after_cleared="$(printf '%s' "$after" | jq -r .cleared)"

  [ -n "$before_mb" ] || return 1
  [ -n "$after_mb" ] || return 1
  [ "$before_mb" != "$after_mb" ] || return 1
  [ "$before_digest" != "$after_digest" ] || return 1
  [ "$before_cleared" = "true" ] || return 1
  [ "$after_cleared" = "false" ] || return 1
}

@test "UAT-003: own-edit rotation - merge_base stays identical while digest and head differ" {
  write_full_roster
  stage .gaia/scripts/y.sh; commit "chore"
  write_marker code-audit-maintainer-shell
  sync_origin_main

  run run_oracle
  before="$(ledger_lines | tail -1)"

  # A maintainer edit to a file the shell member owns; origin/main untouched.
  stage .gaia/scripts/z.sh; commit "more shell"

  run run_oracle
  after="$(ledger_lines | tail -1)"

  before_mb="$(printf '%s' "$before" | jq -r .merge_base)"
  after_mb="$(printf '%s' "$after" | jq -r .merge_base)"
  before_digest="$(printf '%s' "$before" | jq -r .digest)"
  after_digest="$(printf '%s' "$after" | jq -r .digest)"
  before_head="$(printf '%s' "$before" | jq -r .head)"
  after_head="$(printf '%s' "$after" | jq -r .head)"

  [ -n "$before_mb" ] || return 1
  [ "$before_mb" = "$after_mb" ] || return 1
  [ "$before_digest" != "$after_digest" ] || return 1
  [ "$before_head" != "$after_head" ] || return 1
}

@test "on a detached HEAD, branch is empty in the ledger and the run is otherwise unchanged" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  sha="$(commit_sha)"
  git -C "$SANDBOX" checkout --quiet "$sha"
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  rec="$(ledger_lines | tail -1)"
  [ "$(printf '%s' "$rec" | jq -r .branch)" = "" ]
}

@test "with no origin/main, merge_base is empty in the ledger and the run is otherwise unchanged" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  git -C "$SANDBOX" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 && return 1
  run run_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  rec="$(ledger_lines | tail -1)"
  [ "$(printf '%s' "$rec" | jq -r .merge_base)" = "" ]
}

@test "--no-carry-forward writes no ledger file at all (the filter is skipped)" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  run run_oracle --no-carry-forward
  [ "$status" -eq 0 ]
  [ ! -f "$(ledger_path)" ]
}

@test "digest batch unavailable (no sha256 tool) writes no ledger; the degrade path returns before the loop" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  nosha="$(path_without_sha256)"
  out="$( cd "$SANDBOX" && PATH="$nosha" "$SCRIPT" 2>/dev/null )"
  # Filter disabled entirely (digest batch never loads) -> unfiltered passthrough.
  [ "$out" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
}

@test "jq absent still writes breadcrumbs, all cleared:false" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  write_marker code-audit-frontend
  stage .gaia/scripts/token-tally.sh; commit "fix"

  nojq="$(path_without_jq)"
  out="$( cd "$SANDBOX" && PATH="$nojq" "$SCRIPT" 2>/dev/null )"
  grep -qxF "code-audit-frontend" <<<"$out" || return 1
  grep -qxF "code-audit-maintainer-shell" <<<"$out" || return 1

  ledger_content="$(ledger_lines)"
  [ -n "$ledger_content" ] || return 1
  printf '%s\n' "$ledger_content" | grep -qF '"cleared":true' && return 1
  count="$(printf '%s\n' "$ledger_content" | grep -c .)"
  [ "$count" -eq 2 ] || return 1
}

@test "ledger parent path blocked (a file where the directory should be): stdout, exit status, and stderr are unaffected" {
  write_full_roster
  stage app/x.tsx; commit "feat"

  mkdir -p "$SANDBOX/.gaia/local"
  printf 'blocked\n' > "$SANDBOX/.gaia/local/telemetry"

  run run_oracle
  blocked_status="$status"
  blocked_stdout="$output"
  blocked_stderr="$(oracle_stderr)"

  [ ! -d "$SANDBOX/.gaia/local/telemetry" ]
  rm -f "$SANDBOX/.gaia/local/telemetry"

  run run_oracle
  unblocked_status="$status"
  unblocked_stdout="$output"
  unblocked_stderr="$(oracle_stderr)"

  [ "$blocked_status" -eq "$unblocked_status" ]
  [ "$blocked_stdout" = "$unblocked_stdout" ]
  [ "$blocked_stderr" = "$unblocked_stderr" ]
}

@test "ledger file made unwritable (chmod 0444): stdout, exit status, and stderr are unaffected" {
  write_full_roster
  stage app/x.tsx; commit "feat"

  run run_oracle
  [ -f "$(ledger_path)" ] || return 1
  chmod 0444 "$(ledger_path)"
  before_count="$(ledger_lines | grep -c .)"

  run run_oracle
  locked_status="$status"
  locked_stdout="$output"
  locked_stderr="$(oracle_stderr)"

  after_count="$(ledger_lines | grep -c .)"
  [ "$after_count" -eq "$before_count" ]

  chmod 0644 "$(ledger_path)"
  run run_oracle
  unlocked_status="$status"
  unlocked_stdout="$output"
  unlocked_stderr="$(oracle_stderr)"

  [ "$locked_status" -eq "$unlocked_status" ]
  [ "$locked_stdout" = "$unlocked_stdout" ]
  [ "$locked_stderr" = "$unlocked_stderr" ]
}

@test "criterion 18: re-spawn lib absent from the sandbox - stdout, exit status, and stderr unaffected, no ledger" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  rm -f "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
  # The guard (`command -v gaia_respawn_record`) is what keeps this silent:
  # without it, the oracle would attempt to invoke the now-undefined
  # function and leak a "command not found" diagnostic here.
  [ -z "$(run_sandbox_oracle_stderr)" ]
}

@test "criterion 18: re-spawn lib present but unsourceable (syntax error) - stdout and exit status unaffected, no ledger" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  printf 'if true\n' > "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
}

@test "criterion 18: re-spawn lib present but its top level returns 1 - stdout and exit status unaffected, no ledger" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  printf 'return 1\n' > "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
}

@test "criterion 18: re-spawn lib aborts under set -u while sourcing - stdout and exit status unaffected, no ledger" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  # The fifth defective shape, and the one the `|| true` on the source line
  # cannot absorb: an unset-variable reference at the lib's top level kills the
  # shell where it stands, before any later statement runs. The oracle's
  # contract has to survive it the same way it survives the other four.
  printf ': "$GAIA_RESPAWN_NO_SUCH_VAR"\n' > "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
}

@test "criterion 18: re-spawn lib prints at source time - stdout stays the spawn set alone" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  # The lib is contracted to be side-effect-free at source time. This script's
  # stdout is its answer, so a stray print would not just add noise, it would
  # be read back as a member name.
  printf 'echo stray-source-time-output\n' > "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

@test "criterion 18: re-spawn lib sourceable but gaia_respawn_record is defective - stdout and exit status unaffected, no ledger" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  cat "$THIS_DIR/../audit-respawn-lib.sh" > "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  printf '\ngaia_respawn_record() { return 1; }\n' >> "$SANDBOX/.gaia/scripts/audit-respawn-lib.sh"
  run run_sandbox_oracle
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  [ ! -f "$(ledger_path)" ]
}

@test "the ledger lives outside the audit pool: pool_snapshot stays byte-identical while the ledger gains a line" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  before_pool="$(pool_snapshot)"
  run run_oracle
  [ "$status" -eq 0 ]
  after_pool="$(pool_snapshot)"
  [ "$before_pool" = "$after_pool" ]
  [ -f "$(ledger_path)" ]
}

@test "the oracle runs cleanly under macOS's system /bin/bash (bash 3.2 compatibility)" {
  write_full_roster
  stage app/x.tsx; commit "feat"
  run bash -c 'cd "$1" && /bin/bash "$2"' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}
