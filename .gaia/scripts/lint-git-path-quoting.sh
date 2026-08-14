#!/usr/bin/env bash
# lint-git-path-quoting.sh: flag every executed `git diff --name-only` and every
# executed `git ls-files` that omits `-z`, across the framework's tracked shell
# and its CI workflow YAML. Exit 1 with a file:line report on any hit, exit 0
# when clean. Run it directly from the repo root:
# `bash .gaia/scripts/lint-git-path-quoting.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-git-path-quoting.bats, which the `Audit CI
# Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-git-path-quoting.bats`.
# gaia:maintainer-only:end
#
# Why: under git's default `core.quotePath`, a path-listing command C-quotes any
# path carrying a non-ASCII byte, a control character, a double quote or a
# backslash -- it prints `"caf\303\251.txt"`, not `café.txt`. Every consumer
# that then matches the output against a path pattern silently stops matching,
# and in this repository every such consumer fails OPEN: a gate that decides
# "no relevant files changed", or that discovers the files it is about to scan,
# reports its required check green having run nothing. `-z` turns the quoting
# off and NUL-delimits instead.
#
# The class is why this gate exists rather than a review habit. It has been
# found and fixed by hand SEVEN times, every time by a human or an audit member
# reading the code and never once by a check (`#1032`, `#1115`, `#1213`,
# `#1224`, `#1225`, `#1228`, `#1230`). `#1229` is the issue that stopped paying
# that tax for `diff --name-only`, and `#1389` is the one that stopped paying it
# for `ls-files` -- a variant the guard's first shape could not see, which is how
# the class recurred in five discovery call sites INCLUDING this file's own.
#
# Fix a `diff --name-only` hit with the idiom the repository already uses
# throughout:
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
# Fix an `ls-files` hit by reading the NUL stream directly, which keeps every
# byte of the path intact rather than round-tripping it through newlines:
#
#   while IFS= read -r -d '' f; do
#     scan_files+=("$f")
#   done < <(git -c core.quotepath=false ls-files -z <pathspecs>)
#
# `-z` alone is what disables the quoting; `-c core.quotepath=false` is
# belt-and-braces for the reader. A `| LC_ALL=C sort` on such a stream must
# become `| LC_ALL=C sort -z`, or the sort re-joins the records on newlines and
# undoes the fix. Both BSD sort (macOS) and GNU sort accept `-z`.
#
# A consumer that COUNTS rather than iterates takes `| tr -cd '\0' | wc -c`,
# never the `| tr '\0' '\n' | wc -l` round-trip above. Translating the records
# back to newlines makes a path holding a literal newline count twice, so on a
# counting consumer the repair advertised for an iterating one REGRESSES the
# site it was applied to: the pre-repair quoted spelling counted correctly,
# because quoting never splits a record. `-z` fixes the byte fidelity; only
# counting the separators themselves fixes the arithmetic.
#
# Reference fixes: .gaia/scripts/resolve-audit-members.sh (the `changed`
# derivation) and .gaia/tests/shell-lint.sh (the three discovery loops).
#
# Two `ls-files` shapes are deliberately NOT flagged, and each is a closed
# property of the call text rather than a judgment about its consumer:
#
#   --error-unmatch  -- the call is an existence assertion whose contract is its
#                       exit status, not its output; git's own documentation
#                       defines the flag that way. Every such call in this tree
#                       discards stdout. Demanding `-z` there would be a change
#                       with no failure mode behind it.
#   an option-less   -- `-z` is accepted anywhere in the call's OPTION region,
#   -z position         which ends at the first token not starting with `-` or
#                       at an explicit `--`. Unlike `diff --name-only`, whose
#                       `-z` is anchored immediately after the call, `ls-files`
#                       idiomatically carries selector options first
#                       (`--others --exclude-standard -z`). Terminating the walk
#                       at the option region is what stops a pathspec carrying
#                       the token from vouching for a call that still quotes.
#
# `git status --porcelain` is the third member of this family and is deliberately
# OUT of the declared surface rather than merely unreached. Its dominant shape in
# this repository is an emptiness test (`[ -z "$(git status --porcelain)" ]`),
# where quoting cannot change the verdict, and its remaining instances sit in
# adopter-facing workflow templates that regenerate through `bundle:adopter`.
# Claiming it here would red the gate on call sites that carry no failure mode,
# which is how a gate gets bypassed rather than fixed.
#
# One FAIL-OPEN in the `diff --name-only` half, stated here rather than left to
# be rediscovered, because it is the shape this gate is least able to see and the
# one a reader would otherwise assume is covered. The detector matches the call
# as a LITERAL SUBSTRING, so any option written between `diff` and `--name-only`
# hides the call from it: `git diff --cached --name-only` and the `--staged`
# spelling are never checked for `-z`. The `ls-files` half does not have this
# shape of hole, because it walks an option region instead of matching a fixed
# string.
#
# Closing the `diff` half means giving it that same walk and then repairing what
# the walk reaches. Of those sites only .claude/hooks/red-verify-commit-check.sh
# fails OPEN: a C-quoted staged test path matches no `app/*` pattern, so the
# RED-verify glob filter drops it and that guard passes having checked nothing.
# The rest fail closed or are unaffected. None miscounts: git C-quotes a path
# holding a newline onto ONE line, so a quoted line count already equals the
# record count, which is the same fact the counting paragraph above turns on.
#
# gaia-react/gaia#1392 owns the site table and the per-site failure directions,
# and is the ONE place they are maintained. A copy kept here drifts against it,
# which is not a hypothetical: this block carried such a copy for two rounds and
# was corrected in each, once for naming sites this gate's surface cannot reach
# and once for omitting the in-surface site carrying the live defect.
#
# So: the surface this file claims is at zero for `ls-files` and for the bare
# `diff --name-only` spelling, which is what the tests below pin. It is NOT a
# claim about every option spelling of `diff`.
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
# sibling suites run an unquoted `diff --name-only` under `core.quotePath=true`
# as the positive control proving git really does quote.
# A scanner reading raw lines cannot tell a fixture string from an executed
# call, so including them would demand "fixes" that delete the evidence the
# class exists.
scan_files=()
while IFS= read -r -d '' f; do
  scan_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '*.sh' '.husky/*' '.github/workflows/*.yml' '.github/workflows/*.yaml' | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is precisely the
