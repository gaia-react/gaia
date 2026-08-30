#!/usr/bin/env bats
#
# Tests for .gaia/scripts/guard-awk-lib.sh, the shared fixture-versus-execution
# discriminator the GAIA shell guards concatenate into their own awk programs.
#
# The library is awk SOURCE rather than bash functions, so almost every test
# here drives it the way a guard does: source the library for GAIA_GUARD_AWK,
# concatenate a minimal detector onto it, and run awk over a throwaway file. The
# detector looks for one unambiguous token so a failure is never ambiguous about
# which half of the pipeline moved.
#
# Assertions follow .claude/rules/bats-assertions.md: `grep -qF --` with a
# herestring rather than `[[ == * ]]`, POSIX `[ ]` for equality and numerics,
# and `<positive-condition-for-the-bad-case> && return 1` for absence.
#
# GAIA_GUARD_LIB and GAIA_GUARD_STUB override the two artifacts under test. They
# exist for the mutation proofs at the foot of this file, which copy a neutered
# library into a tmpdir and require a NAMED test here to red against it. Nothing
# outside this suite sets either.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB="${GAIA_GUARD_LIB:-$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh}"
  STUB="${GAIA_GUARD_STUB:-$REPO_ROOT/.gaia/scripts/tests/fixtures/stub-guard.sh}"
  SCRIPTS_DIR="$( cd "$( dirname "$LIB" )" && pwd )"
  TMP="$(mktemp -d -t guard-awk-lib-XXXXXX)"
  # shellcheck source=/dev/null
  . "$LIB"
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# The detector a guard would supply. It calls every entry point a production
# guard calls, in the order the library contract fixes: gaia_scan_feed first,
# ahead of every `next`, so the pragma reader sees the comment lines a class
# detector discards.
# shellcheck disable=SC2016
PROBE_AWK='
BEGIN { gaia_scan_reset() }
is_bats && NR == FNR { gaia_scan_prepass($0); next }
FNR == 1 && NR != FNR { gaia_scan_prepass_end() }
{
  gaia_scan_feed($0, is_bats)
  if (!is_bats && gaia_scan_pragma_here(guard))
    printf "%s:%d: pragma honored nowhere outside a bats suite\n", file, FNR
  if (gaia_scan_skip()) next
  if (index($0, "STUBCLASS") == 0) next
  if (gaia_scan_suppressed(guard)) next
  printf "%s:%d: STUBCLASS%s\n", file, FNR, (gaia_scan_run_only() ? " run-only" : "")
}
END { gaia_scan_end(file, is_bats, guard, is_owner, want_desync) }
'

# probe <relpath> <is_bats> [guard] [is_owner] [want_desync]: run the detector
# over $TMP/<relpath>. A bats surface names the file twice, which is the
# two-pass invocation the prepass needs; every other surface names it once.
probe() {
  local f="$1" ib="$2" g="${3:-lint-git-path-quoting}" own="${4:-0}" wd="${5:-1}"
  local args
  args=("$TMP/$f")
  if [ "$ib" -eq 1 ]; then args+=("$TMP/$f"); fi
  run awk -v file="$f" -v is_bats="$ib" -v scripts_dir="$SCRIPTS_DIR" \
      -v guard="$g" -v is_owner="$own" -v want_desync="$wd" \
      "$GAIA_GUARD_AWK$PROBE_AWK" "${args[@]}"
}

# ---- the argument region ---------------------------------------------------

# The helper set is read out of the library rather than restated here, so a
# sixth helper is covered the moment it is added. The floor is a floor and not a
# cardinality: it fails a derivation that came back short, which is the failure
# a non-empty check cannot see.
helper_names() {
  awk '/^function G_classify/, /^}/' "$LIB" \
    | awk '/^  if \(w == /{f = 1} f {print} f && /\) \{$/{exit}' \
    | grep -oE '"[A-Za-z_]+"' | tr -d '"'
}

