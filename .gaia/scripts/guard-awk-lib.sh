#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk source string below is single-quoted
# precisely so that every `$`, `$(`, and awk field reference reaches awk as
# literal program text. An expansion the shell performed here would delete the
# tracker rather than help it.
# shellcheck disable=SC2016
#
# guard-awk-lib.sh: the shared fixture-versus-execution discriminator the GAIA
# shell guards concatenate into their own awk programs so they can scan `*.bats`
# without reading a fixture string as an executed call. Sourced, never run.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite beside this file, which the `Audit CI Tests`
# scripts shard runs. The convention this library exists to hold, and the
# reasoning behind the argument-region rule and the pragma, live in
# wiki/decisions/Shell Guard Fixture Discrimination.md.
# gaia:maintainer-only:end
#
# Why a library of awk SOURCE rather than of bash functions: every consuming
# guard detects its class inside a single-quoted awk program and holds its
# per-line state in awk variables. A bash function can supply none of that state,
# so what is shared has to be awk text a guard concatenates ahead of its own
# program. The sibling errexit guard already demonstrates the shape in-file,
# joining its shared detector to a per-surface program at call time.
#
# Why the name does not begin with `lint-`: the whole-tree-invariant sweep reads
# `check-*.sh`, `audit-*-complete.sh`, `lint-*.sh` and `verify-*.sh` under
# .gaia/scripts as whole-tree-check candidates and demands a roster row for each.
# This file is not a check, so it takes the `*-lib.sh` naming its siblings in
# this directory use and is swept by nothing. No count is given deliberately: the
# set grows, and a number here names a set nothing recounts.
#
# ---------------------------------------------------------------------------
# The contract a consuming guard is written against
# ---------------------------------------------------------------------------
#
# Bash surface: the readonly `GAIA_GUARD_AWK` (the awk source), and
# `gaia_guard_bats_files <label>`, which fills the global array
# `GAIA_GUARD_BATS_FILES` and returns non-zero on an empty bats surface. The
# caller reads that status directly:
#
#     gaia_guard_bats_files my-guard || exit 1
#
# An array rather than a NUL stream on stdout, because bash discards NUL bytes in
# a command substitution and reading the stream through a process substitution
# swallows the function status, which is the hazard every consuming guard already
# documents at its own discovery loop. The read loop stays inside the function so
# NUL safety never crosses a boundary, and the array name is a fixed global
# because bash 3.2 has no nameref.
#
# Awk surface, and the only names a guard may call: gaia_scan_reset,
# gaia_scan_prepass, gaia_scan_prepass_end, gaia_scan_feed, gaia_scan_skip,
# gaia_scan_suppressed, gaia_scan_pragma_here, gaia_scan_run_only,
# gaia_scan_end. Every invocation passes `-v file=`, `-v is_bats=` and
# `-v scripts_dir=`.
#
# Two passes over a bats file, one over everything else. A fixture constant is
# bound far above the helper call that consumes it, so a forward-only scan cannot
# classify it; the guard names the file twice and guards its first pass with
# `is_bats && NR == FNR { gaia_scan_prepass($0); next }`.
#
# `gaia_scan_feed` MUST be the first statement of the guard main rule, ahead of
# every `next`. The pragma reader lives behind it and has to see the full-line
# comments a class detector discards; a guard that skips comments first silently
# loses every pragma in the file.
#
# Line numbers are FNR, never NR. Under the two-pass invocation a pass-2 line NR
# is `file_length + FNR`, so a guard reporting NR is wrong by a whole file length
# on every bats hit. On a single-pass surface the two are equal by construction,
# which is why the switch is safe to make unconditionally.
#
# Every internal global is prefixed `G_`. Awk has no scoping and the errexit
# guard already occupies `W_*`, so an unprefixed global here would collide with a
# consumer rather than with a sibling.
#
# ---------------------------------------------------------------------------
# The argument-region rule, stated closed
# ---------------------------------------------------------------------------
#
# In a `*.bats` file a line is DATA, and gaia_scan_skip answers 1, when and only
# when the statement occupying it is one of:
#
#   - a call whose command word is a recognized fixture-writing helper;
#   - a `cat`, `printf` or `echo` carrying a top-level output redirect;
#   - an assignment whose name the prepass saw handed to such a helper and never
#     saw in an execution position, and whose value opens with a single-quote
#     family literal;
#   - the body of a heredoc whose delimiter was quoted.
#
# Everything else is shell and is reported. The rule names SHAPES, never files, so
# a new suite inherits the behavior with no registration anywhere, and a fixture
# written through a helper the set does not name reds until someone extends the
# set or writes a pragma. The region runs from the command word to the end of the
# STATEMENT, joining backslash continuations and spanning multi-line quoted
# literals, because a fixture literal carrying the class on an interior line is
# the ordinary shape rather than the exotic one.
#
# End of statement, not end of line, and the difference is load-bearing. A
# top-level `;`, `&&` or `||` starts a second statement the suite executes, so a
# line carrying one is never skipped even when it opens with a fixture writer.
# Reading the region to end of line instead classified that second statement as
# data and skipped a real instance on it, on the one surface this library exists
# to arm. Top-level is what makes this safe to enforce: a separator inside a
# quoted literal or a substitution is consumed by the walk before the test sees
# it, which is why the hundreds of fixture bodies in this tree that contain a
# semicolon are unaffected.
#
# The exclusion term on the assignment arm is the whole mechanism that keeps
# executed shell out: a variable body later handed to `bash -c` or `eval` is
# never data, however it was written. That is the shape that shipped a live
# unquoted call inside a suite and survived four rounds of review.
#
# The value must open with `'` or `$'`. A double-quoted value can carry a command
# substitution, so admitting it would let a line that RUNS something be classified
# as a literal; this is a narrowing of the frozen rule, and it fails closed.
#
# ---------------------------------------------------------------------------
# The pragma
# ---------------------------------------------------------------------------
#
# Literal form, on the comment line or lines immediately above the target:
# a `#`, then `gaia-lint-ignore` as the first token, then the guard token, a
# colon, and a mandatory reason. The token is the guard script basename with the
# extension stripped.
#
# `gaia-lint-ignore` must be the FIRST token after the `#`. That is what lets a
# guard header, a changelog, or a wiki page write the word inline in prose
# without creating a live pragma on a scanned surface.
#
# Token resolution is against `<scripts_dir>/<token>.sh`, from the `-v
# scripts_dir=` variable, and never against a cwd-relative path. Every fixture
# test in every consuming suite runs its guard with cwd inside a throwaway repo
# that carries no .gaia/scripts, so cwd-relative resolution would read every
# well-formed token as orphaned and fail every honored-pragma test. Resolution is
# by readability rather than by execute permission, because these guards are not
# mode-executable and awk cannot stat; the verdict is cached per token.
#
# A following comment line whose first token is NOT the keyword continues the
# reason. One whose first token IS the keyword stacks a second pragma on the same
# target. A BLANK line terminates the block, leaving every pragma in it unused.
# An ordinary comment line does not terminate it, because a wrapped reason is
# textually an ordinary comment line and the two are not distinguishable. The
# target is the first non-comment, non-blank line beneath the block.
#
# What is bats-only and what is not: the fixture-region rule, suppression, the
# run-only exemption and the desync verdict are inert when is_bats is 0. Pragma
# BLOCK parsing runs on every surface, so gaia_scan_pragma_here answers on a
# `*.sh`, husky, workflow-YAML or markdown line and the naming guard can report a
# pragma that is honored nowhere. Malformed-pragma errors are not bats-scoped
# either: the designated owner emits them wherever it finds them, so a malformed
# pragma anywhere in the tree is seen exactly once. The UNUSED-pragma error is
# bats-scoped, because outside `*.bats` nothing can consume a pragma and the
# honored-nowhere finding already covers that line.
#
# ---------------------------------------------------------------------------
# ANSI-C quoting, and the two decisions a second tokenizer has to agree with
# ---------------------------------------------------------------------------
#
# ANSI-C quoting, the dollar-prefixed single-quote form, is not ordinary
# single-quoting: inside it a backslash
# escapes, so an escaped quote does NOT close the literal. Read as an ordinary
# span it closes at the escaped quote and reopens at the real terminator, leaving
# the state inverted for the rest of the file. It gets a frame of its own here,
# entered the moment the opening quote is seen immediately after an unquoted `$`.
# This is not theoretical: the fixture literals in the path-quoting suite are
# written in exactly that form.
#
# Decision 1, a literal opened at the very start of a continued line. Quote state
# carries across a backslash continuation, and the opener is recognized at index
# 1 of the continued line exactly as it is mid-line. The one shape not covered is
# an opener SPLIT by the continuation, the `$` as the last character before the
# trailing backslash and the quote as the first character of the next line; it is
# read as an ordinary single quote. Leaving it out is deliberate rather than
# missed: it fails into the desync verdict rather than into silence, and a second
# tokenizer that implemented it would disagree with this one about what the same
# bytes mean.
#
# Decision 2, a `$` that is itself escaped or quoted. The frame opens only from
# the unquoted state and only on a `$` the walk actually reaches. A
# backslash-escaped `$` is consumed by the escape arm, so an escaped dollar
# followed by a quote opens an ordinary single-quoted span. A `$` inside single
# quotes is literal and the quote that follows it CLOSES that span rather than
# opening a new frame. A `$` inside double quotes never opens the frame, because
# bash does not expand ANSI-C quoting there.
#
# ---------------------------------------------------------------------------
# Blind spots, split by which way each fails
# ---------------------------------------------------------------------------
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - A fixture written through a helper outside the recognized set, or into an
#     UNQUOTED heredoc, is read as executed shell. That is the rule doing its
#     job; the repair is to extend the set or to write a pragma.
#   - A `cat`/`printf`/`echo` whose redirect sits on a later line of a continued
#     statement is not recognized as a writer, because the redirect is read from
#     the statement first line only.
#   - An assignment whose value opens with a double quote is never data.
#   - A line that opens with a fixture writer and then carries a top-level `;`,
#     `&&` or `||` is reported whole, rather than split at the separator, and so
#     is every continuation line of that second statement. The region rule
#     answers per line, so a line that is half evidence and half executed shell
#     is read as shell; a fixture that genuinely needs to share a line with a
#     second statement takes a pragma.
#
# FAIL-OPEN, and each is a place the discriminator can hand a guard a false
# clean:
#   - A function invoked only from inside a string (`bash -c "helper"`) is not
#     counted as invoked, so a helper otherwise called only through `run` keeps
#     its exemption. The run-only accessor answers 0 for a function with no
#     invocation at all, which is the closed direction for the ordinary case.
#   - Function bodies are closed by a `}` at column 1. A suite that indents its
#     closing brace carries its function scope further than it should.
#   - A name marked as executed anywhere in the file is executed everywhere in
#     it. That direction is closed for the region rule and open for nothing else.
#
# NEITHER, because they end in the desync verdict rather than in a verdict about
# a line: more than one heredoc opened on a single line, and the split ANSI-C
# opener above. An unread region leaves a quote, a substitution, a continuation
# or a heredoc open at end of input, and gaia_scan_end says so rather than
# letting a guard certify a file it never classified.

