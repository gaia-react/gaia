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

# The argument region ends at the STATEMENT, which is not the same as ending at
# the line. A second statement joined onto a fixture-writing line by a top-level
# separator is shell the suite executes, and a region running to end of line
# classified it as evidence and skipped it. Each separator is asserted
# separately rather than in one loop over a list, so a spelling that regresses
# names itself.
@test "a top-level separator after a fixture writer ends the argument region" {
  local sep
  for sep in ";" "&&" "||"; do
    cat > "$TMP/sep.bats" <<EOF
fixture_file probe.sh 'ok' $sep echo "STUBCLASS on the second statement"
EOF
    probe sep.bats 1
    grep -qF -- "sep.bats:1:" <<<"$output" || return 1
  done
  true
}

@test "a separator inside the fixture literal does not end the argument region" {
  # The discriminating case, and the reason the check above reads the separator
  # from the walk rather than from the raw text: hundreds of fixture bodies in
  # this tree carry a semicolon inside the literal they write. Reading one of
  # those as a second statement would report the evidence itself.
  cat > "$TMP/inlit.bats" <<'EOF'
fixture_file probe.sh 'a=1 ; STUBCLASS inside the literal'
fixture_file probe.sh "b=2 && STUBCLASS inside a double-quoted literal"
EOF
  probe inlit.bats 1
  grep -qF -- "inlit.bats:" <<<"$output" && return 1
  true
}