@test "every recognized fixture-writing helper skips its argument region" {
  local names n h
  names="$(helper_names)"
  n="$(printf '%s\n' "$names" | grep -c .)"
  [ "$n" -ge 5 ]
  for h in $names; do
    cat > "$TMP/h.bats" <<EOF
$h probe.sh "STUBCLASS inside a fixture argument"
echo "STUBCLASS on an executed line"
EOF
    probe h.bats 1
    grep -qF -- "h.bats:2:" <<<"$output" || return 1
    grep -qF -- "h.bats:1:" <<<"$output" && return 1
  done
  true
}

@test "a helper argument carried onto a backslash-continuation line is skipped too" {
  cat > "$TMP/cont.bats" <<'EOF'
fixture_file probe.sh \
  "STUBCLASS on the continuation line"
echo "STUBCLASS on an executed line"
EOF
  probe cont.bats 1
  grep -qF -- "cont.bats:3:" <<<"$output" || return 1
  grep -qF -- "cont.bats:2:" <<<"$output" && return 1
  true
}

@test "a quoted heredoc body is skipped" {
  cat > "$TMP/hd.bats" <<'EOF'
cat > "$TMP/probe.sh" <<'INNER'
STUBCLASS inside a quoted heredoc body
INNER
echo "STUBCLASS on an executed line"
EOF
  probe hd.bats 1
  grep -qF -- "hd.bats:4:" <<<"$output" || return 1
  grep -qF -- "hd.bats:2:" <<<"$output" && return 1
  true
}

@test "a printf argument region carrying an output redirect is skipped" {
  cat > "$TMP/pf.bats" <<'EOF'
printf '%s\n' "STUBCLASS in a printf fixture" > "$TMP/probe.sh"
echo "STUBCLASS on an executed line"
EOF
  probe pf.bats 1
  grep -qF -- "pf.bats:2:" <<<"$output" || return 1
  grep -qF -- "pf.bats:1:" <<<"$output" && return 1
  true
}

@test "a constant later handed to a fixture helper is data on its interior lines" {
  cat > "$TMP/r4.bats" <<'EOF'
BODY='first line
STUBCLASS on an interior line of a fixture literal
third line'

@test "writes it" {
  fixture_file probe.sh "$BODY"
}
EOF
  probe r4.bats 1
  grep -qF -- "r4.bats:2:" <<<"$output" && return 1
  true
}

# The shape that shipped a live unquoted call inside a suite: a multi-line body
# assigned to a variable, handed to a fixture helper AND run through an
# interpreter, whose interior line carries the class. Execution anywhere in the
# file disqualifies the name, so the interior line is executed shell.
@test "a constant the file also executes is never data, even when a helper writes it too" {
  cat > "$TMP/r4x.bats" <<'EOF'
BODY='first line
STUBCLASS on an interior line of an executed body
third line'

@test "runs it" {
  fixture_file probe.sh "$BODY"
  run bash -c "$BODY"
}
EOF
  probe r4x.bats 1
  grep -qF -- "r4x.bats:2:" <<<"$output" || return 1
}

@test "a fixture written through an unrecognized helper is reported" {
  cat > "$TMP/unk.bats" <<'EOF'
write_thing probe.sh "STUBCLASS through a helper the set does not name"
EOF
  probe unk.bats 1
  grep -qF -- "unk.bats:1:" <<<"$output" || return 1
}

@test "with is_bats 0 the fixture region rule skips nothing" {
  cat > "$TMP/off.bats" <<'EOF'
fixture_file probe.sh "STUBCLASS inside a fixture argument"
printf '%s\n' "STUBCLASS in a printf fixture" > "$TMP/probe.sh"
echo "STUBCLASS on an executed line"
EOF
  probe off.bats 0
  [ "$(grep -cF -- "STUBCLASS" <<<"$output")" -eq 3 ]
}

# ---- line numbers ----------------------------------------------------------

