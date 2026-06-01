#!/usr/bin/env bats

# Tests for .github/audit/resolve-check-base.sh.
#
# The helper is consumed by required-check workflows (e.g. tests.yml's "Vitest
# and Playwright" gate). It emits a single line: the most recent PR ancestor of
# HEAD on which the named check concluded SUCCESS, or the main ref for a
# full-scope fallback.
#
# Like resolve-audit-base.bats, each test runs in an isolated `git init`'d temp
# dir whose HEAD sits on a FEATURE branch off `main`, so the merge-base bound
# leaves the branch's own commits walkable. There is no `origin` remote, so the
# fallback main ref resolves to the local `main` branch ("main").
#
# The Checks API path is mocked via a fake `gh` on a prepended PATH. The mock
# is keyed by "sha=check-name" pairs: it prints the success count (1) only when
# BOTH the queried SHA (in the URL) and the check name (embedded in the --jq
# filter) appear in the call's args, else 0. This exercises the name filter.
#
# Coverage:
#   1. No green check on any PR commit            → main ref (fallback)
#   2. Green check on parent                      → that parent SHA
#   3. Non-green parent, green grandparent        → grandparent (last GREEN)
#   4. Newest of several green commits wins        → newest green SHA
#   5. Green check on HEAD itself is never base   → main ref
#   6. Single-commit PR (only HEAD)               → main ref
#   7. No gh / no token (API unreachable)         → main ref
#   8. A different check's green is ignored        → main ref (name filter)
#   9. Missing check-name argument                → main ref

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../resolve-check-base.sh"
  [ -x "$SCRIPT" ] || skip "resolve-check-base.sh not executable"

  CHECK="Vitest and Playwright"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the PR branch diverges from here.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" checkout --quiet -b feature

  # Default: gh reachable with a token, but no green checks mapped yet.
  install_gh_mock
}

# Run the script (default check name) with cwd inside the sandbox.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$CHECK" )
}

# Run the script with an explicit (or empty) check-name argument.
run_in_sandbox_named() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# Add a commit on the feature branch. $1 = file/commit marker.
add_commit() {
  local marker="$1"
  echo "$marker" > "$SANDBOX/${marker}.txt"
  git -C "$SANDBOX" add "${marker}.txt"
  git -C "$SANDBOX" commit --quiet -m "$marker"
}

sha_of() {
  git -C "$SANDBOX" rev-parse "$1"
}

# Install a fake `gh`. $@ = "sha=check-name" pairs, each meaning "this commit
# has a green (success) check-run with this name". The mock prints 1 when both
# the SHA and the name appear in the call args (the SHA in the URL path, the
# name in the --jq filter), else 0 — mirroring `[...] | length` on the real API.
install_gh_mock() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  MAP="$BATS_TEST_TMPDIR/gh-check-map"
  mkdir -p "$GH_BIN"
  : > "$MAP"
  for pair in "$@"; do
    printf '%s\n' "$pair" >> "$MAP"
  done
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
# Mock: resolve-check-base calls
#   gh api repos/<repo>/commits/<sha>/check-runs?per_page=100 --jq '[...] | length'
args="\$*"
while IFS= read -r line; do
  sha="\${line%%=*}"
  name="\${line#*=}"
  case "\$args" in
    *"\$sha"*)
      case "\$args" in
        *"\$name"*) printf '1\n'; exit 0 ;;
      esac
      ;;
  esac
done < "$MAP"
printf '0\n'
exit 0
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# -----------------------------------------------------------------------------
# 1. No green check on any PR commit → main ref
# -----------------------------------------------------------------------------

@test "no green check on any PR commit → main ref" {
  add_commit a
  add_commit b
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 2. Green check on the parent → that parent SHA. (A skipped-but-green run is
#    indistinguishable here — its job check-run is also conclusion=success.)
# -----------------------------------------------------------------------------

@test "green check on parent → parent SHA" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
}

# -----------------------------------------------------------------------------
# 3. Non-green parent, green grandparent → grandparent (last GREEN, not last
#    run). A failed/cancelled run on the parent leaves no green signal.
# -----------------------------------------------------------------------------

@test "non-green parent with green grandparent → grandparent SHA" {
  add_commit a
  green="$(sha_of HEAD)"
  add_commit b
  # b has no green check (simulating a failed/cancelled run).
  install_gh_mock "${green}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$green" ]
}

# -----------------------------------------------------------------------------
# 4. Newest green commit wins over an older green commit
# -----------------------------------------------------------------------------

@test "newest green commit wins over an older green commit" {
  add_commit a
  older="$(sha_of HEAD)"
  add_commit b
  newer="$(sha_of HEAD)"
  add_commit c
  install_gh_mock "${older}=${CHECK}" "${newer}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$newer" ]
  [ "$output" != "$older" ]
}

# -----------------------------------------------------------------------------
# 5. A green check on HEAD itself is never chosen as its own base
# -----------------------------------------------------------------------------

@test "green check on HEAD is not used as its own base" {
  add_commit a
  head="$(sha_of HEAD)"
  install_gh_mock "${head}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 6. Single-commit PR (HEAD is the only commit past merge-base) → main ref
# -----------------------------------------------------------------------------

@test "single-commit PR → main ref" {
  add_commit a
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 7. No gh / no token → API unreachable → main ref
# -----------------------------------------------------------------------------

@test "no GH_TOKEN → API unreachable → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  # A green check exists in principle, but without GH_TOKEN the helper never
  # queries it.
  install_gh_mock "${base}=${CHECK}"
  unset GH_TOKEN || true
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 8. A different check's green is ignored (name filter) → main ref
# -----------------------------------------------------------------------------

@test "green check for a different context is ignored → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=Some Other Check"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# 9. Missing check-name argument → main ref
# -----------------------------------------------------------------------------

@test "missing check-name argument → main ref" {
  add_commit a
  base="$(sha_of HEAD)"
  add_commit b
  install_gh_mock "${base}=${CHECK}"
  run run_in_sandbox_named
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}
