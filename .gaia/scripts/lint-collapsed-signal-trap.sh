#!/usr/bin/env bash
# SC2016 is intentional file-wide: OWN_AWK below is single-quoted precisely so
# every `$`, `$(`, and awk field reference reaches awk as literal program text
# rather than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-collapsed-signal-trap.sh: flag every `trap` that binds EXIT together with
# INT or TERM in one arm, across the framework's tracked shell, the extensionless
# husky hooks, its CI workflow and composite-action YAML, the adopter workflow
# templates, and its tracked bats suites. Run it directly from the repo root:
# `bash .gaia/scripts/lint-collapsed-signal-trap.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. Two statuses say the gate never ran at
# all: 2 when guard-awk-lib.sh is missing beside this script, and 3 when the
# scan-surface discovery failed.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-collapsed-signal-trap.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-collapsed-signal-trap.bats`.
# gaia:maintainer-only:end
#
# Why: bash resumes at the point of interruption once a trapped signal handler
# RETURNS. A handler shared between EXIT and a terminating signal therefore
# deletes the disposition it replaced -- the default for INT and TERM is to
# terminate the process, and after the shared arm runs, the script simply carries
# on as though no signal arrived. The observable outcome is a script that cannot
# be interrupted, and it is silent: the cleanup the author wrote does happen, so
# the handler looks like it worked.
#
# The demand is a CLOSED RULE rather than a judgment about any one handler body,
# and the reason is that no shared arm can be correct. The handler either returns,
# which is the uninterruptible case above, or it exits, which gives the wrong
# status on the ordinary EXIT path the same arm also serves. There is no third
# behaviour, so a shared arm is wrong whatever its body does, and the gate needs
# to read only the signal list.
#
# The repair is one arm per disposition, the shape the tree already uses:
#
#     trap 'rm -f -- "$tmp"' EXIT
#     trap 'exit 130' INT
#     trap 'exit 143' TERM
#
# The signal arms exit, which runs the EXIT arm, which owns the cleanup. 130 and
# 143 are the conventional 128+SIGNUM statuses a shell reports for a process
# killed by SIGINT and SIGTERM.
#
# What this gate does NOT flag, each a closed property of the call text:
#
#   trap - SIGSPEC   -- removal, which RESTORES the default disposition. It is
#                       the opposite of the defect, not a weaker form of it.
#   trap -p / -l     -- query forms. They install nothing.
#   a single arm     -- `trap ... EXIT` alone, `trap ... INT` alone. The class is
#                       the SHARING, not either signal.
#
# Provenance: the class was repaired by hand twice in gaia-react/gaia#1716, in
# .gaia/scripts/audit-respawn-prune.sh and .gaia/scripts/lint-guard-rule-shell-
# coverage.sh, and each repair was pinned by a per-file assertion in that
# script's own sibling suite. Each pin greps one hardcoded path, so the rule they
# encoded was armed for exactly two files -- the hand-kept list
# .claude/rules/guards-must-fail.md names as an arming-stage failure. The third
# instance, in .specify/extensions/gaia/lib/with-ledger-lock.sh, sat unreached by
# any of it; gaia-react/gaia#1717 is the issue that replaced the two pins with
# this tree-wide gate.
#
# Scan surface: tracked `*.sh`, the extensionless husky hooks, the workflow and
# composite-action YAML whose `run:` bodies are shell by another name, the
# adopter workflow templates under
# .gaia/cli/src/automation/templates/workflows/, and tracked `*.bats`, collected
# as its own set below. The templates render into an ADOPTER's CI, where a
# collapsed arm is this class one distribution hop further out; that is the same
# reason the sibling run-interpolation and grep-escape gates scan them.
#
# `.gaia/cli/templates/workflows/` is a build artifact copied from `src/` by
# `bundle:adopter` and is deliberately NOT scanned, so no hit is reported twice
# and no report names a file the repair must not hand-edit.
#
# `*.md` is deliberately OUT of the surface, unlike the sibling path-quoting
# gate. That gate scans fenced blocks because several tracked pages are executed
# instruction an agent runs verbatim. A `trap` is not that: it configures a
# long-lived script, and this repository's markdown carries the collapsed shape
# only as the counter-example a page is explaining. Claiming markdown would red
# the gate on documentation of its own class, which is how a gate gets bypassed
# rather than fixed.
#
# The convention behind this file's `*.bats` argument-region discrimination and
# its pragma is recorded once, in
# wiki/decisions/Shell Guard Fixture Discrimination.md.