# The one test that catches a consumer reporting NR instead of FNR. Under the
# two-pass invocation a pass-2 line NR is file_length + FNR, so the filler is
# long enough that the two numbers cannot coincide.
@test "a bats hit reports its own FNR, not the two-pass NR" {
  {
    local i
    for i in $(seq 1 40); do echo "# filler $i"; done
    echo 'echo "STUBCLASS well past the halfway point"'
    for i in $(seq 1 10); do echo "# tail $i"; done
  } > "$TMP/long.bats"
  probe long.bats 1
  grep -qF -- "long.bats:41:" <<<"$output" || return 1
  grep -qF -- "long.bats:92:" <<<"$output" && return 1
  true
}

# ---- the pragma ------------------------------------------------------------

@test "a pragma is honored above its target in a bats file" {
  cat > "$TMP/pg.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: the demonstration is the point here
echo "STUBCLASS on the target line"
EOF
  probe pg.bats 1
  grep -qF -- "pg.bats:2:" <<<"$output" && return 1
  grep -qF -- "unused gaia-lint-ignore" <<<"$output" && return 1
  true
}

@test "a reason wrapped across consecutive comment lines reads as one reason" {
  cat > "$TMP/wrap.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: a reason long enough that it
# continues onto a second comment line and then a third
# before the target arrives
echo "STUBCLASS on the target line"
EOF
  probe wrap.bats 1 lint-git-path-quoting 1 1
  grep -qF -- "STUBCLASS" <<<"$output" && return 1
  grep -qF -- "no reason given" <<<"$output" && return 1
  true
}

# A wrapped reason is textually an ordinary comment, so the two cannot be told
# apart and neither ends the block. Only a blank line does.
@test "an unrelated prose comment between the pragma and its target does not void it" {
  cat > "$TMP/prose.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: the demonstration is the point here
# An unrelated remark about the fixture below, written by someone who had no
# idea a pragma was open.
echo "STUBCLASS on the target line"
EOF
  probe prose.bats 1
  grep -qF -- "prose.bats:4:" <<<"$output" && return 1
  grep -qF -- "unused gaia-lint-ignore" <<<"$output" && return 1
  true
}

@test "two stacked pragmas naming two guards both apply to the same target" {
  cat > "$TMP/stack.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: first of the stack
# gaia-lint-ignore lint-grep-ere-escapes: second of the stack
echo "STUBCLASS on the target line"
EOF
  probe stack.bats 1 lint-git-path-quoting
  grep -qF -- "STUBCLASS" <<<"$output" && return 1
  probe stack.bats 1 lint-grep-ere-escapes
  grep -qF -- "STUBCLASS" <<<"$output" && return 1
  true
}

@test "a blank line between the pragma and its target voids the block" {
  cat > "$TMP/blank.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: voided by the blank line below

echo "STUBCLASS on the line that is no longer a target"
EOF
  probe blank.bats 1
  grep -qF -- "blank.bats:3:" <<<"$output" || return 1
  grep -qF -- "blank.bats:1: unused gaia-lint-ignore for lint-git-path-quoting" <<<"$output" || return 1
}

@test "a pragma whose target carries no instance is reported unused by the guard it names" {
  cat > "$TMP/unused.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: nothing here to suppress
echo "an ordinary line"
EOF
  probe unused.bats 1 lint-git-path-quoting
  grep -qF -- "unused.bats:1: unused gaia-lint-ignore for lint-git-path-quoting" <<<"$output" || return 1
  probe unused.bats 1 lint-grep-ere-escapes
  grep -qF -- "unused gaia-lint-ignore" <<<"$output" && return 1
  true
}

@test "an orphaned token and a missing reason are reported once, and only by the owner" {
  cat > "$TMP/mal.bats" <<'EOF'
# gaia-lint-ignore lint-no-such-guard: names a script that does not exist
echo "an ordinary line"

# gaia-lint-ignore lint-grep-ere-escapes:
echo "another ordinary line"
EOF
  probe mal.bats 1 lint-git-path-quoting 1 1
  [ "$(grep -cF -- "malformed gaia-lint-ignore: lint-no-such-guard does not resolve to .gaia/scripts/lint-no-such-guard.sh" <<<"$output")" -eq 1 ]
  [ "$(grep -cF -- "malformed gaia-lint-ignore for lint-grep-ere-escapes: no reason given" <<<"$output")" -eq 1 ]
  probe mal.bats 1 lint-git-path-quoting 0 1
  grep -qF -- "malformed gaia-lint-ignore" <<<"$output" && return 1
  true
}

