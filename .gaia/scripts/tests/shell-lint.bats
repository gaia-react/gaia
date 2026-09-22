#!/usr/bin/env bats
# Tests for .gaia/tests/shell-lint.sh: the whole-tree guards the deterministic
# local shell gate folds in (.gaia/scripts/lint-*.sh), and the concurrent
# linter harness those passes run alongside. Each detector's own
# correctness is covered by its own suite; this one covers the wiring.
#
# The gate's bash-3.2 parse pass, its `--only` flag, and its argument parsing
# live in the sibling suite .gaia/scripts/tests/shell-lint-bash32.bats, split
# out along the seam the gate itself has -- `--only bash32-parse` names that
# pass precisely because it is separable from everything here.
#
# Why two files rather than one. A shard's cost is the sum of its files'
# runtimes and the sharder assigns whole files, so a suite that outruns the
# group's ~150s floor becomes an irreducible leg that no repartition can
# relieve; one file holding every gate run here reached the 13-minute cap in
# .github/workflows/audit-ci-tests.yml and was cancelled (#1619). The seam is
# the gate's own, not an arbitrary cut: a test belongs here if it drives the
# gate's whole run, and there if it drives the pass `--only` can select.
#
# The split divides the text and not the cost, which is worth knowing before
# reaching for it again. The whole-tree runs stayed here, so this half remains
# far above that floor while the sibling sits well under it, and the two are
# nowhere near an even division. What the split bought is a smaller unit for
# the sharder to place, not a cheaper one; what keeps this file off the same
# leg as the group's other cost outlier is SCRIPTS_COST_OUTLIERS in
# .gaia/tests/bats-shards.sh, which anchors each of them to a bucket of its own
# rather than letting the byte weight decide. Lowering the number here means
# reducing how many times the tests below re-drive the whole-tree gate.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no linter
# binary). The rig below is duplicated in the sibling rather than shared:
# this repo has no bats helper-loading precedent, and a helper file would land
# under .gaia/scripts/tests/ carrying an extension that either escapes
# shell-lint's own *.sh discovery or joins the capability oracle's obligated
# surface. The two copies are held in step by a test below rather than by this
# sentence, since nothing reds when prose is disobeyed.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GATE="$REPO_ROOT/.gaia/tests/shell-lint.sh"
  # A clean, pinned-version shellcheck stub lets the gate clear both shellcheck
  # passes and reach the array-guard pass without a real shellcheck binary. Its
  # `version:` tracks SHELLCHECK_PIN in shell-lint.sh; a stale stub after a pin
  # bump only makes the gate emit a non-fatal version-drift WARN (stderr, no
  # exit-status change), so this suite still passes -- keep them in sync anyway.
  STUB_DIR="$(mktemp -d -t shell-lint-stub-XXXXXX)"
  cat > "$STUB_DIR/shellcheck" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
# Record one line per invocation when a log path is set, so a test can assert
# which files a pass linted and with which dialect. Unset by default, so the
# stub stays a pure always-clean fake for every other test.
if [ -n "${SHELLCHECK_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SHELLCHECK_LOG"
fi
# Report a finding for exactly one named file, so a test can place a failure in
# a chosen worker's chunk. Quoted inside the pattern, so a path is matched
# literally rather than as a glob. Unset by default.
if [ -n "${SHELLCHECK_FAIL_ON:-}" ]; then
  case " $* " in
    *" $SHELLCHECK_FAIL_ON "*)
      printf 'In %s line 1:\nSC9999 (error): stub finding\n' "$SHELLCHECK_FAIL_ON"
      exit 1
      ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUB_DIR/shellcheck"
}