if [ -n "${GAIA_GUARD_AWK_LIB_SOURCED:-}" ]; then return 0; fi
GAIA_GUARD_AWK_LIB_SOURCED=1

# The awk source. Single-quoted, so every literal single quote inside is spelled
# `\047` and no comment in it may carry an apostrophe.
# shellcheck disable=SC2034
readonly GAIA_GUARD_AWK='
function gaia_scan_reset(   k) {
  G_line_reset()
  G_nun = 0
  G_nmal = 0
  G_pre_seen = 0
  G_pre_done = 0
  G_is_bats = 0
  for (k in G_arg_name) delete G_arg_name[k]
  for (k in G_exec_name) delete G_exec_name[k]
  for (k in G_fixname) delete G_fixname[k]
  for (k in G_run_call) delete G_run_call[k]
  for (k in G_plain_call) delete G_plain_call[k]
  for (k in G_fn_def) delete G_fn_def[k]
  for (k in G_res) delete G_res[k]
}

# Everything the walk carries across lines, cleared both at BEGIN and at the
# transition into pass 2, where the scan restarts at line 1 with the prepass
# sets resolved and nothing else.
function G_line_reset(   k) {
  G_q = ""; G_tick = 0; G_depth = 0; G_narith = 0; G_cont = 0
  G_heredoc = ""; G_hd_tabs = 0; G_hd_quoted = 0
  G_region = 0; G_skip = 0; G_redir = 0
  G_curfn = ""; G_intest = 0
  G_np = 0; G_nact = 0
  for (k in G_qstack) delete G_qstack[k]
  for (k in G_arith) delete G_arith[k]
}

