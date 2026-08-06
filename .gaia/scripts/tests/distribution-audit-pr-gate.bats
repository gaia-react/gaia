#!/usr/bin/env bats
# Behavioural tests for the Distribution Audit (PR) gate, the required check in
# .github/workflows/distribution-audit-pr.yml that fails a pull request
# introducing a newly-shipping file the committed .gaia/manifest.json does not
# answer.
#
# The tests EXECUTE the step's real `run:` body, extracted from the workflow
# YAML, against a sandbox git repository with a mocked
# `.gaia/cli/gaia-maintainer` standing in for the release CLI. That is the same
# technique .github/audit/tests/ci-status-member-gate.bats uses on
# code-review-audit.yml: the workflow is the source under test, not a file these
# assertions merely grep.
#
# The local PreToolUse mirror of this gate
# (.claude/hooks/distribution-preflight-check.sh) is covered by its own suite,
# .gaia/tests/hooks/distribution-preflight-check.bats. The two gates are
# deliberately kept in agreement, and the encoding test below has a counterpart
# there for exactly that reason: a fix to one that misses the other leaves the
# authority and its early warning disagreeing about the same input.
#
# The extracted body writes /tmp/pr-changed.txt and /tmp/missing.txt, the paths
# the workflow itself uses. That is the shipped code running unmodified, which
# is the point; nothing else in this repo's suites reads those two names.
#
# Assertion style (.claude/rules/bats-assertions.md): POSIX `[ ]` and `grep -qF`
# for presence; a positive match plus an explicit `return 1` for absence, since a
# `!`-negated non-final line never fails a test under `set -e`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/distribution-audit-pr.yml"
  [ -f "$WORKFLOW" ] || skip "distribution-audit-pr.yml not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  command -v git >/dev/null 2>&1 || skip "git not available"

  SANDBOX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  # `core.quotePath` is pinned rather than inherited throughout: it is git's
  # DEFAULT and the condition the encoding test makes a claim about, so a
  # maintainer who turns it off in ~/.gitconfig would otherwise green against
  # the bug itself.
  git -C "$SANDBOX" config core.quotePath true

  printf 'base\n' > "$SANDBOX/base.txt"
  git -C "$SANDBOX" add base.txt
  git -C "$SANDBOX" commit --quiet -m "base"
  git -C "$SANDBOX" checkout --quiet -b feature
}

# commit_file PATH: add one file on the feature branch.
commit_file() {
  local path="$1"
  printf 'ship\n' > "$SANDBOX/$path"
  git -C "$SANDBOX" add "$path"
  git -C "$SANDBOX" commit --quiet -m "add $path"
}

# install_maintainer_mock MISSING_JSON: write an executable
# .gaia/cli/gaia-maintainer inside the sandbox that prints a
# `release manifest --check --json` report. Exit 1, because that is what the
# real CLI does on any drift and the step treats exit < 2 as a usable report.
install_maintainer_mock() {
  local missing="$1"
  mkdir -p "$SANDBOX/.gaia/cli"
  printf '%s' "$missing" > "$SANDBOX/.gaia/missing.json"
  cat > "$SANDBOX/.gaia/cli/gaia-maintainer" <<'EOF'
#!/usr/bin/env bash
printf '{"missing":%s}' "$(cat "$(dirname "$0")/../missing.json")"
exit 1
EOF
  chmod +x "$SANDBOX/.gaia/cli/gaia-maintainer"
}

# Extract the gate step's `run:` shell body from the workflow YAML and dedent it.
# Matches the `- name:` line EXACTLY and stops at the next one, so a sibling step
# added later cannot bleed into the body under test.
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

# Extraction guard, run before every assertion that executes the body. A change
# to the step's name or indentation empties the awk capture, and a body that is
# empty or truncated exits 0 doing nothing -- which reads as a PASSING gate here,
# greening every test in this file on the check they exist to hold. Anchor on two
# lines the step cannot lose while still being the gate.
gate_body() {
  local body
  body="$(extract_step_body 'Gate unanswered newly-shipping files')" || {
    echo "could not extract the gate step's run: body from $WORKFLOW" >&2
    return 1
  }
  grep -qF 'release manifest --check --json' "$body" || {
    echo "extracted body does not invoke the manifest checker; the capture is truncated" >&2
    return 1
  }
  grep -qF 'comm -12' "$body" || {
    echo "extracted body does not intersect missing with changed; the capture is truncated" >&2
    return 1
  }
  printf '%s' "$body"
}

