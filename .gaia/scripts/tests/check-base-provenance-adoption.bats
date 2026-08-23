#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-base-provenance-adoption.sh: the
# spawn oracle, the pull-request merge gate, and the Code Audit Team member
# resolver stay a single-source-of-truth over base provenance only because
# nothing lets that fact drift silently. This suite is what actually fails a
# build when a second definition, a stopped-adopting consumer, or a
# regrown origin-then-local chain lands.
#
# Every test drives the check through its <repo_root> parameter against a
# fixture tree, matching check-resolver-singleton.bats's reasoning: a
# predicate that only ever runs against the healthy real tree has every
# branch it takes be the passing one, so a broken predicate still reports
# green.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-base-provenance-adoption.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-base-provenance-adoption.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-base-provenance-adoption.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# write_baseline <dir>: a healthy tree -- the resolver's definition plus the
# three named consumers, each already adopting it, and no fallback chain
# anywhere. Every "must fail" fixture starts here and mutates one thing.
write_baseline() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/.gaia/scripts"
  cat >"$dir/.claude/hooks/lib/audit-base-provenance.sh" <<'EOF'
#!/usr/bin/env bash
audit_resolve_base_provenance() {
  printf 'unresolvable\tdefault-branch\t\n'
}
EOF
  cat >"$dir/.gaia/scripts/resolve-audit-spawn.sh" <<'EOF'
#!/usr/bin/env bash
prov="$(audit_resolve_base_provenance "$repo_root" default-branch)" || prov=""
EOF
  cat >"$dir/.claude/hooks/pr-merge-audit-check.sh" <<'EOF'
#!/usr/bin/env bash
prov="$(audit_resolve_base_provenance "$tree_root" pr-record "" "$pr_record_base")" || prov=""
EOF
  cat >"$dir/.gaia/scripts/resolve-audit-members.sh" <<'EOF'
#!/usr/bin/env bash
prov="$(audit_resolve_base_provenance "$repo_root" default-branch "$BASE_OVERRIDE")" || prov=""
EOF
  printf 'fixture\n' >"$dir/README.md"
}

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR seeded
# with write_baseline and committed. Files it sees only via `git grep` /
# `git ls-files` require this: a plain directory of files is invisible to
# both, so a fixture skipping this step greens every "must fail" case by
# finding no matches at all.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  write_baseline "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

commit_all() {
  local dir="$1"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m update
}

@test "structural: sourcing the script defines gaia_check_base_provenance_adoption with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_base_provenance_adoption >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: exits 0 with all three assertions satisfied" {
  run gaia_check_base_provenance_adoption "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "audit_resolve_base_provenance definitions found: 1" <<<"$output" || return 1
  grep -qF ".gaia/scripts/resolve-audit-spawn.sh: adopted" <<<"$output" || return 1
  grep -qF ".claude/hooks/pr-merge-audit-check.sh: adopted" <<<"$output" || return 1
  grep -qF ".gaia/scripts/resolve-audit-members.sh: adopted" <<<"$output" || return 1
}