set -euo pipefail

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, the shape
# .gaia/scripts/lint-errexit-source-guard.sh demands for an unbracketed load in
# an errexit-reachable file.
_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'lint-collapsed-signal-trap: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}

# The scan surface comes from the shared library rather than from a read loop
# here, so every gate consuming it discovers the same set the same way and a
# widened pathspec cannot reach one of them and miss the others. The call fills
# GAIA_GUARD_SCAN_FILES and returns non-zero on an empty surface, which is a
# hard error rather than a clean tree; the status is read directly, because a
# substitution would swallow it.
#
# The library's own status is carried out rather than flattened to 1: 1 says the
# tree was read and held nothing, 3 says it was never read at all, and an
# operator handed 1 for the second would look at the tree instead of the
# discovery.
gaia_guard_scan_files lint-collapsed-signal-trap shell husky workflows || exit $?

# A separate set from the scan surface above, never a widened pathspec: a tree
# carrying .sh and no .bats must not pass clean carried by the rest of it.
gaia_guard_bats_files lint-collapsed-signal-trap || exit 1

# The class-detection program, concatenated after $GAIA_GUARD_AWK so it can call
# the shared fixture-versus-execution discriminator. Single-quoted, so every
# literal single quote inside is spelled `\047` and no comment in it may carry an
# apostrophe.
#
# Known blind spots, stated rather than discovered later and split by which way
# they fail, because that is the part that matters.
#
# FAIL-OPEN, each one a call the scan cannot read:
#   - A signal list continued onto the next line with a trailing backslash. The
#     scan is line-oriented, so it sees a list that stops at the continuation.
#   - A call assembled through a variable (`$TRAP_CMD`, `eval "trap ..."`), which
#     is tokenizer-bound the same way every sibling gate says of its own class.
#   - A `trap` inside a command substitution on a line whose earlier text opens a
#     quote. The command-position test counts quotes per line, so it reads that
#     token as data. A trap installed inside `$( )` binds the SUBSHELL rather
#     than the script, so nothing this gate exists to protect is at risk there.
#   - A handler written as an ANSI-C literal carrying a backslash-escaped single
#     quote (`$\047...\\\047...\047`). The handler skip reads the escaped quote as
#     the terminator, so the signal list it then walks is the literal tail rather
#     than the real list.
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - An empty handler (`trap "" EXIT INT`), which is a deliberate IGNORE rather
#     than a cleanup. It is still the uninterruptible shape, and the repair is
#     still one arm per disposition, so the demand is right; it is listed here
#     because the author did not write a handler body and may not read the
#     message as describing what they wrote.
#
# FALSE POSITIVE, the third direction:
#   - Prose or a pattern in which `trap` stands at a statement boundary with EXIT
#     and INT after it, on a line whose quotes balance. No such line exists in
#     this tree, which the gate running clean over its own suite is what proves.
# shellcheck disable=SC2016
readonly OWN_AWK='
    # in_command_position(p): 1 when the `trap` just matched stands where a
    # command word stands, 0 when it is text inside a literal.
    #
    # Two closed properties of the prefix, and no shell tokenizer. An ODD count
    # of unescaped single or double quotes puts the token inside a string, which
    # is exactly what a grep pattern naming this class looks like and is the
    # shape this tree carries in three places. And the trimmed prefix must be
    # empty or end at a statement boundary; anything else is an argument
    # position, where a bare word is a value rather than a command.
    function in_command_position(p,   i, c, sq, dq, t) {
      sq = 0
      dq = 0
      for (i = 1; i <= length(p); i++) {
        c = substr(p, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "\047") { if (dq % 2 == 0) sq++ }
        else if (c == "\"") { if (sq % 2 == 0) dq++ }
      }
      if (sq % 2 == 1 || dq % 2 == 1) return 0
      t = p
      sub(/[[:space:]]+$/, "", t)
      if (t == "") return 1
      # The colon is in the class for the YAML half of the surface: a workflow
      # or composite-action step written inline as `- run: trap ...` puts the
      # command word straight after it, and without the colon that whole shape
      # is unreachable. It costs a false positive only on an unquoted prose line
      # ending in a colon, which no scanned file carries.
      if (t ~ /[;&|(){}:]$/) return 1
      if (t ~ /(^|[[:space:]])(then|else|do|if|while|until|!)$/) return 1
      return 0
    }

    # signal_words(s): the signal list of a call that INSTALLS a handler,
    # uppercased and space-joined, or the empty string when the statement
    # installs nothing. `s` is the text following the command word.
    #
    # The handler argument is consumed rather than searched, because a handler
    # body legitimately mentions the signal names -- `exit 130` on INT is the
    # repair this gate advertises -- and a scan that read the whole tail would
    # report the repair as the defect.
    function signal_words(s,   i, n, a, tok, q, c, out, esc) {
      sub(/^[[:space:]]+/, "", s)
      if (s == "") return ""
      # A query form reports and installs nothing.
      if (s ~ /^-[pl]([[:space:]]|$)/) return ""
      # `- SIGSPEC` RESTORES the default disposition. That is the correct
      # removal, and reading it as an installation would red every teardown.
      if (s ~ /^-([[:space:]]|$)/) return ""
      if (s ~ /^--[[:space:]]/) sub(/^--[[:space:]]+/, "", s)
      q = substr(s, 1, 1)
      # ANSI-C quoting opens with a dollar immediately before the quote; from the
      # quote onward it is consumed as an ordinary single-quoted span, which is
      # the escaped-quote blind spot the header states.
      if (q == "$" && substr(s, 2, 1) == "\047") { s = substr(s, 2); q = "\047" }
      if (q == "\047") {
        s = substr(s, 2)
        i = index(s, "\047")
        if (i == 0) return ""
        s = substr(s, i + 1)
      } else if (q == "\"") {
        s = substr(s, 2)
        i = 0
        esc = 0
        for (n = 1; n <= length(s); n++) {
          c = substr(s, n, 1)
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { i = n; break }
        }
        if (i == 0) return ""
        s = substr(s, i + 1)
      } else {
        sub(/^[^[:space:]]+/, "", s)
      }
      n = split(s, a, /[[:space:]]+/)
      out = ""
      for (i = 1; i <= n; i++) {
        tok = a[i]
        if (tok == "") continue
        # A separator ends the statement; what follows is a different command,
        # and reading its words as signals would invent a list nobody wrote.
        if (tok ~ /^[#;&|)}]/) break
        sub(/[;&|)}"\047`]+$/, "", tok)
        if (tok == "") continue
        out = out " " toupper(tok)
      }
      return out
    }

    # collapsed(words): 1 when the list binds EXIT together with INT or TERM.
    # Every spelling bash accepts for the three is read -- the bare name, the SIG
    # prefix, and the number (0 EXIT, 2 INT, 15 TERM) -- because a gate that read
    # one spelling would be armed for the shape its author happened to write.
    function collapsed(words,   i, n, a, t, has_exit, has_signal) {
      n = split(words, a, /[[:space:]]+/)
      has_exit = 0
      has_signal = 0
      for (i = 1; i <= n; i++) {
        t = a[i]
        if (t == "") continue
        sub(/^SIG/, "", t)
        if (t == "EXIT" || t == "0") has_exit = 1
        else if (t == "INT" || t == "2") has_signal = 1
        else if (t == "TERM" || t == "15") has_signal = 1
      }
      return (has_exit && has_signal)
    }

    BEGIN { gaia_scan_reset() }
    # Pass 1 of a two-pass `*.bats` invocation accumulates the prepass sets a
    # fixture constant bound far above its consuming helper call needs; every
    # other surface is single-pass, so this rule never matches there.
    is_bats && NR == FNR { gaia_scan_prepass($0); next }
    {
      # First statement of the main rule, ahead of every next, so the pragma
      # reader behind it sees the full-line comments the comment skip discards.
      gaia_scan_feed($0, is_bats)
      # The off-surface finding: a pragma naming this guard cannot waive anything
      # outside `*.bats`, whether or not its target line carries an instance, so
      # it is read here rather than at the print point below, which would go
      # silently inert on every pragma above a clean line.
      if (!is_bats && gaia_scan_pragma_here("lint-collapsed-signal-trap"))
        printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, FNR
      # A full-line comment is skipped outright, which covers both a shell
      # comment and a `#` line inside a workflow `run:` block. A comment SHOWING
      # the collapsed shape is documentation rather than a call, and this file is
      # itself the proof that the shape occurs in a header.
      if ($0 ~ /^[[:space:]]*#/) next

      consumed = 0
      rest = $0
      while ((pos = index(rest, "trap")) > 0) {
        abs = consumed + pos
        consumed = abs + 3
        rest = substr($0, consumed + 1)

        # A word character on either side means this is a longer identifier
        # (`strap`, `trapdoor`, `lint-collapsed-signal-trap.sh`), not the
        # command. The dot and the dash are in the class BECAUSE this gate names
        # itself in prose that its own scan reads.
        prev = (abs > 1) ? substr($0, abs - 1, 1) : ""
        if (prev ~ /[A-Za-z0-9_.-]/) continue
        after = substr($0, abs + 4, 1)
        if (after ~ /[A-Za-z0-9_.-]/) continue

        if (!in_command_position(substr($0, 1, abs - 1))) continue
        if (!collapsed(signal_words(substr($0, abs + 4)))) continue
        # In this order: a fixture-region line is data (skip), an honored pragma
        # is a deliberate waiver (suppressed), both inert when is_bats is 0.
        if (is_bats && (gaia_scan_skip() || gaia_scan_suppressed("lint-collapsed-signal-trap"))) continue
        printf "%s:%d: this arm binds EXIT together with INT or TERM: the handler returns, bash resumes where the signal arrived, and the signal no longer terminates\n", file, FNR
      }
    }
    END { gaia_scan_end(file, is_bats, "lint-collapsed-signal-trap", 0, 1) }
'

# scan_file <path> <is_bats>: run the concatenated program over <path>. A `*.bats`
# file is named twice so the prepass sees the whole file before the class
# detector runs; every other surface is a single pass.
scan_file() {
  local f="$1"
  local is_bats="$2"
  if [ "$is_bats" -eq 1 ]; then
    awk -v file="$f" -v is_bats=1 -v scripts_dir="$_gaia_guard_lib_dir" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$f" "$f"
  else
    awk -v file="$f" -v is_bats=0 -v scripts_dir="$_gaia_guard_lib_dir" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$f"
  fi
}

report=""
for f in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f" 0)
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for f in ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f" 1)
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The class-remedy footer names the repair for a class hit and for nothing
  # else. A run whose findings are all pragma hygiene (unused, malformed,
  # honored nowhere) or the desync ERROR would otherwise print a remedy that has
  # nothing to do with what went red, pointing the operator at the wrong fix.
  if printf '%s' "$report" \
    | grep -v -e 'gaia-lint-ignore' -e ': ERROR: ' \
    | grep -q '[^[:space:]]'; then
    # printf, not echo: the format string is single-quoted so the sample code
    # inside stays literal -- it is being printed, not run.
    # shellcheck disable=SC2016
    printf 'Fix by giving each disposition its own arm, letting the signal arms exit into the EXIT arm that owns the cleanup:\n    trap %srm -f -- "$tmp"%s EXIT\n    trap %sexit 130%s INT\n    trap %sexit 143%s TERM\n' \
      "'" "'" "'" "'" "'" "'" >&2
  fi
  exit 1
fi

echo "lint-collapsed-signal-trap: clean" >&2
exit 0