teardown() {
  [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  return 0
}

# Derive a rig path the way the gate discovers its file list: NUL-delimited with
# `core.quotepath` off. A plain `git ls-files '*.sh' | head -n 1` disagrees with
# the gate under git's default quoting -- a tracked path carrying a non-ASCII
# byte comes back C-quoted, so SHELLCHECK_FAIL_ON would name a path the pass
# never lints, and the two worker-chunk tests below would assert the gate fails
# closed on a finding that was never planted in either chunk.
# A read loop rather than `head -z`: that flag is GNU-only and absent from
# macOS's head, which is the platform this whole gate exists for.
# `.gaia/scripts/lint-git-path-quoting.sh` now scans `*.bats` too, through the
# shared fixture-versus-execution discriminator, so an executed helper like
# `tracked_sh` above sits on that gate's surface rather than being exempt from
# it.
#
# Args: first|last
tracked_sh() {
  local which_end="$1" f first="" last=""
  while IFS= read -r -d '' f; do
    if [ -z "$first" ]; then
      first="$f"
    fi
    last="$f"
  done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.sh')
  if [ "$which_end" = "first" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$last"
  fi
}

# gate_pass_headers: the name of every pass the gate announces, one per line,
# read off the gate itself. A pass's header is the only thing that says it ran
# whether or not it found anything, and the name is the part of that header
# carrying no interpolation, so it is the part a test can match literally.
#
# The short read is the dangerous case here, not the empty one: a header shape
# the `sed` below cannot read would drop that pass out of the set silently and
# leave a caller asserting over a subset while its name still says every. So the
# marker is counted a second way, by a plain literal match rather than by the
# extraction, and a disagreement returns non-zero instead of a shorter list.
gate_pass_headers() {
  local raw names
  raw="$(grep -c '"--> ' "$GATE")"
  names="$(sed -n 's/^[[:space:]]*echo "--> \([^(:]*\).*/\1/p' "$GATE" | sed 's/[[:space:]]*$//')"
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq "$raw" ] || return 1
  printf '%s\n' "$names"
}

# wti_transitive_guards: the guards whole-tree-invariants.sh leaves out of its
# own roster ON THE GROUND that this gate runs them, one bare name per line.
#
# An EXTERNAL source, which is the whole point of it. gate_pass_headers above
# reads the gate, and so does the count that cross-checks it, so both sides of
# that pairing shrink together when a pass is deleted from the gate and the
# assertion stays green over the loss. This file records the same fact from the
# other side: `.gaia/tests/whole-tree-invariants.sh` excludes a set of lint
# scripts from the set it runs directly, each with the written reason that THIS
# GATE invokes them. The helper below derives that set rather than restating its
# size, so a script added to or removed from it is recounted here rather than
# left to decay. A pass deleted from the gate therefore falsifies that file's
# written reason, and neither side of the pairing above can see it happen.
#
# The consequence is scoped to that claim deliberately, and not stated as the
# guard ceasing to run: every excluded guard also carries a sibling suite under
# .gaia/scripts/tests/ that runs it over the real tree, so a regression still
# reds somewhere. What is lost is this gate's enforcement of it and the truth of
# the sentence whole-tree-invariants.sh writes about it.
#
# Short-read guarded the way gate_pass_headers is, and for the same reason: an
# extraction that reads none of the lines yields an empty set that every
# assertion over it passes.
wti_transitive_guards() {
  local wti raw names
  wti="$REPO_ROOT/.gaia/tests/whole-tree-invariants.sh"
  raw="$(grep -c 'runs transitively, shell-lint.sh invokes it' "$wti")"
  names="$(sed -n 's#^\.gaia/scripts/\([a-z-]*\)\.sh|runs transitively, shell-lint\.sh invokes it.*#\1#p' "$wti")"
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq "$raw" ] || return 1
  [ "$raw" -gt 1 ] || return 1
  printf '%s\n' "$names"
}

# The rig above is duplicated into the sibling suite rather than shared, for the
# reason this file's header gives. "Keep the two copies in step" is prose, and
# prose is a claim that decays: a fix to gate_pass_headers' short-read guard, or
# to the stub's literal `case` matching, applied to one file leaves the other
# driving the old shape, and both suites stay green because each runs its own
# copy. This turns that sentence into a claim that re-checks itself.
#
# The shared pieces are compared by name rather than by line range, so either
# file may grow or reorder around them. The bash32 stub is deliberately absent
# from this file and so is not in the set; setup() therefore differs between the
# two by exactly that stub and is compared through the shellcheck stub's own
# heredoc instead of whole.

rig_piece() {
  # $1 = file, $2 = the piece: a function name, or `shellcheck-stub` for the
  # heredoc body the setup writes.
  case "$2" in
    shellcheck-stub)
      # Anchored on the redirect TARGET rather than on the heredoc operator.
      # A literal `<<'STUB'` in this pattern is one the splitter in
      # .gaia/scripts/capability-oracle-lib.sh reads as a real heredoc open, so
      # it would wait for a terminator this file never supplies again and blind
      # the oracle to every line below -- the class the sibling fixture
      # "a comment inside a nested quoted body opens no heredoc" exists for.
      # `q` on the range's end, because the target matches again on the
      # `chmod` line below the heredoc and sed would open a SECOND range there,
      # running to the next terminator or to EOF. The two files differ in what
      # follows, so without the quit this compares unequal tails and fails on
      # copies that are in fact identical.
      sed -n "/STUB_DIR\/shellcheck\"/,/^STUB\$/{p;/^STUB\$/q;}" "$1"
      ;;
    *) sed -n "/^$2() {$/,/^}$/p" "$1" ;;
  esac
}

