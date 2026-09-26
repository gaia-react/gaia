#!/usr/bin/env bash
# shell-lint.sh: run shellcheck over every tracked shell script, bats suite, and
# husky hook, then parse every tracked shell script with bash 3.2, then the
# repo-authored guards shellcheck cannot model: the hook
# array-guard (.gaia/scripts/lint-hook-array-guard.sh), the git path-quoting
# guard (.gaia/scripts/lint-git-path-quoting.sh), the workflow
# run-interpolation guard (.gaia/scripts/lint-workflow-run-interpolation.sh),
# the errexit status-read guard (.gaia/scripts/lint-errexit-status-read.sh),
# the SIGPIPE-reader guard (.gaia/scripts/lint-sigpipe-readers.sh), the hook
# cwd-relative-load guard (.gaia/scripts/lint-hook-cwd-relative-loads.sh), and
# the hook jq-availability guard (.gaia/scripts/lint-hook-jq-availability.sh).
# Exit 0 when clean, 1 on any finding at or above the severity floor, and 1 on
# a pass that cannot run at all (no shellcheck binary, an empty *.sh discovery
# set, an unusable bash-3.2 interpreter). A red gate is therefore not always a
# findings list; the ERROR line says which case it is. Exit 2 is neither: it is
# a usage error, a bad argument, and no pass ran at all.
# Run it directly from anywhere: `bash .gaia/tests/shell-lint.sh`.
#
# Usage: shell-lint.sh [--only bash32-parse]
#
# `--only bash32-parse` runs the bash-3.2 parse pass and nothing else. That is
# how .github/workflows/shell-lint.yml arms that pass on a macOS runner, which
# is the only host in this repo's CI carrying a real bash 3.2, without paying
# for the shellcheck harness there: macOS runner minutes bill at 10x, and every
# other pass either needs shellcheck or reads a surface the ubuntu leg already
# covers. The parse pass is the one whose verdict depends on the host's
# /bin/bash, so it is the one worth a second runner.
#
# Maintainer-only. Adopters run GAIA's bash but never author it, so the linter
# guarding the framework's own shell has no adopter surface. Excluded from the
# release tarball by the `.gaia/tests` entry in `.gaia/release-exclude`.
#
# Why a gate and not just the audit agent: the code-audit-maintainer-shell agent
# already treats shellcheck as an authoritative oracle, but it is dispatched by a
# model and is advisory-only, so nothing *enforces* a clean tree. Hand-applied
# linting regresses silently. This is the deterministic backstop; the agent keeps
# the lenses shellcheck cannot model (hook fail-open, stdin-JSON shape,
# `jq -n` injection safety).
#
# Two severity floors over three discovery passes, because the file types carry
# different noise profiles:
#
#   *.sh   -> `style`, the strictest floor. The genuine style/info-tier codes are
#            curated: SC1091/SC1090 (shellcheck cannot follow a dynamically
#            sourced path) are excluded below as pure tooling artifacts, and the
#            intentional single-quoted jq/awk programs (SC2016) carry file-level
#            `# shellcheck disable=SC2016` directives, so the gate stays live to a
#            genuine SC2016 bug in any file that does not opt out.
#
#   .husky/* -> `style` as well, but linted as POSIX `sh` in a pass of its own.
#            The hooks are extensionless, so no glob above reaches them, and
#            husky runs each one as `sh -e`, so bash-only constructs must fail
#            here even though they pass in the *.sh pass.
#
#   *.bats -> `warning`. Errors and warnings are the tiers with live failure
#            modes (a masked `!` assertion that never fails a test [SC2314], a
#            `local x=$(...)` that swallows the command's exit [SC2155], a `cd`
#            with no `|| exit` guard [SC2164]). The `info`/`style` tiers on bats
#            carry structural false positives from the bats execution model
#            (SC2030/SC2031 subshell state from `run`, SC2016 assertion
#            strings); those sit below the `warning` floor and never fire, so
#            bats needs no blunt per-code exclude list. Run
#            `shellcheck -S style <file>` by hand to see the sub-floor tiers.
#
#            SC2317 is NOT one of those structural codes, and reading it as one
#            writes off a class that is both real and cheap to clear. A `@test`
#            body parses as a top-level brace group rather than a function, so a
#            bare `return` inside one is a script-level return and every `@test`
#            after it reads as unreachable. A suite carrying no such return
#            reports none of it. It sits below the floor because the idiom is
#            semantically correct rather than unfixable; the spelling that
#            avoids it is the explicit `true` .claude/rules/bats-assertions.md
#            already prescribes for a test whose last check is
#            `<positive-for-the-bad-case> && return 1`.
#
# Never begin a comment line with the bare word `shellcheck`: a comment of that
# shape is parsed as a directive, and a malformed one (SC1072/SC1073) aborts the
# parse of the whole file, silently leaving it unlinted. Write "Run shellcheck
# ..." or "The shellcheck binary ..." instead. Two lines in this very file tripped
# that trap on the gate's first CI run.
#
# Prerequisites:
#   the shellcheck binary on PATH; install via:
#     brew install shellcheck          (macOS)
#     https://github.com/koalaman/shellcheck/releases  (pinned tarball, as CI does)
#
# CI: .github/workflows/shell-lint.yml
set -euo pipefail

