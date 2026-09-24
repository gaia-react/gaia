#!/usr/bin/env bats
#
# audit-resolve-scope.sh: the one-command scope resolution a Code Audit Team
# member runs by literal path. These probes pin the script's own contract
# (confinement, exit codes, output shape, the two changed-file lists, the
# dirty check, and the capture). Whether each member definition invokes it the
# way its self-skip and keying need is audit-base-agreement.bats' concern.
#
# Every fixture carries its own copy of the script and the machinery it runs,
# at the real repo-relative paths, because the script refuses a --root that is
# not the tree it sits in.
#
# Run under bash 5 (.claude/rules/bats-assertions.md): `source
# .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/audit-resolve-scope.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  # A `gh` that answers nothing, so the probes that put this directory first on
  # PATH never reach the developer's real `gh` or its GH_REPO / GH_HOST.
  mkdir -p "$BATS_TEST_TMPDIR/no-gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/no-gh/gh"
  chmod +x "$BATS_TEST_TMPDIR/no-gh/gh"
  REPO_ROOT="$(git -C "$THIS_DIR" rev-parse --show-toplevel)"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; the capture probes here would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
}

# make_repo <name> [<initial-branch>]: a committed repo carrying the script and
# everything it reaches for.
make_repo() {
  local name="$1" branch="${2:-main}"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.gaia/scripts" "$dir/.gaia/local/audit" \
    "$dir/.github/audit" "$dir/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-respawn-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$dir/.gaia/scripts/"
  chmod +x "$dir/.gaia/scripts/audit-resolve-scope.sh" "$dir/.gaia/scripts/audit-scope-digest.sh"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$dir/.github/audit/"
  chmod +x "$dir/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$dir/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" \
    "$dir/.claude/hooks/lib/"
  printf '2.0.0\n' > "$dir/.gaia/VERSION"
  git -C "$dir" init -q --initial-branch="$branch"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  printf '%s' "$(cd "$dir" && pwd -P)"
}

commit_file() {
  local repo="$1" path="$2"
  mkdir -p "$(dirname "$repo/$path")"
  printf 'touched\n' >> "$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "touch $path"
}

# value_of <output> <KEY>: the value of the first KEY= line.
value_of() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# ---------- confinement -------------------------------------------------------

@test "refuses a --root that is not the tree the script sits in" {
  local repo
  repo="$(make_repo foreign)"
  run "$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not to $(cd "$REPO_ROOT" && pwd -P), the tree this script belongs to"* ]] || return 1
  [[ "$output" != *"KEY_BASE="* ]] || return 1
}

@test "refuses an empty --root instead of resolving the ambient directory" {
  local repo
  repo="$(make_repo empty-root)"
  run bash -c 'cd "$1" && "$1/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root ""' _ "$repo"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--root is empty"* ]] || return 1
}

@test "refuses a --root that does not exist" {
  local repo
  repo="$(make_repo missing-root)"
  run "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not resolve to a directory"* ]] || return 1
}

@test "refuses a subdirectory of its own tree" {
  local repo
  repo="$(make_repo subdir-root)"
  run "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo/.gaia"
  [ "$status" -eq 2 ]
}

@test "accepts a symlinked spelling of its own tree and prints the physical root" {
  local repo link
  repo="$(make_repo symlinked)"
  link="$BATS_TEST_TMPDIR/link-to-repo"
  ln -s "$repo" "$link"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  run "$link/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$link"
  [ "$status" -eq 0 ]
  [ "$(value_of "$output" AUDIT_ROOT)" = "$repo" ]
}

@test "usage errors exit 2" {
  local repo
  repo="$(make_repo usage)"
  run "$repo/.gaia/scripts/audit-resolve-scope.sh" --root "$repo"
  [ "$status" -eq 2 ]
  run "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell
  [ "$status" -eq 2 ]
  run "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo" --bogus
  [ "$status" -eq 2 ]
}

# ---------- resolution ---------------------------------------------------------

