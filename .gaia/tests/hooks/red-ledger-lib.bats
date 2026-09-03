#!/usr/bin/env bats

# Tests for the RED-ledger foundation: the Node signal helper
# (.gaia/scripts/red-ledger/extract-test-signals.mjs) and the shared shell lib
# (.claude/hooks/lib/red-ledger.sh) that both RED hooks source.
#
# The signal helper parses a TS/TSX test file and emits one
# {"fullName","signal"} line per test/it call. The shell lib provides the
# ledger path, repo-relative path normalization, and a thin wrapper that runs
# the helper. These tests exercise both against the fixture test files under
# fixtures/red-ledger/.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT"
  HELPER="$REPO_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  LIB="$REPO_ROOT/.claude/hooks/lib/red-ledger.sh"

  # Repo-relative fixture paths (helper + lib expect repo-relative input run
  # from the repo root).
  FIX_REL=".gaia/tests/hooks/fixtures/red-ledger"

  # The ledger path is keyed to the repo's own tree key; ask the shipped
  # resolver for it rather than hardcoding a second copy of the literal.
  TREE_KEY=$(bash "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" --tree-key "$REPO_ROOT")
}

# Run the Node helper from the repo root with a repo-relative fixture path.
run_helper() {
  run bash -c "cd '$REPO_ROOT' && node '$HELPER' '$1'"
}

# Feed the file's bytes through --stdin. run_helper takes no trailing argv, so
# the stdin leg needs its own runner; both must reach the same helper.
run_helper_stdin() {
  run bash -c "cd '$REPO_ROOT' && cat '$1' | node '$HELPER' '$1' --stdin"
}

# Source the lib in a clean shell and run a function, from the repo root.
run_lib() {
  run bash -c "cd '$REPO_ROOT' && set -uo pipefail && . '$LIB' && $1"
}

# --- signal helper: fullName ---

@test "helper emits the bare title for a top-level test" {
  run_helper "$FIX_REL/top-level.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"adds two numbers"'* ]]
}

@test "helper joins nested describe titles with the test title" {
  run_helper "$FIX_REL/nested-describe.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"outer inner does a thing"'* ]]
}

# --- signal helper: distinct tests, distinct signals ---

@test "two tests in one file yield two lines with distinct signals" {
  run_helper "$FIX_REL/two-tests.test.ts"
  [ "$status" -eq 0 ]
  # Two output lines.
  [ "$(printf '%s\n' "$output" | grep -c '"fullName"')" -eq 2 ]
  local sig1 sig2
  sig1=$(printf '%s\n' "$output" | sed -n '1p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  sig2=$(printf '%s\n' "$output" | sed -n '2p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  [ -n "$sig1" ]
  [ -n "$sig2" ]
  [ "$sig1" != "$sig2" ]
}

@test "every signal carries the sha256: prefix" {
  run_helper "$FIX_REL/two-tests.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"signal":"sha256:'* ]]
}

# --- signal helper: stability under reformatting, change on edit ---

@test "reformatting-only edit yields the same signal" {
  run_helper "$FIX_REL/stable-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/stable-b.test.ts"
  [ "$status" -eq 0 ]
  local sig_b
  sig_b=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" = "$sig_b" ]
}

@test "changing an assertion literal yields a different signal" {
  run_helper "$FIX_REL/stable-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/changed.test.ts"
  [ "$status" -eq 0 ]
  local sig_changed
  sig_changed=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" != "$sig_changed" ]
}

# --- signal helper: kind classification ---

@test "helper tags an expectTypeOf-only test kind=type-only" {
  run_helper "$FIX_REL/kind-type-only.test.ts"
  [ "$status" -eq 0 ]
  local kind
  kind=$(printf '%s\n' "$output" \
    | jq -r 'select(.fullName=="type proof via expectTypeOf") | .kind')
  [ "$kind" = "type-only" ]
}

@test "helper tags a @ts-expect-error-only test kind=type-only" {
  run_helper "$FIX_REL/kind-type-only.test.ts"
  [ "$status" -eq 0 ]
  local kind
  kind=$(printf '%s\n' "$output" \
    | jq -r 'select(.fullName=="type proof via ts-expect-error") | .kind')
  [ "$kind" = "type-only" ]
}

@test "helper tags a plain runtime test kind=runtime" {
  run_helper "$FIX_REL/top-level.test.ts"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.kind')" = "runtime" ]
}

@test "helper tags both mixed runtime+type tests kind=runtime" {
  run_helper "$FIX_REL/kind-mixed.test.ts"
  [ "$status" -eq 0 ]
  # Two tests, and every one classifies runtime (a runtime assertion present
  # alongside a type-level proof is still runtime, never type-only).
  [ "$(printf '%s\n' "$output" | grep -c '"fullName"')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | jq -r '.kind' | sort -u)" = "runtime" ]
}

# --- signal helper: exit codes ---

@test "helper exits 0 with no output on a valid file with no tests" {
  run_helper "$FIX_REL/no-tests.test.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helper exits non-zero with a stderr message on a broken file" {
  run_helper "$FIX_REL/broken.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extract-test-signals"* ]]
}

