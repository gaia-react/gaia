#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk programs below are single-quoted
# precisely so every `$`, `$(`, and awk field reference reaches awk as literal
# program text. shellcheck's built-in awk heuristic, which exempts a literal
# single-quoted program handed to a bare `awk` command word, does not extend
# to one handed to a variable command word ("$GAIA_AWK"), so this file needs
# the directive that a bare-`awk` invocation would not have.
# shellcheck disable=SC2016
#
# lint-errexit-source-guard.sh: flag every `source` / `.` that can run with
# errexit armed and is not bracketed against an unparseable target. Exit 1 with
# a file:line report on any hit, exit 0 when clean. Run it directly from the
# repo root: `bash .gaia/scripts/lint-errexit-source-guard.sh`.#
# Four statuses say the gate never ran at all: 2 when guard-awk-lib.sh is
# missing beside this script, 3 when the scan-surface discovery failed, 5 when
# no awk interpreter is present at all, and 6 when GAIA_AWK resolves to an
# interpreter that identifies as neither mawk nor BWK one-true-awk.
# gaia:maintainer-only:start
#
# Enforced twice, and only one of the two blocks a merge. The sibling bats suite
# .gaia/scripts/tests/lint-errexit-source-guard.bats runs in the `Audit CI Tests`
# scripts shard, a declared-required context; it fails when this scan finds a
# hit and self-tests the detector against known-bad fixtures. That job's `code`
# filter is what arms it, so every path the scan below reads has to be named
# there; a path the scan reads and the filter misses reports green having run
# this assertion zero times, which is the failure this gate exists to prevent,
# one level up. That obligation is discharged once and for all rather than per
# root: the scan surface is a SUBSET of every tracked `*.sh`, and the filter
# already carries a `**/*.sh` entry, so no widening of this scan can outrun the
# filter and the second edit a root used to owe is gone with the roots. Subset
# rather than equality is what makes the discharge sound: the filter arms on
# strictly more than the scan reads, and arming on more can only over-trigger
# the job, never leave a scanned path unarmed.
# `Shell Lint` runs the same scan a second way through .gaia/tests/shell-lint.sh;
# it is advisory rather than required, so it reports a regression without
# blocking the merge. Also runnable directly:
# `bats .gaia/scripts/tests/lint-errexit-source-guard.bats`.
# gaia:maintainer-only:end
#
# Why: under errexit, sourcing a file that is present but UNPARSEABLE abandons
# the shell at the load, on bash 3.2.57 and 5.3 alike. In a PreToolUse hook that
# exit is 2, the deny code, so an interrupted `/update-gaia`, an unresolved merge
# conflict, or a truncated write turns a hook into a gate that denies every tool
# call -- including the edit that would repair the library. The class has been
# repaired one site at a time, round after round, because the repair reached for
# was `bash -n X && . X`, a proof about exactly one file: `bash -n` does not
# RECURSE, so each round's fix left a residual one source level deeper, and each
# round found it there. This check works on the errexit-reachable source CLOSURE,
# so it sees a library's own loads whether or not any consumer parse-checked the
# library, and no future round can leave a residual it cannot see inside the
# scan surface below. The closure stops at that surface, which is every tracked
# `*.sh` outside `.husky/` and outside any `tests/` directory: a load in an
# UNTRACKED file, in one that is not a `.sh` at all, or in one the `tests/`
# prune removes, is outside this check whatever sources it. The prune is the
# qualifier worth reading twice, because it costs more than the fixtures it
# exists for: `.gaia/tests/distribution/` is a real maintainer harness rather
# than a bats corpus, and its unbracketed loads sit outside this closure. That
# qualifier is the honest form of the claim, and it no longer names a directory
# anyone has to remember to widen.
#
# Reference fixes: .claude/hooks/block-no-verify.sh (flat bracket, a file that
# arms errexit itself) and .claude/hooks/lib/verb-arming.sh (state-preserving
# bracket, a library that inherits it).
#
# The two accepted shapes, and why there are two rather than one:
#
#   # in a file that arms errexit ITSELF -- a flat restore is what it had
#   set +e; [ -f X ] && . X 2>/dev/null; set -e
#   type some_fn >/dev/null 2>&1 || <degrade>
#
#   # in a LIBRARY, which inherits errexit from whichever caller sourced it
#   errexit_was=0; case $- in *e*) errexit_was=1 ;; esac
#   set +e
#   . X 2>/dev/null
#   if [ "$errexit_was" = 1 ]; then set -e; fi
#   type some_fn >/dev/null 2>&1 || <degrade>
#
# A third requirement cuts ACROSS both shapes rather than adding a third one. A
# file that arms `trap ... ERR` has to disarm and re-arm the trap across the
# load as well as suspending errexit. The two mechanisms are independent:
# `set +e` stops errexit from aborting on a failing command and does nothing
# about an armed ERR trap, which fires on that same command regardless. So an
# unparseable target fires the trap mid-source and the shell leaves from inside
# the load, which is the outcome this check is named for, reached through the
# one door `set +e` does not close:
#
#   trap - ERR
#   set +e
#   . X 2>/dev/null
#   set -e
#   trap 'exit 0' ERR
#   type some_fn >/dev/null 2>&1 || <degrade>
#
# Reference fix: .claude/hooks/wiki-session-stop.sh, one of the sites repaired
# for gaia-react/gaia#1856. Every one of those had been passing this lint while
# carrying the defect, which is what put the requirement here rather than
# leaving it to review.
#
# `trap '' ERR` is the IGNORE disposition and `trap -p ERR` is a query; neither
# installs a handler, so neither demands the disarm. The signal word is read
# case-insensitively and with any quotes stripped, because bash accepts `err`
# and `"ERR"` as the same pseudo-signal. A missed DISARM is the direction that
# costs there: it would leave the walk believing a trap is still live and red a
# file that had in fact disarmed it.
#
# Three accepted misses, all deliberate. Whether the tree holds an instance of
# one is a fact about the tree rather than about the miss, so each carries its
# own answer below and no tally up here stands in for them.
#
# The arm reads a trap the file writes ITSELF, so a library that INHERITS an
# armed trap from whichever caller sourced it is outside it -- the same boundary
# the state-preserving shape exists to straddle for errexit, and closing it
# would owe a second closure beside the errexit one in pass 2. Live here:
# .claude/hooks/lib/gaia-active-plan.sh brackets its own load state-preservingly
# and disarms no trap, and token-rollup-merge.sh and token-tally-git-op.sh both
# source it while arming errexit AND an ERR trap. So widening this one would red
# a real site rather than none.
#
# A handler saved and restored through `$(trap -p ERR)` and `eval` is invisible
# for the ordinary reason, that the walk masks command substitutions. Nothing in
# the tree writes it.
#
# And the requirement is armed only inside the errexit-reachable closure, which
# the trap itself does not need: an armed ERR trap aborts on a failing load with
# no errexit anywhere. That one is a decided scope rather than an oversight.
# Seeding REACH from an ERR arm as well as from an errexit arm would red
# .claude/hooks/token-tally-review.sh, which arms the trap, never arms errexit,
# and loads unbracketed on purpose: its own comment records the trap firing as
# the intended exit-0 degrade. Widening the closure would have to answer that
# file first.
#
# One shape IS reported that a reader may expect to be exempt: a load inside an
# AND-OR list, `set +e; . X || true; set -e`. Bash exempts such a command from
# the ERR trap as well as from errexit, so the trap does not fire there. This
# check credits `||` nowhere -- an unbracketed `. X || true` is reported
# unguarded on the same stance -- so the arm inherits that stance rather than
# carving an exception into it, and the reported reason is worded to say the
# trap fires unless an enclosing AND-OR list exempts the load, rather than
# claiming it always fires.
#
# A library's callers do not all arm errexit -- verb-arming.sh has several
# consumers that do not -- so a flat `set -e` ARMS errexit in those, and the caller
# then dies at its next non-zero command. That is why the flat shape is a hit at
# a library site rather than a style preference, and why this check answers a
# second question per site: is this file an ENTRY POINT, or is it sourced?
#
# The entry-point test is "arms errexit itself AND nothing in the scan set
# sources it", not "arms errexit itself". A file can be both: a script run as
# `bash <path>` that a second file also sources. Its own `set -e` says nothing
# about the shell it lands in when it is sourced, so the weaker test would
# certify a flat restore in exactly the file that has both callers to get wrong.
#
# `"${BASH:-bash}" -n X && . X` is also accepted. It is measurably safe (it
# degrades on missing and on unparseable, both interpreters) and a good many
# sites carry it; it costs a fork per load, which is why it is not the shape to
# reach for in new code, but it is not a defect.
#
# What this check does NOT cover, decided rather than inherited: whether the
# DEGRADE path is itself safe. A guarded load that fails still leaves every
# variable the successful load would have assigned unset, and under `set -u` the
# first read of one aborts the shell just as the source would have -- which is
# how block-rm-rf.sh failed while this class was being repaired. That is a
# different predicate (unset-variable reachability, not guard shape), it needs
# the whole function body rather than the load site, and folding it in here
# would make one check answer two questions and report both under one name. It
# is left to `type <fn> >/dev/null 2>&1 || <degrade>` at the site, which every
# reference fix above already carries, and to review.

