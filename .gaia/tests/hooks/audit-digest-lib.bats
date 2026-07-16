#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-digest.sh, the single per-member
# content-digest derive point, and its CLI entrypoint
# .gaia/scripts/audit-member-digest.sh.
#
# A member's digest is a sha256 over exactly the files that member owns plus the
# shared gate machinery (plus the in-scope-but-ownerless paths for the default
# member), classified by the existing ownership classifier + machinery matcher,
# never by git pathspec. The headline behavior: an out-of-glob-only commit
# leaves every member's digest byte-identical, so its marker re-validates with no
# re-audit. Every degradation resolves fail-closed (empty output, non-zero exit).
#
# Fixtures use the builtin roster (no .gaia/audit-ci.yml in the fixture), which
# names all three members: code-audit-frontend (default), code-audit-maintainer-
# shell, code-audit-maintainer-node. Membership is proved by ROTATION: a path is
# in member M's digest set iff flipping one byte in it rotates M's digest.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS system bash 3.2 does
# not fail a @test on a false bare `[[ ]]` that is not the last command, so
# non-final checks use POSIX `[ ]`, `grep -q`, or an explicit `|| return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  DIGEST_LIB="$REPO_ROOT/.claude/hooks/lib/audit-digest.sh"
  CLI="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  [ -f "$DIGEST_LIB" ] || skip "audit-digest.sh not present"
  # The digest needs a sha256 tool + git; it does NOT need jq.
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "no sha256 tool"
  fi
}

git_init() {
  local d="$1"
  git -C "$d" init --quiet --initial-branch=main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false
}

# Seed a fixture repo with an owned file for each of the three members, a
# machinery file (in every member's set), a nested rules machinery file, an
# out-of-glob CHANGELOG, and a wiki file (both ownerless + allowlisted).
seed_repo() {
  local d="$1"
  mkdir -p "$d/app" "$d/.gaia/scripts" "$d/.gaia/cli/src" "$d/.gaia" \
    "$d/.claude/rules/foo" "$d/wiki"
  git_init "$d"
  echo "export const x = 1;"  > "$d/app/x.ts"                 # frontend (auditable base)
  echo "#!/usr/bin/env bash"  > "$d/.gaia/scripts/foo.sh"     # maintainer-shell owned, not machinery
  echo "export const y = 2;"  > "$d/.gaia/cli/src/index.ts"   # maintainer-node
  printf '1.6.1\n'            > "$d/.gaia/VERSION"             # machinery (all members)
  echo "rule body"            > "$d/.claude/rules/foo/bar.md" # machinery (.claude/rules/**), nested
  echo "# changelog"          > "$d/CHANGELOG.md"             # out-of-glob (ownerless + allowlisted)
  echo "doc"                  > "$d/wiki/x.md"                # out-of-glob (ownerless + allowlisted)
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "seed"
}

# digest_of <root> <member> [<ref>] -> 64-hex on stdout, non-zero on fail-closed.
digest_of() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIB" "$root" "$member" "$ref"
}

# Commit a one-line mutation to <path> and echo "<pre> <post>" (the shas before
# and after), so a test can compute each member's digest at both.
mutate_commit() {
  local root="$1" path="$2" pre post
  pre="$(git -C "$root" rev-parse HEAD)"
  printf 'mutation-%s\n' "$RANDOM" >> "$root/$path"
  git -C "$root" commit -aqm "mutate $path"
  post="$(git -C "$root" rev-parse HEAD)"
  printf '%s %s' "$pre" "$post"
}

# ---------------------------------------------------------------------------
# audit_digests_all: one line per roster member, each a 64-hex digest.
# ---------------------------------------------------------------------------

@test "audit_digests_all emits every roster member with a 64-hex digest" {
  ROOT="$BATS_TEST_TMPDIR/all"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  out="$(bash -c '. "$1"; audit_digests_all "$2"' _ "$DIGEST_LIB" "$ROOT")"
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    d="$(grep -F "$m"$'\t' <<<"$out" | cut -f2)"
    [ "${#d}" -eq 64 ] || return 1
    case "$d" in *[!0-9a-f]*) return 1 ;; esac
  done
}

# ---------------------------------------------------------------------------
# UAT-001 / SC1: the flagship out-of-glob no-op. A CHANGELOG-only edit A->B
# touches no path any member owns and no machinery path, so EVERY member's
# digest is byte-identical across A and B.
# ---------------------------------------------------------------------------