@test "prints every scalar, in order, and the two lists on a resolvable feature branch" {
  local repo full_base keys
  repo="$(make_repo resolves)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  commit_file "$repo" docs/b.md
  full_base="$(git -C "$repo" merge-base HEAD main)"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  keys="$(printf '%s\n' "$output" | sed -n 's/=.*//p' | awk '!seen[$0]++' | tr '\n' ' ')"
  [ "$keys" = "AUDIT_ROOT FULL_BASE BASE_REF BASE_REASON KEY_REF ANCHOR_TREE BASE_SHA KEY_BASE AUDIT_KEY D_SCOPE FULL_CHANGED CHANGED " ]
  [ "$(value_of "$output" FULL_BASE)" = "$full_base" ]
  [ "$(value_of "$output" AUDIT_KEY)" = "$full_base.feat" ]
  [ "$(value_of "$output" BASE_SHA)" = "$full_base" ]
  [ "$(value_of "$output" KEY_BASE)" = "$full_base" ]
  [[ "$(value_of "$output" D_SCOPE)" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$output" | grep -qxF 'FULL_CHANGED=app/a.ts'
  printf '%s\n' "$output" | grep -qxF 'FULL_CHANGED=docs/b.md'
  printf '%s\n' "$output" | grep -qxF 'CHANGED=app/a.ts'
  printf '%s\n' "$output" | grep -qxF 'CHANGED=docs/b.md'
}

@test "KEY_BASE matches what the argument-less resolver yields" {
  local repo reader_ref reader_base
  repo="$(make_repo key-agreement)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  reader_ref="$(cd "$repo" && ./.github/audit/resolve-audit-base.sh 2>/dev/null)"
  reader_base="$(git -C "$repo" merge-base "$reader_ref" HEAD)"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-node --root "$repo"
  [ "$status" -eq 0 ]
  [ "$(value_of "$output" KEY_BASE)" = "$reader_base" ]
}

@test "an unresolvable membership base exits 1 before resolving anything else" {
  local repo
  repo="$(make_repo no-base master)"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"do NOT self-skip"* ]] || return 1
  [ "$(value_of "$output" FULL_BASE)" = "" ]
  [[ "$output" != *"KEY_BASE="* ]] || return 1
  [[ "$output" != *"D_SCOPE="* ]] || return 1
}

@test "--skip-full-base resolves on a repo whose membership base is unresolvable" {
  local repo
  repo="$(make_repo skip-full-base master)"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base
  [ "$status" -eq 0 ]
  [[ "$output" != *"FULL_BASE="* ]] || return 1
  [[ "$output" == *"KEY_BASE="* ]] || return 1
}

@test "--review-path narrows CHANGED and leaves FULL_CHANGED whole" {
  local repo
  repo="$(make_repo review-path)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  commit_file "$repo" app/b.tsx
  commit_file "$repo" scripts/c.sh
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" \
    --review-path '*.ts' --review-path '*.tsx'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGED=app/a.ts'
  printf '%s\n' "$output" | grep -qxF 'CHANGED=app/b.tsx'
  printf '%s\n' "$output" | grep -qxF 'FULL_CHANGED=scripts/c.sh'
  [ "$(printf '%s\n' "$output" | grep -cxF 'CHANGED=scripts/c.sh')" -eq 0 ]
}