@test "a pipeline is one statement, so a pipe does not end the argument region" {
  # A lone `|` and a lone `&` are deliberately not separators. Pinning that
  # keeps a later widening of the separator set from silently reporting every
  # fixture written through a pipeline.
  cat > "$TMP/pipe.bats" <<'EOF'
printf '%s\n' "STUBCLASS piped into a fixture path" > "$TMP/probe.sh"
EOF
  probe pipe.bats 1
  grep -qF -- "pipe.bats:" <<<"$output" && return 1
  true
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

# ---- the redirect arm names a path, never a file descriptor ----------------

# `>&2` dups a descriptor; it is not an output redirect to a path, so an
# `echo ... >&2` is a diagnostic rather than a fixture write. Reading it as one
# made the whole line data and skipped a real instance on it, silently, on the
# one surface this library exists to arm.
@test "a stderr dup does not turn a diagnostic line into fixture data" {
  cat > "$TMP/redir.bats" <<'EOF'
echo "STUBCLASS in a diagnostic" >&2
EOF
  probe redir.bats 1
  grep -qF -- "redir.bats:1:" <<<"$output" || return 1
  true
}

@test "a redirect to a path still makes the line fixture data" {
  cat > "$TMP/topath.bats" <<'EOF'
echo "STUBCLASS in a fixture" > "$TMP/written.txt"
EOF
  probe topath.bats 1
  grep -qF -- "topath.bats:1:" <<<"$output" && return 1
  true
}

@test "an appending redirect to a path still makes the line fixture data" {
  cat > "$TMP/append.bats" <<'EOF'
echo "STUBCLASS in a fixture" >> "$TMP/written.txt"
EOF
  probe append.bats 1
  grep -qF -- "append.bats:1:" <<<"$output" && return 1
  true
}

@test "a descriptor dup written as 2>&1 leaves the line executable shell" {
  cat > "$TMP/dup21.bats" <<'EOF'
echo "STUBCLASS in a diagnostic" 2>&1
EOF
  probe dup21.bats 1
  grep -qF -- "dup21.bats:1:" <<<"$output" || return 1
  true
}

# ---- stacked pragmas naming one guard --------------------------------------

# Both apply to the same target, so both are used. Marking only the first left
# the second reported unused over a target that does carry an instance.
@test "two pragmas naming the same guard are both marked used" {
  cat > "$TMP/stack.bats" <<'EOF'
# gaia-lint-ignore lint-git-path-quoting: the first reason
# gaia-lint-ignore lint-git-path-quoting: the second reason
echo "STUBCLASS on the target line"
EOF
  probe stack.bats 1 lint-git-path-quoting 1 1
  grep -qF -- "unused gaia-lint-ignore" <<<"$output" && return 1
  grep -qF -- "stack.bats:3:" <<<"$output" && return 1
  true
}

# ---- backtick runs are fence delimiters, not command substitution ----------

# A three-backtick opener carrying a language tag is an odd count, so a
# per-character toggle left the span open and every comment line inside the
# fence read as literal data, which meant a pragma there was never parsed.
@test "a fenced block does not leave the backtick span open" {
  printf '%s\n' 'text before' '```bash' '# gaia-lint-ignore lint-git-path-quoting: an example' 'echo "STUBCLASS"' '```' > "$TMP/fence.md"
  probe fence.md 0
  grep -qF -- "fence.md:4:" <<<"$output" || return 1
  true
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
          f && index($0, "return hit") > 0 { sub(/return hit/, "return 0"); f = 0 }
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

# ============================================================================
# Section A: shared-entry-point conformance (UAT-010)
# ============================================================================
#
# Every check below greps all four participating files at once: the three
# production guards and the stub-guard fixture. That is why this whole
# section lives in a single-agent phase rather than three parallel edits.

participating_files() {
  printf '%s\n' \
    "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" \
    "$REPO_ROOT/.gaia/scripts/tests/fixtures/stub-guard.sh"
}

production_guards() {
  printf '%s\n' \
    "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh"
}

@test "each participating file's shellcheck source= line carries the library's full repo-relative path" {
  local f
  while IFS= read -r f; do
    grep -qF -- ".gaia/scripts/guard-awk-lib.sh" "$f" || { echo "$f: no shellcheck source= citation" >&2; return 1; }
  done < <(participating_files)
}

@test "each participating file brackets its library load with set +e and set -e on one line" {
  # README C1.1's frozen block, verbatim. The load is script-relative by
  # design and does not itself carry the full path (which lives above it,
  # on the shellcheck source= directive line), so this checks the bracket
  # rather than a second copy of the path.
  local f load
  load='set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e'
  while IFS= read -r f; do
    grep -qF -- "$load" "$f" || { echo "$f: unbracketed or reworded library load" >&2; return 1; }
  done < <(participating_files)
}

@test "each participating file concatenates GAIA_GUARD_AWK ahead of its own awk program" {
  local f
  while IFS= read -r f; do
    grep -qF -- '$GAIA_GUARD_AWK' "$f" || { echo "$f: no GAIA_GUARD_AWK concatenation" >&2; return 1; }
  done < <(participating_files)
}

@test "the five common entry points are called, not merely named, in all four files" {
  # A CALL is the name immediately followed by "(". Both this file's own
  # header comments and the stub guard's name every entry point in prose,
  # so a raw name-match would misread a comment as a call.
  local f name
  while IFS= read -r f; do
    for name in gaia_scan_reset gaia_scan_feed gaia_scan_skip gaia_scan_suppressed gaia_scan_end; do
      grep -qF -- "$name(" "$f" || { echo "$f: never calls $name" >&2; return 1; }
    done
  done < <(participating_files)
}

# README C1.3 freezes nine entry points. The stub is capped at a 40-line
# non-boilerplate body (asserted below by "the stub guard non-boilerplate
# body stays inside its line budget") and its own header states it calls the
# five common ones above and none of the other four: no prepass (it reports
# on one surface with no need for a second pass), no gaia_scan_pragma_here
# (it has no off-surface pragma to name), and no gaia_scan_run_only (it
# detects a class errexit arming does not reach).
@test "each production guard calls gaia_scan_prepass and gaia_scan_pragma_here; only the errexit gate also calls gaia_scan_run_only" {
  local f
  while IFS= read -r f; do
    grep -qF -- "gaia_scan_prepass(" "$f" || { echo "$f: never calls gaia_scan_prepass" >&2; return 1; }
    grep -qF -- "gaia_scan_pragma_here(" "$f" || { echo "$f: never calls gaia_scan_pragma_here" >&2; return 1; }
  done < <(production_guards)
  grep -qF -- "gaia_scan_run_only(" "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" || return 1
  grep -qF -- "gaia_scan_run_only(" "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" && return 1
  grep -qF -- "gaia_scan_run_only(" "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" && return 1
  true
}

# Deviation from the plan's README table, recorded rather than silently
# absorbed: the table lists gaia_scan_prepass_end among the four the
# production guards "additionally call". None of the three calls it by
# name. The library's own gaia_scan_feed invokes it internally on the
# transition into pass 2 (guard-awk-lib.sh: "if (G_pre_seen && !G_pre_done)
# gaia_scan_prepass_end()"), so a guard running the two-pass invocation gets
# it for free and never has to name it. The contract is satisfied either
# way; this is a fact about the tree, not a defect.
@test "no participating file calls gaia_scan_prepass_end directly" {
  local f
  while IFS= read -r f; do
    grep -qF -- "gaia_scan_prepass_end(" "$f" && { echo "$f: calls gaia_scan_prepass_end directly" >&2; return 1; }
  done < <(participating_files)
  true
}

@test "no participating file calls a gaia_scan_* name outside the frozen nine" {
  local f name
  while IFS= read -r f; do
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in
        gaia_scan_reset|gaia_scan_prepass|gaia_scan_prepass_end|gaia_scan_feed|gaia_scan_skip|gaia_scan_suppressed|gaia_scan_pragma_here|gaia_scan_run_only|gaia_scan_end) ;;
        *) echo "$f: calls unrecognized entry point $name" >&2; return 1 ;;
      esac
    done < <(grep -oE 'gaia_scan_[A-Za-z_]+\(' "$f" | sed 's/(//' | sort -u)
  done < <(participating_files)
}

