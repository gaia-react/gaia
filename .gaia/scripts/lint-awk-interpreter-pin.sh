#!/usr/bin/env bash
# SC2016 is intentional file-wide: SCAN_AWK below is single-quoted precisely so
# every `$`, `$(`, and awk field reference reaches awk as literal program text
# rather than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-awk-interpreter-pin.sh: flag every awk invocation in the
# guard-awk-lib.sh closure whose command word is a bare interpreter name rather
# than the resolved `"$GAIA_AWK"`. Run it directly from the repo root:
# `bash .gaia/scripts/lint-awk-interpreter-pin.sh`.
#
# Exit 0 when clean, and 1 with a file:line report on any hit. Four statuses say
# the gate never ran at all: 2 when guard-awk-lib.sh is missing beside this
# script, 4 when the closure derivation came back empty, 5 when no awk
# interpreter is present at all, and 6 when GAIA_AWK resolves to an interpreter
# that identifies as neither mawk nor BWK one-true-awk. The discovery statuses
# the shared library raises, 1 for a tracked shell set that came back empty, 2
# for a working directory below the repository root, and 3 for a discovery that
# failed outright, are forwarded rather than flattened, for the reason that
# library's own header gives.
#
# 4 rather than 3 for the empty closure, and the distinction is the point: 3
# says the tracked shell set was never read, 4 says it was read and the closure
# this gate governs is not in it. The repairs are different -- a broken
# checkout against a renamed or deleted library -- and an operator handed one
# status for both would look in the wrong place. No other guard's status set is
# consulted here; 4 is this script's own.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-awk-interpreter-pin.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-awk-interpreter-pin.bats`.
# gaia:maintainer-only:end
#
# Why: POSIX leaves a great deal of awk implementation-defined, and this
# repository runs more than one implementation. `.github/workflows/shell-lint.yml`
# runs on ubuntu, whose default `awk` is mawk; a maintainer on macOS runs BWK
# one-true-awk at /usr/bin/awk. A program authored and verified under one can
# mean something else under the other, silently, and in the direction that
# matters: a guard's detector quietly stops matching what it was written to
# match and still reports green. That is the same shape
# .gaia/scripts/lint-grep-ere-escapes.sh exists for on the BSD-versus-GNU grep
# divergence, one layer down.
#
# .gaia/scripts/awk-interp-lib.sh closed that divergence for the closure by
# resolving one sanctioned interpreter into GAIA_AWK and converting every
# invocation in it. What that resolver cannot do is bind the next guard someone
# adds to the closure, which is what this gate is for.
#
# ---------------------------------------------------------------------------
# The closed rule, and why it pins the interpreter rather than the constructs
# ---------------------------------------------------------------------------
#
# In the governed surface, an awk invocation whose command word is a bare `awk`,
# `gawk`, `mawk` or `nawk`, or an absolute or relative path whose basename is one
# of those, is a hit. The required form is `"$GAIA_AWK"`.
#
# The REJECTED alternative is the shape the grep sibling had to take: enumerate
# the diverging CONSTRUCTS and flag those. `length(array)`, `gensub`, `asort`, a
# regex `RS`, `printf` conversion semantics, locale-dependent collation, and the
# next one. It is rejected on the grep guard's own stated ground -- an
# enumeration of the divergent constructs is always one construct short, and
# each round of extending it invites the next -- and on two more:
#
#   - grep is not swappable per invocation without shipping a grep, so its guard
#     had no choice but to constrain the patterns. awk IS swappable, and
#     awk-interp-lib.sh made it so. Constraining the interpreter closes the class
#     at its root rather than chasing the constructs that expose it.
#   - the interpreter rule is verifiable by construction. With every invocation
#     in the surface going through one resolved binary, local and CI cannot
#     disagree by interpreter at all, and the resolver's own sanctioned-set
#     refusal is what keeps that binary honest. A construct enumeration would
#     also need an awk-program parser, where this needs a command-position
#     reader.
#
# There is NO ALLOWLIST. An allowlist is an enumeration and therefore a coverage
# claim, and the repair here is always the same one edit -- write `"$GAIA_AWK"`
# -- and never wrong, so the closed rule costs nothing to hold. Nothing in the
# governed surface needs one, which is what this gate running clean over it
# establishes.
#
# ---------------------------------------------------------------------------
# The governed surface, stated closed
# ---------------------------------------------------------------------------
#
# Exactly the guard-awk-lib.sh closure as it sits beside that library: the
# library, the libraries it itself sources, and every tracked shell file IN THE
# ANCHOR'S OWN DIRECTORY whose source statement names it. The set is DERIVED
# below rather than listed here, so a consumer added later joins the surface
# with no edit to this file, the same reason
# .gaia/scripts/tests/shell-lint.bats derives its roster from
# whole-tree-invariants.sh rather than restating it.
#
# The surface is the closure and not the tree because the closure is where
# GAIA_AWK can be obeyed. Deliberately NOT claimed, in the form the grep sibling
# uses for `sed -E`, stated here rather than discovered later:
#
#   - Every command-position awk site in a tracked shell file that does not
#     source guard-awk-lib.sh. There are real ones, among them
#     .gaia/tests/shell-lint.sh's shellcheck-version read and the `awk -F=`
#     one-liner in .github/workflows/shell-lint.yml's install step. Neither owes
#     a conversion and neither owes an entry in any list here: they are outside
#     the surface, by the same decision that set it. A substantial minority of
#     the files in that wider set carry no .gaia/release-exclude entry and so
#     SHIP, where the resolver must not exist at all, and widening this gate to
#     reach them would be a re-decision rather than a correction -- the
#     divergence being closed was measured on the closure's guards specifically,
#     and converting the rest is a larger project than adopting the resolver was.
#   - `.gaia/scripts/tests/fixtures/stub-guard.sh`, which is a LIVE instance of
#     this class and is named rather than left to be discovered. It sources the
#     anchor, so it inherits GAIA_AWK and the rule could be obeyed there, and it
#     runs the shared tokenizer under a bare `awk`. It sits below the anchor's
#     directory rather than beside it, which is what puts it outside the surface
#     above. The repair is the one-line conversion every other consumer took,
#     and it is not folded in here because it is coupled: `mutate()` in
#     .gaia/scripts/tests/guard-awk-lib.bats copies the library into a scratch
#     tree WITHOUT awk-interp-lib.sh beside it, so a converted stub would meet
#     an unset GAIA_AWK there and abort under `set -u` instead of running the
#     mutation it is there to prove. Converting the fixture means teaching that
#     harness to carry the resolver too, which is a change to an existing
#     suite's proof machinery rather than to this gate.
#   - `*.bats`. The closure is `*.sh`, so a bats suite is not in it, and the
#     fixture-versus-execution discrimination guard-awk-lib.sh exists to provide
#     is not needed here. A suite carrying a bare `awk` in a fixture string is
#     invisible to this gate and is meant to be.
#   - An interpreter reached through any name but the four above, or through a
#     variable other than GAIA_AWK (`"$MY_AWK"`, `"$AWK"`). Nothing in command
#     position distinguishes those from a correctly pinned call.
#
# ---------------------------------------------------------------------------
# Blind spots, split by which way each fails
# ---------------------------------------------------------------------------
#
# FAIL-OPEN, each one a call the scan cannot read as one:
#   - An interpreter invoked through a wrapper that takes a command as its
#     argument: `xargs awk`, `env awk`, `command awk`, `sudo awk`, `exec awk`.
#     The name sits in argument position, which this scan deliberately does not
#     report, because argument position is where prose and grep patterns naming
#     this repository's own tools live and a gate that reds on those gets
#     bypassed rather than obeyed.
#   - A call inside a heredoc body. The body is skipped wholesale, which is
#     right for the prose and fixture text that fills most of them and wrong for
#     the rare one fed to `bash`.
#   - A command word assembled from an expansion (`"${tool}"`, `"$dir/awk"`).
#   - A call on a line the walk left desynced. That one does not fail silently:
#     see the ERROR finding below.
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - Any of the four names in command position, including `mawk` and the
#     absolute `/usr/bin/awk`, which are the two interpreters the resolver
#     itself reaches for. Naming one directly pins the surface to that
#     implementation and routes around the resolver's identity probe, which is
#     the case that must not pass on its name.
#   - A file whose walk ends with a quote, a command substitution or a heredoc
#     still open is reported as an ERROR rather than certified clean. An unread
#     region is the one state in which a clean verdict means nothing, so the
#     gate says so instead of letting it pass, the same posture
#     guard-awk-lib.sh's own desync verdict takes.
#
# FALSE POSITIVE, the third direction, named because the demanded edit would
# make no sense to the author. A `case` pattern arm and a subshell close both
# reopen command position here, so a `)` followed by one of the four names is
# read as a call. That is what the shell does with it too, so the reading is
# correct; it is listed because the shape looks like data at a glance.
#
# Full-line comments, trailing comments after a word boundary, single-quoted
# and double-quoted string bodies, and longer identifiers that merely contain
# one of the names (`my_awk_prog`, `GAIA_AWK_STATUS`) are all quiet, which they
# have to be: this file, its siblings and the resolver all name `mawk`,
# `gawk` and `/usr/bin/awk` in their own refusal messages and their own prose.