@test "UAT-001: a CHANGELOG-only commit leaves every member's digest unchanged" {
  ROOT="$BATS_TEST_TMPDIR/uat001"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "CHANGELOG.md")"
  a="${refs% *}"
  b="${refs#* }"
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    da="$(digest_of "$ROOT" "$m" "$a")"
    db="$(digest_of "$ROOT" "$m" "$b")"
    [ -n "$da" ] || return 1
    [ "$da" = "$db" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# UAT-006: the real fail-open direction. Flipping a byte in an owned path
# rotates that member's digest (so the owned path IS in the input set); an
# unrelated member's digest is unchanged; an out-of-set edit rotates nothing.
# ---------------------------------------------------------------------------

@test "UAT-006: a specialist-owned (node) byte flip rotates only that member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006node"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".gaia/cli/src/index.ts")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$a")" != "$(digest_of "$ROOT" code-audit-maintainer-node "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" = "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-shell "$a")" = "$(digest_of "$ROOT" code-audit-maintainer-shell "$b")" ] || return 1
}

@test "UAT-006: a default-member auditable-base (app) byte flip rotates only the frontend digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006app"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "app/x.ts")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" != "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$a")" = "$(digest_of "$ROOT" code-audit-maintainer-node "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-shell "$a")" = "$(digest_of "$ROOT" code-audit-maintainer-shell "$b")" ] || return 1
}

@test "UAT-006: a machinery (.gaia/VERSION) byte flip rotates every member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006mach"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".gaia/VERSION")"
  a="${refs% *}"; b="${refs#* }"
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$m" "$a")" != "$(digest_of "$ROOT" "$m" "$b")" ] || return 1
  done
}

@test "UAT-006: an out-of-set (wiki) edit rotates no member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006wiki"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "wiki/x.md")"
  a="${refs% *}"; b="${refs#* }"
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$m" "$a")" = "$(digest_of "$ROOT" "$m" "$b")" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# UAT-009: membership is the classifier's, matching dispatch, for a nested
# .claude/rules/ path (machinery via .claude/rules/**), an app/ path (default
# member's auditable base), and a .gaia/cli/src/ path (specialist ERE), never
# git pathspec.
# ---------------------------------------------------------------------------

@test "UAT-009: nested .claude/rules/foo/bar.md is machinery (rotates every member)" {
  ROOT="$BATS_TEST_TMPDIR/uat009rules"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".claude/rules/foo/bar.md")"
  a="${refs% *}"; b="${refs#* }"
  for m in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$m" "$a")" != "$(digest_of "$ROOT" "$m" "$b")" ] || return 1
  done
}

@test "UAT-009: app/x.ts lands only in the frontend digest; .gaia/cli/src only in node" {
  ROOT="$BATS_TEST_TMPDIR/uat009own"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  # app path: frontend only.
  refs="$(mutate_commit "$ROOT" "app/x.ts")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" != "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$a")" = "$(digest_of "$ROOT" code-audit-maintainer-node "$b")" ] || return 1
  # cli path: node only.
  refs="$(mutate_commit "$ROOT" ".gaia/cli/src/index.ts")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$a")" != "$(digest_of "$ROOT" code-audit-maintainer-node "$b")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" = "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1
}

# ---------------------------------------------------------------------------
# Determinism: the frontend digest folds the in-scope-but-ownerless set, so a
# root Dockerfile change rotates it while a wiki file (allowlisted) does not.
# ---------------------------------------------------------------------------

@test "determinism: an in-scope-but-ownerless root Dockerfile rotates the frontend digest; a wiki file does not" {
  ROOT="$BATS_TEST_TMPDIR/ownerless"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  echo "FROM scratch" > "$ROOT/Dockerfile"
  git -C "$ROOT" add Dockerfile
  git -C "$ROOT" commit --quiet -m "add Dockerfile"

  # A Dockerfile edit rotates the frontend digest (folded in).
  refs="$(mutate_commit "$ROOT" "Dockerfile")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" != "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1

  # A wiki edit does not.
  refs="$(mutate_commit "$ROOT" "wiki/x.md")"
  a="${refs% *}"; b="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$a")" = "$(digest_of "$ROOT" code-audit-frontend "$b")" ] || return 1
}