# The permitted set below is a hand-written allowlist rather than a derived
# one, deliberately: this check exists to catch an ADDED private tokenizer,
# so what it compares against has to be the frozen policy, not a
# restatement of whatever the file happens to define today.
own_awk_functions() {
  grep -oE '^[[:space:]]*function [A-Za-z_][A-Za-z0-9_]*' "$1" | awk '{print $2}' | sort -u
}

@test "no production guard or the stub defines an awk function outside its recorded permitted set" {
  # G_-prefixed names are the library's own internals. They reach a guard's
  # ASSEMBLED awk program only through $GAIA_GUARD_AWK concatenation at run
  # time; they live in guard-awk-lib.sh, a separate file, so grepping a
  # guard's own file text, as own_awk_functions does, never sees them and
  # needs no allowance here.
  #
  # scan_window and ere_mode are RETAINED, PERMITTED class-detection walks:
  # scan_window is the ERE guard's pattern-window walk and the class
  # detector cannot work without it. Its ANSI-C reading must agree with the
  # library's; that is a semantic claim no grep can make, so it is recorded
  # here rather than asserted.
  local actual expected

  actual="$(own_awk_functions "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh")"
  [ "$actual" = "option_walk" ]

  actual="$(own_awk_functions "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh")"
  expected="$(printf '%s\n' ere_mode scan_window)"
  [ "$actual" = "$expected" ]

  # Deviation from the plan's README table, recorded rather than silently
  # absorbed: the table lists eight functions for this file. The tree
  # carries ten. pragma_offsurface (the off-surface honored-nowhere
  # emitter, README C1.4 / C4) and yfeed (the run:-body feed dispatch point
  # for the YAML arm) both landed with Phase 2's arming task and are not in
  # the table. Pinned against what the file defines today, per this task's
  # own instruction to build the set from the tree rather than from the
  # doc.
  actual="$(own_awk_functions "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh")"
  expected="$(printf '%s\n' arm check_desync eat_word feed has_status_read pragma_offsurface report reset_state walk yfeed)"
  [ "$actual" = "$expected" ]

  actual="$(own_awk_functions "$REPO_ROOT/.gaia/scripts/tests/fixtures/stub-guard.sh")"
  [ -z "$actual" ]
}

# ============================================================================
# Section B: the no-basename-list assertion (UAT-006, README C8)
# ============================================================================

strip_full_line_comments() {
  grep -vE '^[[:space:]]*#' "$1"
}

