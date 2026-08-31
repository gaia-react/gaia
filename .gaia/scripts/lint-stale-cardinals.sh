#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk source strings below are
# single-quoted precisely so that every `$` and awk field reference reaches awk
# as literal program text.
# shellcheck disable=SC2016
#
# lint-stale-cardinals.sh: flag a DEFINITE cardinal that names a countable set
# of repository artifacts in a comment or a bats `@test` name, where nothing
# recounts the set. Exit 1 with a file:line report on any hit, exit 0 when
# clean. Run it directly from the repo root:
# `bash .gaia/scripts/lint-stale-cardinals.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-stale-cardinals.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh, which is how it
# reaches every pull request. Also runnable directly:
# `bats .gaia/scripts/tests/lint-stale-cardinals.bats`.
#
# The convention behind this file's argument-region discrimination and its
# pragma is recorded once, in wiki/decisions/Shell Guard Fixture Discrimination.md.
# gaia:maintainer-only:end
#
# Why: a bare count is a name for a set, and it decays the way a name does. The
# set grows, nothing recounts, and the number becomes a false claim a reader
# trusts precisely because it is specific. `.claude/rules/code-comments.md`
# (`## Counts`) states the rule and the remedy; this gate is what makes the
# requirement checkable rather than merely asserted, the same relationship
# .gaia/scripts/lint-shipped-issue-refs.sh has to that file's issue-reference
# section. `.claude/rules/bats-assertions.md` states the same prohibition for a
# `@test` name and for the comment describing a derived set, which is why a
# `@test` line is scanned here alongside a comment.
#
# The remedy, in the rule's own order of preference: name the members or point
# at what holds them and let the reader count; or, where the number genuinely
# carries the claim, add something that recounts it and leave the number
# self-correcting. Correcting a stale figure without adding the recount just
# restarts the decay from a fresher number.
#
# ---------------------------------------------------------------------------
# What is a candidate, and why each narrowing is there
# ---------------------------------------------------------------------------
#
# A candidate is a DEFINITE DETERMINER, then a CARDINAL of at least three, then
# a REPO-ARTIFACT PLURAL NOUN, within a short window. Each of the three terms
# is a narrowing measured against this tree rather than assumed, because the
# naive predicate -- a number beside a plural noun -- fires in the high hundreds
# here and a gate nobody can keep green gets disabled.
#
# DEFINITE, not bare. This is the discriminator that makes the class separable
# at all. A bare cardinal is ordinary structural English: "two ways", "three
# things", "two arms" describe the shape of the argument being made in the very
# same comment, and the enumeration is right there, so the phrase is rewritten
# whenever it changes. A definite determiner is different in kind: a possessive
# or an all-quantifier binding a cardinal to a set the reader is expected to
# already know, of siblings, of hooks, of callers, asserts a cardinality for a
# specific population that lives somewhere else in the tree and moves without
# touching this sentence. Both instances of the class that were in reach on this
# surface carried a determiner, and so did every instance already standing in
# the tree when this gate was written; the bare-subject form ("Six subcommands
# answer here") is real, and the FAIL-OPEN list below is where it is accounted
# for rather than here. Dropping this term multiplies the report several-fold
# with nothing in the added set that a reader would call a defect.
#
# AT LEAST THREE. A pair is the one cardinality English spends as a structural
# word rather than as a measurement -- "the two sides", "the two halves", "the
# two consumers" -- and its enumeration is invariably adjacent. The rule's own
# worked examples all start above it. Admitting a cardinality of two roughly
# doubles the report and the added entries are overwhelmingly of that shape.
#
# A CLOSED NOUN VOCABULARY, in NOUNS below. Without it the report is dominated
# by nouns that name an abstraction rather than a countable artifact ("ways",
# "shapes", "halves", "reasons"), for which there is no set to recount and so no
# repair. The vocabulary names things this repository CONTAINS and a reader
# could go and count. It is deliberately a closed list rather than a
# morphological guess: a list that is short and wrong is visible, and a
# heuristic that is subtly wrong is not. Extending it is a one-line change, and
# an extension that reds the tree is the gate working.
#
# ---------------------------------------------------------------------------
# The scan surface, and the one carve-out
# ---------------------------------------------------------------------------
#
# Tracked `*.sh` and `*.bats`: full-line comments, plus the `@test` name line.
# That is where `.claude/rules/code-comments.md` and
# `.claude/rules/bats-assertions.md` place the prohibition, and it is where the
# instances that motivated this gate lived.
#
# Markdown is deliberately OUT, and the reason is stronger than the noise
# argument that keeps it out of lint-shipped-issue-refs.sh. Tracked markdown in
# this tree is dominated by DATED, FROZEN records -- CHANGELOG.md, wiki/log.md,
# and the wiki/meta/lint-report-*.md and staleness-audit-*.md series -- in which
# a cardinal is a true statement about the tree AS IT WAS on the day the entry
# was written. Recounting one against today's tree is not a repair; it falsifies
# a record whose whole value is that it does not move. The rule files that
# DEFINE this class are markdown too, and they quote the bad shape as a worked
# example. A gate there would demand edits with no correct answer on both
# populations, which is the shape that gets a gate switched off. A markdown
# surface would need a frozen-record exemption before it could pay, and that is
# a different gate rather than a wider pathspec on this one.
#
# ---------------------------------------------------------------------------
# The pragma
# ---------------------------------------------------------------------------
#
# `gaia-lint-ignore lint-stale-cardinals: <reason>` on the comment line above a
# target waives it there and nowhere else; an unused one is reported. It is
# honored inside `*.bats` only, which is where a suite has to WRITE the bad
# shape as a fixture. Everywhere else the absence of an escape hatch is the
# point: the rule's remedies are always available, so a `*.sh` comment that
# cannot be reworded is a comment stating a count nothing keeps.
#
# The literal form, the token-resolution rule, and the block-continuation rule
# are the shared library's, stated once in .gaia/scripts/guard-awk-lib.sh.
#
# ---------------------------------------------------------------------------
# Blind spots, split by which way each fails
# ---------------------------------------------------------------------------
#
# FAIL-OPEN, each a real instance this scan cannot read:
#   - A cardinal separated from its noun by more words than GAP_MAX below. The
#     window is short on purpose: widening it starts admitting a cardinal and a
#     noun that belong to different clauses of one sentence, which is a false
#     positive whose demanded repair points at the wrong phrase.
#   - A count expressed without a determiner the DET set names, most of all a
#     possessive noun phrase ("the gate's four callers") or a bare subject
#     ("Six subcommands answer here"). The definite-determiner term is what
#     buys the precision, and it is paid for with exactly this.
#   - A noun outside the closed vocabulary.
#   - An ordinal or a written-out range ("the fourth of five callers").
#   - A count in a trailing comment that shares its line with code: only a
#     full-line comment is read, so an instance written after a `#` that follows
#     executable text on the same line is missed. This is the same full-line
#     rule the sibling guards use, and it is what keeps a `#` inside a quoted
#     string from being read as a comment at all.
#   - Everything the shared library lists under its own FAIL-OPEN heading, since
#     a line it classifies as bats fixture data is skipped here too.
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - A determiner that is grammatically definite but whose noun phrase is
#     generic ("all three cases the parser admits"), where the enumeration is
#     immediate and the number is not really a claim about the tree. The
#     remedy the rule prescribes -- name the shape, drop the cardinality -- is
#     available and cheap, so this is not worth a second discrimination.
#   - A cardinal quoted inside a comment as a counter-example, outside `*.bats`
#     where the pragma is honored. This file's own header is written to avoid
#     the shape rather than to waive it, which is the demonstration that the
#     remedy is always reachable.

