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
# library, and no future round can leave a residual it cannot see.
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

scan_files=()
while IFS= read -r f; do
  scan_files+=("$f")
done < <(find ${scan_roots[@]+"${scan_roots[@]}"} -type f -name '*.sh' \
  ! -path '*/tests/*' 2>/dev/null | LC_ALL=C sort)

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
  function mask(s,   out, i, c, d, cl, op) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "`") {
        i++
        while (i <= length(s) && substr(s, i, 1) != "`") i++
        out = out "@"
        continue
      }
      if (c == "$" && (substr(s, i + 1, 1) == "(" || substr(s, i + 1, 1) == "{")) {
        op = substr(s, i + 1, 1)
        cl = (op == "(") ? ")" : "}"
        d = 0
        i++
        for (; i <= length(s); i++) {
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

  # The basename of the first .sh operand on the line, which is the load target
  # at every site in this tree. Empty when the operand is a bare variable.
  function target(s,   t) {
    if (!match(s, /[A-Za-z0-9_.-]+\.sh/)) return ""
    t = substr(s, RSTART, RLENGTH)
    return t
  }

  # Is `.`/`source` the FIRST word of some command on this line, with an operand
  # that could name a file? Command position, not text proximity: `jq -e . "$f"`
  # and `git grep -- .` put the dot in an argument slot and are not loads.
  # Splitting on the separators leaves each command as one field; leading
  # keywords are stripped so `if . "$p"; then` reads as a load, which is the
  # spelling that stayed invisible to the capability oracle for a full release
  # (gaia-react/gaia#1549).
  #
  # The operand test is what keeps English out. A deny message carrying
  # `(wiki/concepts/Git Workflow.md). Create a feature branch` splits at the
  # `)` into a segment whose first word IS a dot, and the sentence that follows
  # is not a path: an operand must name a `.sh` file or be a bare variable
  # expansion, which is every load spelling this tree uses and no prose.
  function is_load(s,   n, i, parts, w, op) {
    n = split(s, parts, /&&|\|\||[;|&(){}]/)
    for (i = 1; i <= n; i++) {
      w = trim(parts[i])
      while (w ~ /^(if|elif|while|until|then|else|do|!|time|exec)[[:space:]]/) {
        sub(/^(if|elif|while|until|then|else|do|!|time|exec)[[:space:]]+/, "", w)
      }
      if (w !~ /^(\.|source)[[:space:]]/) continue
      sub(/^(\.|source)[[:space:]]+/, "", w)
      op = w
      sub(/[[:space:]].*$/, "", op)
      if (op ~ /\.sh["'"'"']?$/) return 1
      if (op ~ /^["'"'"']?\$\{?[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}?["'"'"']?$/) return 1
    }
    return 0
  }

  # Where on the line the load sits, so a same-line `set +e` ahead of it and a
  # same-line `set -e` behind it are read in the order the shell reads them.
  function load_pos(s) {
    if (match(s, /(^|[;&|(){}[:space:]])(\.|source)[[:space:]]/)) return RSTART
    return 1
  }

  FNR == 1 { if (n > 0) flush(); n = 0; file = FILENAME }
  { n++; L[n] = decomment($0); RAW[n] = $0 }

  function flush(   i, s, j, k, pos, ev, evn, evt, evp, suspended, armed, tgt,
                    sn, sline, sshape, sdepth, back, found, res, capture) {
    # Event stream over the whole file, in position order within each line, so a
    # one-line `set +e; . X; set -e` bracket is read the way the shell reads it.
    evn = 0
    capture = 0
    for (i = 1; i <= n; i++) {
      s = L[i]
      if (s ~ /^[[:space:]]*#/) continue
      if (s ~ /case[[:space:]]+\$-[[:space:]]+in/ && s ~ /\*e\*/) capture = 1
      # suspends and restores, left to right
      rest = s
      off = 0
      while (match(rest, /set[[:space:]]+([-+][a-zA-Z]*e[a-zA-Z]*|[-+]o[[:space:]]+errexit)([[:space:]]|;|$)/)) {
        tok = substr(rest, RSTART, RLENGTH)
        evn++
        evt[evn] = (tok ~ /set[[:space:]]+\+/) ? "susp" : "rest"
        evl[evn] = i
        evp[evn] = off + RSTART
        evx[evn] = (s ~ /errexit_was/ && capture) ? "cond" : "flat"
        off += RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      m = mask(s)
      if (is_load(m)) {
        evn++
        evt[evn] = "site"
        evl[evn] = i
        evp[evn] = load_pos(m)
        evx[evn] = target(m)
      }
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
        # `bash -n X` on this line or within the three above it, naming the
        # same target. The multi-line `if bash -n X; then . X; fi` shape puts
        # the check on a preceding line, which is why this is a window rather
        # than a same-line test.
        #
        # The `-n` has to be a flag to a BASH invocation, in that order and
        # without a command separator between them. A bare `-n` test is the
        # commonest thing on a line beside a load -- `[ -n "$lib" ] && . "$lib"`
        # -- and crediting it would read the tree`s most common UNGUARDED shape
        # as its safest one. Accepted miss: a load whose operand is a bare
        # variable gives no target to match, so a parse check of some OTHER file
        # within the window credits it.
        tgt = evx[i]
        found = 0
        for (back = evl[i]; back >= 1 && back >= evl[i] - 3; back--) {
          if (L[back] ~ /(bash|BASH)[^;&|]*[[:space:]]-n[[:space:]]/ \
              && (tgt == "" || index(L[back], tgt))) { found = 1; break }
        }
        if (found) shape = "parsecheck"
      }
      SITESHAPE[++sn] = shape
      SITELINE[sn] = evl[i]
      SITETGT[sn] = evx[i]
    }
    if (armed) printf "ARM|%s\n", file
    for (i = 1; i <= sn; i++) {
      printf "SITE|%s|%d|%s|%s|%s\n", file, SITELINE[i], SITETGT[i], SITESHAPE[i], trim(RAW[SITELINE[i]])
    }
    sn = 0
    delete L; delete RAW; delete evt; delete evl; delete evp; delete evx
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
  $1 == "ARM" { ARM[$2] = 1; next }
  $1 == "SITE" {
    k = ++sn
    SF[k] = $2; SL[k] = $3; ST[k] = $4; SS[k] = $5; SX[k] = $6
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