set -euo pipefail

_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf 'lint-awk-interpreter-pin: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-awk-interpreter-pin: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-awk-interpreter-pin: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENT" >&2
    exit 6
    ;;
esac

# The closure anchor. Everything else in the surface is reached from it, in
# either direction, so this one literal is the whole registration this gate
# carries.
readonly ANCHOR='.gaia/scripts/guard-awk-lib.sh'
ANCHOR_DIR="${ANCHOR%/*}"
ANCHOR_BASE="${ANCHOR##*/}"
readonly ANCHOR_DIR ANCHOR_BASE

# The tracked shell set comes from the shared library rather than from a read
# loop here, so this gate discovers it the same way every sibling does and a
# widened pathspec cannot reach one of them and miss the others. The status is
# read directly, because a substitution would swallow it, and forwarded rather
# than flattened: 1 says the tree was read and held no tracked shell, 2 says the
# working directory is below the root, 3 says the discovery never ran.
gaia_guard_scan_files lint-awk-interpreter-pin shell || exit $?

# tracked_has <path>: 0 when <path> is in the tracked shell set.
tracked_has() {
  local want="$1" f
  for f in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
    if [ "$f" = "$want" ]; then return 0; fi
  done
  return 1
}

if ! tracked_has "$ANCHOR"; then
  printf 'lint-awk-interpreter-pin: ERROR: the closure anchor %s is not in the tracked shell set, so the governed surface is empty; nothing was scanned\n' "$ANCHOR" >&2
  exit 4
