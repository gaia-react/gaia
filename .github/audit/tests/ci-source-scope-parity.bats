#!/usr/bin/env bats

# Guards the "Check for source-code changes" step of
# .github/workflows/code-review-audit.yml against drifting from the Code Audit
# Team roster's default member.
#
# That step decides `has_source`, and `has_source == 'false'` is the path on
# which CI posts the out-of-scope `GAIA-Audit` success carrying the FRONTEND
# member's content digest. The local merge hook accepts that status as the
# default member's clearance, so any path `code-audit-frontend` owns that the
# step reads as out of scope merges with no member having read it.
#
# WHY THIS SUITE EXISTS. The ownerless-path triage granted `.playwright/**` and
# seven root tooling files (Dockerfile, .npmrc, ...) to `code-audit-frontend` in
# .gaia/audit-ci.yml without widening the step's patterns, and PR #2334 (a
# Dockerfile change) received an out-of-scope success for a diff the resolver
# said the frontend member owed. The step stays a workflow-local grep pair
# (.gaia/tests/hooks/audit-scope-lib.bats pins that), so the two lists are
# hand-kept in step and this suite is what holds them there: it derives one
# concrete path from EVERY glob the roster grants `code-audit-frontend`, drives
# the REAL step body extracted from the workflow YAML against a sandbox commit
# touching that path, and asserts `has_source=true`.
#
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  ROSTER="$REPO_ROOT/.gaia/audit-ci.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"
  [ -f "$ROSTER" ] || skip ".gaia/audit-ci.yml not found"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "init"
  BASE_COMMIT="$(git -C "$SANDBOX" rev-parse HEAD)"

  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_OUTPUT
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

# The globs the roster grants `code-audit-frontend`, one per line, unquoted.
# Reads only that entry's `globs:` list and stops at its next key, so a sibling
# member's globs cannot leak in.
frontend_globs() {
  awk '
    /^  - name: / { in_member = ($3 == "code-audit-frontend"); in_globs = 0; next }
    in_member && /^    globs:/ { in_globs = 1; next }
    in_member && in_globs && /^      - / {
      g = $0
      sub(/^      - /, "", g)
      gsub(/"/, "", g)
      print g
      next
    }
    in_member && in_globs && /^    [a-z_]+:/ { in_globs = 0 }
  ' "$ROSTER"
}

# One concrete path a glob matches: each `**` and `*` becomes a literal
# segment. `app/**` -> `app/x`, `*.config.ts` -> `x.config.ts`,
# `tsconfig*.json` -> `tsconfigx.json`.
concrete_path() {
  local g="$1"
  g="${g//\*\*/x}"
  g="${g//\*/x}"
  printf '%s' "$g"
}

# has_source_for <path>: commit <path> on a branch cut from the base commit, run
# the extracted step against it, and print the has_source value it published.
has_source_for() {
  local body="$1" path="$2"
  git -C "$SANDBOX" checkout --quiet -B probe "$BASE_COMMIT"
  mkdir -p "$SANDBOX/$(dirname "$path")"
  echo "change" > "$SANDBOX/$path"
  git -C "$SANDBOX" add -- "$path"
  git -C "$SANDBOX" commit --quiet -m "touch $path"
  : > "$GITHUB_OUTPUT"
  ( cd "$SANDBOX" && AUDIT_BASE="$BASE_COMMIT" bash "$body" ) || return 1
  sed -n 's/^has_source=//p' "$GITHUB_OUTPUT"
}

@test "harness: the step body extracts and publishes has_source" {
  body="$(extract_step_body 'Check for source-code changes')"
  grep -qF 'has_source=true' "$body"
  grep -qF 'has_source=false' "$body"
}

@test "harness: the roster yields the frontend member's globs" {
  globs="$(frontend_globs)"
  # The input-set half, per .claude/rules/guards-must-fail.md: an awk that
  # matched nothing would let the parity test below pass over an empty set.
  grep -qxF 'app/**' <<<"$globs"
  grep -qxF 'Dockerfile' <<<"$globs"
  [ "$(grep -c . <<<"$globs")" -ge 20 ]
}

@test "non-vacuity: a path no member owns reads has_source=false" {
  body="$(extract_step_body 'Check for source-code changes')"
  result="$(has_source_for "$body" 'wiki/notes.md')"
  [ "$result" = "false" ]
}

@test "parity: every glob the roster grants code-audit-frontend reads has_source=true" {
  body="$(extract_step_body 'Check for source-code changes')"
  fail=0
  seen=0
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    seen=$((seen + 1))
    path="$(concrete_path "$glob")"
    result="$(has_source_for "$body" "$path")"
    if [ "$result" != "true" ]; then
      echo "SCOPE DRIFT: roster glob '$glob' (probe path '$path') reads has_source=${result:-<none>}" >&2
      fail=$((fail + 1))
    fi
  done < <(frontend_globs)
  [ "$seen" -ge 20 ]
  [ "$fail" -eq 0 ]
}