function gaia_scan_prepass(line) {
  G_pre_seen = 1
  G_advance(line, 1)
}

function gaia_scan_prepass_end(   n) {
  if (G_pre_done) return
  G_pre_done = 1
  for (n in G_arg_name) if (!(n in G_exec_name)) G_fixname[n] = 1
  G_line_reset()
}

# The guard main rule calls this FIRST, ahead of every next. Retiring the
# previous line pragma set here rather than at end of file is what makes a
# pragma target exactly one line: the guard has already had its chance to
# consume the set by the time the next line is fed.
function gaia_scan_feed(line, is_bats) {
  G_is_bats = is_bats
  if (G_pre_seen && !G_pre_done) gaia_scan_prepass_end()
  G_retire()
  G_advance(line, 0)
}

function gaia_scan_skip() { return G_skip }

# Every matching pragma is marked used, not just the first. Two pragmas naming
# the same guard stack onto one target, and returning at the first left the
# second unmarked, so it was reported unused over a target that does carry an
# instance.
function gaia_scan_suppressed(guard,   i, hit) {
  if (!G_is_bats) return 0
  hit = 0
  for (i = 1; i <= G_nact; i++)
    if (G_act_guard[i] == guard) { G_act_used[i] = 1; hit = 1 }
  return hit
}

function gaia_scan_pragma_here(guard,   i) {
  for (i = 1; i <= G_nact; i++)
    if (G_act_guard[i] == guard) return 1
  return 0
}