@test "the duplicated rig is byte-identical to the sibling suite's copy" {
  local sibling="$THIS_DIR/shell-lint-bash32.bats"
  [ -f "$sibling" ]
  local piece seen=0
  for piece in shellcheck-stub teardown tracked_sh gate_pass_headers; do
    local here there
    here="$(rig_piece "$BATS_TEST_FILENAME" "$piece")"
    there="$(rig_piece "$sibling" "$piece")"
    # Each piece has to be FOUND in both, or a rename turns this into a
    # comparison of two empty strings that agrees with itself.
    [ -n "$here" ]
    [ -n "$there" ]
    [ "$here" = "$there" ]
    seen=$(( seen + 1 ))
  done
  [ "$seen" -eq 4 ]
}


# The gate folds a set of whole-tree guard passes into its run, and the class
# this asserts is one of them losing its invocation while its header echo stays.
# The size of that set is derived below rather than written here, per
# .claude/rules/bats-assertions.md: a cardinal in the prose rots the next time
# the gate gains a guard, and the rotted number reads as a checked assertion.
#
# ONE gate run covers the whole set, not one run per guard. A clean-tree run is the
# same execution whichever proof line is grepped afterwards, and it is the
# suite's most expensive single operation -- the folded guards each walk every
# tracked script, and lint-oracle-blind-invocations alone costs ~20s of it. The
# seven separate tests this replaced paid that seven times over for seven greps
# against byte-identical output, which is most of why this file could hold a
# scripts-N shard at the 13-minute cap in .github/workflows/audit-ci-tests.yml
# (#1619). Splitting one execution across seven @test bodies bought no isolation
# either: a run that fails reds every one of them together.
#
# The set is derived from the gate rather than listed here, for the reason the
# --only absence loop below records: a hand-written list falls behind the gate
# silently. The list this replaced had already done so -- it never named
# lint-errexit-source-guard, so that pass could have lost its invocation with
# nothing red. Deriving it means a guard folded in tomorrow is covered the day
# it lands.
#
# SHELLCHECK_LOG is set on this run so the husky dialect assertion rides along
# rather than paying for a run of its own. The stub is a pure always-clean fake
# with the variable unset, and recording argv changes nothing else it does.