# Pass selection. Empty is the default and what every existing caller passes: it
# runs every pass below, unchanged. One value is selectable, for the reason the
# header gives.
ONLY_PASS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      # `--only <value>`, not `--only=<value>`: one spelling, the same one
      # .gaia/scripts/verify-required-checks.sh takes for its own flags.
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --only needs a pass name" >&2
        exit 2
      fi
      ONLY_PASS="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "usage: shell-lint.sh [--only bash32-parse]" >&2
      exit 2
      ;;
  esac
done

case "$ONLY_PASS" in
  '' | bash32-parse) ;;
  *)
    # Reject rather than fall through to a full run. A typo'd pass name reaching
    # the default would run the shellcheck passes on the macOS leg, which
    # installs no shellcheck, and report the flag's own absence as a lint
    # failure -- loud, but about the wrong thing.
    echo "ERROR: unknown --only pass: $ONLY_PASS (known: bash32-parse)" >&2
    exit 2
    ;;
esac

# Per-file-type severity floors (see the block above). *.sh is held to the
# strictest `style` tier; *.bats joins at `warning`, where the structural bats
# false positives sit below the floor.
SH_SEVERITY=style
BATS_SEVERITY=warning

# Tooling-artifact codes disabled for every pass: SC1091/SC1090 are "shellcheck
# cannot resolve a sourced path computed at runtime", which carries no failure
# mode and fires across the tree wherever a script sources a sibling by a derived
# path. Passed on the command line rather than a repo-root .shellcheckrc, so this
# config stays inside the maintainer-only gate and never ships to adopters as a
# newly-distributed file.
TOOLING_EXCLUDE=SC1091,SC1090

# Pin the linter version so the gate's verdict cannot depend on which machine ran
# it. Ubuntu's apt ships 0.9.0 while Homebrew ships newer, and their directive
# parsers disagree: 0.9.0 flags a comment beginning with whitespace + the word
# `shellcheck` and 0.11.0 does not, so this script passed locally and failed in CI
# on its own first run. CI installs exactly this version; a local mismatch warns
# rather than blocks, because CI is the authority.
SHELLCHECK_PIN=0.11.0

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"

echo "==> .gaia/tests/shell-lint.sh"

# Both are preconditions of the shellcheck passes below and of nothing else,
# so `--only bash32-parse` skips them. Demanding the binary unconditionally
# would red the macOS leg, whose whole cost argument is that it installs no
# linter at all. (That last line deliberately does not begin with the bare word
# a directive is spelled with, per the trap this file's header records.)
if [ -z "$ONLY_PASS" ]; then
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "ERROR: shellcheck not found on PATH. Install it first:" >&2
    echo "  brew install shellcheck        (macOS)" >&2
    echo "  apt-get install -y shellcheck  (Debian/Ubuntu)" >&2
    exit 1
  fi

  have_version="$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
  if [ -n "$have_version" ] && [ "$have_version" != "$SHELLCHECK_PIN" ]; then
    echo "WARN: local shellcheck is $have_version but CI pins $SHELLCHECK_PIN;" >&2
    echo "      verdicts can differ between versions. CI is the authority." >&2
  fi
fi

# Tracked files only. Worktrees under .claude/worktrees/ are untracked checkouts
# of these same scripts, so `git ls-files` never double-counts them.
#
# Collected with a read loop rather than `mapfile`: mapfile is bash 4+, and these
# scripts are authored and run on stock macOS /bin/bash (3.2.57).
#
# NUL-delimited, because under git's default `core.quotePath` a tracked path
# carrying a non-ASCII byte prints C-quoted (`"caf\303\251.sh"`). The quoted
# form fails the `[ -f ]` test every consumer applies and is dropped silently,
# so the pass reports clean having never opened the file. The empty-set guard
# below cannot catch that: the other files match normally, so the set is not
# empty. `.gaia/scripts/lint-git-path-quoting.sh` is the check that keeps this
# whole family quoted.
sh_scripts=()
while IFS= read -r -d '' f; do
  sh_scripts+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.sh')