@test "--base-override replaces the review base and leaves the key base to the resolver" {
  local repo first key_ref
  repo="$(make_repo override)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  first="$(git -C "$repo" rev-parse HEAD)"
  commit_file "$repo" app/b.ts
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" \
    --skip-full-base --base-override "$first"
  [ "$status" -eq 0 ]
  [ "$(value_of "$output" BASE_REF)" = "$first" ]
  [ "$(value_of "$output" BASE_SHA)" = "$first" ]
  key_ref="$(value_of "$output" KEY_REF)"
  [ "$(value_of "$output" KEY_BASE)" = "$(git -C "$repo" merge-base "$key_ref" HEAD)" ]
  [ "$(printf '%s\n' "$output" | grep -c '^CHANGED=')" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGED=app/b.ts'
}

@test "the review list is HEAD's content, not the working tree's" {
  local repo
  repo="$(make_repo head-content)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  git -C "$repo" rm -q app/a.ts
  mkdir -p "$repo/app"
  printf 'uncommitted\n' > "$repo/app/new.ts"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'CHANGED=app/a.ts'
  [ "$(printf '%s\n' "$output" | grep -cxF 'CHANGED=app/new.ts')" -eq 0 ]
}

@test "a non-ASCII path survives byte for byte in both lists" {
  local repo name
  repo="$(make_repo non-ascii)"
  name="$(printf 'app/caf\303\251.ts')"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "$name"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "FULL_CHANGED=$name"
  printf '%s\n' "$output" | grep -qxF "CHANGED=$name"
}

# ---------- dirty check ---------------------------------------------------------

@test "a dirty file in the review list prints a DIRTY line; a dirty file outside it does not" {
  local repo
  repo="$(make_repo dirty)"
  commit_file "$repo" other/untouched.md
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  printf 'edit\n' >> "$repo/app/a.ts"
  printf 'edit\n' >> "$repo/other/untouched.md"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'DIRTY= M app/a.ts'
  [ "$(printf '%s\n' "$output" | grep -c 'DIRTY=.*untouched')" -eq 0 ]
  [[ "$stderr" == *"DIRTY IN REVIEW SCOPE"* ]] || return 1
}

@test "a dirty path holding a space prints raw, byte for byte like its CHANGED line" {
  # Porcelain without -z quotes such a path, so a member's remit glob applied
  # to the DIRTY line misses the file its CHANGED line names.
  local repo name
  repo="$(make_repo dirty-space)"
  name="$(printf 'app/my caf\303\251.ts')"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "$name"
  printf 'edit\n' >> "$repo/$name"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "CHANGED=$name"
  printf '%s\n' "$output" | grep -qxF "DIRTY= M $name"
}

@test "a clean review list prints no DIRTY line" {
  local repo
  repo="$(make_repo clean)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^DIRTY=')" -eq 0 ]
}

@test "a status that cannot run reports the failure sentinel rather than a clean tree" {
  local repo shim
  repo="$(make_repo status-fails)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  # A git that fails only `status`, so every other call the script makes runs
  # for real and the sentinel can only come from the dirty check.
  cat > "$shim/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = status ] && exit 128; done
exec $(command -v git) "\$@"
EOF
  chmod +x "$shim/git"
  run --separate-stderr env PATH="$shim:$PATH" "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'DIRTY=dirty-scope check failed'
}

# ---------- capture ---------------------------------------------------------------

@test "the capture is the value audit-scope-digest.sh --read returns, and a re-run returns it unchanged" {
  local repo first second read_back key_base
  repo="$(make_repo capture)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  first="$(value_of "$output" D_SCOPE)"
  key_base="$(value_of "$output" KEY_BASE)"
  [[ "$first" =~ ^[0-9a-f]{64}$ ]] || return 1
  read_back="$("$repo/.gaia/scripts/audit-scope-digest.sh" --read --root "$repo" --member code-audit-maintainer-shell --base "$key_base")"
  [ "$read_back" = "$first" ]
  commit_file "$repo" .gaia/scripts/audit-key-lib.sh
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  second="$(value_of "$output" D_SCOPE)"
  [ "$second" = "$first" ]
}

@test "AUDIT_KEY is empty on a detached HEAD, where the branch half of the key is undeterminable" {
  local repo
  repo="$(make_repo detached)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  git -C "$repo" checkout -q --detach HEAD
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'AUDIT_KEY='
  [ -n "$(value_of "$output" KEY_BASE)" ]
}

# ---------- a diff that cannot list paths ----------------------------------------

# fail_git_diff <dir>: a git shim that fails only `diff`, so the empty list a
# swallowed failure would leave can only come from the diff under test.
fail_git_diff() {
  mkdir -p "$1"
  cat > "$1/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = diff ] && exit 128; done
exec $(command -v git) "\$@"
EOF
  chmod +x "$1/git"
}