@test "fixture: healthy baseline passes" {
  local repo
  repo="$(make_fixture_repo healthy)"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "fixture: two definitions fails and names both files" {
  local repo
  repo="$(make_fixture_repo two-defs)"
  cat >"$repo/.claude/hooks/lib/second-def.sh" <<'EOF'
#!/usr/bin/env bash
audit_resolve_base_provenance() {
  echo copy
}
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "audit_resolve_base_provenance definitions found: 2" <<<"$output" || return 1
  grep -qF "audit-base-provenance.sh" <<<"$output" || return 1
  grep -qF "second-def.sh" <<<"$output" || return 1
}

@test "fixture: zero definitions fails" {
  local repo
  repo="$(make_fixture_repo zero-defs)"
  rm "$repo/.claude/hooks/lib/audit-base-provenance.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "audit_resolve_base_provenance definitions found: 0" <<<"$output" || return 1
}

@test "fixture: a comment mention is not a second definition" {
  local repo
  repo="$(make_fixture_repo comment-mention)"
  printf '#!/usr/bin/env bash\n# audit_resolve_base_provenance() is the shared resolver\n' >"$repo/.claude/hooks/lib/note.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
  grep -qF "audit_resolve_base_provenance definitions found: 1" <<<"$output" || return 1
}

@test "fixture: a call is not a second definition" {
  local repo
  repo="$(make_fixture_repo a-call)"
  printf '#!/usr/bin/env bash\nx="$(audit_resolve_base_provenance "$root" default-branch)"\n' >"$repo/.claude/hooks/lib/caller.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
  grep -qF "audit_resolve_base_provenance definitions found: 1" <<<"$output" || return 1
}

@test "fixture: a consumer that stopped calling the resolver fails and names it" {
  local repo
  repo="$(make_fixture_repo stopped-calling)"
  printf '#!/usr/bin/env bash\necho no longer adopted\n' >"$repo/.claude/hooks/pr-merge-audit-check.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/pr-merge-audit-check.sh: NOT adopted" <<<"$output" || return 1
}

@test "fixture: a missing consumer fails and names it" {
  local repo
  repo="$(make_fixture_repo missing-consumer)"
  rm "$repo/.gaia/scripts/resolve-audit-members.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".gaia/scripts/resolve-audit-members.sh: MISSING" <<<"$output" || return 1
}

@test "fixture: a re-introduced private chain fails, -C spelling" {
  local repo
  repo="$(make_fixture_repo private-chain-c)"
  cat >"$repo/.claude/hooks/regrown.sh" <<'EOF'
#!/usr/bin/env bash
base=$(git -C "$root" merge-base HEAD "refs/remotes/origin/$d" 2>/dev/null \
  || git -C "$root" merge-base HEAD "$d" 2>/dev/null \
  || true)
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/regrown.sh:2:" <<<"$output" || return 1
}

@test "fixture: a re-introduced private chain fails, bare spelling with no -C" {
  local repo
  repo="$(make_fixture_repo private-chain-bare)"
  cat >"$repo/.claude/hooks/regrown-bare.sh" <<'EOF'
#!/usr/bin/env bash
base=$(git merge-base HEAD "origin/$d" 2>/dev/null \
  || git merge-base HEAD "$d" 2>/dev/null \
  || true)
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/regrown-bare.sh:2:" <<<"$output" || return 1
}

@test "fixture: a re-introduced private chain fails, two independent if blocks (I1)" {
  local repo
  repo="$(make_fixture_repo private-chain-ifblocks)"
  # The spelling the shared resolver itself uses. A detector that only follows
  # a `||` or `\` continuation misses it, and the likeliest way a consumer
  # regrows the ladder is by copying the canonical file, so this shape is the
  # one most worth catching rather than the one least.
  cat >"$repo/.claude/hooks/regrown-ifblocks.sh" <<'EOF'
#!/usr/bin/env bash
resolve() {
  local d="$1" base=""
  if git rev-parse --verify --quiet "refs/remotes/origin/$d" >/dev/null 2>&1; then
    base=$(git merge-base HEAD "refs/remotes/origin/$d" 2>/dev/null)
  fi
  if [ -z "$base" ]; then
    base=$(git merge-base HEAD "$d" 2>/dev/null)
  fi
  printf '%s\n' "$base"
}
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/regrown-ifblocks.sh:" <<<"$output" || return 1
}

@test "fixture: two merge-base calls further apart than the window are not paired" {
  local repo
  repo="$(make_fixture_repo private-chain-window)"
  # The windowed scan must not turn into "any two merge-base calls anywhere in
  # one file", which would flag unrelated derivations sitting in separate
  # functions and make the check useless noise.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'first() { base=$(git merge-base HEAD "refs/remotes/origin/$d" 2>/dev/null); }\n'
    for _ in $(seq 40); do printf '# spacer\n'; done
    printf 'unrelated() { other=$(git merge-base HEAD "$d" 2>/dev/null); }\n'
  } >"$repo/.claude/hooks/far-apart.sh"
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "fixture: the written exemption (worthiness-presence-check.sh) passes and is named as allowed" {
  local repo
  repo="$(make_fixture_repo exemption)"
  cat >"$repo/.claude/hooks/worthiness-presence-check.sh" <<'EOF'
#!/usr/bin/env bash
base=$(git merge-base HEAD "origin/$d" 2>/dev/null \
  || git merge-base HEAD "$d" 2>/dev/null \
  || true)
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
  grep -qF ".claude/hooks/worthiness-presence-check.sh:2:" <<<"$output" || return 1
  grep -qF "(allowed carrier)" <<<"$output" || return 1
}

@test "fixture: the real single-call shapes are not flagged" {
  local repo
  repo="$(make_fixture_repo single-call-shapes)"
  cat >"$repo/.claude/hooks/lib/single-calls.sh" <<'EOF'
#!/usr/bin/env bash
merge_base="$(git -C "$repo_root" merge-base HEAD refs/remotes/origin/main 2>/dev/null || true)"
git -C "$root" merge-base --is-ancestor "$sha" HEAD >/dev/null 2>&1 || rc=$?
EOF
  commit_all "$repo"
  run gaia_check_base_provenance_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "usage: no repo_root and not a git repository exits 2" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"
  run bash -c 'cd "$1" && bash "$2"' _ "$dir" "$CHECK"
  [ "$status" -eq 2 ]
}
