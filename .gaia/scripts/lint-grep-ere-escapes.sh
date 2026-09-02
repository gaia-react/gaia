#!/usr/bin/env bash
# SC2016 is intentional file-wide: OWN_AWK below is single-quoted precisely so
# every `$`, `$(`, and awk field reference reaches awk as literal program
# text rather than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-grep-ere-escapes.sh: flag every backslash-escaped LETTER inside an
# extended-regex grep pattern, across the framework's tracked shell, its CI
# workflow and composite-action YAML, and the adopter workflow templates. Run it
# directly from the repo root: `bash .gaia/scripts/lint-grep-ere-escapes.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. Two statuses say the gate never ran at
# all: 2 when guard-awk-lib.sh is missing beside this script, and 3 when the
# scan-surface discovery failed.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-grep-ere-escapes.bats, which the `Audit CI Tests` CI
# job runs, and folded into .gaia/tests/shell-lint.sh so every shell-lint caller
# enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-grep-ere-escapes.bats`.
# gaia:maintainer-only:end
#
# Why: POSIX leaves a backslash before an ordinary character UNDEFINED in an
# ERE, and the two grep implementations this repository runs on resolved that
# freedom differently. Measured on macOS `/usr/bin/grep` (BSD grep 2.6.0-FreeBSD)
# against GNU grep on the ubuntu runner:
#
#     \r \n \t \f \a \e   BSD expands to the control character;
#                         GNU matches the bare LETTER.
#     \d \D               BSD expands to the digit / non-digit class;
#                         GNU matches the bare letter.
#
# So one pattern means two different things depending on which machine runs it,
# and the inversion is silent in the direction that matters: a `\r?` written on
# macOS to tolerate CRLF matches a carriage return locally and an optional
# literal `r` in CI, so the check it belongs to quietly stops matching what it
# was written to match and still reports green. That is the shape this gate
# exists for -- invisible to shellcheck, invisible to a suite that runs on the
# authoring platform, and failing toward a pass.
#
# Portable repairs, in the order to reach for them:
#   - a bracket expression, which is POSIX and identical everywhere:
#     `[[:digit:]]`, `[[:space:]]`, `[0-9]`.
#   - a literal control character the SHELL produces, not the regex:
#     `grep -E "carriage$(printf '\r')return"`, or `$'\r'` in bash.
#   - normalize ahead of the match: `tr -d '\r'`, `sed 's/\r$//'`.
#
# The demand is a CLOSED RULE rather than a list of escapes: every backslash
# before a letter is a hit unless the letter is one of `s S w W b B`. An
# enumeration of the divergent escapes is always one escape short, and each
# round of extending it invites the next.
#
# That allowlist is the set both implementations were MEASURED to support with
# the same meaning: `\s`/`\S` whitespace, `\w`/`\W` word character, `\b`/`\B`
# word boundary. They are GNU extensions rather than POSIX, and BSD grep
# implements all six identically, so a pattern using them means one thing on
# both platforms. Roughly ten call sites in this tree use them; demanding a
# rewrite there would cost a flood of edits with no defect behind any of them,
# which is how a gate gets bypassed rather than obeyed.
#
# Everything OUTSIDE that allowlist is flagged, including the letters both
# implementations happen to treat as a bare literal today (`\q`, `\z`, `\p`).
# That is FAIL-CLOSED and deliberate: POSIX leaves them undefined, so today's
# agreement is a coincidence of two implementations rather than a guarantee, and
# the repair is always the same -- drop the backslash -- and never wrong. No
# such escape appears in this tree, so the closed rule costs nothing to hold.
#
# Deliberately NOT claimed: `sed -E`, which carries the identical divergence for
# `\t` and friends. It is a real sibling class and a real gap, left out because
# a sed pattern sits inside an `s///` expression whose delimiter is
# author-chosen, so locating it needs machinery this scan does not have. Stated
# here rather than discovered later.
#
# Scan surface: tracked `*.sh`, the extensionless husky hooks, the workflow and
# composite-action YAML whose `run:` bodies are shell by another name, and the
# adopter workflow templates under
# .gaia/cli/src/automation/templates/workflows/. The templates render into an
# ADOPTER's CI, where the pattern an author wrote and verified on macOS is
# executed by GNU grep on a runner neither this repo's review nor the adopter's
# ever watches; that is this class one distribution hop further out, and it is
# the same reason the sibling run-interpolation gate scans them.
#
# `.gaia/cli/templates/workflows/` is a build artifact copied from `src/` by
# `bundle:adopter` and is deliberately NOT scanned, so no hit is reported twice
# and no report names a file the repair must not hand-edit.
#
# The YAML halves are scanned as RAW LINES rather than by locating `run:` bodies
# structurally, which is the opposite of what the sibling run-interpolation gate
# does, and the asymmetry is the point. That gate's class exists only inside a
# `run:` body, because `${{ }}` is correct everywhere else in a workflow. A
# `grep -E` is a shell call wherever it appears in a workflow file -- in a `run:`
# body, in an agent prompt a step feeds to a model, in a composite action's
# step -- and it carries this class in all of them, so there is nothing for the
# structure to discriminate.
#
# One file type is out of the surface for the reason stated beside it; the
# other now joins it under its own discrimination:
#
#   *.bats  -- tracked bats suites are scanned as their own set, discriminated
#              by the shared `.gaia/scripts/guard-awk-lib.sh`, which tells a
#              fixture literal from an executed call so the suite that
#              demonstrates this class no longer has to be exempt from it. A
#              `gaia-lint-ignore lint-grep-ere-escapes: <reason>` comment above
#              a line waives it there, and nowhere else; an unused one is
#              reported. Residual FAIL-OPENs on this surface, same as the
#              non-bats one below: a fixture written through a helper the
#              shared library's idiom set does not name is skipped rather than
#              reported when it should be the reverse; and every FAIL-OPEN
#              already listed above (a pattern held in a variable, a
#              continued pattern, `\t` in a double-quoted pattern, a wrapper
#              or reassembled grep name, an unbalanced substitution) still
#              applies here unchanged -- none of them is a bats-only gap.
#   *.md    -- the sibling path-quoting gate scans the fenced blocks of tracked
#              markdown because several are executed instruction. The same is
#              true here, but the class needs the pattern to be authored on one
#              platform and RUN on another, and an executed markdown snippet is
#              run by an agent on the author's own machine. The exposure the
#              class needs does not arise, and the fence-state machinery is not
#              free.
#
# `scan_window` and `ere_mode` below are this gate's own retained tokenizer,
# the class detector's window walk rather than the shared library's fixture,
# heredoc, or pragma tracker, and they stay. `scan_window`'s ANSI-C reading
# agrees with the shared library's on the ordinary case, an unescaped `$`
# immediately before a quote opens ANSI-C mode, a `$` inside double quotes
# never does. It does not special-case a backslash-escaped `$` immediately
# before a quote, so unlike the library it reads that shape as ANSI-C too,
# a narrow known gap rather than a claim of full agreement.
#
# The convention behind this file's argument-region discrimination and its
# pragma is recorded once, in wiki/decisions/Shell Guard Fixture Discrimination.md.