fi

# The closure, derived in both directions from the anchor and deduplicated into
# a bash array rather than a sorted newline list: a path carrying a newline
# would split a line-delimited list into two members that name no file, and the
# array never has to be re-parsed.
MEMBERS=()
member_add() {
  local p="$1" m
  for m in ${MEMBERS[@]+"${MEMBERS[@]}"}; do
    if [ "$m" = "$p" ]; then return 0; fi
  done
  MEMBERS+=("$p")
}
member_add "$ANCHOR"

# A source statement, as every file in this closure spells one: the `.` or
# `source` sits at the start of a line or after a `;`, `&&` or `||`, which is
# the shape the bracketed `set +e; [ -f ... ] && . ...; set -e` idiom produces.
# A `# shellcheck source=` directive is a comment and carries no `.` in command
# position, so it is not read as one.
readonly SOURCE_RE='(^|[;&|(])[ \t]*(\.|source)[ \t]'

# One hop DOWN: the libraries the anchor itself sources, resolved beside it.
# awk-interp-lib.sh is reached this way rather than named, so renaming the
# resolver moves the surface with it.
down_list="$("$GAIA_AWK" -v re="$SOURCE_RE" '
  $0 !~ re { next }
  match($0, /[A-Za-z0-9._-]+\.sh/) > 0 { print substr($0, RSTART, RLENGTH) }