# Run the extracted body in the sandbox with the env the pull_request trigger
# binds, so the workflow_dispatch fallback (which fetches origin) never fires.
run_gate() {
  local body="$1"
  ( cd "$SANDBOX" \
    && BASE_SHA="$(git -C "$SANDBOX" rev-parse main)" \
       HEAD_SHA="$(git -C "$SANDBOX" rev-parse HEAD)" \
       bash "$body" )
}

# ---- the gate reaches its verdict at all -------------------------------

@test "fails on a newly-shipping file with no answer in the manifest" {
  commit_file "shipped.txt"
  install_maintainer_mock '[{"file":"shipped.txt"}]'
  run run_gate "$(gate_body)"
  [ "$status" -eq 1 ]
  grep -qF 'shipped.txt' <<<"$output" || return 1
  grep -qF '1 newly-shipping file(s)' <<<"$output" || return 1
}

@test "passes when the report answers every file this PR changes" {
  commit_file "shipped.txt"
  install_maintainer_mock '[]'
  run run_gate "$(gate_body)"
  [ "$status" -eq 0 ]
}

@test "passes when the unanswered file is not this PR's own change" {
  # An inherited manifest backlog is not this PR's to drain, so a `missing`
  # entry the PR never touched must not fail it. Pins that the two sides really
  # are intersected rather than the `missing` set being failed on whole, which
  # is what makes the encoding test below a test of the INTERSECTION.
  commit_file "shipped.txt"
  install_maintainer_mock '[{"file":"unrelated.txt"}]'
  run run_gate "$(gate_body)"
  [ "$status" -eq 0 ]
}

# ---- path encoding -----------------------------------------------------

# Under git's default `core.quotePath`, `git diff --name-only` C-quotes any path
# carrying non-ASCII or control bytes: it wraps the path in double quotes and
# backslash-escapes the offending bytes, emitting the quotes as literal
# characters. The `missing` set reaches the same intersection through `jq -r`,
# which emits raw bytes, so the two sides speak different encodings for exactly
# the paths at issue. `comm -12` matches nothing, `offenders` comes back empty,
# and this required check reports GREEN for a newly-shipping file that carries no
# ship-or-withhold answer. A green is also what a correctly-answered PR produces,
# so by then the failure is indistinguishable from an ordinary pass.
@test "fails when the unanswered path carries non-ASCII bytes" {
  commit_file "café.txt"
  install_maintainer_mock '[{"file":"café.txt"}]'
  run run_gate "$(gate_body)"
  [ "$status" -eq 1 ]
  grep -qF 'café.txt' <<<"$output" || return 1
  # Non-vacuity: the same repository and the same range through the pre-fix
  # spelling. Without it a sandbox whose path was quietly all-ASCII would pass
  # while proving nothing. No path this sandbox commits contains a double quote,
  # so a quote in this list can only be git's own.
  local quoted
  quoted="$(git -C "$SANDBOX" diff --name-only --diff-filter=ACMR "main...HEAD")"
  grep -qF '"' <<<"$quoted" || {
    printf 'the pre-fix spelling did not quote, so this sandbox proves nothing: %s\n' "$quoted"
    return 1
  }
}

# ---- the extraction guard is not hollow --------------------------------

@test "the extraction guard rejects a workflow whose gate step is renamed" {
  local doctored
  doctored="$BATS_TEST_TMPDIR/doctored.yml"
  sed 's/^      - name: Gate unanswered newly-shipping files$/      - name: Something else entirely/' \
    "$WORKFLOW" > "$doctored"
  WORKFLOW="$doctored"
  run gate_body
  [ "$status" -eq 1 ]
  grep -qF 'could not extract' <<<"$output" || return 1
}
