#!/usr/bin/env bash
# shell-lint.sh: run shellcheck over every tracked shell script, bats suite, and
# husky hook, then the hook array-guard (.gaia/scripts/lint-hook-array-guard.sh).
# Exit 0 when clean, 1 on any finding at or above the severity floor.
# Run it directly from anywhere: `bash .gaia/tests/shell-lint.sh`.
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

# Tracked files only. Worktrees under .claude/worktrees/ are untracked checkouts
# of these same scripts, so `git ls-files` never double-counts them.
#
# Collected with a read loop rather than `mapfile`: mapfile is bash 4+, and these
# scripts are authored and run on stock macOS /bin/bash (3.2.57).
sh_scripts=()
while IFS= read -r f; do
  sh_scripts+=("$f")
done < <(git -C "$REPO_ROOT" ls-files '*.sh')

bats_scripts=()
while IFS= read -r f; do
  bats_scripts+=("$f")
done < <(git -C "$REPO_ROOT" ls-files '*.bats')

husky_hooks=()
while IFS= read -r f; do
  husky_hooks+=("$f")
done < <(git -C "$REPO_ROOT" ls-files '.husky/*')

# Guard the expansion below: on bash 3.2 a bare "${sh_scripts[@]}" over an EMPTY
# array aborts with `unbound variable` under `set -u`. An empty *.sh result also
# means the glob or the repo root resolved wrong, which should fail loudly, not
# lint nothing and report success. The *.bats set is allowed to be empty and is
# simply skipped; only the always-present *.sh set is a hard precondition.
if [ "${#sh_scripts[@]}" -eq 0 ]; then
  echo "ERROR: no tracked *.sh files found under $REPO_ROOT" >&2
  exit 1
fi

# Run every pass before failing, so one invocation reports every finding across
# all passes rather than hiding a later pass's findings behind an earlier one.
status=0

echo "--> shellcheck *.sh (severity=$SH_SEVERITY): ${#sh_scripts[@]} tracked scripts"
# Run from the repo root so the paths the linter prints are repo-relative.
if ! (cd "$REPO_ROOT" && shellcheck --severity="$SH_SEVERITY" --exclude="$TOOLING_EXCLUDE" "${sh_scripts[@]}"); then
  status=1
fi

if [ "${#bats_scripts[@]}" -gt 0 ]; then
  echo "--> shellcheck *.bats (severity=$BATS_SEVERITY): ${#bats_scripts[@]} tracked suites"
  if ! (cd "$REPO_ROOT" && shellcheck --severity="$BATS_SEVERITY" --exclude="$TOOLING_EXCLUDE" "${bats_scripts[@]}"); then
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
  if ! (cd "$REPO_ROOT" && shellcheck -s sh --severity="$SH_SEVERITY" --exclude="$TOOLING_EXCLUDE" "${husky_hooks[@]}"); then
    status=1
  fi
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

if [ "$status" -ne 0 ]; then
  echo "==> shell-lint FAILED" >&2
  exit 1
fi

echo "==> shell-lint passed"