# These guards are not mode-executable, so resolution asks whether the target
# reads rather than whether it runs.
@test "a token resolves by readability rather than by execute permission" {
  mkdir -p "$TMP/scripts"
  : > "$TMP/scripts/lint-mode-probe.sh"
  chmod 0644 "$TMP/scripts/lint-mode-probe.sh"
  cat > "$TMP/mode.bats" <<'EOF'
# gaia-lint-ignore lint-mode-probe: resolves through a non-executable file
echo "STUBCLASS on the target line"
EOF
  run awk -v file=mode.bats -v is_bats=1 -v scripts_dir="$TMP/scripts" \
      -v guard=lint-mode-probe -v is_owner=1 -v want_desync=1 \
      "$GAIA_GUARD_AWK$PROBE_AWK" "$TMP/mode.bats" "$TMP/mode.bats"
  grep -qF -- "STUBCLASS" <<<"$output" && return 1
  grep -qF -- "malformed" <<<"$output" && return 1
  true
}

# Every fixture test in every consuming suite runs its guard from a throwaway
# repo that carries no .gaia/scripts, so a cwd-relative resolution would read
# every well-formed token as orphaned.
@test "a token resolves against scripts_dir and not against the working directory" {
  cat > "$TMP/cwd.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: resolved from somewhere else entirely
echo "STUBCLASS on the target line"
EOF
  mkdir -p "$TMP/elsewhere"
  run bash -c "cd '$TMP/elsewhere' && awk -v file=cwd.bats -v is_bats=1 \
      -v scripts_dir='$SCRIPTS_DIR' -v guard=lint-git-path-quoting \
      -v is_owner=1 -v want_desync=1 \
      \"\$GAIA_GUARD_AWK\$PROBE_AWK\" '$TMP/cwd.bats' '$TMP/cwd.bats'"
  grep -qF -- "STUBCLASS" <<<"$output" && return 1
  grep -qF -- "malformed" <<<"$output" && return 1
  true
}

# The off-surface arm: nothing is honored outside a bats suite, and the block is
# still parsed there so the guard the pragma names can say so.
@test "with is_bats 0 no pragma is honored and the block is still visible" {
  cat > "$TMP/offp.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: honored nowhere on this surface
echo "STUBCLASS on the target line"
EOF
  probe offp.bats 0 lint-git-path-quoting
  grep -qF -- "offp.bats:2: STUBCLASS" <<<"$output" || return 1
  grep -qF -- "offp.bats:2: pragma honored nowhere outside a bats suite" <<<"$output" || return 1
}

# ---- the run-only exemption ------------------------------------------------

@test "run_only answers 1 inside a helper whose every invocation is a run" {
  cat > "$TMP/ro.bats" <<'EOF'
only_run() {
  echo "STUBCLASS inside a helper only ever run detached"
}

@test "one" {
  run only_run
}
EOF
  probe ro.bats 1
  grep -qF -- "ro.bats:2: STUBCLASS run-only" <<<"$output" || return 1
}

@test "run_only answers 0 for a helper one call site invokes plainly" {
  cat > "$TMP/mixed.bats" <<'EOF'
mixed_call() {
  echo "STUBCLASS inside a helper called both ways"
}

@test "one" {
  run mixed_call
  mixed_call
}
EOF
  probe mixed.bats 1
  grep -qF -- "mixed.bats:2: STUBCLASS" <<<"$output" || return 1
  grep -qF -- "run-only" <<<"$output" && return 1
  true
}