set -euo pipefail

_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'lint-grep-ere-escapes: guard-awk-lib.sh is missing beside this script\n' >&2
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
gaia_guard_scan_files lint-grep-ere-escapes shell husky workflows || exit $?

# A separate set from the scan surface above, never a widened pathspec: a tree
# carrying .sh and no .bats must not pass clean carried by the rest of it.
gaia_guard_bats_files lint-grep-ere-escapes || exit 1

# scan_file <path>: print one `file:line: message` per divergent escape.
#
# Known blind spots, stated rather than discovered later and split by which way
# they fail, because that is the part that matters.
#
# FAIL-OPEN, each one a pattern the scan cannot read:
#   - A pattern held in a VARIABLE (`grep -qE "$KEY_RE"`). The escape lives at
#     the assignment, which this scan does not associate with the call. Several
#     call sites in this tree are of that shape.
#   - A pattern continued onto the next line, since the scan is line-oriented.
#   - `\\t` written inside a DOUBLE-quoted pattern. The shell collapses the pair
#     to a single backslash before grep sees it, so grep gets `\t` while the
#     scan reads a portable escaped backslash. Inside single quotes, where the
#     shell passes both bytes through, the reading is correct.
#   - A grep reached through a wrapper name (`zgrep`, `ugrep`) or assembled
#     through a variable (`"$GREP" -E`), neither of which is in command position
#     as this scan recognizes it.
#   - A pattern following a command substitution that contains an unbalanced
#     `)` inside a quoted string of its own. The substitution skip counts
#     parentheses without tracking quotes, so it leaves the region early and the
#     rest of the line is read in the wrong state.
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - Any backslash-escaped letter outside the six-letter allowlist, including
#     the ones both implementations currently treat as a literal.
#
# FALSE POSITIVE, a third direction, and the one worth naming explicitly because
# in each case the demanded edit is not a repair the author can make sense of.
# Neither shape occurs in this tree, which is what the gate running clean over
# it establishes. Each carries its own repair, because they do not share one:
#   - A grep pattern quoted inside ANOTHER tool's program text, as in
#     `awk '/grep -E "a\tb"/ { print }'`. The escape belongs to awk's regex,
#     which has its own portability rules, but the scan sees a `grep` in what
#     looks like command position. Telling the two apart needs a shell
#     tokenizer, which is more machinery than this gate is worth. Hoisting the
#     program into a variable does NOT clear it, because the assignment line
#     still carries the grep token; only moving the escaped letter itself onto a
#     line holding no grep token does.
#   - A TRAILING SHELL COMMENT after the call, as in
#     `grep -qE "^x$" f  # tolerate \t here`. The unquoted-terminator set below
#     stops the walk at a shell metacharacter, and `#` is deliberately not in
#     it: an unquoted `#` is only a comment at the start of a word, and mid-word
#     it is an ordinary character a pattern may legitimately contain, which the
#     scan cannot tell apart without tokenizing. Fail-closed is the right side
#     to err on here, but the demanded repair points at a comment rather than at
#     any regex, so it is named rather than left to be discovered. There is no
#     pattern-side repair at all: hoisting the pattern into a variable leaves
#     the hit, because the escape is in the comment. Move the comment to its own
#     line, where the full-line skip below reaches it, or reword it.
#
# `$'...'` is NOT a hit, and the discrimination is load-bearing rather than
# cosmetic: `$'\r'` is one of the repairs this gate's own hint text advertises.
# Inside ANSI-C quoting the shell expands the escape and grep receives a real
# control character, so the pattern never carries the ambiguity. Flagging it
# would red the tree on the fix.
readonly OWN_AWK='
    BEGIN { gaia_scan_reset() }
    is_bats && NR == FNR { gaia_scan_prepass($0); next }
    # scan_window(w): walk the text following an ERE-mode grep and return the
    # first divergent escape letter in it, or "" when there is none.
    #
    # The walk stops at the first UNQUOTED shell terminator, which is what keeps
    # the scan inside the one command: without it, `grep -E ... | tr ., \n.` and
    # `grep -E ... < <(sed -E ...)` would both hand this gate an escape that
    # belongs to a different command with different portability rules.
    # Quote-awareness is what makes that stop correct rather than approximate --
    # `grep -qE .(^|[^/\\])\.gaia/local.` carries a `|` inside its pattern, and
    # a terminator scan that could not see quotes would stop in the middle of
    # the pattern and read half of it.
    function scan_window(w,   n, i, c, nxt, q, ansi, substdepth, intick, prev) {
      n = length(w)
      q = ""
      ansi = 0
      substdepth = 0
      intick = 0
      for (i = 1; i <= n; i++) {
        c = substr(w, i, 1)
        # A legacy backtick substitution is the same shell output as `$(...)` and
        # is skipped for the same reason: `"^key:`printf .\r.`?$"` is the repair
        # this gate advertises, written in the older spelling. Backticks do not
        # nest, so a flag is the whole state; the closing tick is matched here
        # rather than by the quote machinery below, which never sees one.
        if (intick) {
          if (c == "`") intick = 0
          continue
        }
        # A command substitution is shell OUTPUT rather than regex text: it runs
        # before grep is invoked, so no escape inside one ever reaches the
        # pattern. `"$(printf .\r.)"` is one of the repairs this gate advertises,
        # so reading into a substitution would red the tree on the fix. Tracking
        # the nesting is also what stops the `)` that closes one from being read
        # as the terminator that ends the command.
        if (substdepth > 0) {
          if (c == "(") substdepth++
          else if (c == ")") substdepth--
          continue
        }
        # Neither form is entered from inside single quotes, where `$(` and a
        # backtick are literal characters the shell never acts on.
        if (q != "\047" && c == "$" && substr(w, i + 1, 1) == "(") {
          substdepth = 1
          i++
          continue
        }
        if (q != "\047" && c == "`") {
          intick = 1
          continue
        }
        if (q == "") {
          if (c == "\047") {
            # A quote opening immediately after `$` is ANSI-C quoting, where the
            # shell expands the escape and grep never sees a backslash.
            prev = (i > 1) ? substr(w, i - 1, 1) : ""
            q = "\047"
            ansi = (prev == "$")
            continue
          }
          if (c == "\"") { q = "\""; ansi = 0; continue }
          if (index("|;&<>)", c) > 0) return ""
        } else if (c == q) {
          q = ""
          ansi = 0
          continue
        }
        if (c != "\\") continue
        nxt = substr(w, i + 1, 1)
        # Consume the escaped character whatever it is, so a `\\` pair cannot
        # leave the second backslash to be read as the start of a new escape and
        # so a `\"` cannot be mistaken for the end of a double-quoted pattern.
        i++
        if (nxt == "\\") continue
        if (ansi) continue
        if (nxt !~ /[A-Za-z]/) continue
        if (index(agreed, nxt) > 0) continue
        return nxt
      }
      return ""
    }
    # ere_mode(w): read the option region following a grep and return 1 when the
    # call is in EXTENDED-regex mode and no later option takes it back out.
    #
    # The region is read rather than a fixed position matched, because grep
    # options are idiomatically bundled and ordered freely (`-qE`, `-Eq`, `-rEn`,
    # `-E --color=always`). The walk stops at the first token that is not an
    # option, which is where the pattern begins.
    #
    # `-F`, `-P`, and `-G` select a DIFFERENT matcher, and any of them anywhere
    # in the bundle clears extended mode here. In all three the class does not
    # apply: `-F` has no regex at all; `-P` is PCRE on GNU, where every escape
    # here is defined and identical, and is not supported at all on BSD grep,
    # which exits 2 with `invalid option -- P` rather than misreading the
    # pattern; and `-G` is a BRE, whose backslash rules are a separate class
    # this gate does not claim.
    #
    # A bundle naming TWO matchers (`-EF`, `-FE`) is therefore read as
    # not-extended rather than resolved, and that is deliberate. The two
    # platforms disagree about what such a call even means, and neither runs it
    # as a portable extended match: BSD grep honours the LAST matcher letter, so
    # `-FE` is extended there while `-EF` is fixed, and GNU grep refuses the
    # pair outright, `conflicting matchers specified` and exit 2, in either
    # order. A call like that is already broken on GNU, loudly and before the
    # pattern is ever read, which is a different failure from the silent
    # inversion this gate exists for. Resolving the bundle instead would flag an
    # escape inside a command that cannot run on the platform the flag names.
    function ere_mode(w, isegrep,   nt, t, tok, o, cl, last, ere, skipnext) {
      ere = isegrep
      skipnext = 0
      nt = split(w, tok, "[ \t]+")
      for (t = 1; t <= nt; t++) {
        o = tok[t]
        if (o == "") continue
        # `-e PATTERN` and `-f FILE` take a separate value, which must not be
        # read as an option even when it begins with a dash.
        if (skipnext) { skipnext = 0; continue }
        if (o == "--") break
        if (substr(o, 1, 1) != "-") break
        if (o == "--extended-regexp") { ere = 1; continue }
        if (o == "--fixed-strings" || o == "--perl-regexp" || o == "--basic-regexp") { ere = 0; continue }
        if (substr(o, 1, 2) == "--") continue
        cl = substr(o, 2)
        if (index(cl, "E") > 0) ere = 1
        if (index(cl, "F") > 0 || index(cl, "P") > 0 || index(cl, "G") > 0) ere = 0
        last = substr(cl, length(cl), 1)
        if (last == "e" || last == "f") skipnext = 1
      }
      return ere
    }
    {
      gaia_scan_feed($0, is_bats)
      # The off-surface finding: a pragma naming this guard cannot waive
      # anything outside *.bats, whether or not its target line carries an
      # instance, so it is read here rather than at the print point below,
      # which would go silently inert on every pragma above a clean line.
      if (!is_bats && gaia_scan_pragma_here("lint-grep-ere-escapes"))
        printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, FNR
      # A full-line comment is skipped outright, which covers both a shell
      # comment and a `#` line inside a workflow `run:` block. A comment
      # SHOWING a bad pattern is documentation rather than a call, and this
      # file is itself the proof that the shape occurs.
      if ($0 ~ /^[[:space:]]*#/) next

      consumed = 0
      rest = $0
      while ((pos = index(rest, "grep")) > 0) {
        abs = consumed + pos
        consumed = abs + 3
        rest = substr($0, consumed + 1)

        # A trailing word character means this is a longer identifier
        # (`grepped`, `grep_re`), not the command.
        after = substr($0, abs + 4, 1)
        if (after ~ /[A-Za-z0-9_-]/) continue

        # A leading word character means the same, with `egrep` as the one
        # exception: it is the command, and it is extended-regex by definition.
        # A path-invoked `/usr/bin/grep` is a real invocation, so `/` is not in
        # the class that disqualifies one.
        prev = (abs > 1) ? substr($0, abs - 1, 1) : ""
        isegrep = 0
        if (prev == "e") {
          prev2 = (abs > 2) ? substr($0, abs - 2, 1) : ""
          if (prev2 ~ /[A-Za-z0-9_.-]/) continue
          isegrep = 1
        } else if (prev ~ /[A-Za-z0-9_.-]/) {
          continue
        }

        window = substr($0, abs + 4)
        if (!ere_mode(window, isegrep)) continue
        esc = scan_window(window)
        if (esc == "") continue
        if (is_bats && (gaia_scan_skip() || gaia_scan_suppressed("lint-grep-ere-escapes"))) continue
        printf "%s:%d: \\%s in an extended-regex grep pattern: BSD grep (macOS) and GNU grep (CI) read a backslash-escaped letter differently, so the pattern means two things\n", file, FNR, esc
      }
    }
    END { gaia_scan_end(file, is_bats, "lint-grep-ere-escapes", 0, 1) }
'

# scan_file <path> <is_bats>: run the concatenated program over <path>. A
# *.bats file is named twice so the prepass sees the whole file before the
# class detector runs; every other surface keeps today's single pass.
scan_file() {
  local f="$1"
  local is_bats="$2"
  if [ "$is_bats" -eq 1 ]; then
    awk -v file="$f" -v agreed="sSwWbB" -v is_bats=1 -v scripts_dir="$_gaia_guard_lib_dir" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$f" "$f"
  else
    awk -v file="$f" -v agreed="sSwWbB" -v is_bats=0 -v scripts_dir="$_gaia_guard_lib_dir" \
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
  # The class-remedy footer below names the repair for a class hit and for
  # nothing else. A run whose findings are all pragma hygiene (unused,
  # malformed, honored nowhere) or the desync ERROR would otherwise print a
  # remedy that has nothing to do with what actually went red, pointing the
  # operator at the wrong fix. Gate it on at least one non-blank finding that is
  # neither, rather than on the report merely being non-empty.
  if printf '%s' "$report" \
    | grep -v -e 'gaia-lint-ignore' -e ': ERROR: ' \
    | grep -q '[^[:space:]]'; then
    # printf, not echo: the hint carries backslash escapes that echo may expand
    # depending on the shell (SC2028). The format string is single-quoted so the
    # sample code inside stays literal -- it is being printed, not run.
    # shellcheck disable=SC2016
    printf 'Fix each by writing the character portably:\n    a bracket expression: [[:digit:]], [[:space:]], [0-9]\n    a real control character from the shell: $%s\\r%s, or "$(printf %s\\r%s)"\n    or normalize ahead of the match: tr -d %s\\r%s\n' "'" "'" "'" "'" "'" "'" >&2
  fi
  exit 1
fi

echo "lint-grep-ere-escapes: clean" >&2
exit 0