# 0 inside a @test body and 0 for a function nothing invokes, both of them the
# closed direction: bats runs a test body under errexit, and a helper with no
# call site in this file carries no evidence that it is only ever run detached.
function gaia_scan_run_only() {
  if (!G_is_bats) return 0
  if (G_intest) return 0
  if (G_curfn == "") return 0
  if (!(G_curfn in G_fn_def)) return 0
  if (!(G_curfn in G_run_call)) return 0
  if (G_curfn in G_plain_call) return 0
  return 1
}

function gaia_scan_end(file, is_bats, guard, is_owner, want_desync,   i, out) {
  out = 0
  G_retire()
  G_flush_block()
  if (is_bats) {
    for (i = 1; i <= G_nun; i++) {
      if (G_un_guard[i] != guard) continue
      printf "%s:%d: unused gaia-lint-ignore for %s: the line below it carries no instance of that class\n", file, G_un_line[i], guard
      out = 1
    }
  }
  if (is_owner) {
    for (i = 1; i <= G_nmal; i++) {
      if (G_mal_kind[i] == 1)
        printf "%s:%d: malformed gaia-lint-ignore: %s does not resolve to .gaia/scripts/%s.sh\n", file, G_mal_line[i], G_mal_tok[i], G_mal_tok[i]
      else
        printf "%s:%d: malformed gaia-lint-ignore for %s: no reason given\n", file, G_mal_line[i], G_mal_tok[i]
      out = 1
    }
  }
  if (is_bats && want_desync \
      && (G_q != "" || G_tick || G_depth > 0 || G_cont || G_heredoc != "")) {
    printf "%s: ERROR: the scan lost track of shell state before the end of the file, so the remainder was never classified and this gate cannot certify it clean\n", file
    out = 1
  }
  return out
}

# ---- one physical line -----------------------------------------------------

function G_advance(line, mode,   stripped, lit, entry_open, isstruct) {
  G_skip = 0

  # A heredoc body is data the shell hands to a command, never shell it runs, so
  # nothing in it arms, opens, or classifies anything.
  if (G_heredoc != "") {
    G_skip = (G_is_bats && G_hd_quoted) ? 1 : 0
    if (G_hd_close(line)) { G_heredoc = ""; G_hd_quoted = 0; G_hd_tabs = 0 }
    return
  }

  lit = (G_q != "" || G_tick || G_depth > 0)
  entry_open = (lit || G_cont)

  if (entry_open) {
    G_walk(line)
    if (mode == 1 && G_region && !lit) G_mark_names(line, 0)
    if (G_sep) G_region = 0
    G_skip = (G_is_bats && G_region) ? 1 : 0
    return
  }

  stripped = line
  sub(/^[ \t]+/, "", stripped)
  G_region = 0

  if (stripped == "") {
    if (mode == 0) G_flush_block()
    return
  }
  if (substr(stripped, 1, 1) == "#") {
    if (mode == 0) G_read_comment(stripped)
    return
  }

  isstruct = G_structure(line, stripped, mode)
  G_walk(line)
  if (!isstruct) G_classify(stripped, mode)
  if (mode == 0) G_target_block()
  # Clearing the region rather than only suppressing this line is what carries
  # the bound onto the continuation lines of the second statement. A statement
  # continued by a trailing backslash or by an open literal re-enters through
  # the entry_open arm above, which reads G_region and never re-reads the
  # separator, so a per-line suppression ended at the separator line and handed
  # the continuation back as data.
  if (G_sep) G_region = 0
  G_skip = (G_is_bats && G_region) ? 1 : 0
}

