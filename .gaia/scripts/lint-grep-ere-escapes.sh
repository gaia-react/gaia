#!/usr/bin/env bash
# lint-grep-ere-escapes.sh: flag every backslash-escaped LETTER inside an
# extended-regex grep pattern, across the framework's tracked shell, its CI
# workflow and composite-action YAML, and the adopter workflow templates. Exit 1
# with a file:line report on any hit, exit 0 when clean. Run it directly from
# the repo root: `bash .gaia/scripts/lint-grep-ere-escapes.sh`.
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
# Two file types are deliberately out of the surface:
#
#   *.bats  -- the suites are where this class is DEMONSTRATED. This gate's own
#              sibling suite carries `grep -E 'a\tb'` fixture strings as the
#              evidence the detector works, and a scanner reading raw lines
#              cannot tell a fixture from an executed call, so including them
#              would demand "fixes" that delete the proof. This is a real
#              FAIL-OPEN and worth naming as one: a bats suite runs on macOS
#              locally and on ubuntu in CI, so it is exposed to the class rather
#              than exempt from it. Every suite in this tree is at zero for the
#              class today, and the exclusion is what buys the detector.
#   *.md    -- the sibling path-quoting gate scans the fenced blocks of tracked
#              markdown because several are executed instruction. The same is
#              true here, but the class needs the pattern to be authored on one
#              platform and RUN on another, and an executed markdown snippet is
#              run by an agent on the author's own machine. The exposure the
#              class needs does not arise, and the fence-state machinery is not
#              free.

set -euo pipefail

# `git ls-files` rather than a filesystem walk, so an untracked scratch script
# is never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these
# scripts run on stock macOS /bin/bash (3.2.57).
scan_files=()
while IFS= read -r -d '' f; do
  scan_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z \
                      '*.sh' '.husky/*' \
                      '.github/workflows/*.yml' '.github/workflows/*.yaml' \
                      '.github/actions/*/action.yml' '.github/actions/*/action.yaml' \
                      '.gaia/cli/src/automation/templates/workflows/*.tmpl' \
           | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is the lie-green
# failure gates exist to stop. Every real tree carries tracked `*.sh`, so an
# empty result means the discovery is wrong rather than the tree.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-grep-ere-escapes: ERROR: no tracked shell, workflows, or workflow templates matched the scan surface; nothing was scanned" >&2
  exit 1
fi

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
scan_file() {
  local f="$1"
  awk -v file="$f" -v agreed="sSwWbB" '
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
    # `-F`, `-P`, and `-G` set a DIFFERENT matcher, and each one wins over an
    # earlier `-E` because grep honours the last matcher option given. In all
    # three the class does not apply: `-F` has no regex at all, `-P` is PCRE
    # where every escape here is defined and identical, and `-G` is a BRE, whose
    # backslash rules are a separate class this gate does not claim.
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
    # A full-line comment is skipped outright, which covers both a shell comment
    # and a `#` line inside a workflow `run:` block. A comment SHOWING a bad
    # pattern is documentation rather than a call, and this file is itself the
    # proof that the shape occurs.
    /^[[:space:]]*#/ { next }
    {
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
        if (esc != "")
          printf "%s:%d: \\%s in an extended-regex grep pattern: BSD grep (macOS) and GNU grep (CI) read a backslash-escaped letter differently, so the pattern means two things\n", file, NR, esc
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
  # printf, not echo: the hint carries backslash escapes that echo may expand
  # depending on the shell (SC2028). The format string is single-quoted so the
  # sample code inside stays literal -- it is being printed, not run.
  # shellcheck disable=SC2016
  printf 'Fix each by writing the character portably:\n    a bracket expression: [[:digit:]], [[:space:]], [0-9]\n    a real control character from the shell: $%s\\r%s, or "$(printf %s\\r%s)"\n    or normalize ahead of the match: tr -d %s\\r%s\n' "'" "'" "'" "'" "'" "'" >&2
  exit 1
fi

echo "lint-grep-ere-escapes: clean" >&2
exit 0
