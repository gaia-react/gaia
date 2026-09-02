#!/usr/bin/env bats

# Guards the base-sha resolution in the "Resolve audit base" step of
# .github/workflows/code-review-audit.yml.
#
# That step turns the ref name resolve-audit-base.sh hands back into a 40-hex
# sha, because audit-scope-digest.sh builds its scope-file path from the value
# and a slash in a ref name escapes into that path. When the ref does not
# resolve at all -- an adopter whose default branch is not `main`, on a run
# where the helper itself failed and the hardcoded `origin/main` fallback took
# over -- the step must exit non-zero naming the ref, rather than handing a
# junk base downstream.
#
# WHY THIS SUITE EXISTS. The guard shipped unreachable. The fallback was a bare
# `git rev-parse "${base}^{commit}"`, and `git rev-parse` ECHOES an unresolved
# argument on STDOUT before exiting 128, so the command substitution captured
# the literal string `origin/main^{commit}`. That is non-empty, so `[ -z ]`
# never fired, the `exit 1` was dead code, and the diagnostic never printed. No
# test drove the step body, so nothing caught it. The repair is `--verify
# --quiet`, which prints nothing and exits 1. This suite is the adversarial
# fixture for the repaired guard: it drives the REAL step body extracted from
# the workflow YAML against a sandbox repo, so it exercises shipped code rather
# than grepping for a flag.
#
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  echo "base" > "$SANDBOX/file.txt"
  git -C "$SANDBOX" add file.txt
  git -C "$SANDBOX" commit --quiet -m "init"
  BASE_COMMIT="$(git -C "$SANDBOX" rev-parse HEAD)"

  # A second commit, so `merge-base <first> HEAD` has a real answer to give and
  # the resolvable arm is not silently testing `merge-base HEAD HEAD`.
  echo "more" >> "$SANDBOX/file.txt"
  git -C "$SANDBOX" commit --quiet -am "second"

  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  : > "$GITHUB_OUTPUT"
  export GITHUB_OUTPUT
}

# The step resolves its base through this helper, at the path the extracted
# body invokes relative to cwd (the sandbox). Stubbed so each test picks the
# ref the guard is driven with.
stub_resolver() {
  mkdir -p "$SANDBOX/.github/audit"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" \
    > "$SANDBOX/.github/audit/resolve-audit-base.sh"
  chmod +x "$SANDBOX/.github/audit/resolve-audit-base.sh"
}

# Pull one step's `run:` body out of code-review-audit.yml, dedented. Matches
# the `      - name:` step header exactly, so a sibling step whose name is a
# prefix of this one cannot be picked up instead.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

run_step() {
  ( cd "$SANDBOX" && bash "$1" )
}

@test "harness: the step body extracts and carries the base_sha resolution" {
  body="$(extract_step_body 'Resolve audit base')"
  grep -qF 'base_sha=' "$body"
  grep -qF 'could not resolve' "$body"
}

@test "adversarial: an unresolvable base exits non-zero and names the ref" {
  body="$(extract_step_body 'Resolve audit base')"
  stub_resolver 'origin/does-not-exist'

  run run_step "$body"
  [ "$status" -ne 0 ]
  grep -qF "could not resolve 'origin/does-not-exist' to a base sha" <<<"$output"
  # The junk value never reaches a consumer: no base_sha line was published.
  grep -qE '^base_sha=' "$GITHUB_OUTPUT" && return 1
  return 0
}

@test "non-vacuity: a resolvable base publishes a 40-hex base_sha and exits 0" {
  body="$(extract_step_body 'Resolve audit base')"
  stub_resolver "$BASE_COMMIT"

  run run_step "$body"
  [ "$status" -eq 0 ]

  grep -qE '^base_sha=[0-9a-f]{40}$' "$GITHUB_OUTPUT"
  grep -qF "base_sha=${BASE_COMMIT}" "$GITHUB_OUTPUT"
}

@test "a ref NAME resolves to a sha, which is what keeps a slash out of the scope path" {
  body="$(extract_step_body 'Resolve audit base')"
  git -C "$SANDBOX" branch --quiet trunk "$BASE_COMMIT"
  stub_resolver 'trunk'

  run run_step "$body"
  [ "$status" -eq 0 ]

  # `base` keeps the readable ref for the diff prose...
  grep -qF 'base=trunk' "$GITHUB_OUTPUT"
  # ...while base_sha is the hex the digest keys on, with no slash to escape.
  grep -qE '^base_sha=[0-9a-f]{40}$' "$GITHUB_OUTPUT"
}

@test "the fallback carries --verify --quiet in all three byte-identical copies" {
  # The structural half. A regression to the bare `git rev-parse` spelling
  # restores exactly the unreachable guard this suite exists for, and the three
  # copies must not drift apart on it.
  local f seen=0
  for f in \
    "$REPO_ROOT/.github/workflows/code-review-audit.yml" \
    "$REPO_ROOT/.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl" \
    "$REPO_ROOT/.gaia/cli/templates/workflows/code-review-audit.yml.tmpl"
  do
    [ -f "$f" ] || continue
    seen=$(( seen + 1 ))
    grep -qF 'git rev-parse --verify --quiet "${base}^{commit}"' "$f"
    grep -qF 'git rev-parse "${base}^{commit}"' "$f" && return 1
  done
  # The input-set half, per .claude/rules/guards-must-fail.md: without it a
  # renamed or moved copy is skipped by the `-f` test and this test passes over
  # an empty set, which is indistinguishable from passing over all three.
  [ "$seen" -eq 3 ]
}