bats_scripts=()
while IFS= read -r -d '' f; do
  bats_scripts+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.bats')

husky_hooks=()
while IFS= read -r -d '' f; do
  husky_hooks+=("$f")
done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '.husky/*')

# Guard the expansion below: on bash 3.2 a bare "${sh_scripts[@]}" over an EMPTY
# array aborts with `unbound variable` under `set -u`. An empty *.sh result also
# means the glob or the repo root resolved wrong, which should fail loudly, not
# lint nothing and report success. The *.bats set is allowed to be empty and is
# simply skipped; only the always-present *.sh set is a hard precondition.
if [ "${#sh_scripts[@]}" -eq 0 ]; then
  echo "ERROR: no tracked *.sh files found under $REPO_ROOT" >&2
  exit 1
fi

# Concurrent shellcheck workers. One shellcheck invocation is single-threaded and
# CPU-bound, so a pass costs the whole file list on one core; splitting the list
# across workers costs the longest chunk. Capped rather than set to the core
# count: on a 12-core machine 6 workers lint the tree in ~8.0s and 12 in ~6.6s,
# so the last doubling buys under two seconds for twice the resident shellcheck
# processes. `getconf _NPROCESSORS_ONLN` is the portable count -- macOS has no
# `nproc` and the CI image has no `sysctl -n hw.ncpu` -- and a machine that
# answers with nothing or with non-digits falls back to 2 rather than failing.
JOBS_CAP=6
detect_jobs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  case "$n" in
    '' | *[!0-9]*) n=2 ;;
  esac
  if [ "$n" -lt 1 ]; then
    n=1
  fi
  if [ "$n" -gt "$JOBS_CAP" ]; then
    n="$JOBS_CAP"
  fi
  printf '%s\n' "$n"
}
JOBS="$(detect_jobs)"

# Per-worker logs. Removed on every exit path, including the failing one.
LINT_TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/shell-lint.XXXXXX")"
trap 'rm -rf "$LINT_TMP"' EXIT

# Run one shellcheck pass over a file list, split across $JOBS concurrent
# workers: concurrent workers cannot write to a shared stdout, or
# findings from different chunks interleave differently on every run. Each
# worker buffers to its own log; the logs replay after every worker is waited
# on. The split is contiguous rather than round-robin so findings replay in the
# same file order one serial invocation over the whole list prints them in. The
# one divergence is cosmetic: shellcheck's trailing `For more information:`
# wiki-link block is per invocation, so a run with findings in more than one
# chunk prints that block more than once.
#
# Args: <slug> <severity> <file>...
# Every pass split this way lets shellcheck read each file's own shebang, so
# there is no dialect argument; the husky pass, which needs an explicit `-s sh`,
# lints a single file and stays serial.
# Returns 0 only when every worker exited 0. A worker's status is collected per
# pid: a bare `wait` returns the last job's status only and would green a
# finding in any other chunk.
run_shellcheck_pass() {
  local slug severity
  slug="$1"
  severity="$2"
  shift 2

  local files
  files=("$@")

  local total workers base rem w start len pids rc worker_rc log
  total="${#files[@]}"
  workers="$JOBS"
  if [ "$workers" -gt "$total" ]; then
    workers="$total"
  fi
  base=$((total / workers))
  rem=$((total % workers))

  # Every worker index below $workers gets at least one file, so no chunk is
  # ever empty. An empty one would reach shellcheck as a bare invocation with no
  # file operands, which exits non-zero on usage -- loud, not lie-green.
  pids=()
  w=0
  while [ "$w" -lt "$workers" ]; do
    start=$((w * base))
    if [ "$w" -lt "$rem" ]; then
      start=$((start + w))
      len=$((base + 1))
    else
      start=$((start + rem))
      len="$base"
    fi
    # Run from the repo root so the paths the linter prints are repo-relative.
    (
      cd "$REPO_ROOT" || exit 2
      shellcheck --severity="$severity" --exclude="$TOOLING_EXCLUDE" "${files[@]:$start:$len}"
    ) >"$LINT_TMP/$slug.$w.log" 2>&1 &
    pids+=("$!")
    w=$((w + 1))
  done

  rc=0
  w=0
  while [ "$w" -lt "$workers" ]; do
    worker_rc=0
    # `|| worker_rc=$?` rather than `if ! wait ...`, because inside an `if !`
    # body $? is the negated status (0), not the command's. Nothing aborts
    # early: every worker is waited on and every log replays even when the
    # first one failed.
    wait "${pids[$w]}" || worker_rc=$?
    if [ "$worker_rc" -ne 0 ]; then
      rc=1
    fi
    w=$((w + 1))
  done

  # Replay in worker order, never completion order.
  w=0
  while [ "$w" -lt "$workers" ]; do
    log="$LINT_TMP/$slug.$w.log"
    if [ -f "$log" ]; then
      cat "$log"
    else
      # A worker that produced no log ran no lint, so its files went unchecked.
      echo "ERROR: missing worker log $log" >&2
      rc=1
    fi
    w=$((w + 1))
  done

  return "$rc"
}