set -euo pipefail

# Scan surface: every tracked `*.sh` outside `.husky/` and outside any `tests/`
# directory, derived from the shared library rather than enumerated here. The
# `.husky` half is the shared `shell` set's own pathspec, which excludes the
# directory the `husky` set owns; the `tests/` half is applied below. Paths come
# back repo-relative, so the printed file:line is repo-relative.
#
# It was a hand-listed root array until gaia-react/gaia#1880, and that array
# missed a root three recounts running: #1846 hit the class in `.github` and
# handed the question back, #1870 answered it for `.github` alone, and #1880
# found eleven more instances one root further out, under
# `.specify/extensions/gaia/lib`, every one of them in a file that SHIPS to
# adopters. An enumeration maintained by hand is wrong the moment the tree
# grows, and a guard whose SCOPE is enumerated has the same defect as a guard
# whose CRITERIA are. Deriving the surface is what makes a fourth miss
# impossible rather than merely unexpected, and it is the majority idiom among
# the sibling `lint-*.sh` gates: they reach their surfaces through this same
# shared library, through their own `git ls-files` pathspecs, through the
# committed manifest, or through the hook registrations, and a hand-listed root
# array is the rare shape rather than the usual one. Grepping for
# `gaia_guard_scan_files` and `ls-files` finds most of them but not all, since
# the manifest and registration readers derive without either, so the leftovers
# of that grep are not the hand-listed set and reading the leftovers is what
# separates the two. The switch was measured to be surface-equivalent over the
# roots the array already named -- the tracked set and the old `find` walk
# agreed file for file -- so it changed nothing about what is scanned except
# adding the roots the array was missing.
#
# The old array carried a rule about where a root may be written, base
# assignment for a root that ships and a maintainer-only block for one that does
# not, so that the release runtime-dependency check would not read a shipped
# script as reaching for a path the bundle does not carry. Derivation retires
# that rule rather than restating it: the surface is whatever the tree in front
# of the guard tracks, so an adopter clone resolves its own and there is no
# assignment left to place wrongly.
#
# The `tests/` prune is applied HERE rather than in the shared library, because
# four other gates consume the same `shell` set and none of them wants one.
# Their bats fixtures deliberately plant broken loads, and a check that reads
# its own negative fixtures as findings can never be clean. One `*/tests/*`
# case rather than a per-directory list, so it covers `.gaia/scripts/tests` and
# `.github/audit/tests` alike and needs no edit when shell appears somewhere new.
#
# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no `.gaia/scripts/`. Bracketed
# against an unparseable target because this file arms errexit itself, which is
# the flat shape this very guard demands of such a load.
_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  echo "lint-errexit-source-guard: guard-awk-lib.sh is missing beside this script" >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    echo "lint-errexit-source-guard: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present" >&2
    exit 5
    ;;
  6)
    printf 'lint-errexit-source-guard: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENT" >&2
    exit 6
    ;;
esac

# `git ls-files` resolves against the working directory, not the repository, so
# from a subdirectory the surface silently narrows to that subtree and the scan
# reports clean having read a fraction of the tree. That is the same
# partial-surface-reads-clean failure the old root array's missing-root
# assertion refused, and losing it with the array would trade one silent
# narrowing for another. `--show-prefix` is empty only at the top level, and it
# answers without comparing two paths, so a symlinked checkout (`/var` ->
# `/private/var`, which every bats fixture under `mktemp -d` sits behind) cannot
# make a correct invocation look wrong.
if ! scan_prefix="$(git rev-parse --show-prefix 2>/dev/null)"; then
  echo "lint-errexit-source-guard: not inside a git work tree, so the scan surface cannot be resolved; nothing was scanned" >&2
  exit 2
fi
if [ -n "$scan_prefix" ]; then
  echo "lint-errexit-source-guard: run from the repository root; from '${scan_prefix%/}' the surface would silently narrow to that subtree" >&2
  exit 2
fi