' "$ANCHOR")"
while IFS= read -r base; do
  [ -n "$base" ] || continue
  if tracked_has "$ANCHOR_DIR/$base"; then member_add "$ANCHOR_DIR/$base"; fi
done <<<"$down_list"

# One hop UP: every tracked shell file BESIDE the anchor whose own source
# statement names it. One awk pass over that set rather than one process per
# file, which is the difference between tens of milliseconds and a second.
# `index()` against a `-v` variable rather than a dynamic regex, so a basename
# carrying a regex metacharacter cannot widen the match.
#
# Beside the anchor, not anywhere in the tree, and the narrowing is the one
# stated in this file's header under `tests/fixtures/stub-guard.sh`. A
# candidate is a tracked file whose directory IS the anchor's, so a consumer
# added to that directory joins with no edit here and a consumer added below it
# does not.
TRACKED=()
for f in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
  if [ "${f%/*}" = "$ANCHOR_DIR" ] && [ -f "$f" ]; then TRACKED+=("$f"); fi
done
up_list="$("$GAIA_AWK" -v re="$SOURCE_RE" -v anchor="$ANCHOR_BASE" '
  FNR == 1 { hit = 0 }
  hit { next }
  $0 !~ re { next }
  index($0, anchor) > 0 { print FILENAME; hit = 1 }
' ${TRACKED[@]+"${TRACKED[@]}"})"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  member_add "$path"
done <<<"$up_list"