# ---------------------------------------------------------------------------
# UAT-012: path-name framing (scoped per CG-001). A space in a path is the
# BINDING assertion: two owned sets identical except one path embeds a space
# yield different digests, and a recompute of the same content agrees. The
# embedded-newline case is a documented known limitation (the reused classifiers
# read newline-delimited stdin), asserted as fail-closed rather than fixed.
# ---------------------------------------------------------------------------

@test "UAT-012: a space in an owned path changes the digest, and a recompute agrees" {
  R1="$BATS_TEST_TMPDIR/nospace"
  R2="$BATS_TEST_TMPDIR/space"
  mkdir -p "$R1/app" "$R2/app"
  git_init "$R1"
  git_init "$R2"
  # Identical content, path differs only by a space.
  echo "export const z = 3;" > "$R1/app/normal.ts"
  echo "export const z = 3;" > "$R2/app/with space.ts"
  git -C "$R1" add -A && git -C "$R1" commit --quiet -m "seed"
  git -C "$R2" add -A && git -C "$R2" commit --quiet -m "seed"

  d1="$(digest_of "$R1" code-audit-frontend)"
  d2="$(digest_of "$R2" code-audit-frontend)"
  [ "${#d1}" -eq 64 ] || return 1
  [ "${#d2}" -eq 64 ] || return 1
  [ "$d1" != "$d2" ] || return 1
  # Recompute of the space-path repo agrees (determinism under a space).
  [ "$d2" = "$(digest_of "$R2" code-audit-frontend)" ] || return 1
}

@test "UAT-012: an embedded-newline path is a documented known limitation (fail-closed, not a wrong digest)" {
  # The membership classifiers read newline-delimited stdin, so a path whose
  # name embeds a literal newline is mis-split during selection. The engine
  # detects the resulting count mismatch and fails closed (empty, non-zero)
  # rather than hashing a mis-aligned set -- safe, never a wrong digest. This
  # is out of scope to "fix" (it would mean changing the classifier semantics).
  R="$BATS_TEST_TMPDIR/newline"
  mkdir -p "$R/app"
  git_init "$R"
  printf 'export const z = 3;\n' > "$R/app/x.ts"
  # A tracked path literally containing a newline byte.
  bad="$(printf 'app/we\nird.ts')"
  printf 'export const w = 4;\n' > "$R/$bad"
  git -C "$R" add -A
  git -C "$R" commit --quiet -m "seed with newline path"

  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend' _ "$DIGEST_LIB" "$R"
  # Either it fails closed (preferred) -- never a bare/partial digest match.
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# UAT-013: fail-closed. A masked sha256 tool, a failing git ls-tree, or a
# non-git root each emit NOTHING and exit non-zero -- never a partial/empty
# digest that could key or match a marker.
# ---------------------------------------------------------------------------

@test "UAT-013: sha256 tool masked -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013mask"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash -c '
    sha256sum() { return 1; }
    shasum() { return 1; }
    . "$1"
    audit_member_digest "$2" code-audit-frontend
  ' _ "$DIGEST_LIB" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "UAT-013: a failing git ls-tree (invalid ref) -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013ref"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend "no-such-ref"' _ "$DIGEST_LIB" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "UAT-013: a non-git root -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013nogit"
  mkdir -p "$ROOT"
  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend' _ "$DIGEST_LIB" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# The CLI entrypoint mirrors the lib: a 64-hex digest + exit 0, and a non-zero
# exit on any fail-closed condition (never swallowed into 0). Usage errors exit 2.
# ---------------------------------------------------------------------------

@test "CLI: prints the same 64-hex digest the lib computes, exit 0" {
  ROOT="$BATS_TEST_TMPDIR/cli"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash "$CLI" --root "$ROOT" --member code-audit-frontend
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 64 ]
  [ "$output" = "$(digest_of "$ROOT" code-audit-frontend)" ] || return 1
}

@test "CLI: missing --root or --member exits 2" {
  run bash "$CLI" --member code-audit-frontend
  [ "$status" -eq 2 ]
  ROOT="$BATS_TEST_TMPDIR/cli2"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash "$CLI" --root "$ROOT"
  [ "$status" -eq 2 ]
}

@test "CLI: a fail-closed digest exits non-zero with empty stdout (never swallowed)" {
  ROOT="$BATS_TEST_TMPDIR/cli3"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash "$CLI" --root "$ROOT" --member code-audit-frontend --ref no-such-ref
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