# lie-green failure the gate itself exists to stop elsewhere. Every real tree
# carries tracked `*.sh`, so an empty result means the discovery is wrong rather
# than the tree. `.gaia/tests/shell-lint.sh` treats the identical condition as a
# hard error for its own discovery, and this is that reasoning applied here.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-git-path-quoting: ERROR: no tracked files matched the scan surface; nothing was scanned" >&2
  exit 1
fi

# scan_file <path>: print one `file:line: message` per unquoted call.
#
# Four discriminations, each earning its place on a real line in this
# repository rather than on symmetry:
#
#   invoked  -- the text immediately before the call is a `git` invocation,
#               optionally carrying -C/-c options. Without it,
#               check-audit-base-derivation.sh's GAIA_AUDIT_DIFF_CALL is a hit:
#               the call is that variable's VALUE, not a command.
#   in-span  -- an odd number of backticks before the call on the line means it
#               sits inside a markdown code span, so it is prose. Without it,
#               the audit workflow's agent prompt is a hit, where a code span
#               instructs a model to run the command.
#   anchored -- for `diff --name-only`, ` -z` must sit IMMEDIATELY after the
#               call, not merely somewhere in it. Unanchored, a pathspec
#               carrying the token vouches for a call that still quotes. The
#               same discrimination assertion 4 in
#               check-audit-base-derivation.sh makes, for the same reason.
#   in-option-region
#            -- for `ls-files`, whose selector options idiomatically precede
#               `-z`, the anchored rule above would reject every real call. The
#               walk accepts `-z` as a standalone token anywhere in the option
#               region and stops at the first token not beginning with `-`, or
#               at an explicit `--`. That termination is what preserves the
#               anchored rule's actual guarantee: a pathspec cannot vouch for
#               the call, because the walk never reaches one.
#
# Full-line comments are skipped outright, which covers both a shell comment and
# a `#` line inside a workflow `run:` block.
#
# Known blind spots, stated rather than discovered later, and split by which
# WAY they fail, because that is the part that matters and an earlier draft of
# this block got it wrong by calling them all fail-closed.
#
# The backtick boundary is stated as a RULE rather than as a list of shapes,
# deliberately. An enumeration of shapes is always one shape short, and each
# round of extending it invites the next; the rule below is closed, so it cannot
# be incomplete:
#
#   The command-position test recognizes a backtick opening immediately after
#   `=` or `(`, and NOTHING ELSE. Every other position is treated as a markdown
#   code span.
#
# Both of that rule's error directions follow from it and neither is a separate
# discovery:
#   - FAIL-OPEN: a backtick command substitution opening after anything else --
#     a quote, a pipe, a separator, or bare command position -- is missed. That
#     is a real miss, and closing it needs a shell tokenizer, which is more
#     machinery than this gate is worth.
#   - FAIL-CLOSED: parenthetical prose whose parenthesis is followed by a
#     backtick is flagged as an invocation. The repair is to reword the prose.
#
# The other boundaries, both FALSE POSITIVES, so both fail CLOSED. They demand
# `-z`, which is never wrong on a call whose output is parsed, so each costs a
# correct edit and never a missed defect:
#   - `-z` written on a line continuation after the call reads as missing.
#   - A single-quoted string containing a literal `git diff --name-only` reads
#     as an invocation. This is the sharper reason `*.bats` is out of scope.
#
# One further FALSE NEGATIVE, unrelated to backticks and equally tokenizer-bound:
#   - A call assembled through a variable (`$GIT diff --name-only`).
#
# Out of scope entirely: `-z` does not, on its own, survive a path containing a
# literal newline when the consumer re-splits on newlines via `tr`. That is a
# separate and far rarer class than the one this gate closes, and nothing here
# asserts otherwise.
scan_file() {
  local f="$1"
  awk -v file="$f" '
    # ls_verdict(window): walk the option region of an `ls-files` call, setting
    # has_z when a standalone -z appears in it and existence_only when
    # --error-unmatch does. Both are deliberately global: awk has no other way
    # to return a pair. The walk stops at the first token that is not an option,
    # which is exactly where a pathspec would begin, so a pathspec can never
    # vouch for the call.
    function ls_verdict(window,   n, i, tok, arr) {
      has_z = 0
      existence_only = 0
      n = split(window, arr, "[ \t]+")
      for (i = 1; i <= n; i++) {
        tok = arr[i]
        # Leading whitespace in the window yields an empty first field; it is
        # not a token, and skipping it must not terminate the walk.
        if (tok == "") continue
        if (tok == "--") break
        if (substr(tok, 1, 1) != "-") break
        if (tok == "-z") has_z = 1
        if (tok == "--error-unmatch") existence_only = 1
      }
    }
    BEGIN {
      ncalls = 2
      callname[1] = "diff --name-only"
      callname[2] = "ls-files"
    }
    /^[[:space:]]*#/ { next }
    {
      for (c = 1; c <= ncalls; c++) {
      call = callname[c]
      calllen = length(call)
      consumed = 0
      rest = $0
      while ((pos = index(rest, call)) > 0) {
        abs = consumed + pos
        prefix = substr($0, 1, abs - 1)
        window = substr($0, abs + calllen)

        # Any leading git global option, not just -c/-C: `git --no-pager diff
        # --name-only` is as much an invocation as `git -C "$root" diff`, and a
        # selector naming two options by hand misses the rest of an open set.
        # An option token is anything starting with `-`; the optional following
        # token is the value form -c/-C take.
        invoked = (prefix ~ /(^|[^[:alnum:]_.-])git( +-[^ ]+( +[^- ][^ ]*)?)* +$/)

        ticks = gsub(/`/, "`", prefix)
        inspan = (ticks % 2 == 1)
        # An odd backtick count alone cannot tell a markdown code span from a
        # LEGACY COMMAND SUBSTITUTION -- the two are textually identical, and
        # reading `changed=`git diff --name-only "$B"`` as prose is a fail-OPEN
        # miss rather than the fail-closed kind this scan is happy to make. A
        # backtick opening immediately after `=` or `(` is in command position,
        # so it is substitution rather than prose. Those two characters are the
        # whole rule, in both directions: every other opening position is missed
        # (fail-open) and parenthetical prose is flagged (fail-closed). The
        # blind-spot block above states that as a rule rather than enumerating
        # the shapes it produces.
        if (prefix ~ /[=(]`/) inspan = 0

        if (call == "ls-files") {
          ls_verdict(window)
          quoted_ok = (has_z || existence_only)
        } else {
          quoted_ok = (index(window, " -z") == 1)
        }

        if (invoked && !inspan && !quoted_ok)
          # The message deliberately does NOT put `git` in front of the call
          # name: with the binary name there, this very line matches the
          # detector and the gate flags its own diagnostic. Caught by running
          # the gate over its own tree, which is the cheapest possible proof
          # that the "invoked" discrimination works.
          printf "%s:%d: %s without -z: a C-quoted non-ASCII path stops matching in the consumer\n", file, NR, call
        consumed = abs + calllen - 1
        rest = substr($0, consumed + 1)
      }
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
  printf 'Fix a diff hit: changed="$(git diff --name-only -z "${base}...HEAD" | tr %s\\0%s %s\\n%s)"\n' "'" "'" "'" "'" >&2
  # The ls-files repair reads the NUL stream directly rather than translating it
  # back to newlines, so it needs no `tr` and survives a path containing one.
  # shellcheck disable=SC2016
  printf 'Fix an ls-files hit: while IFS= read -r -d %s%s f; do ...; done < <(git ls-files -z <pathspecs>)\n' "'" "'" >&2
  exit 1
fi

echo "lint-git-path-quoting: clean" >&2
exit 0