@test "the gate invokes every folded guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_LOG="$STUB_DIR/argv.log" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qF -- "shell-lint passed" <<<"$output"

  # Each folded guard is asserted twice: the gate's own header, which says the
  # gate reached the pass, and the guard's OWN clean line, which is printed by
  # the guard script itself and so appears only if the invocation actually ran.
  # The header alone would survive exactly the edit this test exists to catch.
  local p folded=0
  while IFS= read -r p; do
    case "$p" in lint-*) ;; *) continue ;; esac
    folded=$(( folded + 1 ))
    grep -qF -- "--> $p" <<<"$output"
    grep -qF -- "$p: clean" <<<"$output"
  done < <(gate_pass_headers)

  # A refused or short derivation would make the loop above assert over a subset
  # while its name still says every, so the count is taken a second way, by a
  # literal match on the gate rather than by the extraction, and a disagreement
  # reds here instead of quietly shrinking the set.
  [ "$folded" -eq "$(grep -c 'echo "--> lint-' "$GATE")" ]
  [ "$folded" -gt 1 ]

  # Both of those read the GATE, so deleting a whole pass from it shrinks the
  # expectation and the cross-check together and neither notices. The floor
  # above is the only outside constraint, and it leaves every folded pass but
  # two droppable. So the set is required a third time from a source the
  # gate cannot move: every guard whole-tree-invariants.sh declines to run
  # itself BECAUSE this gate runs it has to be a pass this gate actually ran.
  # Two of them are invoked from nowhere else in the tree, so a pass dropped
  # here stops running entirely while that file still says it runs.
  #
  # Captured rather than piped in through a process substitution, because that
  # spelling throws the helper's exit status away: on a refused derivation the
  # loop reads nothing, runs its body zero times, and the assertion passes
  # having checked nothing. The capture turns the refusal back into a failure.
  local w wti_list
  wti_list="$(wti_transitive_guards)"
  [ -n "$wti_list" ]
  [ "$(printf '%s\n' "$wti_list" | grep -c .)" -gt 1 ]
  while IFS= read -r w; do
    [ -n "$w" ]
    grep -qF -- "--> $w" <<<"$output"
    grep -qF -- "$w: clean" <<<"$output"
  done <<<"$wti_list"

  # The husky hooks are extensionless, so they match neither the *.sh nor the
  # *.bats discovery glob and need a pass of their own. Husky runs them as
  # `sh -e`, so that pass pins the dialect: shellcheck takes one dialect per
  # invocation, which is why this cannot fold into the *.sh pass.
  grep -qE -- '(^| )-s sh( |$).*\.husky/pre-commit' "$STUB_DIR/argv.log"
}


# The *.sh and *.bats passes split their file list across concurrent shellcheck
# workers, one buffered log each. Two ways that aggregation goes green over a
# real finding, and one test for each end of the list: collecting the status of
# only the last worker (what a bare `wait` returns), and collecting the status of
# only the first. The gate discovers files in `git ls-files` order and slices
# that list contiguously, so the first tracked path is always in the first
# worker's chunk and the last is always in the last worker's. On a single-core
# host both tests still assert the finding fails the gate, just without
# distinguishing the two workers.

@test "shell-lint fails closed on a finding in the FIRST worker's chunk" {
  first_sh="$(tracked_sh first)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$first_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  # The failing worker's buffered log has to replay too, or the gate reds
  # without ever naming what is broken.
  grep -qF -- "In $first_sh line 1:" <<<"$output"
}