@test "helper exits non-zero when the argument is missing" {
  run bash -c "cd '$REPO_ROOT' && node '$HELPER'"
  [ "$status" -ne 0 ]
}

@test "helper resolves typescript from node_modules" {
  run bash -c "cd '$REPO_ROOT' && node -e 'require(\"typescript\")'"
  [ "$status" -eq 0 ]
}

# A reader that stops early closes the pipe under the helper's feet. Without an
# EPIPE listener on process.stdout, node raises Unhandled 'error' event, prints
# a stack trace, and exits 1. The fixture has to out-write the 64KB pipe buffer
# for the close to land mid-write; a small one drains in a single flush and the
# assertion passes even unguarded.
@test "helper exits 0 quietly when a large output meets an early-closing reader" {
  local big="$BATS_TEST_TMPDIR/big.test.ts"
  seq 1 3000 |
    awk '{printf "test(\"generated case %s\", () => {\n  expect(%s).toBe(%s);\n});\n", $1, $1, $1}' \
      >"$big"

  # The full output must clear the buffer, else the early close proves nothing.
  run bash -c "cd '$REPO_ROOT' && node '$HELPER' '$big' | wc -c"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr -d '[:space:]')" -gt 65536 ]

  # stderr has to be captured from the same run whose stdout is closed early;
  # sending stdout elsewhere to read stderr would remove the EPIPE entirely.
  local err="$BATS_TEST_TMPDIR/epipe.err"
  run bash -c "cd '$REPO_ROOT' && node '$HELPER' '$big' 2>'$err' | head -c 100 >/dev/null; echo \"\${PIPESTATUS[0]}\""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [ ! -s "$err" ]
}

# --- shell lib: red_ledger_path ---

@test "red_ledger_path with an explicit root joins it onto the tree-keyed ledger path" {
  run_lib "red_ledger_path '$REPO_ROOT'"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/.gaia/local/red-ledger/$TREE_KEY/observations.jsonl" ]
}

@test "red_ledger_path with no root defaults to gaia_resolve_tree_root of the process cwd, keyed the same way" {
  run_lib 'red_ledger_path'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/.gaia/local/red-ledger/$TREE_KEY/observations.jsonl" ]
}

# --- shell lib: red_ledger_repo_rel ---