@test "run_only answers 0 for a helper nothing invokes" {
  cat > "$TMP/never.bats" <<'EOF'
never_called() {
  echo "STUBCLASS inside a helper with no call site at all"
}
EOF
  probe never.bats 1
  grep -qF -- "never.bats:2: STUBCLASS" <<<"$output" || return 1
  grep -qF -- "run-only" <<<"$output" && return 1
  true
}

@test "run_only answers 0 inside a test body" {
  cat > "$TMP/body.bats" <<'EOF'
@test "one" {
  echo "STUBCLASS inside a test body, which bats runs under errexit"
}
EOF
  probe body.bats 1
  grep -qF -- "body.bats:2: STUBCLASS" <<<"$output" || return 1
  grep -qF -- "run-only" <<<"$output" && return 1
  true
}

# ---- ANSI-C quoting and the desync verdict ---------------------------------

# The minimal repro for the tokenizer defect. Read as an ordinary single-quoted
# span the literal closes at the escaped quote and reopens at the real
# terminator, leaving the state inverted for the rest of the file, which is what
# the desync assertion below detects.
@test "an escaped quote inside an ANSI-C literal does not invert the quote state" {
  cat > "$TMP/ansi.bats" <<'EOF'
x=$'a\'b'
echo "STUBCLASS after the literal"
EOF
  probe ansi.bats 1
  grep -qF -- "ansi.bats:2: STUBCLASS" <<<"$output" || return 1
  grep -qF -- "ERROR: the scan lost track of shell state" <<<"$output" && return 1
  true
}

@test "a file ending inside an unterminated heredoc earns the desync error" {
  cat > "$TMP/ds.bats" <<'EOF'
cat > probe.sh <<INNER
STUBCLASS inside a body whose terminator never arrives
EOF
  probe ds.bats 1 lint-git-path-quoting 0 1
  grep -qF -- "ds.bats: ERROR: the scan lost track of shell state before the end of the file" <<<"$output" || return 1
}

@test "a file ending inside an open quote earns the desync error" {
  cat > "$TMP/dq.bats" <<'EOF'
x="an opening quote with no partner
echo "STUBCLASS somewhere below it"
EOF
  probe dq.bats 1 lint-git-path-quoting 0 1
  grep -qF -- "dq.bats: ERROR: the scan lost track of shell state" <<<"$output" || return 1
}

@test "a file ending on a backslash continuation earns the desync error" {
  printf '%s' 'echo "STUBCLASS" \' > "$TMP/dc.bats"
  probe dc.bats 1 lint-git-path-quoting 0 1
  grep -qF -- "dc.bats: ERROR: the scan lost track of shell state" <<<"$output" || return 1
}

# The errexit guard keeps its own desync detector, so it passes want_desync 0 and
# must not meet two ERROR lines for one file. That argument exists for this.
@test "want_desync 0 suppresses the desync error on the same unreadable file" {
  cat > "$TMP/ds0.bats" <<'EOF'
cat > probe.sh <<INNER
STUBCLASS inside a body whose terminator never arrives
EOF
  probe ds0.bats 1 lint-git-path-quoting 0 0
  grep -qF -- "ERROR: the scan lost track of shell state" <<<"$output" && return 1
  true
}

# ---- the stub guard --------------------------------------------------------

@test "the stub guard skips a fixture region and honors a pragma with no logic of its own" {
  cat > "$TMP/stub.bats" <<'EOF'
fixture_file probe.sh "STUBCLASS inside a fixture argument"

# gaia-lint-ignore stub-guard: the demonstration is the point here
echo "STUBCLASS under a pragma"

echo "STUBCLASS on an executed line"
EOF
  run bash "$STUB" "$TMP/stub.bats"
  [ "$status" -eq 1 ]
  grep -qF -- "stub.bats:6:" <<<"$output" || return 1
  grep -qF -- "stub.bats:1:" <<<"$output" && return 1
  grep -qF -- "stub.bats:4:" <<<"$output" && return 1
  true
}

# A future adopter that needs more machinery than this reds the budget rather
# than quietly re-inventing a tokenizer beside the one the library owns.
@test "the stub guard non-boilerplate body stays inside its line budget" {
  local n
  n="$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$|^#!|^set -euo pipefail$' "$STUB")"
  [ "$n" -le 40 ]
}