@test "shell-lint fails closed on a finding in the LAST worker's chunk" {
  last_sh="$(tracked_sh last)"
  [ -n "$last_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$last_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "In $last_sh line 1:" <<<"$output"
}

# The folded guards named in GUARD_SLUGS fork through a bounded pool: dispatch
# order is a scheduling hint (GUARD_HEAVY_HINT, dispatched first) with
# everything else following in GUARD_SLUGS' own declared order, but a
# fork/collect loop can still lose exactly one end of that pool the way a bare
# `wait` loses exactly one end of a worker list. The tests below drive both
# ends.
#
# dispatch_first_last derives the guard occupying each end from the gate's own
# tables rather than naming one here, so a reorder of either table is followed
# instead of silently mistested. The first dispatch slot is always
# GUARD_HEAVY_HINT's own first entry, by construction: the gate dispatches
# that whole list before anything else. The last slot is GUARD_SLUGS' own last
# entry, PROVIDED that entry is not itself a member of GUARD_HEAVY_HINT -- the
# gate appends everything else in declared order after every hint, so
# GUARD_SLUGS' last entry lands last overall only when the hint list has not
# already claimed it. Refuses (rather than guess) if that stops holding, so a
# false read of this helper reds the test that calls it instead of pointing
# the fixture at the wrong guard.
dispatch_first_last() {
  local heavy_block slugs_block heavy_first slugs_last
  heavy_block="$(sed -n '/^GUARD_HEAVY_HINT=(/,/^)/p' "$GATE" | sed '1d;$d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  slugs_block="$(sed -n '/^GUARD_SLUGS=(/,/^)/p' "$GATE" | sed '1d;$d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  heavy_first="$(printf '%s\n' "$heavy_block" | sed -n '1p')"
  slugs_last="$(printf '%s\n' "$slugs_block" | sed -n '$p')"
  [ -n "$heavy_first" ] || return 1
  [ -n "$slugs_last" ] || return 1
  if printf '%s\n' "$heavy_block" | grep -qxF -- "$slugs_last"; then
    return 1
  fi
  printf '%s\n%s\n' "$heavy_first" "$slugs_last"
}

# Overrides EVERY folded guard with a trivial stub that emits only its own
# "<name>: clean" line, on the stream the real guard would have used, so a
# test exercising pool mechanics (fork/collect/replay ordering, dispatch
# ends, stream separation, the missing-log arm) does not pay for seventeen
# real tree scans to prove it -- the guards under test here run this gate's
# OWN dispatch/collect/replay code, not the guards' own detection logic,
# which each has its own suite for. Built from the SAME
# SHELL_LINT_GUARD_OVERRIDE_* seam the single-guard-failure tests below
# already use, one override per guard, so the gate gains no new seam for
# this.
#
# The stdout/stderr split below is fixture data reproduced from the real
# guard scripts (this file's own header explains the split; the ones named
# here are those printing their clean line via a bare `printf`, no `>&2`)
# rather than derived live -- a stub rig is allowed to assume the shape it
# stands in for. No count here: the list goes stale by gaining a member, and
# a cardinal beside it would only go stale twice. Re-derive it with
# `grep -n ': clean' .gaia/scripts/lint-*.sh` when a guard is folded in; a
# stub whose stream disagrees with its real guard makes the stream-split
# assertions test the rig rather than the gate.
#
# Prints one `SHELL_LINT_GUARD_OVERRIDE_<slug>=<path>` line per folded guard,
# meant to be read into an array and passed to `env`; a caller needing a
# guard's real detection logic overrides that one slug again afterward, and
# the later assignment for the same name wins.
#
# Args: <dir to write stub scripts into>
stub_all_guards() {
  local dir="$1" stdout_guards p script stream_redirect var
  stdout_guards="lint-guard-rule-shell-coverage lint-hook-wiki-inventory lint-wiki-cached-version lint-hook-advisory-classification lint-scripts-wiki-inventory lint-hook-jq-availability lint-hook-monitor-arming"
  while IFS= read -r p; do
    case "$p" in lint-*) ;; *) continue ;; esac
    script="$dir/$p.stub.sh"
    case " $stdout_guards " in
      *" $p "*) stream_redirect="" ;;
      *) stream_redirect=" >&2" ;;
    esac
    cat > "$script" <<EOF
#!/usr/bin/env bash
printf '%s: clean\n' "$p"$stream_redirect
exit 0
EOF
    chmod +x "$script"
    var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$p" | tr '-' '_')"
    printf '%s=%s\n' "$var" "$script"
  done < <(gate_pass_headers)
}

@test "a guard failing in the FIRST dispatch slot fails the gate and every other guard still runs" {
  local pair first override_var stub
  pair="$(dispatch_first_last)"
  [ -n "$pair" ]
  first="$(printf '%s\n' "$pair" | sed -n '1p')"
  override_var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$first" | tr '-' '_')"
  stub="$STUB_DIR/dispatch-first-fail.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: first dispatch slot" >&2
exit 1
STUB
  chmod +x "$stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  overrides+=("$override_var=$stub")
  run env PATH="$STUB_DIR:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "stub failure: first dispatch slot" <<<"$output"
  # Every guard here is running from an override, and the gate owes a notice
  # naming each one. Without this, deleting that notice leaves the whole suite
  # green while a substituted guard becomes invisible again: the run reports
  # the same banners, the same exit status and the same verdict as a real one,
  # and the only residue is one `: clean` line missing among nineteen, which
  # nothing looks for. The sibling SHELL_LINT_BASH32 seam is pinned the same
  # way, by asserting the substituted interpreter it names.
  grep -qF -- "$first: GUARD OVERRIDE" <<<"$output"
  local p
  while IFS= read -r p; do
    case "$p" in lint-*) ;; *) continue ;; esac
    [ "$p" = "$first" ] && continue
    grep -qF -- "--> $p" <<<"$output"
  done < <(gate_pass_headers)
}