# Run every pass before failing, so one invocation reports every finding across
# all passes rather than hiding a later pass's findings behind an earlier one.
status=0

# The single verdict, called from both exit points -- `--only` mode stopping
# after its selected pass, and the end of a full run -- so a selected run and a
# full run cannot report the same state differently.
report_verdict() {
  if [ "$status" -ne 0 ]; then
    echo "==> shell-lint FAILED" >&2
    exit 1
  fi
  echo "==> shell-lint passed"
  exit 0
}

# The three shellcheck passes, skipped under `--only bash32-parse` along with
# the binary they need.
if [ -z "$ONLY_PASS" ]; then
  echo "--> shellcheck *.sh (severity=$SH_SEVERITY, jobs=$JOBS): ${#sh_scripts[@]} tracked scripts"
  if ! run_shellcheck_pass sh "$SH_SEVERITY" ${sh_scripts[@]+"${sh_scripts[@]}"}; then
    status=1
  fi

  if [ "${#bats_scripts[@]}" -gt 0 ]; then
    echo "--> shellcheck *.bats (severity=$BATS_SEVERITY, jobs=$JOBS): ${#bats_scripts[@]} tracked suites"
    if ! run_shellcheck_pass bats "$BATS_SEVERITY" ${bats_scripts[@]+"${bats_scripts[@]}"}; then
      status=1
    fi
  fi

  # The husky hooks are extensionless, so they match neither glob above and would
  # escape the gate entirely. `-s sh` is passed explicitly rather than left to the
  # per-file directive: husky runs every hook as `sh -e`, so the dialect is a
  # property of the directory, and a newly added hook is linted correctly whether
  # or not its author remembered the directive. It has to be its own invocation
  # because shellcheck takes one dialect per run.
  if [ "${#husky_hooks[@]}" -gt 0 ]; then
    echo "--> shellcheck .husky/* (dialect=sh, severity=$SH_SEVERITY): ${#husky_hooks[@]} tracked hooks"
    if ! (cd "$REPO_ROOT" && shellcheck -s sh --severity="$SH_SEVERITY" --exclude="$TOOLING_EXCLUDE" ${husky_hooks[@]+"${husky_hooks[@]}"}); then
      status=1
    fi
  fi
fi

# Parse every tracked *.sh with bash 3.2. The passes above run shellcheck, which
# does not implement bash 3.2's command-substitution lexer, so a construct that
# parses on bash 5 and is a syntax error on 3.2 clears all of them. The runners
# are ubuntu bash 5, and stock macOS ships 3.2.57 as /bin/bash, the version
# these scripts declare support for, so the divergence
# is observable on a maintainer's own machine and nowhere else. That is where
# the one shipped instance of the class sat undetected: an apostrophe in a
# comment inside a quoted heredoc nested in a command substitution made
# .claude/hooks/lib/audit-rules-changed.sh unparseable on 3.2, and sourcing it
# aborted .github/audit/resolve-audit-base.sh with no output at all, emptying
# the audit review scope at status 0.
#
# Scoped to *.sh. Bats syntax is not bash syntax -- a bare `@test "..." {` is a
# syntax error to every bash -- so `-n` over a .bats file would report on the
# wrong grammar; covering the suites needs bats' own expansion and is not this
# pass.
#
# SHELL_LINT_BASH32 overrides the interpreter, which is what lets the bats
# suite drive the fail-closed and loud-skip branches on a host carrying only
# one bash.
BASH32="${SHELL_LINT_BASH32:-/bin/bash}"
echo "--> bash-3.2 parse ($BASH32 -n): ${#sh_scripts[@]} tracked scripts"
if [ ! -x "$BASH32" ]; then
  # Fail closed, the same precondition the empty-*.sh-set guard above carries:
  # a pass that cannot run has to say so, never report clean having parsed
  # nothing.
  echo "ERROR: $BASH32 is not executable; the bash-3.2 parse pass cannot run" >&2
  status=1
