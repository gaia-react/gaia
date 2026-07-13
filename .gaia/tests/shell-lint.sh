#!/usr/bin/env bash
# shell-lint.sh: run shellcheck over every tracked shell script in the repo.
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
# Severity floor: `warning`. Errors and warnings are the tiers with live failure
# modes (unquoted expansions that word-split, BSD-vs-GNU portability breaks,
# subshell scoping bugs). The `info`/`style` tiers are dominated here by
# SC2016 (single-quoted jq/awk programs, intentional) and SC1091 (shellcheck
# cannot resolve a dynamically sourced path), which would gate on noise. Run
# `shellcheck -S style <file>` by hand to see those tiers.
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

SEVERITY=warning

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
scripts=()
while IFS= read -r f; do
  scripts+=("$f")
done < <(git -C "$REPO_ROOT" ls-files '*.sh')

# Guard the expansion below: on bash 3.2 a bare "${scripts[@]}" over an EMPTY
# array aborts with `unbound variable` under `set -u`. An empty result also means
# the glob or the repo root resolved wrong, which should fail loudly, not lint
# nothing and report success.
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "ERROR: no tracked *.sh files found under $REPO_ROOT" >&2
  exit 1
fi

echo "--> shellcheck (severity=$SEVERITY): ${#scripts[@]} tracked scripts"

# Run from the repo root so the paths the linter prints are repo-relative.
if ! (cd "$REPO_ROOT" && shellcheck --severity="$SEVERITY" "${scripts[@]}"); then
  echo "==> shell-lint FAILED" >&2
  exit 1
fi

echo "==> shell-lint passed"