@test "a guard failing in the LAST dispatch slot fails the gate and every other guard still runs" {
  local pair last override_var stub
  pair="$(dispatch_first_last)"
  [ -n "$pair" ]
  last="$(printf '%s\n' "$pair" | sed -n '2p')"
  override_var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$last" | tr '-' '_')"
  stub="$STUB_DIR/dispatch-last-fail.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: last dispatch slot" >&2
exit 1
STUB
  chmod +x "$stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  overrides+=("$override_var=$stub")
  run env PATH="$STUB_DIR:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "stub failure: last dispatch slot" <<<"$output"
  local p
  while IFS= read -r p; do
    case "$p" in lint-*) ;; *) continue ;; esac
    [ "$p" = "$last" ] && continue
    grep -qF -- "--> $p" <<<"$output"
  done < <(gate_pass_headers)
}

@test "two guards failing at once both report their own output, each under its own banner, in declared order" {
  local pair first last first_var last_var first_stub last_stub
  pair="$(dispatch_first_last)"
  [ -n "$pair" ]
  first="$(printf '%s\n' "$pair" | sed -n '1p')"
  last="$(printf '%s\n' "$pair" | sed -n '2p')"
  first_var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$first" | tr '-' '_')"
  last_var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$last" | tr '-' '_')"
  first_stub="$STUB_DIR/two-fail-a.sh"
  last_stub="$STUB_DIR/two-fail-b.sh"
  cat > "$first_stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: A" >&2
exit 1
STUB
  cat > "$last_stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: B" >&2
exit 1
STUB
  chmod +x "$first_stub" "$last_stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  overrides+=("$first_var=$first_stub" "$last_var=$last_stub")
  run env PATH="$STUB_DIR:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "stub failure: A" <<<"$output"
  grep -qF -- "stub failure: B" <<<"$output"
  # Both under their own banner, in declared order: a bare `wait` collecting
  # only one end, or a replay reading a log under the wrong index, would put
  # one finding under the other guard's banner or drop it entirely.
  local banner_a_ln banner_b_ln a_ln b_ln
  banner_a_ln="$(printf '%s\n' "$output" | grep -n -F -- "--> $first" | head -n 1 | cut -d: -f1)"
  banner_b_ln="$(printf '%s\n' "$output" | grep -n -F -- "--> $last" | head -n 1 | cut -d: -f1)"
  a_ln="$(printf '%s\n' "$output" | grep -n -F -- "stub failure: A" | head -n 1 | cut -d: -f1)"
  b_ln="$(printf '%s\n' "$output" | grep -n -F -- "stub failure: B" | head -n 1 | cut -d: -f1)"
  [ -n "$banner_a_ln" ]
  [ -n "$banner_b_ln" ]
  [ -n "$a_ln" ]
  [ -n "$b_ln" ]
  [ "$a_ln" -gt "$banner_a_ln" ] || return 1
  [ "$a_ln" -lt "$banner_b_ln" ] || return 1
  [ "$b_ln" -gt "$banner_b_ln" ] || return 1
}

