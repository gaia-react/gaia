#!/usr/bin/env bash
# lint-shipped-issue-refs.sh: flag every unqualified `#NNN` issue or pull-request
# reference on a shipped non-Markdown file. Exit 1 with a file:line report on any
# hit, exit 0 when clean. Run it directly from the repo root:
# `bash .gaia/scripts/lint-shipped-issue-refs.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-shipped-issue-refs.bats, which the `Audit CI Tests`
# job runs, and called on every pull request by the `Distribution Audit` job in
# .github/workflows/distribution-audit-pr.yml. Also runnable directly:
# `bats .gaia/scripts/tests/lint-shipped-issue-refs.bats`.
#
# The pull-request caller is deliberately the distribution gate rather than a
# paths-filtered test job. Any shipped file can acquire a bare reference, so a
# filter narrow enough to name the surface would have to name nearly the whole
# tree; `Distribution Audit` already runs on every pull request with no filter,
# and its subject is already the manifest-derived shipped set. Co-locating also
# closes a real hole: the file set below comes from the COMMITTED manifest, so a
# brand-new shipped file would be invisible here -- except that the step above
# it in that same job fails the pull request until the manifest acknowledges
# every newly-shipping file the pull request touched. The two gates compose, and
# neither alone is complete.
# gaia:maintainer-only:end
#
# Why: `#NNN` resolves against whatever repository the reader is looking at. On a
# file GAIA ships, the reader is an adopter, and the number silently resolves
# against THEIR tracker -- a real issue of theirs, about something else entirely,
# or nothing at all. `.claude/rules/code-comments.md` (`## Issue and PR
# references`) requires the qualified `gaia-react/gaia#NNN` form on those files
# for that reason, and this gate is what makes the requirement checkable rather
# than merely asserted.
#
# Markdown is out of scope, the same carve-out the rule states: Markdown spends
# `#` on headings and on quoted counter-examples, so a whole-file scan there
# reads as noise. Release-excluded files are out of scope by construction, since
# the scan set is the manifest and the manifest lists only what ships; no reader
# of a release-excluded file can be misled about whose issue a number names.

set -euo pipefail

MANIFEST=".gaia/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "lint-shipped-issue-refs: ERROR: $MANIFEST not found; run from the repository root" >&2
  exit 1
fi

# Collected with a read loop rather than `mapfile`, which is bash 4+, because
# these scripts run on stock macOS /bin/bash (3.2.57).
scan_files=()
while IFS= read -r f; do
  scan_files+=("$f")
done < <(jq -r '.files | keys[]' "$MANIFEST" | grep -v '\.md$' | LC_ALL=C sort)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# manifest that is valid JSON but carries no `files` key -- or a `jq` that is
# absent -- leaves the array empty and the gate prints `clean` having scanned
# nothing. That is the lie-green failure this class of gate exists to stop.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-shipped-issue-refs: ERROR: the manifest yielded no non-Markdown files; nothing was scanned" >&2
  exit 1
fi