# G_walk(line): advance quote, substitution, backtick, heredoc and continuation
# state across one line, and record whether the line carried a top-level output
# redirect. Ordering is load-bearing throughout: each arm consumes the character
# the arm below it would misread.
function G_walk(line,   n, i, c, nx, j, ch, delim, quoted, prev) {
  G_redir = 0
  G_sep = 0
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)

    # ANSI-C quoting. A backslash escapes here, which is the whole reason this
    # frame exists rather than sharing the ordinary single-quote arm below.
    if (G_q == "A") {
      if (c == "\\") { if (i == n) { G_cont = 1; return } ; i++; continue }
      if (c == "\047") G_q = ""
      continue
    }
    # Ordinary single quotes make every byte literal, backslash included, so
    # this comes before the escape handling.
    if (G_q == "\047") { if (c == "\047") G_q = ""; continue }

    if (c == "\\") { if (i == n) { G_cont = 1; return } ; i++; continue }

    if (G_tick) {
      if (c == "`") {
        j = i
        while (j <= n && substr(line, j, 1) == "`") j++
        if (j - i >= 3) { i = j - 1; continue }
        G_tick = 0
      }
      continue
    }

    if (c == "$") {
      nx = substr(line, i + 1, 1)
      if (G_q == "" && nx == "\047") { G_q = "A"; i++; continue }
      if (nx == "(") {
        # A substitution opens from inside double quotes too, which is the
        # ordinary spelling of a captured command. The saved quote state is what
        # returns the walk to the string when the region closes.
        G_qstack[G_depth] = G_q
        G_depth++
        G_q = ""
        i++
        # `$((` is arithmetic, not a command substitution. Consume the second
        # paren as its own level so the closing `))` balances by construction.
        if (substr(line, i + 1, 1) == "(") {
          G_qstack[G_depth] = ""
          G_depth++
          G_arith[G_depth] = 1
          G_narith++
          i++
        }
        continue
      }
      continue
    }
    # A run of three or more backticks is a markdown fence delimiter, not a
    # command substitution. Toggling per character left an odd-length run (the
    # ```lang opener) with the span still open, so every comment line inside the
    # fence read as literal span data and a pragma there was never parsed. A
    # fence marker is inert to this span tracker; the content INSIDE the fence is still
    # scanned, which is what the markdown surface expects.
    if (c == "`") {
      j = i
      while (j <= n && substr(line, j, 1) == "`") j++
      if (j - i >= 3) { i = j - 1; continue }
      G_tick = 1
      continue
    }

    if (G_q == "\"") { if (c == "\"") G_q = ""; continue }
    if (c == "\047") { G_q = "\047"; continue }
    if (c == "\"")   { G_q = "\"";   continue }

    # A heredoc opens at ANY substitution depth, because its body occupies lines
    # of this file whatever nesting opened it. Skipped inside arithmetic, where
    # `<<` is a left shift and its digits would otherwise read as a delimiter and
    # swallow the rest of the file.
    if (c == "<" && substr(line, i + 1, 1) == "<" && G_narith == 0) {
      # `<<<` is a herestring: its operand is a word on this same line.
      if (substr(line, i + 2, 1) == "<") { i += 2; continue }
      j = i + 2
      G_hd_tabs = 0
      quoted = 0
      if (substr(line, j, 1) == "-") { G_hd_tabs = 1; j++ }
      while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
      delim = ""
      ch = substr(line, j, 1)
      if (ch == "\047" || ch == "\"") {
        quoted = 1
        j++
        while (j <= n && substr(line, j, 1) != ch) { delim = delim substr(line, j, 1); j++ }
        j++
      } else {
        if (ch == "\\") { quoted = 1; j++ }
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.\/-]/) { delim = delim substr(line, j, 1); j++ }
      }
      if (delim != "") { G_heredoc = delim; G_hd_quoted = quoted }
      i = j - 1
      continue
    }

    # The bare arithmetic COMMAND, sibling of the `$(( ))` expansion above. Two
    # levels, so its `))` balances the same way.
    if (G_depth == 0 && c == "(" && substr(line, i + 1, 1) == "(") {
      G_qstack[G_depth] = ""
      G_depth++
      G_qstack[G_depth] = ""
      G_depth++
      G_arith[G_depth] = 1
      G_narith++
      i++
      continue
    }

    if (G_depth > 0) {
      if (c == "(") { G_qstack[G_depth] = ""; G_depth++; continue }
      if (c == ")") {
        if (G_arith[G_depth]) { delete G_arith[G_depth]; G_narith-- }
        G_depth--
        G_q = G_qstack[G_depth]
        continue
      }
      continue
    }

    # A redirect counts for rule 2 only when it names a PATH. `>&2` and `2>&1`
    # dup a file descriptor, so an `echo ... >&2` is a diagnostic to stderr
    # rather than a fixture write, and treating it as one made the whole line
    # data: a real instance on it was skipped, silently, on the one surface
    # this library exists to arm. Reading `>&` as no redirect at all fails
    # closed, which is the direction the argument-region rule requires.
    if (c == ">") {
      nx = substr(line, i + 1, 1)
      if (nx == ">") nx = substr(line, i + 2, 1)
      if (nx != "&") G_redir = 1
      continue
    }

    # A top-level statement separator bounds the argument region. Everything
    # after it on this physical line belongs to a SECOND statement, which the
    # suite executes, so a region running to end of line would classify that
    # shell as fixture data and skip it. Detected here, at depth zero and
    # outside every quote frame, because the arms above have already consumed
    # any separator sitting inside a literal or a substitution. That is what
    # keeps the many tracked fixture lines whose written literal contains a
    # separator character from reading as two statements; they are the ordinary
    # case rather than the exotic one, which is why the test has to run after
    # those arms have consumed the literal, rather than over the raw text.
    # A lone `&` and a lone `|` are deliberately not separators; a pipeline is
    # one statement, and `>&` was consumed above.
    if (c == ";") { G_sep = 1; continue }
    if (c == "&" && substr(line, i + 1, 1) == "&") { G_sep = 1; i++; continue }
    if (c == "|" && substr(line, i + 1, 1) == "|") { G_sep = 1; i++; continue }

    # An unquoted `#` opens a comment only at the start of a word; mid-word it is
    # an ordinary character a path or a pattern may carry.
    if (c == "#") {
      if (i == 1) break
      prev = substr(line, i - 1, 1)
      if (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|" || prev == "(") break
      continue
    }
  }
  G_cont = 0
}