@test "none of the three guards or the library names a literal bats suite basename on a non-comment line" {
  # UAT-006 / README C8: the discrimination must not be a per-file or
  # per-suite allowlist, and an allowlist would have to live in code.
  # Scoped to non-comment lines because the guards' header comments
  # legitimately name their own sibling suites ("Enforced by the sibling
  # bats suite ..."); a whole-file assertion would delete those references
  # for no gain. The literal pathspec token '*.bats' can never match this
  # character class, because the character before the dot is '*', outside
  # [A-Za-z0-9_.-], so there is no allowlist arm to carve out.
  local f
  for f in "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" \
           "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" \
           "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" \
           "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh"; do
    strip_full_line_comments "$f" | grep -qE '[A-Za-z0-9_.-]+\.bats' \
      && { echo "$f: names a bats basename on a non-comment line" >&2; return 1; }
  done
  true
}

@test "a bats suite basename planted on a non-comment line reds the no-basename-list check" {
  local copy="$TMP/planted.sh"
  cp "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" "$copy"
  printf '\nSUITE=lint-git-path-quoting.bats\n' >> "$copy"
  strip_full_line_comments "$copy" | grep -qE '[A-Za-z0-9_.-]+\.bats' || return 1
}

# ============================================================================
# Section C: the mechanical documentation arm (UAT-013)
# ============================================================================
#
# This is the MECHANICAL half only: what a grep can prove about citation,
# resolution, registration and heading structure. A separately-labelled
# HUMAN review arm is owed and is not this: a human confirms the page
# states in its own prose why suppression is bats-only, what makes a line
# fixture data, and what the pragma must contain, and that it points at
# each guard header for that guard's blind spots rather than restating
# them. That review happens as the first step of Phase 4, with the user,
# before /distribution-audit, and its outcome is recorded in PROGRESS.md.

wiki_citing_files() {
  printf '%s\n' \
    "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" \
    "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" \
    "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh"
}

@test "every participating file cites the wiki decision page" {
  local f
  while IFS= read -r f; do
    grep -qF -- "wiki/decisions/Shell Guard Fixture Discrimination.md" "$f" \
      || { echo "$f: does not cite the page" >&2; return 1; }
  done < <(wiki_citing_files)
}

extract_wiki_paths() {
  grep -oE 'wiki/[A-Za-z0-9/ _.-]+\.md' "$1" | sort -u
}

@test "every wiki/*.md path any participating file cites resolves on disk" {
  local f p
  while IFS= read -r f; do
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$REPO_ROOT/$p" ] || { echo "$f: cites $p, which does not resolve" >&2; return 1; }
    done < <(extract_wiki_paths "$f")
  done < <(wiki_citing_files)
}

@test "a citation rewritten to a non-existent page reds the resolution check" {
  local copy="$TMP/broken.sh" p bad=1
  cp "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" "$copy"
  sed -i.bak 's#wiki/decisions/Shell Guard Fixture Discrimination\.md#wiki/decisions/No Such Page At All.md#' "$copy"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$REPO_ROOT/$p" ] || bad=0
  done < <(extract_wiki_paths "$copy")
  [ "$bad" -eq 0 ]
}

@test "the wiki decision page is registered inside the maintainer-only block of the Decisions (ADRs) section" {
  local index="$REPO_ROOT/wiki/index.md"
  awk '/^## Decisions \(ADRs\)/{f=1; next} f && /^## /{exit} f{print}' "$index" \
    | awk '/gaia:maintainer-only:start/{m=1} /gaia:maintainer-only:end/{m=0} m && /Shell Guard Fixture Discrimination/{found=1} END{exit !found}' \
    || { echo "page entry missing from the maintainer-only block of Decisions (ADRs)" >&2; return 1; }

  local starts ends
  starts="$(grep -c -- 'gaia:maintainer-only:start' "$index")"
  ends="$(grep -c -- 'gaia:maintainer-only:end' "$index")"
  [ "$starts" -eq "$ends" ]
}