# scan_file <path>: print one `file:line: message` per unqualified reference.
#
# A candidate is `#` followed by a maximal run of 2-4 digits. Two tests decide
# whether it is a reference this gate wants:
#
#   unqualified -- the character before the `#` is not a word character, `/`, or
#                  `#`. That single test is what excludes the compliant form:
#                  in `gaia-react/gaia#726` the preceding character is `a`, and
#                  in `capricorn86/happy-dom#978` it is `m`, so an owner/repo
#                  prefix of any shape is skipped without enumerating one. `#`
#                  is excluded so a `##` heading or a doubled sigil is not a
#                  candidate.
#   not-hex     -- the character after the digit run is not a hex letter. This
#                  is what keeps `#123456` and `#12ab` out: taking the digit run
#                  MAXIMALLY and then rejecting a hex-letter follower is the
#                  same discrimination the rule's original grep expressed
#                  through backtracking, stated directly.
#
# The colour exemption, the one discrimination that is not in the rule's
# original grep. A 3- or 4-digit all-numeric token such as `#333` or `#0000` is
# simultaneously a valid issue number and a valid CSS short hex colour, and
# shipped CSS is in the manifest. A colour carrying a hex LETTER never reaches
# this test, having already failed one of the two above: `#0f0` breaks the digit
# run after one digit, and `#00f` is followed by a hex letter. Only the
# all-numeric ones are ambiguous. Nothing lexical separates those two readings,
# so this uses the surrounding punctuation, which is what actually differs: a
# colour sits inside a declaration VALUE. Both sides must hold -- some `:` or
# `=` opens the value to the left with no `;`/`{`/`}` in between, and a `,`,
# `;`, `)`, a quote, or a `}` closes it to the right. A reference does not
# survive that: `(#726)` finds no opener, and `see #726.` finds no closer.
#
# The honest limit, stated rather than discovered later. A reference that
# satisfies both halves above is exempted and missed, and the shapes that do are
# ordinary rather than contrived, which is the part to take seriously:
#
#   # TODO: fix #726, then remove
#   # Why: the hook denies (#727).
#   # Why: see #728 }
#
# Read the mechanism above for what qualifies rather than generalizing from
# these three, because both halves are narrower than "the line has a colon
# somewhere": the leftward walk stops at a `;`, `{` or `}`, and the closer must
# sit immediately after the digits (or after only spaces, before a `}`). So
# `# Why: it fails; see #726,` and `# TODO: fix #727 then remove, please` are
# both FLAGGED. That is a FAIL-OPEN miss and it is accepted. The other direction
# reds
# the build on a colour, which is a false positive on a line that has NO
# correct repair -- the author cannot write `gaia-react/gaia#333` for a shade of
# grey -- and this gate runs on every pull request. A two-digit candidate cannot
# be a colour at all and so is never exempted, whatever surrounds it.
scan_file() {
  local f="$1"
  # Character-set membership is tested with index() against literal sets rather
  # than with regex literals, and that is portability rather than taste: the
  # sets this scan needs contain `/`, `"` and `'`, and how an awk lexer treats
  # each of those inside a /.../ literal (and inside a bracket expression within
  # one) varies by implementation. CI runs a different awk from a macOS
  # checkout, so a set written as a regex could be read one way locally and
  # another way in the job that gates the merge. index() has no such freedom.
  # `\047` spells the single quote so the character never appears literally
  # inside this single-quoted shell string.
  awk -v file="$f" '
    BEGIN {
      DIGITS   = "0123456789"
      HEX      = "0123456789ABCDEFabcdef"
      # A candidate must not be preceded by any of these: a word character
      # (so `gaia-react/gaia#726` and `happy-dom#978` are skipped whole), the
      # path separator, or a second sigil.
      WORDISH  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_/#-"
      # What terminates a CSS colour value.
      CLOSERS  = ";,\")\047"
      # What ends a declaration, so the leftward walk knows it has left one.
      STOPPERS = ";{}"
    }
    {
      i = 1
      n = length($0)
      while (i <= n) {
        if (substr($0, i, 1) != "#") { i++; continue }

        # Maximal digit run after the sigil.
        j = i + 1
        while (j <= n && index(DIGITS, substr($0, j, 1)) > 0) j++
        digits = j - i - 1
        if (digits < 2 || digits > 4) { i++; continue }

        # An empty `before` (start of line) is not in any set, so index()
        # returns 0 and the candidate survives, which is the intent.
        before = (i == 1) ? "" : substr($0, i - 1, 1)
        if (before != "" && index(WORDISH, before) > 0) { i = j; continue }

        after = (j > n) ? "" : substr($0, j, 1)
        if (after != "" && index(HEX, after) > 0) { i = j; continue }

        if (digits == 3 || digits == 4) {
          # Left context: is the token somewhere inside a declaration VALUE?
          # Walk back to the nearest `:` or `=`, giving up if a `;`, `{` or `}`
          # ends the declaration first, or if the line starts. Testing only the
          # character immediately before the token would recognize a colour
          # solely where it LEADS the value (`color: #333`) and miss every
          # compound one (`border: 1px solid #333`, `linear-gradient(#555,
          # #666)`, `var(--x, #333)`), which is the common shape, so the gate
          # would red the build on nearly every real stylesheet.
          k = i - 1
          opens = 0
          while (k >= 1) {
            c = substr($0, k, 1)
            if (c == ":" || c == "=") { opens = 1; break }
            if (index(STOPPERS, c) > 0) break
            k--
          }

          # Right context: a closer immediately after, or trailing whitespace
          # then `}` for a declaration that omits its final semicolon
          # (`outline: 2px dashed #999 }`). Whitespace alone is deliberately
          # NOT a closer: `see #726 for the reason` would otherwise be exempt
          # on any line that happens to carry an earlier `:`.
          closes = (after != "" && index(CLOSERS, after) > 0)
          if (!closes) {
            m = j
            while (m <= n && (substr($0, m, 1) == " " || substr($0, m, 1) == "\t")) m++
            closes = (m <= n && substr($0, m, 1) == "}")
          }

          if (opens && closes) { i = j; continue }
        }

        ref = substr($0, i + 1, digits)
        printf "%s:%d: unqualified issue reference #%s: on a shipped file it resolves against the reader\047s own tracker; write gaia-react/gaia#%s\n", file, NR, ref, ref
        i = j
      }
    }
  ' "$f"
}

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  # A manifest entry with no file on disk is skipped rather than reported. The
  # committed manifest can name a file a working tree has not received yet, and
  # a missing-file complaint here would be a distribution-boundary finding
  # wearing this gate's clothes; the release CLI's own `--check` owns that.
  [ -f "$f" ] || continue
  # GAIA ships binary assets (favicons, fonts, images). Their bytes are not
  # text, but nothing stops a run of them from spelling ` #726`, and a report
  # naming a line number inside a PNG is noise the reader cannot act on. Skip
  # them, which also avoids walking megabytes of asset data a character at a
  # time.
  #
  # `grep -I` decides by CONTENT, so a newly shipped binary of any extension is
  # covered without a denylist that would be one extension short. An empty file
  # matches nothing and is skipped too, which costs nothing: it has no line to
  # flag.
  #
  # Note for anyone tempted to drop this as belt-and-braces: an earlier draft of
  # scan_file matched characters with regexes, and awk aborted the whole run
  # with a multibyte conversion error on the first shipped PNG. The index()
  # rewrite removed that abort on the awk tested here, so the skip is no longer
  # what keeps the run alive; it is what keeps the report honest.
  grep -Iq . "$f" || continue
  hits=$(scan_file "$f")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  echo "See .claude/rules/code-comments.md (## Issue and PR references) for the paired/unpaired test and the remedy." >&2
  exit 1
fi

echo "lint-shipped-issue-refs: clean" >&2
exit 0