else
  # SC2016: the single quotes are intentional. BASH_VERSINFO has to expand
  # inside the resolved interpreter, not in this shell.
  # shellcheck disable=SC2016
  bash32_major="$("$BASH32" -c 'printf "%s\n" "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
  case "$bash32_major" in
    '' | *[!0-9]*)
      # Fail closed for the same reason: an interpreter that will not report a
      # version is one this pass cannot reason about.
      echo "ERROR: $BASH32 reported no numeric major version; the bash-3.2 parse pass cannot run" >&2
      status=1
      ;;
    *)
      if [ "$bash32_major" -ge 4 ]; then
        # Skip LOUDLY, the posture .gaia/scripts/bats5.sh already takes on the
        # mirror-image gap. A silent skip on every bash-5 host would reproduce
        # one layer up the exact failure this pass exists to close: the tree
        # would read clean everywhere and be parsed nowhere.
        echo "############################################################" >&2
        echo "# WARNING: $BASH32 is bash $bash32_major, so the bash-3.2" >&2
        echo "# parse pass was SKIPPED. A 3.2-only syntax error is invisible" >&2
        echo "# to this run. Re-run on stock macOS /bin/bash (3.2.57) before" >&2
        echo "# trusting this gate over shell syntax." >&2
        echo "############################################################" >&2
      else
        # One subshell for the whole sweep rather than one per file, and run
        # from the repo root so the file:line the interpreter prints is
        # repo-relative. Every file is parsed before the sweep reports, so one
        # invocation names every broken script rather than only the first.
        if ! (
          cd "$REPO_ROOT" || exit 2
          sweep_rc=0
          for f in ${sh_scripts[@]+"${sh_scripts[@]}"}; do
            "$BASH32" -n "$f" || sweep_rc=1
          done
          exit "$sweep_rc"
        ); then
          status=1
        fi
      fi
      ;;
  esac
fi

# `--only bash32-parse` has run its pass and stops here. The guards below
# read the tree with tools that have nothing to do with the host's /bin/bash, so
# a second runner would only re-run what the ubuntu leg already did.
if [ -n "$ONLY_PASS" ]; then
  report_verdict
fi

# Every guard named in GUARD_SLUGS below walks the whole tracked tree on its
# own, so running them one after another pays for the slowest ones (12-21s
# apiece) once per guard queued behind them. Forked concurrently they cost
# roughly the single slowest guard instead of their sum. Every guard already
# writes to a unique `mktemp` path or is read-only, so nothing here adds a new
# shared-write hazard; that was re-derived, not assumed, by sweeping every
# `lint-*.sh` for `mktemp`.
#
# FC-2 (this plan's README): dispatch order and replay order are different
# contracts. Dispatch order below is a scheduling choice, applied only to
# shrink wall-clock time; GUARD_HEAVY_HINT starts the pool on the guards
# measured heaviest so a late straggler does not sit behind five short ones,
# but a stale hint only costs seconds, never correctness. Replay order is
# fixed at GUARD_SLUGS' declared order, below, and is a contract:
# .gaia/scripts/tests/shell-lint.bats derives its own roster from this file's
# own literal `echo` banner lines, in the order they appear, so the banner
# sequence has to match GUARD_SLUGS every time.
#
# The banner stays a literal `echo` line per guard: `--> <name>
# (<parenthetical>)`, same indentation, same position, one per guard. The
# table below may carry a script path, never the banner text itself.
# .gaia/scripts/tests/shell-lint.bats:123-129 greps the source for the
# banner marker and cross-checks the count against a `sed` extraction of the
# same pattern, so a table-driven banner, or a comment naming the marker in
# its quoted form, both make that helper refuse.
#
# Streams split, they never merge. Most of these guards print their own
# `<name>: clean` line to stderr and a minority print it to stdout via a bare
# `printf '%s: clean\n' "$PROG"`. Which guards fall on which side is a fact
# about the guards rather than about this file, so derive it
# (`grep -n ': clean' .gaia/scripts/lint-*.sh`) rather than reading a list
# here: naming the set inline is what leaves a count behind to go stale as
# guards are folded in. `2>&1`, the merge run_shellcheck_pass above
# uses, is wrong here: it would relocate the stderr majority's clean lines
# and findings onto stdout, and .gaia/scripts/tests/shell-lint.bats:245 could
# not catch the regression, because bats `run` merges both streams into
# `$output` before any assertion sees them. So every guard's stdout and
# stderr are captured to two separate logs and replayed to stdout and stderr
# respectively; the cost is that a single guard's own stdout and stderr no
# longer interleave with each other, only with themselves.
#
GUARD_SLUGS=(
  lint-hook-array-guard
  lint-git-path-quoting
  lint-workflow-run-interpolation
  lint-errexit-status-read
  lint-sigpipe-readers
  lint-hook-cwd-relative-loads
  lint-hook-jq-availability
)
GUARD_COUNT="${#GUARD_SLUGS[@]}"