# ---- the bats discovery ----------------------------------------------------

# The widened pathspec matching nothing means the discovery is wrong, not that
# the tree is clean, and the caller reads that as a status rather than through a
# substitution that would swallow it.
@test "an empty bats surface is a hard error and a populated one fills the array" {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q .
  printf 'x\n' > "$repo/a.sh"
  git -C "$repo" add -A
  run bash -c "cd '$repo' && . '$LIB' && gaia_guard_bats_files probe"
  [ "$status" -eq 1 ]
  grep -qF -- "probe: ERROR" <<<"$output" || return 1
  printf 'x\n' > "$repo/a.bats"
  git -C "$repo" add -A
  run bash -c "cd '$repo' && . '$LIB' && gaia_guard_bats_files probe && printf '%s\n' \"\${#GAIA_GUARD_BATS_FILES[@]}\" \"\${GAIA_GUARD_BATS_FILES[0]}\""
  [ "$status" -eq 0 ]
  grep -qF -- "a.bats" <<<"$output" || return 1
}

@test "the library sources twice in one shell without erroring under errexit" {
  run bash -c "set -euo pipefail; . '$LIB'; . '$LIB'; printf 'ok\n'"
  [ "$status" -eq 0 ]
  grep -qF -- "ok" <<<"$output" || return 1
}

# ---- mutation proofs -------------------------------------------------------
#
# Both proofs fork bats over a suite that contains them, so the naive shape
# re-enters itself unboundedly. Two mechanisms hold it, and the phase that adds
# the cross-suite half of this proof reuses both spellings unchanged: the
# GAIA_GUARD_MUTATION_CHILD sentinel every mutation test skips on and every
# inner invocation sets, and a `--filter` naming the one test the mutation is
# expected to red.

# mutate <sed-free awk program> : write a neutered copy of the library into a
# tmpdir laid out so the stub fixture beside it resolves the copy, and fail
# outright when the mutation did not apply. An unapplied mutation makes the
# proof vacuous while it still reports green.
mutate() {
  local prog="$1" dir="$TMP/mut"
  mkdir -p "$dir/scripts/tests/fixtures"
  awk "$prog" "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh" > "$dir/scripts/guard-awk-lib.sh"
  cmp -s "$dir/scripts/guard-awk-lib.sh" "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh" && return 1
  cp "$REPO_ROOT/.gaia/scripts/tests/fixtures/stub-guard.sh" "$dir/scripts/tests/fixtures/stub-guard.sh"
  MUT_LIB="$dir/scripts/guard-awk-lib.sh"
  MUT_STUB="$dir/scripts/tests/fixtures/stub-guard.sh"
}

# Target: "a pragma is honored above its target in a bats file".
@test "mutation: a pragma reader that always declines reds the honored-pragma test" {
  [ -z "${GAIA_GUARD_MUTATION_CHILD:-}" ] || skip "mutation child run"
  mutate '/^function gaia_scan_suppressed/{f = 1}
          f && index($0, "G_act_used[i] = 1; return 1") > 0 { sub(/return 1/, "return 0"); f = 0 }
          {print}'
  GAIA_GUARD_MUTATION_CHILD=1 GAIA_GUARD_LIB="$MUT_LIB" \
    run bats --filter 'a pragma is honored above its target in a bats file' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
}

# Target: "the stub guard skips a fixture region and honors a pragma with no
# logic of its own".
@test "mutation: a fixture-region rule that always declines reds the stub guard test" {
  [ -z "${GAIA_GUARD_MUTATION_CHILD:-}" ] || skip "mutation child run"
  mutate '/^function gaia_scan_skip\(\)/ { print "function gaia_scan_skip() { return 0 }"; next }
          {print}'
  GAIA_GUARD_MUTATION_CHILD=1 GAIA_GUARD_STUB="$MUT_STUB" \
    run bats --filter 'the stub guard skips a fixture region and honors a pragma' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
}
