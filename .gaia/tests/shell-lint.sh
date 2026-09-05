#!/usr/bin/env bash
# shell-lint.sh: run shellcheck over every tracked shell script, bats suite, and
# husky hook, then parse every tracked shell script with bash 3.2, then the
# repo-authored guards shellcheck cannot model: the hook
# array-guard (.gaia/scripts/lint-hook-array-guard.sh), the errexit source guard
# (.gaia/scripts/lint-errexit-source-guard.sh), the git path-quoting
# guard (.gaia/scripts/lint-git-path-quoting.sh), the workflow
# run-interpolation guard (.gaia/scripts/lint-workflow-run-interpolation.sh),
# the grep ERE-escape guard (.gaia/scripts/lint-grep-ere-escapes.sh), the
# errexit status-read guard (.gaia/scripts/lint-errexit-status-read.sh), the
# oracle-blind invocation guard
# (.gaia/scripts/lint-oracle-blind-invocations.sh), the stale-cardinal guard
# (.gaia/scripts/lint-stale-cardinals.sh), the guard-rule shell-coverage
# guard (.gaia/scripts/lint-guard-rule-shell-coverage.sh), the collapsed
# signal-trap guard (.gaia/scripts/lint-collapsed-signal-trap.sh), and the
# bundled-hooks inventory guard (.gaia/scripts/lint-hook-wiki-inventory.sh).
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
#            are dominated by structural false positives from the bats execution
#            model (SC2317 unreachable `@test`/`setup`/`teardown` bodies,
#            SC2030/SC2031 subshell state from `run`, SC2016 assertion strings);
#            those sit below the `warning` floor and never fire, so bats needs no
#            blunt per-code exclude list. Run `shellcheck -S style <file>` by hand
#            to see the sub-floor tiers.
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
# workers. Same fork/log/replay shape as .gaia/tests/run-bats-parallel.sh, and
# for the same reason: concurrent workers cannot write to a shared stdout, or
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

# Fold in the hook array-guard: shellcheck cannot model the bash-3.2.57
# empty-array abort -- a bare "${arr[@]}" over an EMPTY array aborts under
# `set -u`, exiting a hook before it can emit its deny JSON. Running it here
# means every shell-lint caller -- plan per-phase gates, the
# code-audit-maintainer-shell oracle, CI shell-lint.yml, and manual runs --
# enforces the class locally, not only the Audit CI Tests job. Run from
# the repo root so its cwd-relative .claude/hooks/*.sh scan resolves.
echo "--> lint-hook-array-guard (bash-3.2 empty-array class under set -u)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-hook-array-guard.sh"); then
  status=1
fi

# Fold in the errexit source guard, for the same reason as the array guard: the
# linter above cannot model it either. Under errexit, sourcing a file that is
# present but UNPARSEABLE abandons the shell at the load, which in a PreToolUse
# hook is exit 2 -- a deny on every matching call, including the edit that would
# repair the library. It works on the errexit-reachable source closure rather
# than on one file, so it sees a library's own loads whether or not a consumer
# parse-checked the library. Run from the repo root so its cwd-relative scan
# roots resolve and the file:line it prints is repo-relative.
echo "--> lint-errexit-source-guard (unbracketed source under errexit)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-errexit-source-guard.sh"); then
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
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh"); then
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
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-workflow-run-interpolation.sh"); then
  status=1
fi

# Fold in the grep ERE-escape guard, for the same reason as the three above:
# the linter above models the shell AROUND a regex and never the regex itself.
# POSIX leaves a backslash before a letter undefined in an ERE, and BSD grep
# (macOS) expands `\r` `\t` `\d` where GNU grep (the runner) matches the bare
# letter, so a pattern authored and verified locally means something else in CI.
# That is the class this gate reaches that the passes above cannot: it is
# invisible to shellcheck, invisible to a suite run on the authoring platform,
# and it fails toward a check that quietly passes. Run from the repo root so its
# `git ls-files` discovery resolves and the file:line it prints is
# repo-relative.
echo "--> lint-grep-ere-escapes (BSD-vs-GNU regex escapes in a grep -E pattern)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh"); then
  status=1
fi

# Fold in the errexit status-read guard, for the same reason as the four above:
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
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh"); then
  status=1
fi

# Fold in the oracle-blind invocation guard, for a reason the guards above do
# not share: the class it reads is not a defect in the shell at all. The file it
# flags runs correctly; what breaks is the capability oracle's record of what
# that file reaches for, and the manifests shipped off that record. No rule the
# linter above models touches it, and no suite over the oracle sees it either,
# because the trigger is the TREE growing an idiom rather than the oracle
# changing. Run from the repo root so its cwd-relative scan roots resolve and
# the file:line it prints is repo-relative.
echo "--> lint-oracle-blind-invocations (an invocation the capability oracle's anchors cannot see)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-oracle-blind-invocations.sh"); then
  status=1