# The library's own status is carried out rather than flattened to 1: 1 says the
# tree was read and held no tracked shell at all, 3 says it was never read, and
# an operator handed 1 for the second would look at the tree instead of at the
# discovery. The status is read directly rather than through a substitution,
# which would swallow it.
gaia_guard_scan_files "lint-errexit-source-guard" shell || exit $?

scan_files=()
for scan_candidate in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
  case "$scan_candidate" in */tests/*) continue ;; esac
  scan_files[${#scan_files[@]}]="$scan_candidate"
done

# Distinct from the library's own empty-union refusal above, which fires when
# the tree carries no tracked shell at all. This one fires when it carries some
# and the prune took every file, a surface the scan below would otherwise report
# clean having opened nothing.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-errexit-source-guard: every tracked shell file sits under a tests/ directory; nothing was scanned" >&2
  exit 1
fi

# Pass 1. Per file, emit two record kinds on stdout:
#   ARM|<file>                                  the file arms errexit itself
#   SITE|<file>|<line>|<target>|<shape>|<text>  one source site
# `shape` is decided from the file alone: parsecheck, cond, flat, leak, none.
# Reachability is global and is decided in pass 2; a site in a file that never
# runs under errexit is reported by pass 1 and dropped there.
records="$("$GAIA_AWK" '
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

  # Strip a trailing comment. Only ever removes text, so it can hide a site,
  # never invent one; a `#` inside a string costs at most the rest of that line.
  function decomment(s,   i, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = "" ; continue }
      if (c == "\"" || c == "'"'"'") { q = c; continue }
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) return substr(s, 1, i - 1)
    }
    return s
  }

  # Blank out `$(...)`, `${...}` and backtick spans, replacing each with a single
  # `@`. Everything below splits the line on shell separators to find command
  # position, and a `(` or `{` inside an operand -- `. "$(dirname "$0")/lib.sh"`,
  # `. "${dir:-}/lib.sh"` -- splits the load away from its own operand and hides
  # the site. Masking first keeps the separators that are separators.
  # `close` and `index` are awk built-ins, so the delimiters are named cl/op.
  #
  # Quote state is not optional here, though it looks like a refinement. Single
  # quotes suspend every expansion, so a `$(`, `${` or backtick written inside
  # them is a literal character; read as a span opener it starts a depth walk
  # that never closes, and the whole tail of the line becomes one sentinel.
  # Line-locally that hides a load written after it. File-wide it is worse: the
  # block-depth counters read this same masked line, so a `fi` or `esac` lost to
  # the erase leaves the depth elevated for every remaining line of the file,
  # and every later flat restore in a library is then credited as a conditional
  # one. Masking stays ON inside DOUBLE quotes, because `. "$(dirname "$0")/x.sh"`
  # depends on it, and an unbalanced `$(` there is a real line continuation
  # whose tail genuinely belongs to the span.
  function mask(s,   out, i, c, d, cl, op, q, len) {
    out = ""
    q = ""
    len = length(s)
    for (i = 1; i <= len; i++) {
      c = substr(s, i, 1)
      if (q == "'"'"'") { out = out c; if (c == "'"'"'") q = ""; continue }
      if (c == "\\" && i < len) { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == "'"'"'" && q == "") { q = "'"'"'"; out = out c; continue }
      if (c == "\"") { q = (q == "\"") ? "" : "\""; out = out c; continue }
      if (c == "`") {
        i++
        while (i <= len && substr(s, i, 1) != "`") i++
        out = out "@"
        continue
      }
      if (c == "$" && (substr(s, i + 1, 1) == "(" || substr(s, i + 1, 1) == "{")) {
        op = substr(s, i + 1, 1)
        cl = (op == "(") ? ")" : "}"
        d = 0
        i++
        for (; i <= len; i++) {
          c = substr(s, i, 1)
          if (c == op) d++
          else if (c == cl) { d--; if (d == 0) break }
        }
        out = out "@"
        continue
      }
      out = out c
    }
    return out
  }

  # Quoted spans blanked to spaces, with the quote characters kept and the
  # LENGTH PRESERVED, so a position computed over this string indexes the same
  # column as the string it was made from. The event scan needs both halves:
  # `echo "remember to run set -e"` sitting between a suspend and a load
  # otherwise closes the suspend and the load is then reported unguarded, and a
  # string spelling `set +e` above a genuinely unguarded load makes the check
  # report a suspend that never happened. Both directions cost diagnostic
  # accuracy rather than coverage, which is why this blanks rather than drops.
  function blank_quoted(s,   i, c, q, out, len) {
    out = ""
    q = ""
    len = length(s)
    for (i = 1; i <= len; i++) {
      c = substr(s, i, 1)
      if (q != "") {
        # Inside double quotes a backslash escapes the next character, so a
        # `\"` must not be read as the closing quote.
        if (c == "\\" && q == "\"" && i < len) { out = out "  "; i++; continue }
        out = out ((c == q) ? c : " ")
        if (c == q) q = ""
        continue
      }
      if (c == "\\" && i < len) { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == "\"" || c == "\047") { q = c; out = out c; continue }
      out = out c
    }
    return out
  }

  # How many conditional constructs this text opens, and how many it closes.
  # Command position, not text proximity, for the same reason `is_load` tests
  # it: `esac` inside a word is not a block terminator.
  function opens(s,   c, t) {
    c = 0
    t = s
    while (match(t, /(^|[;&|(){}[:space:]])(if|case)([[:space:]]|$)/)) {
      c++
      t = substr(t, RSTART + RLENGTH - 1)
    }
    return c
  }

  function closes(s,   c, t) {
    c = 0
    t = s
    while (match(t, /(^|[;&|(){}[:space:]])(fi|esac)([[:space:]]|;|$)/)) {
      c++
      t = substr(t, RSTART + RLENGTH - 1)
    }
    return c
  }

  # The delimiters of every heredoc this line OPENS, newline-separated, or
  # empty. A line may open more than one (`cat <<A <<B` runs the bodies in
  # order), so the caller consumes them as a queue rather than tracking one:
  # returning only the first leaves the body of B read as shell, and a `set +e`
  # or a load written inside it becomes an event the file does not contain.
  #
  # A character walk
  # rather than a regex, because the two shapes a regex gets wrong are both live
  # in this tree and both fail OPEN: a `<<WORD` inside a quoted string opens a
  # heredoc that never closes, and every line below it is then skipped as body,
  # so the scan reports clean over input it never read; and `<<<WORD` is a
  # herestring, whose operand is a word on this same line rather than a body on
  # the lines below.
  #
  # `.gaia/scripts/lint-errexit-status-read.sh` carries a fuller tracker of the
  # same kind, inside a walk that also holds quote state ACROSS lines. This one
  # is deliberately narrower: it answers one question per line and carries no
  # state between them, which is what the event scan needs and all it can use.
  # What bounds the difference is not the walk but the end-of-file guard below.
  # A heredoc still open when the file ends is reported and fails the check, so
  # a shape this walk reads wrong stops the scan loudly instead of silently
  # skipping the rest of a file.
  function heredoc_delim(s,   i, c, q, arith, j, ch, d, len, all, pre, tabs) {
    q = ""
    arith = 0
    all = ""
    len = length(s)
    for (i = 1; i <= len; i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = ""; continue }
      if (c == "\\") { i++; continue }
      if (c == "\"" || c == "\047") { q = c; continue }
      # `$(( ))`, where `<<` is a left shift and not a redirection.
      if (c == "$" && substr(s, i + 1, 2) == "((") { arith++; i += 2; continue }
      # The bare `(( ))` arithmetic COMMAND is the same left shift in a
      # different spelling, and missing it is the worse failure of the two: the
      # digits of `(( n = n << 3 ))` read as a delimiter, every line below is
      # skipped as body, and the check exits reporting a heredoc that does not
      # exist while the loads below it genuinely went unread. Command position
      # is what separates it from a `(` inside an operand; `let n=n<<3` needs no
      # carve-out, because bash itself parses that `<<` as a redirection. `for`
      # belongs in the keyword list beside the others: the C-style
      # `for (( i = 0; i < (n << 2); i++ ))` header is the arithmetic spelling
      # this tree actually uses, and it is the one with live sites.
      if (c == "(" && substr(s, i + 1, 1) == "(") {
        pre = substr(s, 1, i - 1)
        if (pre ~ /(^|[;&|(){}[:space:]])(if|while|until|then|else|elif|do|for)[[:space:]]+$/ \
            || pre ~ /(^|[;&|(){}])[[:space:]]*$/) { arith++; i++; continue }
      }
      if (arith > 0 && c == ")" && substr(s, i + 1, 1) == ")") { arith--; i++; continue }
      if (c != "<" || substr(s, i + 1, 1) != "<" || arith > 0) continue
      if (substr(s, i + 2, 1) == "<") { i += 2; continue }
      j = i + 2
      tabs = 0
      if (substr(s, j, 1) == "-") { tabs = 1; j++ }
      while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
      d = ""
      ch = substr(s, j, 1)
      if (ch == "\047" || ch == "\"") {
        j++
        while (j <= len && substr(s, j, 1) != ch) { d = d substr(s, j, 1); j++ }
        j++
      } else {
        while (j <= len && substr(s, j, 1) ~ /[A-Za-z0-9_.\/-]/) { d = d substr(s, j, 1); j++ }
      }
      # Queued with the form that opened it, because only `<<-` allows the
      # terminator to be indented. Stripping tabs for every heredoc lets a
      # tab-indented delimiter close a plain `<<EOF` the shell keeps reading,
      # and every line the shell still hands over as data is then read as code.
      if (d != "") all = all (all == "" ? "" : "\n") (tabs ? "T" : "P") d
      i = j - 1
    }
    return all
  }

  # The delimiter at the head of the pending queue, and the queue with that
  # head removed.
  function hd_head(qq) { return (index(qq, "\n")) ? substr(qq, 1, index(qq, "\n") - 1) : qq }
  function hd_rest(qq) { return (index(qq, "\n")) ? substr(qq, index(qq, "\n") + 1) : "" }

  # The basename of the first .sh operand on the line, which is the load target
  # at every site in this tree. Empty when the operand is a bare variable.
  function target(s,   t) {
    if (!match(s, /[A-Za-z0-9_.-]+\.sh/)) return ""
    t = substr(s, RSTART, RLENGTH)
    return t
  }

  # Is this segment a LOAD? Command position, not text proximity: `jq -e . "$f"`
  # and `git grep -- .` put the dot in an argument slot and are not loads.
  # Leading keywords are stripped so `if . "$p"; then` reads as a load, which is
  # the spelling that went undetected for a full release (gaia-react/gaia#1549).
  #
  # The operand test is what keeps English out. A deny message carrying
  # `(wiki/concepts/Git Workflow.md). Create a feature branch` splits at the
  # `)` into a segment whose first word IS a dot, and the sentence that follows
  # is not a path. Two conditions together, and the second is the load-bearing
  # one: an operand names a `.sh` file or is a bare variable expansion, AND the
  # segment ENDS there, carrying nothing after the operand but redirections. A
  # sentence continues past its variable -- `... $((a - b)) row(s). $ledger is
  # untouched.` -- and two such lines are live in this tree today. Without the
  # end-of-segment test a log string reads as an unguarded load the moment its
  # file arms errexit, and the check reports a remedy that makes no sense for it.
  #
  # An operand the mask reduced to the sentinel WAS a whole `${...}` or `$(...)`
  # expansion, so it names a file this walk cannot resolve and the load still
  # has to be judged; without that arm the braced spellings pass silently.
  function segment_is_load(w,   op, rem) {
    while (w ~ /^(if|elif|while|until|then|else|do|!|time|exec)[[:space:]]/) {
      sub(/^(if|elif|while|until|then|else|do|!|time|exec)[[:space:]]+/, "", w)
    }
    if (w !~ /^(\.|source)[[:space:]]/) return 0
    sub(/^(\.|source)[[:space:]]+/, "", w)
    op = w
    sub(/[[:space:]].*$/, "", op)
    rem = trim(substr(w, length(op) + 1))
    # Only redirections may follow. `2>/dev/null`, `>/dev/null 2>&1`, `>&2`.
    # Accepted miss, stated rather than silent: `source lib.sh --flag` passes
    # ARGUMENTS to the sourced file, a legal spelling this tree does not use,
    # and it reads as not-a-load rather than as an unguarded one. Admitting a
    # trailing word would readmit every sentence whose next word is a variable,
    # which is the thing this test exists to keep out.
    if (rem != "" && rem !~ /^([0-9]*[<>]+&?[[:space:]]*[^[:space:]]*[[:space:]]*)+$/) return 0
    if (op ~ /\.sh["'"'"']?$/) return 1
    if (op ~ /^["'"'"']?\$[A-Za-z_][A-Za-z0-9_]*["'"'"']?$/) return 1
    if (op ~ /^["'"'"']?@["'"'"']?$/) return 1
    return 0
  }

  # WHERE on the line the load sits, so a same-line `set +e` ahead of it and a
  # same-line `set -e` behind it are read in the order the shell reads them --
  # and 0 when the line carries no load at all.
  #
  # ONE predicate decides both the column and the load-ness, of the SAME token.
  # Splitting them is what put a decoy column on a real site twice: a quoted
  # decoy first, then an unquoted argument-position dot after the quote filter
  # landed. Either way the site sorted to the decoy, and a decoy sitting inside
  # a closed `set +e`..`set -e` span made a genuinely unguarded load after that
  # span read as bracketed, so the gate exited clean on the class it exists to
  # catch. Each candidate is now tested where it stands: blanked in `qq` means
  # it existed only inside a string, and its own segment -- from the token to
  # the next separator -- has to read as a load on its own terms.
  # EVERY accepted position, space-joined, or empty when the line carries no
  # load. Returning only the first leaves a second load on the same line judged
  # by nothing, and -- worse -- draws no closure edge, so every unguarded load
  # inside the file it reaches is dropped along with it. The compact one-line
  # bracket this check itself prescribes is what invites writing two.
  function load_pos(mm, qq,   rest, off, seg, p, ms, ml, all) {
    all = ""
    rest = mm
    off = 0
    while (length(rest) > 0) {
      if (match(rest, /&&|\|\||[;|&(){}]/)) {
        ms = RSTART
        ml = RLENGTH
        seg = substr(rest, 1, ms - 1)
      } else {
        ms = 0
        ml = 0
        seg = rest
      }
      # The WHOLE segment, from one separator to the next, because command
      # position is what `segment_is_load` tests and a slice starting at the
      # token makes that token the first word by construction: `grep -Iq . "$f"`
      # would then read as a load of `"$f"`.
      if (segment_is_load(trim(seg))) {
        if (match(seg, /(^|[[:space:]])(\.|source)[[:space:]]/)) {
          p = off + RSTART
          if (substr(seg, RSTART, 1) != "." && substr(seg, RSTART, 1) != "s") p++
          if (substr(qq, p, 1) != " ") all = all (all == "" ? "" : " ") p
        }
      }
      if (ms == 0) break
      off = off + ms + ml - 1
      rest = substr(rest, ms + ml)
    }
    return all
  }

  # Does a `bash -n` credit live on this line, with its FLAG outside every
  # string? The bash token itself is read from the raw line on purpose: the live
  # reference shape writes it as `"${BASH:-bash}" -n X`, where the name sits
  # INSIDE quotes while the flag does not, so requiring the name to be unquoted
  # would refuse the shape this check recommends. Requiring the flag to be
  # unquoted is what refuses a decoy that spells a whole invocation inside a
  # message string, which would otherwise certify a genuinely unguarded load of
  # the same target sitting beside it.
  #
  # `qb` is the raw line with quoted interiors blanked, so it indexes the same
  # columns; the masked view cannot be used here because masking changes length.
  function has_parse_check(raw, qb,   t, off, p, ms, ml) {
    t = qb
    off = 0
    while (match(t, /[[:space:]]-n[[:space:]]/)) {
      # Snapshot before bash_invocation, which calls match() itself.
      ms = RSTART
      ml = RLENGTH
      p = off + ms
      if (bash_invocation(substr(raw, 1, p + ml - 1))) return 1
      off = off + ms + ml - 1
      t = substr(t, ms + ml)
    }
    return 0
  }

  # Is `pre` -- the raw text from the start of the line through the `-n` this
  # walk just matched -- a BASH INVOCATION carrying that flag? Three steps: cut
  # back to the command segment, strip the compound-command keywords that may
  # precede a command word, and require the command WORD itself to name bash.
  #
  # Command position is the whole point, and a substring test is what it
  # replaces. `${BASH_SOURCE[0]}` and `${BASH_VERSINFO[0]}` are this tree`s
  # commonest library-header idioms, and both name the string this test used to
  # look for, so `[ "${BASH_SOURCE[0]}" != "" -a -n "$x" ] && . X` read as a
  # parse-checked load of X. The header above states the stronger contract this
  # implements: the `-n` is a flag to a bash invocation, in that order and with
  # no command separator between them.
  #
  # Three spellings are accepted, all of them live here: a bare `bash`, a path
  # ending in `/bash`, and a parameter expansion of `BASH` -- the reference
  # shape writes `"${BASH:-bash}" -n X`, with the name inside quotes, which is
  # why the quotes are stripped rather than required absent, and why a `:-`
  # default is read and required to name bash too.
  #
  # The strip has to name EVERY reserved word that can precede a command word,
  # or the command this reads is the keyword and a real check goes uncredited.
  # A first draft named `if`/`elif`/`then`/`do` and stopped, which refused four
  # one-line spellings the check credited before it: an `else` arm, a `while` or
  # `until` header, and a `case` arm. None can be a command name, so stripping
  # them opens no hole this arm did not already have -- the same-line credit has
  # never tested the ORDER of the check and the load, so `. X; bash -n X` is
  # credited too. Ordering is what the multi-line arm`s `then` containment test
  # buys, and widening this list neither adds to nor subtracts from it.
  #
  # Refused, fail-closed and deliberately, each of them absent from this tree:
  # `! bash -n X`, whose negation inverts the answer, so crediting the branch
  # below it would be backwards; an invocation behind an environment assignment
  # or behind `env`/`command`; and any non-option word between the command word
  # and the flag, which is what keeps `bash X -n` from certifying a load of X.
  # Every one of those reports a load whose author can re-spell it into a
  # credited shape. The opposite direction certifies a load nothing checked,
  # which is the abort this whole check exists to end.
  function bash_invocation(pre,   w, mid, d) {
    sub(/^.*[;&|]/, "", pre)
    sub(/[[:space:]]+-n[[:space:]]*$/, "", pre)
    pre = trim(pre)
    while (match(pre, /^([{(]|if|elif|else|then|do|while|until)[[:space:]]+/) \
           || match(pre, /^case[[:space:]]+[^[:space:]]+[[:space:]]+in[[:space:]]+/) \
           || match(pre, /^[(]?[^[:space:]()]+[)][[:space:]]+/)) {
      pre = trim(substr(pre, RLENGTH + 1))
    }
    w = pre
    sub(/[[:space:]].*$/, "", w)
    mid = substr(pre, length(w) + 1)
    if (mid !~ /^([[:space:]]+-[^[:space:]]*)*[[:space:]]*$/) return 0
    gsub(/["\047]/, "", w)
    if (w ~ /(^|\/)bash$/) return 1
    if (w ~ /^\$[{]?BASH[}]?$/) return 1
    if (w ~ /^\$[{]BASH:[-=][^}]*[}]$/) {
      d = w
      sub(/^\$[{]BASH:[-=]/, "", d)
      sub(/[}]$/, "", d)
      return (d ~ /(^|\/)bash$/)
    }
    return 0
  }

  FNR == 1 { if (n > 0) flush(); n = 0; file = FILENAME }
  { n++; L[n] = decomment($0); RAW[n] = $0; QL[n] = blank_quoted(L[n]) }

  # ERR-trap disposition from one `trap` call. `s` starts at the `trap` token on
  # the quote-blanked masked line; the return is "errarm" when the call INSTALLS
  # a handler for ERR, "errdis" when it removes or ignores one, and "" when the
  # call does not name ERR or installs nothing.
  #
  # Read off the quote-blanked view like every other predicate in the walk, so a
  # `trap ... ERR` spelled inside a string arms nothing. That view keeps the
  # quote characters and blanks what sits between them, which is what lets the
  # EMPTY handler be told from a non-empty one: an empty handler bound to ERR is
  # the ignore disposition, fires nothing, and owes no disarm. The action is read
  # by hand rather than by a quote-stripping regex because an octal escape
  # inside an ERE is not portable across the awks this runs on.
  #
  # Both views of the line are needed, and `qs` and `ms` are the SAME line in
  # each: blanking preserves length, so an index computed over the blanked view
  # addresses the same column of the masked one. The ACTION is read off the
  # blanked view, which is what tells an empty handler from a non-empty one. The
  # SIGNAL LIST is read off the masked view, where a quoted signal word still
  # carries its letters; blanking has emptied them, and reading the list there
  # would take `trap - "ERR"` for a call naming no signal at all.
  function trap_err(qs, ms,   tail, mtail, i, k, c, len, act, w, nw, saw, sig) {
    tail = qs
    mtail = ms
    # Strip the `trap` token and its trailing whitespace from both views by the
    # same width, or every index below addresses the wrong column of `mtail`.
    if (!match(tail, /^trap[[:space:]]+/)) return ""
    tail = substr(tail, RLENGTH + 1)
    mtail = substr(mtail, RLENGTH + 1)
    # Stop at the first command separator, so a one-line `trap - ERR; set +e`
    # does not read the rest of the line as part of the signal list. A separator
    # inside a quoted handler was blanked to a space before this ran.
    if (match(tail, /[;&|)}]/)) {
      tail = substr(tail, 1, RSTART - 1)
      mtail = substr(mtail, 1, RSTART - 1)
    }
    len = length(tail)
    c = substr(tail, 1, 1)
    if (c == "\047" || c == "\"") {
      for (i = 2; i <= len && substr(tail, i, 1) != c; i++) ;
      act = (i == 2) ? "E" : "A"
      i++
    } else {
      for (i = 1; i <= len && substr(tail, i, 1) !~ /[[:space:]]/; i++) ;
      act = substr(tail, 1, i - 1)
    }
    # Bash accepts the pseudo-signal in any case and through a quoted word, so
    # both are normalized away before the compare. The quote strip goes through
    # a STRING regex rather than an ERE literal for the portability reason
    # above; neither quote character is a metacharacter, so it needs no escape.
    saw = 0
    nw = split(substr(mtail, i), w, /[[:space:]]+/)
    for (k = 1; k <= nw; k++) {
      sig = w[k]
      gsub("\047", "", sig)
      gsub("\"", "", sig)
      if (toupper(sig) == "ERR") saw = 1
    }
    if (!saw) return ""
    if (act == "-p" || act == "-l") return ""
    if (act == "-" || act == "E") return "errdis"
    return "errarm"
  }

  function flush(   i, s, j, k, pos, ev, evn, evt, evp, suspended, armed, tgt,
                    errarmed,
                    sn, sline, sshape, sdepth, back, found, res, capture,
                    m, q, mrest, cur, pfx, indepth, blockdepth, capdepth,
                    mstart, mlen, lps, lpa, np) {
    # Event stream over the whole file, in position order within each line, so a
    # one-line `set +e; . X; set -e` bracket is read the way the shell reads it.
    evn = 0
    capture = 0
    heredoc = ""
    prev_then = 0
    for (i = 1; i <= n; i++) {
      s = L[i]
      # A heredoc body is DATA, not code. This file is its own worked example:
      # its own failure-message heredoc spells both `set +e` and `set -e`, and
      # read as code that pair brackets nothing while reporting that it does.
      # The delimiter test is the one the shell applies: the line IS the
      # delimiter, with leading tabs allowed only for the `<<-` form.
      if (heredoc != "") {
        # Marked for the parse-check window below, which reads lines directly
        # rather than through this scan and would otherwise read a body line as
        # code. The terminator is marked with the body: it is the delimiter, not
        # a statement.
        HDBODY[i] = 1
        cur = hd_head(heredoc)
        t = s
        if (substr(cur, 1, 1) == "T") sub(/^\t+/, "", t)
        cur = substr(cur, 2)
        if (s == cur || t == cur) heredoc = hd_rest(heredoc)
        continue
      }
      heredoc = heredoc_delim(s)
      # A line carrying no code carries no answer either. `decomment` has
      # already emptied a full-line comment, so this arm covers a comment and a
      # blank line alike, and it leaves `prev_then` UNCHANGED rather than
      # clearing it: clearing turns the documented two-line restore into a
      # defect the moment someone writes a comment between the `then` and the
      # `set -e`, which in this tree is the likely spelling rather than an
      # exotic one, and reds a required shard on a correct file.
      if (s ~ /^[[:space:]]*$/) continue
      # One coordinate system for the whole line, or the sort below reorders a
      # correct bracket into a false hit: the position of a site is measured over
      # the MASKED line, so a command substitution ahead of a `set +e` shrinks the
      # column of the site but not that of the set event, and the load then sorts
      # ahead of the suspend it sits inside. Masking replaces each span with exactly one
      # character and introduces no `set` token, so measuring both over `m` is
      # sound as well as consistent; blanking quoted spans preserves length, so
      # `q` indexes the same columns as `m`.
      m = mask(s)
      q = blank_quoted(m)
      # `q`, not `s`: a usage or error message spelling `case $- in *e*)` inside
      # a string would otherwise arm the capture for the rest of the file, and
      # every later flat restore inside any conditional would then be credited
      # as state-preserving. `mask` leaves `$-` alone (the `$` is followed by a
      # `-`), so a real unquoted capture reads identically here.
      if (q ~ /case[[:space:]]+\$-[[:space:]]+in/ && q ~ /\*e\*/) {
        if (!capture) capdepth = blockdepth
        capture = 1
      }
      # suspends and restores, left to right
      rest = q
      off = 0
      while (match(rest, /set[[:space:]]+([-+][a-zA-Z]*e[a-zA-Z]*|[-+]o[[:space:]]+errexit)([[:space:]]|;|$)/)) {
        # Snapshot the match BEFORE anything below calls match() again: awk
        # keeps RSTART/RLENGTH global, `opens`/`closes` set them, and reading
        # them afterwards advances `rest` by a no-match (-1) rather than past
        # the token, which never terminates.
        mstart = RSTART
        mlen = RLENGTH
        tok = substr(rest, mstart, mlen)
        pos = off + mstart
        evn++
        evt[evn] = (tok ~ /set[[:space:]]+\+/) ? "susp" : "rest"
        evl[evn] = i
        evp[evn] = pos
        # A restore is state-PRESERVING when the file captured the incoming
        # errexit state and this restore is conditional on something. That is a
        # structural test on purpose: keying it to the identifier `errexit_was`
        # would report the documented bracket as a defect whenever its author
        # named the variable anything else, and print back the shape they used
        # as the remedy. What the check can see is the `case $- in *e*` capture
        # and whether the restore is lexically INSIDE a conditional construct
        # opened after that capture; what it cannot see, and does not claim to,
        # is whether the captured value is the one tested.
        #
        # Containment rather than `then`-adjacency, because the ordinary
        # spellings are not adjacent: a second statement between the `then` and
        # the `set -e`, a restore in an `else` arm, a `case "$was" in 1) set -e`
        # arm. Adjacency reported all three as flat defects. Depth is measured
        # against the depth at the capture, so an include guard wrapping a whole
        # library does not credit an unconditional restore inside it.
        pfx = substr(q, 1, pos - 1)
        indepth = blockdepth + opens(pfx) - closes(pfx)
        evx[evn] = (capture && (pfx ~ /(then|&&|\|\|)[[:space:]]*$/ || prev_then || indepth > capdepth)) \
          ? "cond" : "flat"
        off = pos + mlen - 1
        rest = substr(rest, mstart + mlen)
      }
      # ERR-trap arms and disarms, into the SAME event stream as the suspends and
      # restores above rather than a flag beside it. Positions are measured over
      # `q` like every other event, so a one-line
      # `trap - ERR; set +e; . X; set -e` is read in the order the shell runs it,
      # and a re-arm written after one load still governs the next load below it.
      rest = q
      mrest = m
      off = 0
      while (match(rest, /(^|[;&|(){}[:space:]])trap[[:space:]]/)) {
        # Snapshot the match BEFORE `trap_err` runs: it calls match() itself, and
        # awk keeps RSTART/RLENGTH global, so reading them afterwards would
        # advance `rest` by whatever that call last matched.
        mstart = RSTART
        mlen = RLENGTH
        # The match may have consumed a leading separator; the token starts after
        # it. `mrest` is walked in lockstep so the two views stay column-aligned.
        if (substr(rest, mstart, 4) != "trap") { mstart++; mlen-- }
        pos = off + mstart
        ev = trap_err(substr(rest, mstart), substr(mrest, mstart))
        if (ev != "") {
          evn++
          evt[evn] = ev
          evl[evn] = i
          evp[evn] = pos
          evx[evn] = ""
        }
        off = pos + mlen - 1
        rest = substr(rest, mstart + mlen)
        mrest = substr(mrest, mstart + mlen)
      }
      lps = load_pos(m, q)
      if (lps != "") {
        np = split(lps, lpa, " ")
        for (k = 1; k <= np; k++) {
          evn++
          evt[evn] = "site"
          evl[evn] = i
          evp[evn] = lpa[k]
          # From the load token rather than from the start of the line, so a
          # decoy string ahead of a real load does not supply the target, which
          # both names the site in the report and draws the closure edge. It is
          # also what keeps two loads on one line from taking the wrong one.
          evx[evn] = target(substr(m, lpa[k]))
        }
      }
      prev_then = (q ~ /(^|[[:space:]);])then[[:space:]]*$/)
      blockdepth += opens(q) - closes(q)
      if (blockdepth < 0) blockdepth = 0
      if (capdepth > blockdepth) capdepth = blockdepth
    }
    # Order events: line ascending, then position within the line. The flat
    # one-liner `set +e; [ -f X ] && . X; set -e` is the shape that needs this:
    # all three events sit on one line and only their order tells the check the
    # load is covered.
    for (i = 1; i <= evn; i++) {
      for (j = i + 1; j <= evn; j++) {
        if (evl[j] < evl[i] || (evl[j] == evl[i] && evp[j] < evp[i])) {
          t = evt[i]; evt[i] = evt[j]; evt[j] = t
          t = evl[i]; evl[i] = evl[j]; evl[j] = t
          t = evp[i]; evp[i] = evp[j]; evp[j] = t
          t = evx[i]; evx[i] = evx[j]; evx[j] = t
        }
      }
    }
    suspended = 0
    armed = 0
    errarmed = 0
    for (i = 1; i <= evn; i++) {
      if (evt[i] == "errarm") { errarmed = 1; continue }
      if (evt[i] == "errdis") { errarmed = 0; continue }
      if (evt[i] == "susp") { suspended = 1; continue }
      if (evt[i] == "rest") {
        if (suspended) suspended = 0
        else armed = 1
        continue
      }
      # a load site
      shape = "none"
      if (suspended) {
        shape = "leak"
        for (j = i + 1; j <= evn; j++) {
          if (evt[j] == "rest") { shape = evx[j]; break }
          if (evt[j] == "susp") break
        }
        # An armed ERR trap fires on the failing load whatever errexit is doing,
        # unless an enclosing AND-OR list exempts it, so a bracket that restores
        # errexit and leaves the trap armed brackets nothing. The exemption is
        # not carved out here, for the reason the header gives: this check
        # credits `||` nowhere.
        # Carried as a SUFFIX rather than as a shape of its own: a flat
        # restore in a sourced file is a second, independent defect at the same
        # site, and pass 2 reports whichever of the two apply.
        if (errarmed && shape != "leak") shape = shape "+err"
      } else {
        # `bash -n X` naming the same target, on this line or on a preceding
        # line whose block the load is INSIDE. The multi-line
        # `if bash -n X; then . X; fi` shape puts the check on a preceding line,
        # which is why this is a window rather than a same-line test.
        #
        # Containment, not proximity, is what makes a preceding-line credit
        # sound. A parse check whose `then` branch does something else, with the
        # load pulled out below the `fi`, runs that load unconditionally, and
        # crediting it certifies exactly the abort this check exists to end. So
        # a preceding-line check must open a block (`if ...; then`) that no
        # `fi`, `else` or `elif` closes before the load reaches it.
        #
        # The `-n` has to be a flag to a BASH invocation, in that order and
        # without a command separator between them. A bare `-n` test is the
        # commonest thing on a line beside a load -- `[ -n "$lib" ] && . "$lib"`
        # -- and crediting it would read the tree`s most common UNGUARDED shape
        # as its safest one. Accepted miss: a load whose operand is a bare
        # variable gives no target to match, so a parse check of some OTHER file
        # within the window credits it.
        #
        # The window reads lines directly rather than through the event scan
        # above, so it honours that scan`s heredoc classification explicitly. A
        # body line is data: it opens and closes no block, and it certifies
        # nothing. Without that, a body line ending in `then` and spelling a
        # whole parse check of the target certified a genuinely unguarded load
        # written below the terminator, which is the string-decoy class one
        # substrate over.
        tgt = evx[i]
        found = 0
        for (back = evl[i]; back >= 1 && back >= evl[i] - 3; back--) {
          if (back < evl[i]) {
            # The window closes at the first line that ends a block. Read from
            # the quote-blanked view, like every other predicate in the walk: a
            # block keyword spelled inside a string opens or closes nothing.
            if (!HDBODY[back + 1] && QL[back + 1] ~ /^[[:space:]]*(fi|else|elif)([[:space:]]|;|$)/) break
            if (HDBODY[back] || QL[back] !~ /(^|[[:space:]);])then[[:space:]]*$/) continue
          }
          if (has_parse_check(L[back], QL[back]) \
              && (tgt == "" || index(L[back], tgt))) { found = 1; break }
        }
        if (found) shape = "parsecheck"
      }
      SITESHAPE[++sn] = shape
      SITELINE[sn] = evl[i]
      SITETGT[sn] = evx[i]
    }
    # A heredoc still open when the file ends means the walk above read an
    # opener the shell does not, and every line after it was skipped as body.
    # Report that rather than returning a verdict over input never read.
    if (heredoc != "") printf "UNTERMINATED|%s|%s\n", file, substr(hd_head(heredoc), 2)
    if (armed) printf "ARM|%s\n", file
    for (i = 1; i <= sn; i++) {
      printf "SITE|%s|%d|%s|%s|%s\n", file, SITELINE[i], SITETGT[i], SITESHAPE[i], trim(RAW[SITELINE[i]])
    }
    sn = 0
    delete L; delete RAW; delete QL; delete HDBODY
    delete evt; delete evl; delete evp; delete evx
    delete SITESHAPE; delete SITELINE; delete SITETGT
  }

  END { if (n > 0) flush() }