# A scheduling hint only, named rather than derived from a stored cost table:
# a cost table goes stale the moment a guard's own runtime shifts, and a
# stale entry here costs the pool a few seconds of head-of-line blocking,
# never a wrong verdict. Measured heaviest to lightest on an idle host:
# lint-git-path-quoting (~7s), lint-errexit-status-read (~6s). Every other
# guard totals a few seconds combined and dispatches after these in
# GUARD_SLUGS' own declared order.
GUARD_HEAVY_HINT=(
  lint-git-path-quoting
  lint-errexit-status-read
)

# Test-only seams, both unset in every real invocation and both named after
# the SHELL_LINT_BASH32 seam above, which establishes the same shape for the
# bash-3.2 pass: an env var a bats fixture sets to drive a branch no ordinary
# run reaches. SHELL_LINT_GUARD_OVERRIDE_<slug, hyphens as underscores> swaps
# one guard's script for a stub, so a suite can fail a chosen guard without
# editing the guard itself or the tree it scans. SHELL_LINT_GUARD_TMP swaps
# the per-guard log directory for one the suite pre-seeds, which is how a
# fixture drives the missing-log arm below: a path that is already a
# directory refuses the `>` redirect a guard's log needs, so that guard's
# logs are never created and replay treats it exactly as it would a worker
# that crashed before writing one.
guard_script_path() {
  local slug="$1" override_var value
  override_var="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$slug" | tr '-' '_')"
  value="${!override_var:-}"
  if [ -n "$value" ]; then
    # A seam that swaps what the gate EXECUTES has to announce itself, or a
    # run with it set is byte-identical to a real one: same banner, same exit
    # 0, same `shell-lint passed`, with the substituted guard's own `: clean`
    # line merely absent and nothing looking for it. The
    # SHELL_LINT_BASH32 seam this family is modelled on already has the
    # property, printing its interpreter into its own banner; this restores it
    # here. On stderr, which the caller's command substitution does not
    # capture, so it reaches the run output without corrupting the path.
    printf '%s: GUARD OVERRIDE, running %s instead of the real guard\n' \
      "$slug" "$value" >&2
    printf '%s\n' "$value"
  else
    printf '%s\n' "$REPO_ROOT/.gaia/scripts/$slug.sh"
  fi
}