fi

# Fold in the stale-cardinal guard, for a reason none of the guards above share:
# what it reads is not shell at all, it is the PROSE the shell carries. A
# comment or a bats test name asserting how many of something the tree holds is
# a claim nothing recounts, so it stays green while the set it names moves
# underneath it, and every tool above is blind to it by construction: shellcheck
# models the language, and the class lives in the text the language ignores.
# This gate is where it lands rather than in a suite of its own because the
# shell and bats half of its scan surface is already this gate's surface, and
# this is the pass every pull request runs. Its other half, the C-family globs
# `.claude/rules/code-comments.md` binds, reaches past this gate's own surface,
# so the paths filter in .github/workflows/shell-lint.yml carries those globs
# too: a filter narrower than the surface it arms greens a check that scanned
# nothing. Run from the repo root so its `git ls-files` discovery resolves and
# the file:line it prints is repo-relative.
echo "--> lint-stale-cardinals (a definite cardinal naming a set nothing recounts)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-stale-cardinals.sh"); then
  status=1
fi

# Fold in the guard-rule shell-coverage guard. Like the stale-cardinal guard
# above, what it reads is not shell but the prose binding shell: the `paths:`
# frontmatter by which .claude/rules/guards-must-fail.md and
# .claude/rules/partial-cause-reporting.md decide which surfaces they load on. A
# tracked shell file neither list names is one whose author is shown neither rule,
# and nothing else in this repository notices, because a rule that loads nowhere
# and a rule with nothing to say are the same silence. It lands in this gate
# because its scan surface IS this gate's surface -- the tracked shell set -- and
# this is the pass every pull request runs. It is advisory here; the blocking
# runner is its sibling suite .gaia/scripts/tests/lint-guard-rule-shell-coverage.bats
# in the `Audit CI Tests` scripts shard, armed by that job's `**/*.sh` code
# filter AND by its `.husky/**` entry: `**/*.sh` matches no extensionless
# hook, so a pull request touching only .husky/pre-commit arms this check
# through the husky glob alone. Both are named because that entry's own
# stated reason is a different suite, and trimming it on that reason would
# silently unarm this check for husky-only diffs.
# Run from the repo root so its `git ls-files` discovery resolves.
echo "--> lint-guard-rule-shell-coverage (tracked shell the guard/diagnostic rules do not reach)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-guard-rule-shell-coverage.sh"); then
  status=1
fi

# Fold in the collapsed signal-trap guard, for the same reason as the guards
# above: shellcheck models the syntax of a `trap` call and says nothing about
# which dispositions may share one arm. Bash resumes at the point of
# interruption once a trapped handler returns, so an arm shared between EXIT and
# INT or TERM silently deletes the terminating disposition it replaced and the
# script becomes uninterruptible. The class was repaired by hand twice and
# pinned each time by a per-file assertion in that script's own suite, which is
# the hand-kept list .claude/rules/guards-must-fail.md names as an arming-stage
# failure: the third instance sat unreached by any of it. This gate is what
# replaced those pins. Run from the repo root so its `git ls-files` discovery
# resolves and the file:line it prints is repo-relative.
echo "--> lint-collapsed-signal-trap (one trap arm binding EXIT with INT or TERM)"
if ! (cd "$REPO_ROOT" && bash "$REPO_ROOT/.gaia/scripts/lint-collapsed-signal-trap.sh"); then
  status=1
fi

# The bundled-hooks inventory in wiki/concepts/Claude Hooks.md is hand-kept, and
# it drifted silently until four registered hooks were missing from it at once
# (gaia-react/gaia#1786). This gate is what makes the next omission red on the
# pull request that registers the hook. Its subjects are .claude/settings.json
# and that page, neither of them shell, so it rides here rather than earning a
# workflow of its own: this harness is already the folded home for every guard
# that shellcheck cannot model, and the arming line for settings.json lives in
# .github/workflows/shell-lint.yml's paths filter alongside the others. It takes
# the root explicitly rather than resolving one ambiently: it reads two fixed
# paths and needs neither a working checkout nor git on PATH to compare them,
# and this harness already holds the value its argument-free arm would re-derive.
# Hence no `cd` and no subshell either, unlike the siblings above, whose
# tracked-file discovery genuinely needs the working directory.
echo "--> lint-hook-wiki-inventory (a registered hook absent from the bundled-hooks inventory)"
if ! bash "$REPO_ROOT/.gaia/scripts/lint-hook-wiki-inventory.sh" "$REPO_ROOT"; then
  status=1
fi

report_verdict