# Replay order is GUARD_SLUGS' declared order, unconditionally, regardless of
# dispatch order (this file's own header, FC-2). The banner/clean-line PAIRING
# is already covered above (the "invokes every folded guard pass" test); what
# is not is the ORDER of the pairs relative to EACH OTHER, which is exactly
# what a completion-order replay would scramble. Driven through the all-stub
# fixture: every guard comes back clean deterministically, so the loop below
# checks every pair rather than only whichever guards a real tree scan
# happens to leave clean, and does so without paying for seventeen real
# scans.
@test "each guard's banner appears in declared order, and its own clean line -- when present -- stays between its own banner and the next" {
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  run env PATH="$STUB_DIR:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  local expected names_in_output
  expected="$(gate_pass_headers)"
  [ -n "$expected" ]
  names_in_output="$(printf '%s\n' "$output" | sed -n 's/^--> \([^(:]*\).*/\1/p' | sed 's/[[:space:]]*$//')"
  [ "$names_in_output" = "$expected" ] || return 1

  local total i p
  total="$(printf '%s\n' "$expected" | grep -c .)"
  i=1
  while [ "$i" -le "$total" ]; do
    p="$(printf '%s\n' "$expected" | sed -n "${i}p")"
    case "$p" in
      lint-*) ;;
      *)
        i=$((i + 1))
        continue
        ;;
    esac
    if grep -qF -- "$p: clean" <<<"$output"; then
      local banner_ln clean_ln
      banner_ln="$(printf '%s\n' "$output" | grep -n -F -- "--> $p" | head -n 1 | cut -d: -f1)"
      clean_ln="$(printf '%s\n' "$output" | grep -n -F -- "$p: clean" | head -n 1 | cut -d: -f1)"
      [ -n "$banner_ln" ]
      [ -n "$clean_ln" ]
      [ "$clean_ln" -gt "$banner_ln" ] || return 1
      if [ "$i" -lt "$total" ]; then
        local next_p next_ln
        next_p="$(printf '%s\n' "$expected" | sed -n "$((i + 1))p")"
        next_ln="$(printf '%s\n' "$output" | grep -n -F -- "--> $next_p" | head -n 1 | cut -d: -f1)"
        [ -n "$next_ln" ]
        [ "$clean_ln" -lt "$next_ln" ] || return 1
      fi
    fi
    i=$((i + 1))
  done
}

# Streams split, they never merge (this file's own header). No suite driving
# the gate through bats `run` can catch a `2>&1` regression here, because
# `run` merges both streams into $output before any assertion sees them --
# hence the direct redirect to two files below instead. Driven through the
# all-stub fixture so this proves the GATE's own stream handling rather than
# depending on the two named real guards' own scan of the tree.
@test "each guard's clean line lands on the stream its own guard actually writes to, never both" {
  local out_file err_file overrides=() line
  out_file="$STUB_DIR/gate-stdout.log"
  err_file="$STUB_DIR/gate-stderr.log"
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  env PATH="$STUB_DIR:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE" >"$out_file" 2>"$err_file" || true
  # lint-collapsed-signal-trap prints its clean line to stderr;
  # lint-hook-jq-availability prints its to stdout via a bare printf -- one
  # from each side of the split this file's header records.
  grep -qF -- "lint-collapsed-signal-trap: clean" "$err_file"
  grep -qF -- "lint-hook-jq-availability: clean" "$out_file"
  grep -qF -- "lint-collapsed-signal-trap: clean" "$out_file" && return 1
  grep -qF -- "lint-hook-jq-availability: clean" "$err_file" && return 1
  true
}

@test "a missing per-guard log fails the gate rather than passing it" {
  local guard_tmp overrides=() line
  guard_tmp="$(mktemp -d -t shell-lint-guardtmp-XXXXXX)"
  # Guard index 0 is always lint-hook-array-guard: GUARD_SLUGS' own first
  # declared entry, a position that does not move with the dispatch-order
  # hint. Pre-seeding a DIRECTORY at the path its own stdout log would occupy
  # makes the gate's own `>` redirect fail before that guard's process can
  # write anything there -- the same missing-log state a worker that crashed
  # before writing one would also leave behind. The redirect target is what
  # fails, independent of which script the gate was about to invoke there, so
  # the all-stub fixture reaches the same failure without a real scan.
  mkdir -p "$guard_tmp/guard.0.out"
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIR")
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_GUARD_TMP="$guard_tmp" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "ERROR: missing guard log $guard_tmp/guard.0.out" <<<"$output"
}
