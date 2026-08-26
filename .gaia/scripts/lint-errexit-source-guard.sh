#!/usr/bin/env bash
# lint-errexit-source-guard.sh: flag every `source` / `.` that can run with
# errexit armed and is not bracketed against an unparseable target. Exit 1 with
# a file:line report on any hit, exit 0 when clean. Run it directly from the
# repo root: `bash .gaia/scripts/lint-errexit-source-guard.sh`.
# gaia:maintainer-only:start
#
# Enforced twice, and only one of the two blocks a merge. The sibling bats suite
# .gaia/scripts/tests/lint-errexit-source-guard.bats runs in the `Audit CI Tests`
# scripts shard, a declared-required context; it fails when this scan finds a
# hit and self-tests the detector against known-bad fixtures. That job's `code`
# filter is what arms it, so EVERY root the scan below walks has to be named
# there, by a glob broad enough to cover the whole root; a path the scan reads
# and the filter misses reports green having run this assertion zero times,
# which is the failure this gate exists to prevent, one level up. Adding a root
# to the scan below is therefore always two edits, here and in that filter.
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
# library, and no future round can leave a residual it cannot see INSIDE the
# scan roots below. The closure stops at those roots, so a load in a file they
# do not cover is outside this check whatever sources it; the qualifier is the
# honest form of the claim, and widening the roots is what changes it.
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
# A library's callers do not all arm errexit -- verb-arming.sh has eleven and
# seven do not -- so a flat `set -e` ARMS errexit in those seven, and the caller
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

# Scan surface: the hook bodies and their libraries, plus every script under
# each scan root (recursive). `find` (not a `**` glob) keeps the recursive walk
# portable to bash 3.2, which has no globstar. Paths stay cwd-relative so the
# printed file:line is repo-relative when the linter runs from the repo root.
#
# The roots are a variable rather than literal `find` arguments because the set
# differs between this repo and an adopter's. A root that ships must stay on the
# base assignment; one that does not must be appended inside a maintainer-only
# block, or the release runtime-dependency check reads it as a shipped script
# reaching for a path the bundle does not carry, and fails the staging build.
#
# `.gaia/scripts/tests` is excluded below: its bats fixtures deliberately plant
# broken loads, and a check that reads its own negative fixtures as findings can
# never be clean.
scan_roots=(.claude/hooks .gaia/scripts)

# A root that is absent or renamed makes the walk below yield the OTHER root's
# files, and the only guard on the result fires when every root is empty, so the
# check would report clean having read half the surface it claims to cover.
for r in ${scan_roots[@]+"${scan_roots[@]}"}; do
  if [ ! -d "$r" ]; then
    echo "lint-errexit-source-guard: scan root missing: $r" >&2
    exit 1
  fi
done

# The assertion above covers one cause of a partial walk. Three more reach the
# same silent end, because a walk inside a process substitution discards both
# `find`'s diagnostics and its exit status while the other root keeps the count
# guard below quiet: a root that is a SYMLINK to a directory satisfies `-d` but
# is not descended without `-H`; a root whose mode denies read; and an unreadable
# SUBDIRECTORY under a readable root, which no root-level assertion can catch.
# Capturing the walk lets its status fail the run instead, which is the posture
# the assertion above already chose.
scan_files=()
found="$(find -H ${scan_roots[@]+"${scan_roots[@]}"} -type f -name '*.sh' \
  ! -path '*/tests/*' | LC_ALL=C sort)" || {
  echo "lint-errexit-source-guard: the scan walk failed; refusing to report on a partial surface" >&2
  exit 1
}
while IFS= read -r f; do
  [ -n "$f" ] && scan_files+=("$f")
done <<EOF
$found
EOF

if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-errexit-source-guard: no files under: ${scan_roots[*]}" >&2
  exit 1
fi

# Pass 1. Per file, emit two record kinds on stdout:
#   ARM|<file>                                  the file arms errexit itself
#   SITE|<file>|<line>|<target>|<shape>|<text>  one source site
# `shape` is decided from the file alone: parsecheck, cond, flat, leak, none.
# Reachability is global and is decided in pass 2; a site in a file that never
# runs under errexit is reported by pass 1 and dropped there.
records="$(awk '
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
  # the spelling that stayed invisible to the capability oracle for a full
  # release (gaia-react/gaia#1549).
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
    while (match(pre, /^([{(]|if|elif|then|do)[[:space:]]+/)) pre = trim(substr(pre, RLENGTH + 1))
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

  function flush(   i, s, j, k, pos, ev, evn, evt, evp, suspended, armed, tgt,
                    sn, sline, sshape, sdepth, back, found, res, capture,
                    m, q, cur, pfx, indepth, blockdepth, capdepth,
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
    for (i = 1; i <= evn; i++) {
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
{ printf 'FILE|%s\n' ${scan_files[@]+"${scan_files[@]}"}; printf '%s\n' "$records"; } | awk '
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
      else if (SS[k] == "flat" && (!(SF[k] in ARM) || SF[k] in INBOUND)) \
        why = "flat `set -e` restore in a sourced file, which arms errexit in callers that had it off"
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
Then let the existing `type <fn> >/dev/null 2>&1 || <degrade>` decide.
MSG
  exit 1
fi

echo "lint-errexit-source-guard: clean" >&2
exit 0