# The terminator comparison tolerates trailing whitespace deliberately. Bash does
# not, but the two failure directions are not symmetric: ending a heredoc one
# line early costs a few lines read as shell that were not, while never ending
# one swallows every remaining line of the file.
function G_hd_close(line,   probe) {
  probe = line
  if (G_hd_tabs) sub(/^\t+/, "", probe)
  sub(/[ \t]+$/, "", probe)
  return (probe == G_heredoc)
}

# Function and test scope, so the run-only accessor knows which body a line sits
# in. A closing brace at column 1 ends the body; the header states that bound.
function G_structure(line, stripped, mode,   nm) {
  if (substr(line, 1, 1) == "}") { G_curfn = ""; G_intest = 0; return 1 }
  if (stripped ~ /^@test[ \t]/) { G_curfn = ""; G_intest = 1; return 1 }
  if (stripped ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_.-]*[ \t]*\(\)[ \t]*\{?[ \t]*$/) {
    nm = stripped
    sub(/^function[ \t]+/, "", nm)
    sub(/[ \t]*\(\).*$/, "", nm)
    G_curfn = nm
    G_intest = 0
    if (mode == 1) G_fn_def[nm] = 1
    return 1
  }
  return 0
}

# The region rule and, in the prepass, the two sets it will later be resolved
# against. Called after the walk, because the redirect arm needs the walk answer.
function G_classify(stripped, mode,   w, name, v1, v2) {
  w = stripped
  sub(/[ \t].*$/, "", w)
  if (w == "fixture_file" || w == "fixture_script" || w == "writef" \
      || w == "write_file" || w == "write_agent_file") {
    G_region = 1
  } else if ((w == "cat" || w == "printf" || w == "echo") && G_redir) {
    G_region = 1
  } else if (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
    name = stripped
    sub(/=.*$/, "", name)
    v1 = substr(stripped, length(name) + 2, 1)
    v2 = substr(stripped, length(name) + 3, 1)
    if (v1 == "\047" || (v1 == "$" && v2 == "\047")) {
      if (mode == 0 && (name in G_fixname)) G_region = 1
    }
  }
  if (mode == 0) return
  if (G_region) { G_mark_names(stripped, 0); return }
  # A body handed to an interpreter is executed shell however it was written, so
  # every name the line mentions is disqualified from the assignment arm above.
  if (stripped ~ /[a-z]*sh[ \t]+-[A-Za-z]*c([ \t]|$)/ \
      || stripped ~ /(^|[^A-Za-z0-9_-])(eval|source)([^A-Za-z0-9_-]|$)/ \
      || stripped ~ /^\.[ \t]/) {
    G_mark_names(stripped, 1)
  }
  G_pre_calls(stripped)
}