' ${scan_files[@]+"${scan_files[@]}"})"

# Pass 2. Close errexit-reachability over the source graph, then judge each site
# in a reachable file. A library that never arms errexit is still reachable when
# an errexit file sources it, because errexit is inherited by the sourced file;
# that closure is the whole reason this check ends the depth chase.
{ printf 'FILE|%s\n' ${scan_files[@]+"${scan_files[@]}"}; printf '%s\n' "$records"; } | "$GAIA_AWK" '
  BEGIN { FS = "|" }
  # The scan set arrives ahead of the records so a load target can be resolved
  # to a path. A basename that names more than one file resolves to none of
  # them: the edge would be a guess, and a wrong edge either invents
  # reachability or hides it.
  $1 == "FILE" {
    b = $2
    sub(/^.*\//, "", b)
    if (b in BASE) BASE[b] = "!ambiguous"
    else BASE[b] = $2
    next
  }
  $1 == "UNTERMINATED" { UNTERM[++un] = $2 "|" $3; next }
  $1 == "ARM" { ARM[$2] = 1; next }
  $1 == "SITE" {
    k = ++sn
    SF[k] = $2; SL[k] = $3; ST[k] = $4; SS[k] = $5
    # The quoted source line is the LAST field and may itself carry `|`, which
    # is the separator this stream itself uses. Many site records do, most of
    # them on the `|| exit 0` or `|| return 1` that IS the degrade a reader needs,
    # so truncating at the first `|` drops the most useful half of the report.
    # Take $6 and everything after it.
    SX[k] = $6
    for (fi = 7; fi <= NF; fi++) SX[k] = SX[k] "|" $fi
    if (ST[k] != "" && ST[k] in BASE && BASE[ST[k]] != "!ambiguous") {
      EDGE[SF[k]] = EDGE[SF[k]] " " BASE[ST[k]]
      INBOUND[BASE[ST[k]]] = 1
    }
    next
  }
  END {
    for (f in ARM) REACH[f] = 1
    changed = 1
    while (changed) {
      changed = 0
      for (f in REACH) {
        m = split(EDGE[f], tt, " ")
        for (i = 1; i <= m; i++) {
          if (tt[i] == "") continue
          if (!(tt[i] in REACH)) { REACH[tt[i]] = 1; changed = 1 }
        }
      }
    }
    hits = 0
    for (k = 1; k <= un; k++) {
      split(UNTERM[k], u, "|")
      hits++
      printf "%s: a heredoc opened with delimiter `%s` is never closed\n", u[1], u[2]
      printf "    every line below it was skipped as heredoc body, so this file went UNREAD\n"
    }
    for (k = 1; k <= sn; k++) {
      if (!(SF[k] in REACH)) continue
      why = ""
      if (SS[k] == "none") why = "unguarded load in an errexit-reachable file"
      else if (SS[k] == "leak") why = "errexit suspended across the load and never restored"
      else {
        # The `+err` suffix is independent of the shape it rides, so both are
        # decoded and a site carrying both reports both.
        base = SS[k]
        errt = sub(/\+err$/, "", base)
        if (base == "flat" && (!(SF[k] in ARM) || SF[k] in INBOUND)) \
          why = "flat `set -e` restore in a sourced file, which arms errexit in callers that had it off"
        if (errt) {
          if (why != "") why = why "; and "
          why = why "an ERR trap is armed across the load, and `set +e` does not disarm one, so the trap fires on the failing load unless an enclosing AND-OR list exempts it"
        }
      }
      if (why == "") continue
      hits++
      printf "%s:%s: %s\n", SF[k], SL[k], why
      printf "    %s\n", SX[k]
    }
    exit (hits > 0)
  }
' && rc=0 || rc=$?

if [ "${rc:-0}" -ne 0 ]; then
  cat >&2 <<'MSG'
Bracket each load against an unparseable target. In a file that arms errexit:
  set +e; [ -f X ] && . X 2>/dev/null; set -e
In a library, which inherits errexit from its caller:
  errexit_was=0; case $- in *e*) errexit_was=1 ;; esac
  set +e; . X 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
Where the file also arms an ERR trap, disarm and re-arm it across the load:
`set +e` does not disarm a trap, so the trap fires on the failing load anyway
unless an enclosing AND-OR list exempts it.
  trap - ERR
  set +e; . X 2>/dev/null; set -e
  trap 'exit 0' ERR
Then let the existing `type <fn> >/dev/null 2>&1 || <degrade>` decide.
MSG
  exit 1
fi

echo "lint-errexit-source-guard: clean" >&2
exit 0