@test "a membership diff that fails exits 1 rather than printing an empty FULL_CHANGED" {
  local repo shim
  repo="$(make_repo full-diff-fails)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  shim="$BATS_TEST_TMPDIR/shim-full"
  fail_git_diff "$shim"
  run --separate-stderr env PATH="$shim:$PATH" "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'could not list the whole pull request' <<<"$stderr"
  grep -qF -- 'D_SCOPE=' <<<"$output" && return 1
  true
}

@test "a review diff that fails exits 1 rather than printing an empty CHANGED" {
  local repo shim
  repo="$(make_repo review-diff-fails)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  shim="$BATS_TEST_TMPDIR/shim-review"
  fail_git_diff "$shim"
  run --separate-stderr env PATH="$shim:$PATH" "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base
  [ "$status" -eq 1 ]
  grep -qF -- 'could not list the review increment' <<<"$stderr"
  grep -qF -- 'D_SCOPE=' <<<"$output" && return 1
  true
}

@test "a missing base-provenance resolver exits 1 and names it, rather than resolving a private base" {
  local repo
  repo="$(make_repo no-provenance-lib)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  rm "$repo/.claude/hooks/lib/audit-base-provenance.sh"
  run --separate-stderr "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-maintainer-shell --root "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'base-provenance resolver missing' <<<"$stderr"
  grep -qF -- 'KEY_BASE=' <<<"$output" && return 1
  true
}

# ---------- --eligibility: the default member's waive-eligibility set --------
#
# The eligibility base is the fork point against the branch the pull request
# merges into, resolved by its own ladder, and it is not the membership base:
# an unresolvable one prints empty at status 0, because it costs the default
# member its waive brake and nothing else.

# stacked_repo <name>: HEAD's branch forks from `release`, which forks from
# the advertised default. `app/base-only.ts` belongs to the base branch alone.
stacked_repo() {
  local repo
  repo="$(make_repo "$1")"
  git -C "$repo" checkout -q -b release
  commit_file "$repo" app/base-only.ts
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/feat-only.ts
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/release
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s' "$repo"
}

# gh_shim <dir> <base-ref> <log>: a `gh` whose `pr view` answers <base-ref>
# and records every invocation in <log>.
gh_shim() {
  mkdir -p "$1"
  cat > "$1/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$3"
[ "\$1" = pr ] && printf '%s\n' "$2"
exit 0
SHIM
  chmod +x "$1/gh"
}

@test "--eligibility prints ELIG_BASE after AUDIT_KEY and one ELIG_CHANGED line per whole-PR path, unfiltered" {
  local repo keys
  repo="$(make_repo elig-shape)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  commit_file "$repo" scripts/c.sh
  run --separate-stderr env -u GITHUB_ACTIONS -u GITHUB_BASE_REF PATH="$BATS_TEST_TMPDIR/no-gh:$PATH" \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" \
    --skip-full-base --eligibility --review-path '*.ts'
  [ "$status" -eq 0 ]
  keys="$(printf '%s\n' "$output" | sed -n 's/=.*//p' | awk '!seen[$0]++' | tr '\n' ' ')"
  [ "$keys" = "AUDIT_ROOT BASE_REF BASE_REASON KEY_REF ANCHOR_TREE BASE_SHA KEY_BASE AUDIT_KEY ELIG_BASE D_SCOPE CHANGED ELIG_CHANGED " ]
  [ "$(value_of "$output" ELIG_BASE)" = "$(git -C "$repo" merge-base HEAD main)" ]
  printf '%s\n' "$output" | grep -qxF 'ELIG_CHANGED=app/a.ts'
  printf '%s\n' "$output" | grep -qxF 'ELIG_CHANGED=scripts/c.sh'
  [ "$(printf '%s\n' "$output" | grep -cxF 'CHANGED=scripts/c.sh')" -eq 0 ]
}

