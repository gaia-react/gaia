#!/usr/bin/env bash
# lint-diff-name-only-quoting.sh: flag every executed `git diff --name-only`
# that omits `-z`, across the framework's tracked shell and its CI workflow
# YAML. Exit 1 with a file:line report on any hit, exit 0 when clean. Run it
# directly from the repo root: `bash .gaia/scripts/lint-diff-name-only-quoting.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-diff-name-only-quoting.bats, which the `Audit CI
# Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-diff-name-only-quoting.bats`.
# gaia:maintainer-only:end
#
# Why: under git's default `core.quotePath`, `diff --name-only` C-quotes any
# path carrying a non-ASCII byte, a control character, a double quote or a
# backslash -- it prints `"caf\303\251.txt"`, not `café.txt`. Every consumer
# that then matches the output against a path pattern silently stops matching,
# and in this repository every such consumer fails OPEN: a gate that decides
# "no relevant files changed" reports its required check green having run
# nothing. `-z` turns the quoting off and NUL-delimits instead.
#
# The class is why this gate exists rather than a review habit. It has been
# found and fixed FIVE times in five files, every time by a human or an audit
# member reading the code and never once by a check (`#1213`, `#1224`, `#1225`,
# `#1228`, and the sweep landing alongside this file). `#1229` is the issue
# that stopped paying that tax.
#
# Fix any hit with the idiom the repository already uses in seven places:
#
#   changed="$(git diff --name-only -z "${base}...HEAD" | tr '\0' '\n')"
#
# In a workflow `run:` block under `set -eu`, put the pipeline in a subshell
# that sets pipefail, so a git failure still aborts the step as it did before
# the pipe existed -- `$(...)` alone discards NUL bytes, so the `tr` cannot be
# moved out of the substitution:
#
#   changed=$(set -o pipefail; git diff --name-only -z "$B...HEAD" | tr '\0' '\n')
#
# Reference fix: .gaia/scripts/resolve-audit-members.sh (the `changed` derivation).
#
# Sibling gate: .gaia/scripts/check-audit-base-derivation.sh's assertion 4 makes
# the same claim about the audit agents' prose. This file is deliberately not
# folded into it: that check's remit is the audit-base derivation, and its
# `consumes` predicate keys on BASE_REF / BASE_SHA / FULL_BASE / the resolver
# name, none of which any shell call site here mentions.

set -euo pipefail

# Scan surface: tracked shell, the extensionless husky hooks, and the workflow
# YAML whose `run:` blocks are shell by another name. `git ls-files` rather than
# a filesystem walk, so an untracked scratch script or a vendored dependency is
# never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these
# scripts run on stock macOS /bin/bash (3.2.57).
#
# `*.bats` is deliberately NOT in this list, and the omission is load-bearing
# rather than an oversight. The bats suites are where this class is DEMONSTRATED:
# .gaia/scripts/tests/check-audit-base-derivation.bats carries five
# intentionally-unquoted agent-prose fixtures that assertion 4 must catch, and
# five sibling suites run an unquoted `diff --name-only` under
# `core.quotePath=true` as the positive control proving git really does quote.
# A scanner reading raw lines cannot tell a fixture string from an executed
# call, so including them would demand "fixes" that delete the evidence the
# class exists.
scan_files=()
while IFS= read -r f; do
  scan_files+=("$f")
done < <(git ls-files '*.sh' '.husky/*' '.github/workflows/*.yml' '.github/workflows/*.yaml' | LC_ALL=C sort)

# scan_file <path>: print one `file:line: message` per unquoted call.
#
# Three discriminations, each earning its place on a real line in this
# repository rather than on symmetry:
#
#   invoked  -- the text immediately before the call is a `git` invocation,
#               optionally carrying -C/-c options. Without it,
#               .gaia/scripts/check-audit-base-derivation.sh:278 is a hit: the
#               call is the VALUE of GAIA_AUDIT_DIFF_CALL, not a command.
#   in-span  -- an odd number of backticks before the call on the line means it
#               sits inside a markdown code span, so it is prose. Without it,
#               .github/workflows/code-review-audit.yml:486 is a hit: an agent
#               prompt instructing a model to run the command.
#   anchored -- ` -z` must sit IMMEDIATELY after the call, not merely somewhere
#               in it. Unanchored, a pathspec carrying the token vouches for a
#               call that still quotes. The same discrimination assertion 4 in
#               check-audit-base-derivation.sh makes, for the same reason.
#
# Full-line comments are skipped outright, which covers both a shell comment and
# a `#` line inside a workflow `run:` block.
#
# Known blind spots, stated rather than discovered later. All three FALSE
# POSITIVES fail CLOSED -- they demand `-z`, which is never wrong on a call
# whose output is parsed -- so the boundary costs a correct edit, never a missed
# defect:
#   - `-z` written on a line continuation after the call reads as missing.
#   - A single-quoted string containing a literal `git diff --name-only` reads
#     as an invocation. This is the sharper reason `*.bats` is out of scope.
#   - A call assembled through a variable (`$GIT diff --name-only`) is invisible
#     to the scan. That one is a false NEGATIVE, and it is the boundary a raw
#     line scanner cannot close without becoming a shell tokenizer.
# `-z` also does not, on its own, survive a path containing a literal newline
# when the consumer re-splits on newlines via `tr`. That is a separate and far
# rarer class than the one this gate closes, and it is not asserted here.
scan_file() {
  local f="$1"
  awk -v file="$f" '
    /^[[:space:]]*#/ { next }
    {
      call = "diff --name-only"
      calllen = length(call)
      consumed = 0
      rest = $0
      while ((pos = index(rest, call)) > 0) {
        abs = consumed + pos
        prefix = substr($0, 1, abs - 1)
        window = substr($0, abs + calllen)

        invoked = (prefix ~ /(^|[^[:alnum:]_.-])git( +-[cC] +[^ ]+)* +$/)
        ticks = gsub(/`/, "`", prefix)
        inspan = (ticks % 2 == 1)
        quoted_ok = (index(window, " -z") == 1)

        if (invoked && !inspan && !quoted_ok)
          # The message deliberately does NOT read "git diff --name-only": with
          # the binary name in front of the call, this very line matches the
          # detector and the gate flags its own diagnostic. Caught by running
          # the gate over its own tree, which is the cheapest possible proof
          # that the "invoked" discrimination works.
          printf "%s:%d: diff --name-only without -z: a C-quoted non-ASCII path stops matching in the consumer\n", file, NR
        consumed = abs + calllen - 1
        rest = substr($0, consumed + 1)
      }
    }
  ' "$f"
}

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # printf, not echo: the hint text carries backslash escapes (`tr` operands),
  # and echo may expand them depending on the shell (SC2028). The format string
  # is single-quoted so the `$(...)` and `${base}` inside it stay literal -- it
  # is sample code being printed, not code being run. Disabled on this line
  # rather than file-wide, so a genuine SC2016 anywhere else here still fires.
  # shellcheck disable=SC2016
  printf 'Fix each: changed="$(git diff --name-only -z "${base}...HEAD" | tr %s\\0%s %s\\n%s)"\n' "'" "'" "'" "'" >&2
  exit 1
fi

echo "lint-diff-name-only-quoting: clean" >&2
exit 0