@test "red_ledger_repo_rel strips the repo-root prefix from an absolute path" {
  run_lib "red_ledger_repo_rel '$REPO_ROOT/$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

@test "red_ledger_repo_rel strips a leading ./" {
  run_lib "red_ledger_repo_rel './$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

@test "red_ledger_repo_rel is idempotent on an already-relative path" {
  run_lib "red_ledger_repo_rel '$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

# --- shell lib: red_ledger_signals ---

@test "red_ledger_signals returns the helper NDJSON for a valid fixture" {
  run_lib "red_ledger_signals '$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"adds two numbers"'* ]]
  [[ "$output" == *'"signal":"sha256:'* ]]
}

@test "red_ledger_signals propagates the helper non-zero exit on a broken file" {
  run_lib "red_ledger_signals '$FIX_REL/broken.test.ts'"
  [ "$status" -ne 0 ]
}

# --- double-sourcing is safe ---

@test "sourcing the lib twice is a no-op" {
  run bash -c "cd '$REPO_ROOT' && set -uo pipefail && . '$LIB' && . '$LIB' && red_ledger_path '$REPO_ROOT'"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/.gaia/local/red-ledger/$TREE_KEY/observations.jsonl" ]
}

# --- signal helper: comment-free content, fixture pairs ---

@test "a comment-only edit does not rotate the signal, and pins to a known digest" {
  run_helper "$FIX_REL/comment-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/comment-b.test.ts"
  [ "$status" -eq 0 ]
  local sig_b
  sig_b=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" = "$sig_b" ]
  [ "$sig_a" = "sha256:26fd52ef906dbbdbd213a15316025420b2b317022ed2572db0e5a68b14e5d754" ]
}

@test "an assertion absorbed into a comment rotates the signal, and pins each side" {
  run_helper "$FIX_REL/absorb-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/absorb-b.test.ts"
  [ "$status" -eq 0 ]
  local sig_b
  sig_b=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" != "$sig_b" ]
  [ "$sig_a" = "sha256:36440c7f57cac008007a29ed7f02227095071ecd3b1358fc430b19eaaa377ac2" ]
  [ "$sig_b" = "sha256:4713b19b36a174404558498a550b42e4a446ef8cd6c051f2f0565875c7abbefd" ]
}

@test "a tight inline comment does not fuse its neighbours" {
  # fusion-pair.test.ts holds two tests sharing one title on purpose: two
  # differently-titled tests always differ by title alone, which would make
  # this check vacuous, so the two records are read positionally.
  run_helper "$FIX_REL/fusion-pair.test.ts"
  [ "$status" -eq 0 ]
  local sig1 sig2
  sig1=$(printf '%s\n' "$output" | sed -n '1p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  sig2=$(printf '%s\n' "$output" | sed -n '2p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  [ -n "$sig1" ]
  [ -n "$sig2" ]
  [ "$sig1" != "$sig2" ]
}

@test "a relocated @ts-expect-error directive keeps type-only and does not rotate the signal" {
  run_helper "$FIX_REL/directive-a.test.ts"
  [ "$status" -eq 0 ]
  local kind_a sig_a
  kind_a=$(printf '%s\n' "$output" | jq -r 'select(.fullName=="directive relocates") | .kind')
  sig_a=$(printf '%s\n' "$output" | jq -r 'select(.fullName=="directive relocates") | .signal')

  run_helper "$FIX_REL/directive-b.test.ts"
  [ "$status" -eq 0 ]
  local kind_b sig_b
  kind_b=$(printf '%s\n' "$output" | jq -r 'select(.fullName=="directive relocates") | .kind')
  sig_b=$(printf '%s\n' "$output" | jq -r 'select(.fullName=="directive relocates") | .signal')

  [ "$kind_a" = "type-only" ]
  [ "$kind_b" = "type-only" ]
  [ -n "$sig_a" ]
  [ "$sig_a" = "$sig_b" ]
}

# --- signal helper: `//` inside code vs a genuine comment, four positions ---

@test "a slash-doubled code position rotates on mutation and holds on reword, all four positions" {
  local title sig_base sig_mutated sig_reworded
  for title in "slash in a string literal" "slash in a template literal" \
    "slash in a regular expression" "slash in jsx text"; do
    run_helper "$FIX_REL/slash-base.test.tsx"
    [ "$status" -eq 0 ]
    sig_base=$(printf '%s\n' "$output" | jq -r --arg n "$title" 'select(.fullName==$n) | .signal')

    run_helper "$FIX_REL/slash-mutated.test.tsx"
    [ "$status" -eq 0 ]
    sig_mutated=$(printf '%s\n' "$output" | jq -r --arg n "$title" 'select(.fullName==$n) | .signal')

    run_helper "$FIX_REL/slash-reworded.test.tsx"
    [ "$status" -eq 0 ]
    sig_reworded=$(printf '%s\n' "$output" | jq -r --arg n "$title" 'select(.fullName==$n) | .signal')

    [ -n "$sig_base" ]
    # Either half alone passes on a wrong implementation: the mutation half on
    # the unchanged helper, the comment half on an over-excising one.
    [ "$sig_base" != "$sig_mutated" ]
    [ "$sig_base" = "$sig_reworded" ]
  done
}

# --- signal helper: JSX text vs a JSX expression comment ---

@test "changed JSX text rotates the signal" {
  run_helper "$FIX_REL/jsx-text-a.test.tsx"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/jsx-text-b.test.tsx"
  [ "$status" -eq 0 ]
  local sig_b
  sig_b=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" != "$sig_b" ]
}

@test "a changed JSX expression comment does not rotate the signal" {
  # The fixture places the {/* ... */} comment inside the trailing `>`
  # token's swallow range, so this is the standing catcher for a
  # merge-before-discard step order (README.md, "The signal computation").
  run_helper "$FIX_REL/jsx-text-a.test.tsx"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/jsx-comment.test.tsx"
  [ "$status" -eq 0 ]
  local sig_comment
  sig_comment=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" = "$sig_comment" ]
}

# --- signal helper: one computation across disk, stdin, and the ledger writer ---

# All three legs below assert a non-empty signal first: red_ledger_signals
# fail-opens to empty when node is missing, and a run in which every leg
# yields empty output would satisfy an equality check without proving
# anything.

@test "disk and --stdin emit the identical signal for the same fixture" {
  run_helper "$FIX_REL/comment-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_disk
  sig_disk=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper_stdin "$FIX_REL/comment-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_stdin
  sig_stdin=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_disk" ]
  [ "$sig_disk" = "$sig_stdin" ]
}

@test "the worthiness ledger writer records the same signal the helper emits directly" {
  local fullname="captures bippy renders: active, canary resolves name + memo + timing"

  run_helper "$FIX_REL/comment-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_helper
  sig_helper=$(printf '%s\n' "$output" | jq -r --arg n "$fullname" 'select(.fullName==$n) | .signal')
  [ -n "$sig_helper" ]

  local ledger="$BATS_TEST_TMPDIR/worthiness.jsonl"
  run bash -c "cd '$REPO_ROOT' && WORTHINESS_LEDGER_PATH='$ledger' \
    node .gaia/scripts/audit-ledger/append-worthiness.mjs \
    '$FIX_REL/comment-a.test.ts' '$fullname' keep"
  [ "$status" -eq 0 ]

  local sig_ledger
  sig_ledger=$(jq -r '.signal' "$ledger")
  [ "$sig_helper" = "$sig_ledger" ]
}

@test "the helper reads no process.env, the static floor on a second computation" {
  grep -qF -- 'process.env' "$HELPER" && return 1
  true
}

# --- the dependency gate itself ---

# The one test in this file that asserts about the gate rather than through it.
# Every other test here is gated by setup(), so weakening
# require_node_typescript back to a bare `skip` would retire all of them in
# silence -- `ok ... # skip` greens a leg having asserted nothing, which is the
# defect (gaia-react/gaia#1748) this gate was written to end. This test is what
# makes that weakening red.
#
# It cannot escape its own setup(), which calls the gate before any test body
# runs. That is the same shape `require_repo_path` takes in
# .gaia/scripts/tests/retrigger-reachability.bats, and its comment states the
# reading this inherits: "what the test catches is the weakening, not the
# condition." The condition is covered by the other half of the fix instead --
# the workflow now installs the dependency on this suite's leg, so on CI
# setup() passes and this test runs.
@test "the typescript gate fails on a CI runner and still skips off CI" {
  # A directory that provably lacks the dependency, rather than one that
  # happens to: pointing the gate at a real root would make this test's result
  # depend on whether the machine running it had installed deps.
  local bare="$BATS_TEST_TMPDIR/no-typescript"
  mkdir -p "$bare/node_modules"
  local rc

  # Calling the gate in a subshell is what keeps its `skip` arm from marking
  # THIS test skipped: bats' `skip` exits 0, so the subshell's status is
  # exactly the discriminator wanted here -- non-zero is the CI failure arm, 0
  # is the off-CI skip arm.
  # `export` rather than a bare assignment: the gate reads GITHUB_ACTIONS out
  # of the environment, which is the "used externally" case SC2034 asks for.
  rc=0
  ( export GITHUB_ACTIONS=true; require_node_typescript "$bare" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no typescript; five suites would report green" >&2
    return 1
  }

  rc=0
  ( unset GITHUB_ACTIONS; require_node_typescript "$bare" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing dependency must still skip" >&2
    return 1
  }
}

# --- signal helper: corpus standing check over the union glob set ---

@test "the helper over the whole union glob set has no duplicate signal per file, and pins its file/record counts" {
  local corpus="$BATS_TEST_TMPDIR/corpus.ndjson"
  : > "$corpus"

  local file_count=0
  local record_count=0
  local f dup n
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    file_count=$((file_count + 1))
    run_helper "$f"
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
      # .playwright/e2e/legal-a11y.spec.ts emits zero records; a "same number
      # of records" clause over it is satisfied by 0 == 0 and carries no
      # weight on its own.
      dup=$(printf '%s\n' "$output" | jq -r .signal | sort | uniq -d)
      [ -z "$dup" ]
      n=$(printf '%s\n' "$output" | grep -c '"fullName"')
      record_count=$((record_count + n))
      printf '%s\n' "$output" >> "$corpus"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -z 'app/**/*.test.ts' 'app/**/*.test.tsx' \
    '.playwright/**/*.spec.ts' '.playwright/**/*.spec.tsx' \
    '.playwright/**/*.test.ts' '.playwright/**/*.test.tsx')

  # Refresh both by re-running the git ls-files command above and summing the
  # helper's output line count across the result. Re-derive rather than
  # adjusting the old number by the diff's test count: the two cardinals move
  # independently, and #1748 was a `record_count` that drifted while
  # `file_count` stayed put.
  [ "$file_count" -eq 32 ]
  [ "$record_count" -eq 135 ]

  local bad_signal
  bad_signal=$(jq -r '.signal' "$corpus" | grep -vE '^sha256:[0-9a-f]{64}$' || true)
  [ -z "$bad_signal" ]

  local shapes
  shapes=$(jq -r '[keys_unsorted[]] | join(",")' "$corpus" | sort -u)
  [ "$shapes" = "fullName,signal,kind" ]

  # Zero in-scope tests classify type-only today, so this is a floor rather
  # than a check; the real catcher for `kind` classification is the existing
  # case at .gaia/tests/hooks/red-ledger-lib.bats:119-126, which must stay
  # green.
}