@test "without --eligibility no ELIG_ line prints and gh is never called" {
  local repo shim log
  repo="$(stacked_repo elig-off)"
  shim="$BATS_TEST_TMPDIR/gh-off"
  log="$BATS_TEST_TMPDIR/gh-off.log"
  gh_shim "$shim" release "$log"
  run --separate-stderr env -u GITHUB_ACTIONS -u GITHUB_BASE_REF PATH="$shim:$PATH" \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base
  [ "$status" -eq 0 ]
  grep -qF -- 'ELIG_' <<<"$output" && return 1
  [ ! -s "$log" ]
}

@test "--eligibility takes the base from the pull request's own record when Actions declares none" {
  local repo shim log
  repo="$(stacked_repo elig-record)"
  shim="$BATS_TEST_TMPDIR/gh-record"
  log="$BATS_TEST_TMPDIR/gh-record.log"
  gh_shim "$shim" release "$log"
  run --separate-stderr env -u GITHUB_ACTIONS -u GITHUB_BASE_REF PATH="$shim:$PATH" \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base --eligibility
  [ "$status" -eq 0 ]
  grep -qF -- 'pr view' "$log"
  [ "$(value_of "$output" ELIG_BASE)" = "$(git -C "$repo" rev-parse release)" ]
  printf '%s\n' "$output" | grep -qxF 'ELIG_CHANGED=app/feat-only.ts'
  [ "$(printf '%s\n' "$output" | grep -cxF 'ELIG_CHANGED=app/base-only.ts')" -eq 0 ]
}

@test "--eligibility reads GITHUB_BASE_REF under Actions" {
  local repo
  repo="$(stacked_repo elig-actions)"
  run --separate-stderr env GITHUB_ACTIONS=true GITHUB_BASE_REF=release \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base --eligibility
  [ "$status" -eq 0 ]
  [ "$(value_of "$output" ELIG_BASE)" = "$(git -C "$repo" rev-parse release)" ]
  [ "$(printf '%s\n' "$output" | grep -cxF 'ELIG_CHANGED=app/base-only.ts')" -eq 0 ]
}

@test "--eligibility falls back to the advertised default when the declared base has no remote-tracking ref" {
  local repo
  repo="$(stacked_repo elig-unverifiable)"
  run --separate-stderr env GITHUB_ACTIONS=true GITHUB_BASE_REF=no-such-branch \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base --eligibility
  [ "$status" -eq 0 ]
  [ "$(value_of "$output" ELIG_BASE)" = "$(git -C "$repo" merge-base HEAD origin/main)" ]
  printf '%s\n' "$output" | grep -qxF 'ELIG_CHANGED=app/base-only.ts'
}

@test "an unresolvable eligibility base prints ELIG_BASE empty at status 0, with no ELIG_CHANGED line" {
  local repo
  repo="$(make_repo elig-no-base master)"
  run --separate-stderr env -u GITHUB_ACTIONS -u GITHUB_BASE_REF PATH="$BATS_TEST_TMPDIR/no-gh:$PATH" \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base --eligibility
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'ELIG_BASE='
  grep -qF -- 'ELIG_CHANGED=' <<<"$output" && return 1
  grep -qF -- 'no eligibility base' <<<"$stderr"
}

@test "an eligibility diff that fails prints ELIG_BASE empty at status 0 rather than an empty set on a resolved base" {
  local repo shim
  repo="$(make_repo elig-diff-fails)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" app/a.ts
  # Fails only a pathspec-less diff: the review diff always carries `--`.
  shim="$BATS_TEST_TMPDIR/shim-elig"
  mkdir -p "$shim"
  cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
has_diff=0; has_sep=0
for a in "\$@"; do [ "\$a" = diff ] && has_diff=1; [ "\$a" = -- ] && has_sep=1; done
[ "\$has_diff" -eq 1 ] && [ "\$has_sep" -eq 0 ] && exit 128
exec $(command -v git) "\$@"
SHIM
  chmod +x "$shim/git"
  run --separate-stderr env -u GITHUB_ACTIONS -u GITHUB_BASE_REF PATH="$shim:$BATS_TEST_TMPDIR/no-gh:$PATH" \
    "$repo/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$repo" --skip-full-base \
    --eligibility
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'ELIG_BASE='
  grep -qF -- 'could not list the eligibility set' <<<"$stderr"
}