# Collect every `$NAME` and `${NAME}` on the line into one of the two prepass
# sets. The loop shortens its own input each round, so it terminates.
function G_mark_names(s, exec,   rest, p, body) {
  rest = s
  while ((p = index(rest, "$")) > 0) {
    rest = substr(rest, p + 1)
    body = rest
    if (substr(body, 1, 1) == "{") body = substr(body, 2)
    if (match(body, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      if (exec) G_exec_name[substr(body, 1, RLENGTH)] = 1
      else G_arg_name[substr(body, 1, RLENGTH)] = 1
    }
  }
}

# Invocation census for the run-only exemption. A token counts as a call when it
# stands in command position, and as a RUN call only when `run` is the word
# immediately before it.
function G_pre_calls(s,   n, t, i, w, prev, cmd) {
  n = split(s, t, /[ \t]+/)
  prev = ""
  for (i = 1; i <= n; i++) {
    w = t[i]
    if (w == "") continue
    cmd = 0
    if (i == 1) cmd = 1
    else if (prev == "run" || prev == "if" || prev == "then" || prev == "else" \
             || prev == "elif" || prev == "do" || prev == "while" || prev == "until" \
             || prev == "{" || prev == "(" || prev == "!") cmd = 1
    else if (prev ~ /[;&|(]$/) cmd = 1
    if (cmd) {
      if (substr(w, 1, 2) == "$(") w = substr(w, 3)
      else if (substr(w, 1, 1) == "`") w = substr(w, 2)
      sub(/[;&|)]+$/, "", w)
      if (w ~ /^[A-Za-z_][A-Za-z0-9_.-]*$/) {
        if (prev == "run") G_run_call[w]++
        else G_plain_call[w]++
      }
    }
    prev = t[i]
  }
}

# ---- the pragma block ------------------------------------------------------

function G_read_comment(stripped,   rest, tok, guard, reason, p) {
  rest = substr(stripped, 2)
  sub(/^[ \t]+/, "", rest)
  tok = rest
  sub(/[ \t].*$/, "", tok)
  if (tok != "gaia-lint-ignore") {
    # A wrapped reason is textually an ordinary comment, so the two cannot be
    # told apart and neither ends the block.
    if (G_np > 0) G_pg_reason[G_np] = G_pg_reason[G_np] " " rest
    return
  }
  rest = substr(rest, length(tok) + 1)
  sub(/^[ \t]+/, "", rest)
  p = index(rest, ":")
  if (p > 0) { guard = substr(rest, 1, p - 1); reason = substr(rest, p + 1) }
  else { guard = rest; reason = "" }
  sub(/[ \t].*$/, "", guard)
  sub(/^[ \t]+/, "", reason)
  sub(/[ \t]+$/, "", reason)
  G_np++
  G_pg_guard[G_np] = guard
  G_pg_line[G_np] = FNR
  G_pg_reason[G_np] = reason
  if (!G_resolve(guard)) {
    G_nmal++
    G_mal_kind[G_nmal] = 1
    G_mal_line[G_nmal] = FNR
    G_mal_tok[G_nmal] = guard
  } else if (reason == "") {
    G_nmal++
    G_mal_kind[G_nmal] = 2
    G_mal_line[G_nmal] = FNR
    G_mal_tok[G_nmal] = guard
  }
}

# A blank line terminates the block, and every pragma in it then targets nothing.
function G_flush_block(   i) {
  for (i = 1; i <= G_np; i++) G_add_unused(G_pg_guard[i], G_pg_line[i])
  G_np = 0
}

function G_target_block(   i) {
  G_nact = 0
  for (i = 1; i <= G_np; i++) {
    G_nact++
    G_act_guard[G_nact] = G_pg_guard[i]
    G_act_line[G_nact] = G_pg_line[i]
    G_act_used[G_nact] = 0
  }
  G_np = 0
}

function G_retire(   i) {
  for (i = 1; i <= G_nact; i++)
    if (!G_act_used[i]) G_add_unused(G_act_guard[i], G_act_line[i])
  G_nact = 0
}

function G_add_unused(guard, line) {
  G_nun++
  G_un_guard[G_nun] = guard
  G_un_line[G_nun] = line
}

# By readability, never by execute permission: these guards are not
# mode-executable and awk cannot stat. getline answers -1 on a target it cannot
# open and 0 or more on one it can, including an empty file.
function G_resolve(tok,   path, r, junk) {
  if (tok == "") return 0
  if (tok in G_res) return G_res[tok]
  path = scripts_dir "/" tok ".sh"
  r = (getline junk < path)
  close(path)
  G_res[tok] = (r >= 0) ? 1 : 0
  return G_res[tok]
}
'

# Filled by gaia_guard_bats_files, read by its caller. Declared here so a caller
# that iterates before calling reads an empty array rather than an unset name.
GAIA_GUARD_BATS_FILES=()

# gaia_guard_bats_files <guard-label>: fill GAIA_GUARD_BATS_FILES with the
# tracked bats set and return 0, or return 1 having said so on stderr when the
# discovery read nothing.
#
# An empty bats surface is a hard error rather than a clean tree: the widened
# pathspec matching nothing means the discovery is wrong, and a guard that
# scanned no suite and printed clean is the lie-green failure these gates exist
# to stop. The status is the whole point of the shape, so the caller reads it
# directly (`gaia_guard_bats_files <label> || exit 1`) rather than through a
# substitution that would swallow it.
#
# `core.quotepath=false` and a NUL-delimited read, so a path carrying a
# non-ASCII byte is not handed over C-quoted and silently dropped. A read loop
# rather than mapfile, which is bash 4+, because these guards run on stock macOS
# /bin/bash 3.2.57.
gaia_guard_bats_files() {
  local label="${1:-guard}"
  local f
  GAIA_GUARD_BATS_FILES=()
  while IFS= read -r -d '' f; do
    GAIA_GUARD_BATS_FILES+=("$f")
  done < <(git -c core.quotepath=false ls-files -z '*.bats' | LC_ALL=C sort -z)
  if [ "${#GAIA_GUARD_BATS_FILES[@]}" -eq 0 ]; then
    printf '%s: ERROR: no tracked bats suites matched the scan surface; nothing was scanned\n' "$label" >&2
    return 1
  fi
  return 0
}

# Filled by gaia_guard_scan_files, read by its caller. Declared here so a caller
# that iterates before calling reads an empty array rather than an unset name.
GAIA_GUARD_SCAN_FILES=()

# _gaia_guard_scan_set <set-name>: emit that set's tracked paths NUL-delimited
# and return git's own status, or emit nothing and return 2 when the name is not
# one this library knows. Private to gaia_guard_scan_files, and the one place
# each pathspec is written.
#
#   shell      tracked `*.sh`, minus the hook directory the `husky` set owns. A
#              git pathspec glob is matched without FNM_PATHNAME, so its `*`
#              crosses `/` and a `.husky/helper.sh` would otherwise be returned
#              by both sets: scanned twice, and reported twice, by a caller that
#              asked for both.
#   husky      the husky hooks, which are extensionless and so match no
#              extension glob. `.husky/_/h` runs each one as `sh -e`, so a
#              caller that arms them differently from an ordinary script asks
#              for this set separately rather than folding it into `shell`.
#   workflows  the Actions workflows and composite actions, plus the adopter
#              workflow templates, which are `.tmpl` rather than `.yml`.
#
# One set per call rather than one call carrying every pathspec: a `:(exclude)`
# magic pathspec applies to the whole call, so `shell`'s exclude would also
# empty a `husky` set asked for in the same breath.
#
# `core.quotepath=false`, so a path carrying a non-ASCII byte is not handed over
# C-quoted and silently dropped.
_gaia_guard_scan_set() {
  case "$1" in
    shell) git -c core.quotepath=false ls-files -z '*.sh' ':(exclude).husky/*' ;;
    husky) git -c core.quotepath=false ls-files -z '.husky/*' ;;
    workflows)
      git -c core.quotepath=false ls-files -z \
        '.github/workflows/*.yml' '.github/workflows/*.yaml' \
        '.github/actions/*/action.yml' '.github/actions/*/action.yaml' \
        '.gaia/cli/src/automation/templates/workflows/*.tmpl'
      ;;
    *) return 2 ;;
  esac
}