@test "every pinned heading anchor in the wiki page exists and carries content before the next heading" {
  local page="$REPO_ROOT/wiki/decisions/Shell Guard Fixture Discrimination.md"
  local h
  for h in "Why the suppression is bats-only" \
           "What makes a line fixture data" \
           "What a pragma must contain" \
           "Where the blind spots live" \
           "Adopting the convention in a new guard"; do
    awk -v h="## $h" '
      $0 == h { found = 1; next }
      found && /^## / { exit }
      found && NF > 0 { has_content = 1 }
      END { exit !(found && has_content) }
    ' "$page" || { echo "heading '$h' missing or carries no content" >&2; return 1; }
  done
}

@test "each guard's header states its bats reach; the ere and errexit gates also state a bats-tied fail-open" {
  # Presence check against phrasing the guards actually wrote (this task's
  # own instruction: read the headers first and pin what is there, so the
  # check does not rot against the next prose edit).
  grep -qF -- '*.bats' "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh" || return 1
  grep -qF -- '*.bats' "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" || return 1
  grep -qF -- '*.bats' "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" || return 1

  grep -qF -- 'FAIL-OPEN' "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh" || return 1
  grep -qF -- 'FAIL-OPEN' "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" || return 1

  # lint-git-path-quoting.sh's own "*.bats residuals" bullets state only a
  # FAIL-CLOSED shape (an unrecognized fixture helper is reported rather
  # than missed) and a statement about the pragma being honored nowhere on
  # other surfaces; it names no NEW fail-open for the bats surface.
  # Recorded as a finding rather than papered over: the plan's README
  # assumed all three guards would state one.
}