guard_index_of() {
  local name="$1" i=0
  while [ "$i" -lt "$GUARD_COUNT" ]; do
    if [ "${GUARD_SLUGS[$i]}" = "$name" ]; then
      printf '%s\n' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

GUARD_DISPATCH_ORDER=()
GUARD_DISPATCHED=()
gd_i=0
while [ "$gd_i" -lt "$GUARD_COUNT" ]; do
  GUARD_DISPATCHED[gd_i]=""
  gd_i=$((gd_i + 1))
done
for guard_name in ${GUARD_HEAVY_HINT[@]+"${GUARD_HEAVY_HINT[@]}"}; do
  guard_idx="$(guard_index_of "$guard_name")"
  GUARD_DISPATCH_ORDER+=("$guard_idx")
  GUARD_DISPATCHED[guard_idx]=1
done
gd_i=0
while [ "$gd_i" -lt "$GUARD_COUNT" ]; do
  if [ -z "${GUARD_DISPATCHED[$gd_i]}" ]; then
    GUARD_DISPATCH_ORDER+=("$gd_i")
  fi
  gd_i=$((gd_i + 1))
done

GUARD_TMP="${SHELL_LINT_GUARD_TMP:-$LINT_TMP}"
if [ "$GUARD_TMP" != "$LINT_TMP" ]; then
  mkdir -p "$GUARD_TMP"
fi

# Forks one guard by table index and records its pid in the global LAST_PID.
# Called directly, never through a command substitution: a `$(...)` around a
# call that backgrounds a job runs the whole call in a throwaway subshell, so
# the backgrounded child would be reparented away the instant that subshell
# exits and `wait` on its pid would fail in the caller. `</dev/null` on the
# fork: none of these guards read stdin, and a forked job inheriting the
# parent's stdin could otherwise block waiting on a terminal that never
# supplies one.
LAST_PID=""
dispatch_guard() {
  local idx="$1" slug script out err
  slug="${GUARD_SLUGS[$idx]}"
  script="$(guard_script_path "$slug")"
  out="$GUARD_TMP/guard.$idx.out"
  err="$GUARD_TMP/guard.$idx.err"
  (cd "$REPO_ROOT" && bash "$script") </dev/null >"$out" 2>"$err" &
  LAST_PID="$!"
}

# A pool of $JOBS round-robin slots, reusing the same JOBS the shellcheck
# passes above computed (FC-4 in this plan's README forbids a second bound at
# this level). Slot N's previous occupant is always the job dispatched JOBS
# turns earlier, so waiting on a slot before reusing it bounds concurrency at
# JOBS without a separate FIFO queue to shift elements out of: bash 3.2 array
# slicing at the front of a growing/shrinking array is exactly the kind of
# edge a round-robin index sidesteps entirely.
GUARD_RC=()
SLOT_PID=()
SLOT_IDX=()
slot=0
while [ "$slot" -lt "$JOBS" ]; do
  SLOT_PID[slot]=""
  SLOT_IDX[slot]=""
  slot=$((slot + 1))
done

# `|| rc=$?` rather than `if ! wait ...`, same reason run_shellcheck_pass
# above gives: inside an `if !` body `$?` is the negated status, not the
# command's.
collect_slot() {
  local slot="$1" pid idx rc
  pid="${SLOT_PID[$slot]}"
  if [ -z "$pid" ]; then
    return 0
  fi
  idx="${SLOT_IDX[$slot]}"
  rc=0
  wait "$pid" || rc=$?
  GUARD_RC[idx]="$rc"
  SLOT_PID[slot]=""
  SLOT_IDX[slot]=""
}

slot=0
for guard_idx in ${GUARD_DISPATCH_ORDER[@]+"${GUARD_DISPATCH_ORDER[@]}"}; do
  collect_slot "$slot"
  dispatch_guard "$guard_idx"
  SLOT_PID[slot]="$LAST_PID"
  SLOT_IDX[slot]="$guard_idx"
  slot=$(( (slot + 1) % JOBS ))
done
slot=0
while [ "$slot" -lt "$JOBS" ]; do
  collect_slot "$slot"
  slot=$((slot + 1))
done

# Replays one guard's two logs to their real streams and reports whether it
# passed. A missing log means that guard ran no check -- the same failure
# mode the shellcheck pass above guards against with an identical check --
# and is reported and treated as a failure rather than skipped.
replay_guard() {
  local idx="$1" out err rc rc_ok=0 log_ok=1
  out="$GUARD_TMP/guard.$idx.out"
  err="$GUARD_TMP/guard.$idx.err"
  if [ -f "$out" ]; then
    cat "$out"
  else
    echo "ERROR: missing guard log $out" >&2
    log_ok=0
  fi
  if [ -f "$err" ]; then
    cat "$err" >&2
  else
    echo "ERROR: missing guard log $err" >&2
    log_ok=0
  fi
  rc="${GUARD_RC[$idx]:-}"
  if [ -n "$rc" ] && [ "$rc" -eq 0 ]; then
    rc_ok=1
  fi
  if [ "$log_ok" -eq 1 ] && [ "$rc_ok" -eq 1 ]; then
    return 0
  fi
  return 1
}

# Every guard below has already run by this point; what follows only
# replays. The banner order is GUARD_SLUGS' declared order, unconditionally,
# so it is the contract .gaia/scripts/tests/shell-lint.bats reads it as
# regardless of the dispatch order above.

# Fold in the hook array-guard: shellcheck cannot model the bash-3.2.57
# empty-array abort -- a bare "${arr[@]}" over an EMPTY array aborts under
# `set -u`, exiting a hook before it can emit its deny JSON. Running it here
# means every shell-lint caller -- plan per-phase gates, the
# code-audit-maintainer-shell oracle, CI shell-lint.yml, and manual runs --
# enforces the class locally, not only the Audit CI Tests job. Run from
# the repo root so its cwd-relative .claude/hooks/*.sh scan resolves.
echo "--> lint-hook-array-guard (bash-3.2 empty-array class under set -u)"
if ! replay_guard 0; then
  status=1
fi

# Fold in the git path-quoting guard, for the same reason as the array guard:
# the linter above cannot model it, and the class has been fixed seven times by
# hand and never once by a check. It reaches further than the passes above --
# its scan surface includes .github/workflows/*.yml, whose `run:` blocks are
# shell that no *.sh glob sees. It also guards this file's own three discovery
# loops above, which is how the class reached them in the first place. Run from
# the repo root so its own discovery resolves and the file:line it prints is
# repo-relative.
echo "--> lint-git-path-quoting (C-quoted paths from an unquoted diff or ls-files)"
if ! replay_guard 1; then
  status=1
fi

# Fold in the workflow run-interpolation guard, for the same reason as the two
# above: shellcheck never sees this class at all. A `${{ }}` expression in a
# `run:` body is substituted into the script TEXT before bash parses it, so the
# hazard exists in the YAML layer that no shell linter reads -- shellcheck is
# handed the body only after the expression is already gone. Run from the repo
# root so its `git ls-files` resolves and the file:line it prints is
# repo-relative.
echo "--> lint-workflow-run-interpolation (\${{ }} substituted into run: script text)"
if ! replay_guard 2; then
  status=1
fi

# Fold in the errexit status-read guard, for the same reason as the two above:
# the linter above is silent on the class. An assignment takes its command
# substitution's exit status, so under `set -e` a failing command exits ON the
# assignment line and the `rc=$?` after it never runs -- every branch written to
# handle that failure is dead. SC2181 reaches the `if [ $? ]` spelling after a
# plain command and draws nothing on a capture, and shellcheck does not model
# `set -e` assignment status at all. It reaches further than the *.sh passes
# above for the same reason the path-quoting guard does: `run:` bodies are shell
# no *.sh glob sees, and that is exactly where both shipped instances of the
# class lived. Run from the repo root so its `git ls-files` discovery resolves
# and the file:line it prints is repo-relative.
echo "--> lint-errexit-status-read (\$? read after a command-substitution assignment under set -e)"
if ! replay_guard 3; then
  status=1
fi

# Fold in the SIGPIPE-reader guard, for the same reason again: shellcheck reads
# a pipeline into a quiet grep as well-formed, and it is, right up to the point
# where the quiet grep closes the pipe on its first match, the upstream dies of
# SIGPIPE, and `pipefail` hands the caller a FALSE that means a match was found.
# A fixture carrying both live shapes returns exit 0 at the `*.sh` severity floor
# this harness sets, so nothing here saw it; the class had four known
# occurrences, three of them inside guard machinery, before this gate existed.
# Run from the repo root so its `git ls-files` discovery resolves and the
# file:line it prints is repo-relative.
echo "--> lint-sigpipe-readers (a short-circuiting reader inverting a pipeline under pipefail)"
if ! replay_guard 4; then
  status=1
fi

# Fold in the hook cwd-relative-load guard, for the reason every gate above it
# rides here: shellcheck reads `[ -f .claude/hooks/lib/x.sh ] && . .claude/hooks/
# lib/x.sh` as well-formed, and it is, right up to the point where the hook runs
# from a working directory below the repository root, the test answers false for
# a library that is present, and the capability probe behind it takes the
# fail-open written for a library that is absent. Two of the hooks carrying the
# shape were blocking guards, and neither said anything when it stood down. The
# subshell `cd` below is retained only so a failure reads naturally, unlike the
# sibling gates it sits with: this one roots its own scan surface at its
# `${BASH_SOURCE[0]}` and never consults the working directory, which is the
# same property it exists to enforce, and its own suite pins that.
echo "--> lint-hook-cwd-relative-loads (a hook locating framework code from the working directory)"
if ! replay_guard 5; then
  status=1
fi

# Fold in the hook jq-availability guard, for the reason its siblings ride here:
# a `payload=$(jq -r ...)` read is well-formed to the static checker, and it is
# well-formed, right up to the point where jq is not installed, the read ends the
# hook at 127, and the PreToolUse contract reads every status but 2 as a
# non-blocking error. The refused call proceeds with no denial and no diagnostic,
# across the whole fail-closed layer at once.
echo "--> lint-hook-jq-availability (a blocking hook standing down on a missing jq)"
if ! replay_guard 6; then
  status=1
fi

report_verdict