# The class detector. A per-line character walk carrying quote, command
# substitution and heredoc state ACROSS lines, which is what the sibling
# gates' line-local walks do not need and this one does: the closure's guards
# hold their awk programs in single-quoted literals hundreds of lines long, and
# every line inside one is string body rather than shell. Reading each line
# fresh would read those bodies as code and report the awk built-ins in them.
readonly SCAN_AWK='
    function reset_file() {
      Q = ""; DEPTH = 0; CMD = 1; ATWORD = 1; CONT = 0; PEND = 0; HD = ""
    }
    # is_pin(w): 1 when the command word names an awk interpreter by basename.
    # A path-invoked interpreter is still an interpreter, so the basename is
    # what is tested and `/usr/bin/awk` is a hit.
    function is_pin(w,   n, p) {
      n = split(w, p, "/")
      w = p[n]
      return (w == "awk" || w == "gawk" || w == "mawk" || w == "nawk")
    }
    # is_keyword(w): 1 for a reserved word that is FOLLOWED by a command, so
    # command position survives it. `time` and `!` are here; a wrapper that
    # takes a command as an ARGUMENT (xargs, env, command, sudo, exec) is
    # deliberately not, per the fail-open note in this file header.
    function is_keyword(w) {
      return (w == "if" || w == "then" || w == "elif" || w == "else" ||
              w == "do" || w == "while" || w == "until" || w == "time")
    }
    # skip_token(line, i): the index just past the token starting at i, quote
    # aware so a redirect target or a heredoc delimiter carrying whitespace
    # inside a literal is not split at it.
    function skip_token(line, i,   n, c, q) {
      n = length(line); q = ""
      while (i <= n) {
        c = substr(line, i, 1)
        if (q == "") {
          if (c == " " || c == "\t") break
          if (index(";&|<>()", c) > 0) break
          if (c == "\047" || c == "\"") { q = c; i++; continue }
          if (c == "\\") { i += 2; continue }
          i++
          continue
        }
        if (q == "\"" && c == "\\") { i += 2; continue }
        if (c == q) q = ""
        i++
      }
      return i
    }
    # unquote(s): s with every quote and backslash removed, which is how bash
    # reads a heredoc delimiter written as EOF, \047EOF\047, "EOF" or \\EOF.
    function unquote(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\047" || c == "\"" || c == "\\") continue
        out = out c
      }
      return out
    }
    function push(t) { DEPTH++; STKQ[DEPTH] = Q; STKT[DEPTH] = t; Q = ""; CMD = 1; ATWORD = 1; PEND = 0 }
    function pop() { Q = STKQ[DEPTH]; DEPTH--; CMD = 0; ATWORD = 0 }
    function desync(   why) {
      if (PREVFILE == "") return
      why = ""
      if (Q != "") why = "a quoted literal"
      else if (DEPTH > 0) why = "a command substitution"
      else if (HD != "") why = "a heredoc"
      if (why == "") return
      printf "%s: ERROR: %s was still open at end of file; this file was not classified and is not certified clean\n", PREVFILE, why
    }
    function walk(line, fname, lno,   n, i, j, c, nx, w, delim) {
      n = length(line)
      i = 1
      while (i <= n) {
        c = substr(line, i, 1)

        # --- inside a literal: nothing here is shell ---------------------
        if (Q == "\047") { if (c == "\047") Q = ""; i++; continue }
        if (Q == "A") {
          # ANSI-C quoting: a backslash escapes, so an escaped quote does not
          # close the literal.
          if (c == "\\") { i += 2; continue }
          if (c == "\047") Q = ""
          i++
          continue
        }
        if (Q == "\"") {
          if (c == "\\") { if (i == n) { CONT = 1; return }; i += 2; continue }
          if (c == "\"") { Q = ""; i++; continue }
          if (c == "$" && substr(line, i + 1, 1) == "(") { push(0); i += 2; continue }
          if (c == "$" && substr(line, i + 1, 1) == "{") { i = skip_brace(line, i + 2); continue }
          if (c == "`") {
            if (DEPTH > 0 && STKT[DEPTH] == 1) { pop(); i++; continue }
            push(1); i++; continue
          }
          i++
          continue
        }

        # --- unquoted ----------------------------------------------------
        if (c == " " || c == "\t") {
          if (PEND && DEPTH == 0) { CMD = 1; PEND = 0 }
          ATWORD = 1
          i++
          continue
        }
        if (c == "\\") { if (i == n) { CONT = 1; return }; i += 2; ATWORD = 0; continue }
        # An unquoted `#` is a comment only at the start of a word; mid-word it
        # is an ordinary character.
        if (c == "#" && ATWORD) return

        # The command word, read whole so a longer identifier that merely
        # contains one of the names is never mistaken for one of them.
        if (CMD && ATWORD) {
          j = i
          while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.\/+-]/) j++
          if (j > i) {
            w = substr(line, i, j - i)
            nx = substr(line, j, 1)
            if (nx == "=") {
              # An assignment PREFIX keeps command position, but its value is
              # not a command: `FOO=bar awk x` invokes awk. PEND restores
              # command position at the end of the value rather than at the
              # `=`, and the value is still walked, so `x=$(awk ...)` is read.
              CMD = 0; PEND = 1; ATWORD = 0; i = j + 1
              continue
            }
            if (is_keyword(w)) { i = j; ATWORD = 0; continue }
            if (is_pin(w))
              printf "%s:%d: %s in command position: the guard-awk-lib.sh closure must invoke \"$GAIA_AWK\", or the same program runs under a different awk implementation locally than in CI\n", fname, lno, w
            i = j
            ATWORD = 0
            CMD = 0
            continue
          }
          # Not a plain word: a quote, an expansion, a redirect. Whatever it
          # is, it is not a bare interpreter name.
          CMD = 0
        }

        if (c == "\047") {
          # A quote opening immediately after an unquoted `$` is ANSI-C
          # quoting and gets a frame of its own.
          Q = ((i > 1 && substr(line, i - 1, 1) == "$") ? "A" : "\047")
          i++; ATWORD = 0; continue
        }
        if (c == "\"") { Q = "\""; i++; ATWORD = 0; continue }
        if (c == "$" && substr(line, i + 1, 1) == "(") { push(0); i += 2; continue }
        if (c == "$" && substr(line, i + 1, 1) == "{") { i = skip_brace(line, i + 2); ATWORD = 0; continue }
        if (c == "`") {
          if (DEPTH > 0 && STKT[DEPTH] == 1) { pop(); i++; continue }
          push(1); i++; continue
        }
        if (c == ")") {
          if (DEPTH > 0 && STKT[DEPTH] == 0) { pop(); i++; continue }
          # A subshell close or a `case` pattern arm; both reopen command
          # position, which is what the shell does with them too.
          CMD = 1; ATWORD = 1; PEND = 0; i++; continue
        }
        if (index(";&|({}", c) > 0) { CMD = 1; ATWORD = 1; PEND = 0; i++; continue }
        if (c == "!" && ATWORD) { CMD = 1; ATWORD = 1; i++; continue }
        if (c == "<" || c == ">") {
          if (c == "<" && substr(line, i + 1, 1) == "<" && substr(line, i + 2, 1) != "<") {
            # A heredoc. Its BODY starts on the next line, so the rest of this
            # line is still shell and the walk continues past the delimiter.
            # More than one heredoc opened on a line keeps the first, and the
            # second leaves the walk desynced, which the ERROR above reports
            # rather than letting it pass.
            j = i + 2
            if (substr(line, j, 1) == "-") j++
            while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
            i = skip_token(line, j)
            delim = unquote(substr(line, j, i - j))
            if (HD == "" && delim != "") HD = delim
            ATWORD = 1
            continue
          }
          # An ordinary redirect or a here-string: what follows is a target or
          # a datum, never a command word.
          j = i + 1
          while (substr(line, j, 1) == ">" || substr(line, j, 1) == "<" || substr(line, j, 1) == "&") j++
          while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
          i = skip_token(line, j)
          ATWORD = 1
          continue
        }
        ATWORD = 0
        i++
      }
    }
    # skip_brace(line, i): the index just past the `}` closing a `${...}`
    # expansion opened before i. Counted rather than matched, so a nested
    # `${a:-${b}}` does not end the skip early; an unbalanced one runs to end
    # of line, which leaves the rest of the line unread rather than misread.
    function skip_brace(line, i,   n, d, c) {
      n = length(line); d = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "{") d++
        else if (c == "}") { d--; if (d == 0) return i + 1 }
        i++
      }
      return i
    }
    FNR == 1 { desync(); reset_file() }
    {
      PREVFILE = FILENAME
      if (HD != "") {
        # A heredoc body is data. `<<-` strips leading tabs from the
        # terminator; leading spaces are tolerated too, which is wider than
        # bash and errs toward closing the body rather than swallowing the
        # rest of the file.
        probe = $0
        sub(/^[ \t]+/, "", probe)
        if (probe == HD) HD = ""
        next
      }
      if (!CONT && Q == "" && DEPTH == 0) { CMD = 1; ATWORD = 1; PEND = 0 }
      CONT = 0
      walk($0, FILENAME, FNR)
    }
    END { desync() }
'

report="$("$GAIA_AWK" "$SCAN_AWK" ${MEMBERS[@]+"${MEMBERS[@]}"})"

if [ -n "$report" ]; then
  printf '%s\n' "$report"
  # printf, not echo: the hint carries a `$` the shell must not expand and a
  # backslash echo may. The format string is single-quoted so the sample code
  # inside stays literal -- it is being printed, not run.
  printf 'Fix each by invoking the resolved interpreter instead:\n    "$GAIA_AWK" -v x=1 %sprogram%s file\nGAIA_AWK comes from .gaia/scripts/awk-interp-lib.sh, which every file in this\nclosure already loads through guard-awk-lib.sh.\n' "'" "'" >&2
  exit 1
fi

printf 'lint-awk-interpreter-pin: clean\n' >&2
exit 0