set -euo pipefail

_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_bats_files >/dev/null 2>&1 || {
  printf 'lint-stale-cardinals: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}

# `git ls-files` rather than a filesystem walk, so an untracked scratch script
# is never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these
# scripts run on stock macOS /bin/bash (3.2.57).
scan_files=()
while IFS= read -r -d '' f; do
  scan_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '*.sh' | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and the scan below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is the lie-green
# failure gates exist to stop. Every real tree carries tracked `*.sh`, so an
# empty result means the discovery is wrong rather than the tree.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-stale-cardinals: ERROR: no tracked shell scripts matched the scan surface; nothing was scanned" >&2
  exit 1
fi

# A separate set from scan_files, never a widened pathspec: a tree carrying
# .sh and no .bats must not pass clean carried by the rest of the surface.
gaia_guard_bats_files lint-stale-cardinals || exit 1

# The class detector.
#
# Tokenization walks characters against literal sets with index() rather than
# splitting on a regex character class, and that is portability rather than
# taste. These files carry UTF-8 in comments, CI runs a different awk from a
# macOS checkout, and the sibling issue-reference gate recorded an awk aborting
# a whole run with a multibyte conversion error on a regex-driven scan. index()
# has no such freedom: a byte is either in the set or it is not. Folding case
# during the same walk is what lets DET, CARD and NOUN below be plain lowercase
# lists, so a comment shouting its cardinal in capitals is read like any other.
#
# A byte outside the alphanumeric set ENDS the current token rather than being
# skipped over. That is what makes `hooks'` and `idiom-4` tokenize the way a
# reader reads them, and it is why a multibyte character behaves as punctuation
# here, which for this predicate is the right reading.
readonly OWN_AWK='
    BEGIN {
      gaia_scan_reset()
      UPPER  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      LOWER  = "abcdefghijklmnopqrstuvwxyz"
      DIGITS = "0123456789"

      # Characters that end a clause. Without them the walk reads across a
      # sentence boundary and invents a phrase neither sentence contains: a
      # comment closing one sentence on `... at all.` and opening the next on a
      # cardinal hands the walk a determiner, a cardinal and a vocabulary noun
      # in order, spanning the full stop between them. The determiner term this
      # gate depends on is exactly what makes that collision plausible rather
      # than rare, and the suite pins the shape as a control.
      #
      # One of these ends a clause only when WHITESPACE or end of line follows
      # it. That test is what separates prose punctuation from the same
      # characters inside an identifier, and both readings occur constantly on
      # this surface: a path (`.gaia/scripts/`), a label namespace (`surface:`),
      # a filename (`README.md`). Treating those as clause ends silently
      # discards real instances, since a barrier anywhere between the
      # determiner and the noun suppresses the finding.
      ENDERS = ".!?;:"
      SPACE  = " \t"

      # Definite determiners. A possessive pronoun is included and a possessive
      # NOUN is not, for the reason the FAIL-OPEN list in the header gives.
      split("all the its their our your these those", t, " ")
      for (i in t) DET[t[i]] = 1

      # Spelled cardinals from three upward. Two is excluded by the header rule
      # rather than by omission, and one is not a plural claim at all.
      split("three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty", t, " ")
      for (i in t) CARD[t[i]] = 1

      # Nouns naming an artifact this repository CONTAINS, which is what makes
      # a recount possible and therefore what makes the finding actionable.
      split("agents callers commands consumers entries exemptions files fixtures guards helpers hooks jobs labels lines markers members pages rules scripts shards siblings sites skills subcommands suites tests workflows", t, " ")
      for (i in t) NOUN[t[i]] = 1

      # How many words may sit between the cardinal and its noun. One admits
      # the ordinary compound noun phrase, which is a shape the class really
      # takes: one of the two instances this gate was written for is a fixture
      # count carrying a modifier between the cardinal and the noun, and the
      # suite pins it verbatim. See the header for why the window stops there.
      GAP_MAX = 1
    }

    # Pass one over a *.bats file feeds the shared prepass and reports nothing.
    # A fixture constant is bound far above the helper call that consumes it, so
    # a forward-only scan cannot classify it; without this rule the class
    # detector below would also run over pass one and report every bats hit
    # twice.
    is_bats && NR == FNR { gaia_scan_prepass($0); next }

    # tokenize(s): fill TOK[1..NT] with case-folded alphanumeric runs, and
    # END_AFTER[n] with 1 when a clause ender follows token n.
    function tokenize(s,   i, n, ch, k, cur, nxt) {
      NT = 0
      cur = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        k = index(UPPER, ch)
        if (k > 0) {
          cur = cur substr(LOWER, k, 1)
          continue
        }
        if (index(LOWER, ch) > 0 || index(DIGITS, ch) > 0) {
          cur = cur ch
          continue
        }
        if (cur != "") { NT++; TOK[NT] = cur; END_AFTER[NT] = 0; cur = "" }
        if (NT > 0 && index(ENDERS, ch) > 0) {
          nxt = (i < n) ? substr(s, i + 1, 1) : ""
          if (nxt == "" || index(SPACE, nxt) > 0) END_AFTER[NT] = 1
        }
      }
      if (cur != "") { NT++; TOK[NT] = cur; END_AFTER[NT] = 0 }
      return NT
    }

    # is_cardinal(w): a spelled cardinal from three up, or an all-digit run
    # whose value is at least three. The digit test is guarded on the token
    # being all digits, so a version fragment or a hash never reads as a count.
    function is_cardinal(w,   i, ch) {
      if (w in CARD) return 1
      if (w == "") return 0
      for (i = 1; i <= length(w); i++) {
        ch = substr(w, i, 1)
        if (index(DIGITS, ch) == 0) return 0
      }
      return (w + 0) >= 3
    }

    {
      gaia_scan_feed($0, is_bats)
      # The off-surface finding: a pragma naming this guard cannot waive
      # anything outside *.bats, whether or not its target line carries an
      # instance, so it is read here rather than at the print point below,
      # which would go silently inert on every pragma above a clean line.
      if (!is_bats && gaia_scan_pragma_here("lint-stale-cardinals"))
        printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, FNR

      # Only a full-line comment, or a bats test NAME, is prose this gate
      # judges. Everything else on these surfaces is code, where a number is a
      # value rather than a claim about a set.
      if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*@test[[:space:]]/) next

      tokenize($0)
      for (i = 1; i + 2 <= NT; i++) {
        if (!(TOK[i] in DET)) continue
        if (END_AFTER[i]) continue
        if (!is_cardinal(TOK[i + 1])) continue
        if (END_AFTER[i + 1]) continue
        for (j = i + 2; j <= NT && j <= i + 2 + GAP_MAX; j++) {
          # A second determiner opens a new noun phrase, so the cardinal and
          # anything past it belong to different claims. Stopping here is what
          # keeps the window from reaching past the phrase it is reading.
          if (TOK[j] in DET) break
          if (!(TOK[j] in NOUN)) {
            if (END_AFTER[j]) break
            continue
          }
          if (is_bats && (gaia_scan_skip() || gaia_scan_suppressed("lint-stale-cardinals"))) break
          printf "%s:%d: \"%s %s ... %s\" states a count of a set nothing recounts\n", \
            file, FNR, TOK[i], TOK[i + 1], TOK[j]
          break
        }
      }
    }
    END { gaia_scan_end(file, is_bats, "lint-stale-cardinals", 0, 1) }
'

# scan_file <path> <is_bats>: run the concatenated program over <path>. A
# *.bats file is named twice so the prepass sees the whole file before the
# class detector runs; every other surface keeps a single pass.
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
for f in ${scan_files[@]+"${scan_files[@]}"}; do
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
  # nothing to do with what actually went red.
  if printf '%s' "$report" \
    | grep -v -e 'gaia-lint-ignore' -e ': ERROR: ' \
    | grep -q '[^[:space:]]'; then
    printf 'Fix each by preferring the set to its cardinality:\n    name the members, or point at what holds them, and let the reader count\n    or, where the number carries the claim, add a check that recounts it\nSee .claude/rules/code-comments.md (## Counts) for the rule and the remedy.\n' >&2
  fi
  exit 1
fi

echo "lint-stale-cardinals: clean" >&2
exit 0