@test "the wiki-style audit greps add no new match from the wiki page" {
  local page="wiki/decisions/Shell Guard Fixture Discrimination.md"
  ( cd "$REPO_ROOT" && grep -rEn "UAT-[0-9]+|SPEC-[0-9]+" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta" ) \
    | grep -qF -- "$page" && return 1
  ( cd "$REPO_ROOT" && grep -rEn "\bchanged from|was changed|previously (did|was|stated|had|used)|previously set|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" wiki/ --include="*.md" --exclude="log.md" --exclude="hot.md" --exclude-dir="meta" ) \
    | grep -qF -- "$page" && return 1
  true
}

# ============================================================================
# Section D: the cross-suite mutation proofs (UAT-007)
# ============================================================================
#
# Phase 1 wrote the within-suite half above (GAIA_GUARD_LIB / GAIA_GUARD_STUB,
# which exist only for this suite). These two prove the same mutation
# matters to every real consumer: a copy of a production guard, laid beside
# a neutered library exactly the way the real tree lays them, reproduces
# the same verdict flip the guard's own suite already asserts. Same two
# mechanisms, reused unchanged: the GAIA_GUARD_MUTATION_CHILD sentinel every
# mutation test skips on, and a --filter naming the one test the mutation is
# expected to red.

# mutate_guard_copy <sed-free awk program> <guard-basename> <suite-filename>:
# lay a copy of one production guard and its own bats suite beside a
# neutered library, at the same relative depth the real tree uses (guard and
# library siblings under .gaia/scripts/, the suite one level under
# .gaia/scripts/tests/), so the guard's own script-relative resolution finds
# the neutered copy rather than the real one. Sets XG_ROOT and XG_SUITE
# for the caller.
mutate_guard_copy() {
  local prog="$1" guard="$2" suite="$3"
  local dir="$TMP/xmut-$guard"
  mkdir -p "$dir/.gaia/scripts/tests"
  awk "$prog" "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh" > "$dir/.gaia/scripts/guard-awk-lib.sh"
  cmp -s "$dir/.gaia/scripts/guard-awk-lib.sh" "$REPO_ROOT/.gaia/scripts/guard-awk-lib.sh" && return 1
  cp "$REPO_ROOT/.gaia/scripts/$guard.sh" "$dir/.gaia/scripts/$guard.sh"
  cp "$REPO_ROOT/.gaia/scripts/tests/$suite" "$dir/.gaia/scripts/tests/$suite"
  XG_ROOT="$dir"
  XG_SUITE="$dir/.gaia/scripts/tests/$suite"
}

@test "mutation: a pragma reader that always declines reds a named test in every production guard suite" {
  [ -z "${GAIA_GUARD_MUTATION_CHILD:-}" ] || skip "mutation child run"
  local prog='/^function gaia_scan_suppressed/{f = 1}
              f && index($0, "return hit") > 0 { sub(/return hit/, "return 0"); f = 0 }
              {print}'

  mutate_guard_copy "$prog" lint-git-path-quoting lint-git-path-quoting.bats
  GAIA_GUARD_MUTATION_CHILD=1 run bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter "a pragma naming this guard suppresses a genuine instance, resolved against the guard's own directory" \
    "$XG_SUITE"
  [ "$status" -ne 0 ]

  mutate_guard_copy "$prog" lint-grep-ere-escapes lint-grep-ere-escapes.bats
  GAIA_GUARD_MUTATION_CHILD=1 run bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter "a well-formed pragma resolves against the guard's own scripts_dir" \
    "$XG_SUITE"
  [ "$status" -ne 0 ]

  mutate_guard_copy "$prog" lint-errexit-status-read lint-errexit-status-read.bats
  GAIA_GUARD_MUTATION_CHILD=1 run bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter "a pragma naming this gate suppresses the instance below it" \
    "$XG_SUITE"
  [ "$status" -ne 0 ]
}

@test "mutation: a fixture-region rule that always declines reds the stub guard's suite and a production guard's suite" {
  [ -z "${GAIA_GUARD_MUTATION_CHILD:-}" ] || skip "mutation child run"
  local prog='/^function gaia_scan_skip\(\)/ { print "function gaia_scan_skip() { return 0 }"; next }
              {print}'

  # The stub half: Phase 1's own mechanism, reused rather than re-derived.
  mutate "$prog"
  GAIA_GUARD_MUTATION_CHILD=1 GAIA_GUARD_STUB="$MUT_STUB" \
    run bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter 'the stub guard skips a fixture region and honors a pragma with no logic of its own' \
    "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]

  # A production guard's suite: lint-grep-ere-escapes.sh keeps no tokenizer
  # of its own (README C1, "keep only their own class detection"), so its
  # "real repository tree is clean" verdict rests entirely on the library's
  # region-skip protecting its own 23 own-suite fixtures. Tracking the
  # copied suite as the only *.bats file in a throwaway git repo reproduces
  # that verdict without touching the real tree.
  mutate_guard_copy "$prog" lint-grep-ere-escapes lint-grep-ere-escapes.bats
  git -C "$XG_ROOT" init -q .
  git -C "$XG_ROOT" add -A
  GAIA_GUARD_MUTATION_CHILD=1 run bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter "the real repository tree is clean" "$XG_SUITE"
  [ "$status" -ne 0 ]
}

# ============================================================================
# Section E: the empty-bats-half hard error, once, centrally (UAT-017)
# ============================================================================
#
# Each Phase 2 task added its own version of this test, scoped to its own
# guard. This one runs all three against a SINGLE fixture tree, so what it
# proves is that they agree, not merely that each happens to have a test.

@test "all three guards hard-error together on a tree carrying no tracked bats suite" {
  local repo="$TMP/no-bats"
  mkdir -p "$repo/.husky" "$repo/.github/workflows"
  git -C "$repo" init -q .
  printf '#!/usr/bin/env bash\necho hi\n' > "$repo/tracked.sh"
  printf '#!/usr/bin/env sh\necho hi\n' > "$repo/.husky/pre-commit"
  printf 'on: push\njobs:\n  x:\n    steps:\n      - run: echo hi\n' > "$repo/.github/workflows/ci.yml"
  git -C "$repo" add -A

  local guard
  for guard in lint-git-path-quoting lint-grep-ere-escapes lint-errexit-status-read; do
    run bash -c "cd '$repo' && bash '$REPO_ROOT/.gaia/scripts/$guard.sh'"
    [ "$status" -ne 0 ] || { echo "$guard exited 0 on a tree with no tracked bats suite" >&2; return 1; }
  done
}