# gaia_guard_scan_files <guard-label> <set>...: fill GAIA_GUARD_SCAN_FILES with
# the sorted union of the named tracked sets, having said on stderr what went
# wrong on any status but 0. The status is the whole point of the shape, so the
# caller reads it directly (`gaia_guard_scan_files <label> <set>... || exit 1`)
# rather than through a substitution that would swallow it.
#
#   0  the union is non-empty and the array holds it.
#   1  every named set resolved and the union came back empty. A hard error
#      rather than a clean tree, for the reason gaia_guard_bats_files states
#      about its own surface. This is the ONLY status a caller may tolerate,
#      and only where an empty surface is a legitimate tree for it.
#   2  the call itself is wrong: a set name this library does not know, or no
#      set named at all. Either way the guard would scan less than the rule it
#      encodes governs and still report clean, which is the discovery-stage
#      failure `.claude/rules/guards-must-fail.md` names.
#   3  a named set's own `git ls-files` failed (run outside a repository, a
#      broken object store). Distinct from 1 because the repairs differ, and
#      distinct from a partial union because a set that returned nothing on a
#      failed call is otherwise indistinguishable from one that legitimately
#      matched nothing: with several sets asked for, the survivors would carry
#      the union past the empty check and the gate would report clean over a
#      surface it never opened.
#
# Each set is written to a scratch file rather than straight into a process
# substitution, because a process substitution's subshell cannot return its
# status here, which is what leaves a per-set failure indistinguishable from a
# per-set empty result. Every return path removes it explicitly rather than
# through an EXIT trap: this library is sourced, so a trap installed here would
# replace whatever the consuming guard armed for its own cleanup.
#
# A read loop rather than mapfile, which is bash 4+, because these guards run on
# stock macOS /bin/bash 3.2.57.
gaia_guard_scan_files() {
  local label="${1:-guard}"
  if [ "$#" -lt 2 ]; then
    printf '%s: ERROR: gaia_guard_scan_files needs a label and at least one scan set\n' "$label" >&2
    return 2
  fi
  shift

  local scan_tmp name status f
  scan_tmp="$(mktemp -t gaia-guard-scan-XXXXXX)" || {
    printf '%s: ERROR: could not create a scratch file for the scan surface; nothing was scanned\n' "$label" >&2
    return 3
  }

  for name in "$@"; do
    # The `if` is what keeps a non-zero status readable: a bare call would abort
    # under the errexit every consuming guard arms before sourcing this library.
    if _gaia_guard_scan_set "$name" >> "$scan_tmp"; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -eq 2 ]; then
      rm -f "$scan_tmp"
      printf '%s: ERROR: unknown scan set "%s"; nothing was scanned\n' "$label" "$name" >&2
      return 2
    fi
    if [ "$status" -ne 0 ]; then
      rm -f "$scan_tmp"
      printf '%s: ERROR: the %s discovery failed, git exited %s; nothing was scanned\n' \
        "$label" "$name" "$status" >&2
      return 3
    fi
  done

  GAIA_GUARD_SCAN_FILES=()
  while IFS= read -r -d '' f; do
    GAIA_GUARD_SCAN_FILES+=("$f")
  done < <(LC_ALL=C sort -z < "$scan_tmp")
  rm -f "$scan_tmp"

  if [ "${#GAIA_GUARD_SCAN_FILES[@]}" -eq 0 ]; then
    printf '%s: ERROR: no tracked files matched the scan surface (%s); nothing was scanned\n' \
      "$label" "$*" >&2
    return 1
  fi
  return 0
}
