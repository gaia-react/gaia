#!/usr/bin/env bash
# lint-git-path-quoting.sh: flag every executed `git diff --name-only`, every
# executed `git ls-files`, and every executed `git grep` that LISTS FILE NAMES,
# which omits `-z`, across the scan surface the `scan_files` pathspec below
# declares and the comment above it explains. Exit
# 1 with a file:line report on any hit, exit 0 when clean. Run it directly from
# the repo root: `bash .gaia/scripts/lint-git-path-quoting.sh`.#
# Four statuses say the gate never ran at all: 2 when guard-awk-lib.sh is
# missing beside this script, 3 when the scan-surface discovery failed, 5 when
# no awk interpreter is present at all, and 6 when GAIA_AWK resolves to an
# interpreter that identifies as neither mawk nor BWK one-true-awk.
#
# TypeScript is not this script's surface. The CLI's git listing calls are argv
# arrays rather than shell words, and route through `gitZArgs` in
# .gaia/cli/src/util/git-z.ts instead.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-git-path-quoting.bats, which the `Audit CI
# Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-git-path-quoting.bats`.
# gaia:maintainer-only:end
#
# Why: under git's default `core.quotePath`, a path-listing command C-quotes any
# path carrying a non-ASCII byte, a control character, a double quote or a
# backslash -- it prints `"caf\303\251.txt"`, not `café.txt`. Every consumer
# that then matches the output against a path pattern silently stops matching,
# and in this repository every such consumer fails OPEN: a gate that decides
# "no relevant files changed", or that discovers the files it is about to scan,
# reports its required check green having run nothing. `-z` turns the quoting
# off and NUL-delimits instead.
#
# The class is why this gate exists rather than a review habit. It has been
# found and fixed by hand SEVEN times, every time by a human or an audit member
# reading the code and never once by a check (`#1032`, `#1115`, `#1213`,
# `#1224`, `#1225`, `#1228`, `#1230`). `#1229` is the issue that stopped paying
# that tax for `diff --name-only`, and `#1389` is the one that stopped paying it
# for `ls-files` -- a variant the guard's first shape could not see, which is how
# the class recurred in five discovery call sites INCLUDING this file's own.
# `#2055` is the third round of the same story, and it is the reason the header
# above now names three verbs: the arming reached two while this paragraph
# claimed the class broadly, and a listing `git grep` quotes identically. It
# recurred live in `#2054`, where a tree-wide lint discovered carriers with
# `git grep -F -l` and no `-z`: a tracked `wiki/café.md` came back C-quoted,
# named no file on disk, and reached `awk` as an unopenable path, so the
# carrier went ungraded and the run died with awk's message instead of the
# script's own, discarding report lines earlier terms had accumulated.
#
# Fix a `diff --name-only` hit with the idiom the repository already uses
# throughout:
#
#   changed="$(git diff --name-only -z "${base}...HEAD" | tr '\0' '\n')"
#
# In a workflow `run:` block under `set -eu`, put the pipeline in a subshell
# that sets pipefail, so a git failure still aborts the step as it did before
# the pipe existed -- `$(...)` alone discards NUL bytes, so the `tr` cannot be
# moved out of the substitution:
#
#   changed=$(set -o pipefail; git diff --name-only -z "$B...HEAD" | tr '\0' '\n')
#
# Fix an `ls-files` hit by reading the NUL stream directly, which keeps every
# byte of the path intact rather than round-tripping it through newlines:
#
#   while IFS= read -r -d '' f; do
#     scan_files+=("$f")
#   done < <(git -c core.quotepath=false ls-files -z <pathspecs>)
#
# `-z` alone is what disables the quoting; `-c core.quotepath=false` is
# belt-and-braces for the reader. A `| LC_ALL=C sort` on such a stream must
# become `| LC_ALL=C sort -z`, or the sort re-joins the records on newlines and
# undoes the fix. Both BSD sort (macOS) and GNU sort accept `-z`.
#
# Fix a listing `grep` hit the same way, with one constraint the other two verbs
# do not carry: `git grep` takes a POSITIONAL pattern, and the option walk below
# stops at the first non-option token, so `-z` goes in the option region AHEAD
# of the pattern rather than after it:
#
#   while IFS= read -r -d '' f; do
#     carriers+=("$f")
#   done < <(git -C "$root" grep -lIF -z "$needle" -- <pathspecs>)
#
# A `-z` written after the pattern reads as missing and the call reds. That is
# fail-CLOSED, the repair is to move the flag, and options-first is the idiom
# every call in this tree already writes.
#
# A consumer that COUNTS rather than iterates takes `| tr -cd '\0' | wc -c`,
# never the `| tr '\0' '\n' | wc -l` round-trip above. Translating the records
# back to newlines makes a path holding a literal newline count twice, so on a
# counting consumer the repair advertised for an iterating one REGRESSES the
# site it was applied to: the pre-repair quoted spelling counted correctly,
# because quoting never splits a record. `-z` fixes the byte fidelity; only
# counting the separators themselves fixes the arithmetic.
#
# Reference fixes: .gaia/scripts/resolve-audit-members.sh (the `changed`
# derivation) and .gaia/tests/shell-lint.sh (its discovery loops).
#
# Two `ls-files` shapes are deliberately NOT flagged, and each is a closed
# property of the call text rather than a judgment about its consumer:
#
#   --error-unmatch  -- the call is an existence assertion whose contract is its
#                       exit status, not its output; git's own documentation
#                       defines the flag that way. Every such call in this tree
#                       discards stdout. Demanding `-z` there would be a change
#                       with no failure mode behind it.
#   an option-less   -- `-z` is accepted anywhere in the call's OPTION region,
#   -z position         which ends at the first token not starting with `-` or
#                       at an explicit `--`. `ls-files` idiomatically carries
#                       selector options first (`--others --exclude-standard
#                       -z`), and `diff` carries `--cached` or `--staged` ahead
#                       of `--name-only`, so every half reads the region rather
#                       than a fixed position. Terminating the walk at the first
#                       non-option is what stops a pathspec carrying the token
#                       from vouching for a call that still quotes.
#
# `grep` is offered NO carve-out of its own, and that is a decision rather than
# an omission. The shape that would earn the `--error-unmatch` analogue is a
# call whose contract is its exit status: `git grep -q`. But `-q` suppresses the
# very listing the flag above asks for, so a call carrying both is a
# contradiction, none exists in this tree, and a carve-out for it would be
# machinery for a shape that does not occur; should one ever be written, it pays
# one correct edit. The other candidate, a listing call whose output is merely
# counted or tested for emptiness, is not a closed property of the CALL TEXT at
# all. It is a judgment about the consumer, which is the line both `ls-files`
# carve-outs stay on the right side of and the reason they are affordable. So
# every executed `git grep` that lists file names is on the surface.
#
# What the arming covers is five spellings, each of which makes `git grep` print
# a path AS THE WHOLE RECORD: `-l`, `--files-with-matches`, `--name-only`, `-L`
# and `--files-without-match`. The two short spellings are read inside a CLUSTER
# (`-lIF` arms, and so would `-LIF`), because clustering is how every real call
# in this tree writes them.
#
# That is the set this file ARMS ON, stated as such, and deliberately not as a
# claim that no sixth spelling exists. `--heading` is a sixth, documented in the
# git already installed rather than in some future release: it prints the
# filename on a record of its own above that file's matches, C-quoted by the
# identical mechanism. It is left off the surface because its stream INTERLEAVES
# path records with match records, so anything reading it is reading a rendering
# meant for a human rather than a path list, and no call in this tree writes it.
# A closed-set claim would have been the load-bearing half of an enumeration, and
# the one enumeration this file permits itself has to survive being checked
# against the installed tool, so it asserts its own reach instead.
#
# "As the whole record" is doing real work in that sentence. `git grep -n`, and
# the bare default form, print the path too, as the first COLON-DELIMITED FIELD
# of a larger record, and git C-quotes it there by the identical mechanism. This
# gate does not reach those either, and the blind-spot block below states it as a
# miss rather than leaving the sentence above to be read as covering it. What
# keeps them off the surface is the same rule that keeps the `ls-files`
# carve-outs honest: whether a record's path field is parsed out and opened, or
# merely printed to a human alongside the matched text, is a judgment about the
# consumer, and the two shapes are textually identical.
#
# The `-z` half is deliberately NOT cluster-aware, and the asymmetry is the
# point: reading a letter out of a cluster is exact for a flag letter and
# approximate for a cluster carrying an attached value (`-ePATTERN`), and
# telling those apart needs git's own argument parser. Approximating on the
# ARMING half costs a false positive, which fails closed; approximating on the
# DISARMING half would cost a missed defect, which fails open, in a gate whose
# entire purpose is closing fail-open holes. So `-z` is recognized only as a
# standalone token, exactly as it already is for the other two verbs, and
# `git grep -lz` reds with the repair being to write the flag separately. A
# cluster can no more vouch for a call than a pathspec can.
#
# `git status --porcelain` is the third member of this family and is deliberately
# OUT of the declared surface rather than merely unreached. Its dominant shape in
# this repository is an emptiness test (`[ -z "$(git status --porcelain)" ]`),
# where quoting cannot change the verdict, and its remaining instances sit in
# adopter-facing workflow templates that regenerate through `bundle:adopter`.
# Claiming it here would red the gate on call sites that carry no failure mode,
# which is how a gate gets bypassed rather than fixed.
#
# A fenced code block on a tracked markdown page IS on the declared surface, and
# the reason is that several of them are executed instruction rather than
# illustration: an always-loaded rule tells the agent to run that page's steps as
# written, so the snippet is a live call site. Three carried this class at once,
# in the quality gate's own skip check, in the wiki-sync added-page count feeding
# the consolidate trigger, and in the health runbook's staging-tree discovery,
# and no check could see any of them.
#
# The discriminator is FENCE STATE, never a path glob enumerating which pages are
# executed. A glob is an enumeration, and an enumeration goes one page short the
# same way a list of option spellings does; fence state is a closed property of
# the text. An illustrative mention of a path-listing command is idiomatically a
# code span, which the `inspan` rule below already treats as prose, so the two
# rules partition markdown between them: outside a fence nothing is scanned at
# all, and inside one nothing is prose. Swept across every tracked markdown page
# in this repository, that partition reported the live defects and nothing else,
# which is what makes the rule affordable as well as closed.
#
# What the fence rule reads is stated in the scanner beside the code that does
# it: a closer matches the opener's character and length, and a leading `>` is
# part of the delimiter's run. Its remaining blind spots:
#   - An illustrative fenced block that DELIBERATELY shows an unquoted call as a
#     counter-example is flagged. That is FAIL-CLOSED, and the repair is to write
#     the counter-example as a code span or to let it carry `-z`.
#   - A page whose fences do not balance inverts the polarity from the unclosed
#     delimiter onward. FAIL-OPEN past that point, and unlike the nesting case
#     a parity count over the page does detect it, because the page really is
#     unbalanced and renders wrong for its human reader too.
#   - An indented code block, the four-space form carrying no delimiter at all,
#     is never entered and so is never scanned. FAIL-OPEN. Nothing distinguishes
#     it from an indented continuation line without parsing the block structure
#     the delimiters make free, and no page in this tree executes one.
#
# So: the surface this file claims is at zero for `ls-files`, for every listing
# spelling of `grep`, and for every
# option spelling of `diff --name-only`, which is what the tests below pin. The
# `diff` half reads its option region rather than a fixed string, so an OPTION
# written between `diff` and `--name-only` -- `--cached`, `--staged`, or any
# other -- no longer hides the call. A positional REVISION in that position
# still does, and that limit is stated with the other blind spots below rather
# than left to be read out of this sentence.
#
# The sibling plumbing commands come along with that, and the reason is worth
# stating so a maintainer who meets the red does not read it as a misfire. The
# matched text is now the bare `diff`, so every `diff-*` plumbing spelling is
# reached on one mechanism: the tail (`-index`, `-tree`, `-files`) is dash-led,
# so the walk continues past it into the real options and finds `--name-only`
# there. The set is stated by that shared property rather than enumerated,
# because an enumeration of it goes one command short the same way a list of
# option spellings does. The demand is CORRECT on all of them: each quotes a
# path exactly as `git diff` does. None is invoked in this tree today, so this
# is reach the widening brought rather than coverage anyone asked for, and it
# is left in place because narrowing the match to exclude them would trade a
# fail-closed demand that is right for a blind spot that is not.
#
# Sibling gate: .gaia/scripts/check-audit-base-derivation.sh's assertion 4 makes
# the same claim about the audit agents' prose. This file is deliberately not
# folded into it: that check's remit is the audit-base derivation, and its
# `consumes` predicate keys on the audit-base variable spellings and the
# resolver name, none of which any shell call site here mentions.

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
  printf 'lint-git-path-quoting: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-git-path-quoting: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-git-path-quoting: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENT" >&2
    exit 6
    ;;
esac

# Scan surface: tracked shell, the extensionless husky hooks, the workflow YAML
# whose `run:` blocks are shell by another name, tracked markdown, whose
# fenced blocks are shell by another name on any page a rule tells the agent to
# execute, and tracked `*.bats`, collected as its own set below. `git ls-files`
# rather than a filesystem walk, so an untracked scratch script or a vendored
# dependency is never scanned; the same discovery that .gaia/tests/shell-lint.sh
# uses. Collected with a read loop rather than `mapfile`, which is bash 4+,
# because these scripts run on stock macOS /bin/bash (3.2.57).
#
# `*.bats` is a SEPARATE set from the one below, never folded into one widened
# pathspec: a pathspec matching `*.sh` but no `*.bats` would still pass clean,
# which is the exact silent-unarming a widened-but-broken discovery would
# produce. On a `*.bats` line, `guard-awk-lib.sh`'s shared discriminator tells a
# fixture literal, written through a recognized helper, from executed shell a
# suite runs through `bash -c` or `eval`; see
# wiki/decisions/Shell Guard Fixture Discrimination.md for the convention and
# the reasoning behind the argument-region rule and the suppression pragma.
scan_files=()
while IFS= read -r -d '' f; do
  scan_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '*.sh' '.husky/*' '.github/workflows/*.yml' '.github/workflows/*.yaml' '*.md' | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is precisely the
# lie-green failure the gate itself exists to stop elsewhere. Every real tree
# carries tracked `*.sh`, so an empty result means the discovery is wrong rather
# than the tree. `.gaia/tests/shell-lint.sh` treats the identical condition as a
# hard error for its own discovery, and this is that reasoning applied here.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-git-path-quoting: ERROR: no tracked files matched the scan surface; nothing was scanned" >&2
  exit 1
fi

# The `*.bats` surface, discovered and hard-errored on separately by the shared
# library, for the same reason as above: a widened pathspec that quietly missed
# every suite would still pass this guard's own empty-set check.
gaia_guard_bats_files lint-git-path-quoting || exit 1

# scan_file <path>: print one `file:line: message` per unquoted call.
#
# Four discriminations, each earning its place on a real line in this
# repository rather than on symmetry:
#
#   invoked  -- the text immediately before the call is a `git` invocation,
#               optionally carrying -C/-c options. Without it,
#               check-audit-base-derivation.sh's GAIA_AUDIT_DIFF_CALL is a hit:
#               the call is that variable's VALUE, not a command.
#   in-fence -- markdown only, and the whole of what makes a documentation page
#               scannable without making it noisy: a line is a candidate when a
#               fence delimiter has opened and none has closed it. Every other
#               line on the page is prose and is never read.
#   in-span  -- an odd number of backticks before the call on the line means it
#               sits inside a markdown code span, so it is prose. Without it,
#               the audit workflow's agent prompt is a hit, where a code span
#               instructs a model to run the command. It is switched off inside
#               a fence, where a code span cannot nest and an odd count is a
#               legacy substitution instead.
#   in-option-region
#            -- all three halves accept `-z` as a standalone token anywhere in
#               the call's option region, and stop at the first token not
#               beginning with `-`, or at an explicit `--`. A fixed position
#               would be wrong for any of them: `ls-files` idiomatically carries
#               selectors first (`--others --exclude-standard -z`), `diff`
#               carries `--cached` or `--staged` before `--name-only`, and
#               `grep` carries its match selectors (`-I`, `-F`, `-E`) around the
#               listing flag. Terminating the walk is what keeps the guarantee a
#               fixed position was there to give: a pathspec cannot vouch for
#               the call, because the walk never reaches one. `diff` is on the
#               surface only when the walk finds `--name-only` in that region,
#               so a plain `git diff` and a `git diff --quiet` are never
#               candidates; `grep` likewise only when the walk finds a listing
#               flag, so a `git grep -n` and a `git grep -q` are never
#               candidates either.
#
# Full-line comments are skipped outright, which covers both a shell comment and
# a `#` line inside a workflow `run:` block.
#
# Known blind spots, stated rather than discovered later, and split by which
# WAY they fail, because that is the part that matters: they are not all
# fail-closed, and treating them alike hides the ones that are not.
#
# The backtick boundary is stated as a RULE rather than as a list of shapes,
# deliberately. An enumeration of shapes is always one shape short, and each
# round of extending it invites the next; the rule below is closed, so it cannot
# be incomplete:
#
#   The command-position test recognizes a backtick opening immediately after
#   `=` or `(`, and NOTHING ELSE. Every other position is treated as a markdown
#   code span.
#
# Both of that rule's error directions follow from it and neither is a separate
# discovery:
#   - FAIL-OPEN: a backtick command substitution opening after anything else --
#     a quote, a pipe, a separator, or bare command position -- is missed. That
#     is a real miss, and closing it needs a shell tokenizer, which is more
#     machinery than this gate is worth.
#   - FAIL-CLOSED: parenthetical prose whose parenthesis is followed by a
#     backtick is flagged as an invocation. The repair is to reword the prose.
#
# The other boundaries, both FALSE POSITIVES, so both fail CLOSED. They demand
# `-z`, which is never wrong on a call whose output is parsed, so each costs a
# correct edit and never a missed defect:
#   - `-z` written on a line continuation after the call reads as missing. This
#     is not a `*.bats` question and it does not change with the widened
#     surface.
#   - A single-quoted string containing a literal `git diff --name-only` reads
#     as an invocation on `*.sh`, husky, workflow YAML and markdown, where
#     nothing distinguishes a string constant from executed shell. On `*.bats`
#     the same text, written through a recognized fixture-writing idiom, is
#     read as data instead; see
#     wiki/decisions/Shell Guard Fixture Discrimination.md for the convention.
#
# `*.bats` residuals, now that the surface reaches it:
#   - A fixture written through a helper outside guard-awk-lib.sh's recognized
#     set is read as executed shell rather than data, so it reds until the set
#     is extended or the line carries a suppression pragma.
#   - The suppression pragma is itself a residual on every OTHER surface: a
#     `gaia-lint-ignore lint-git-path-quoting: ...` comment above a line on any
#     scanned surface but `*.bats` waives nothing there. This
#     guard is the designated reader for the pragma, and reports that shape as
#     honored nowhere outside `*.bats` rather than treating it as a fix.
#
# Two further FALSE NEGATIVES, unrelated to backticks:
#   - A call assembled through a variable (`$GIT diff --name-only`), which is
#     equally tokenizer-bound.
#   - `--name-only` written AFTER a positional revision (`git diff HEAD
#     --name-only`, `git diff "$base...HEAD" --name-only`). The walk terminates
#     at the revision, because a revision is exactly what a non-option token
#     looks like, so the option region never reaches the flag and the call is
#     classified off-surface. This is a fail-OPEN miss of the gate's own class,
#     and it is the price of the termination rule: the same stop is what keeps
#     a pathspec from vouching for a call that quotes. Distinguishing a revision
#     from a pathspec needs git's own argument parser, not a scanner. Every call
#     in this tree writes its options first, which is the idiom the fix hints
#     advertise, so nothing here is missed today. A listing flag written after
#     `git grep`'s positional PATTERN is the same miss on the same mechanism,
#     and it is the more likely of the two to be written, because a pattern is
#     an ordinary argument where a revision reads as one; the same sentence
#     applies unchanged, including that every call in this tree writes its
#     options first.
#   - A `git grep -n`, or a bare `git grep`, whose caller PARSES the path out of
#     the record it prints. The path is the record's first colon-delimited
#     field and git quotes it exactly as it quotes a listing call's, so such a
#     caller carries this class in full; a caller that only shows the record to
#     a human carries none of it. Nothing in the call text separates the two, so
#     arming on `-n` would red every match-line call in this tree to reach the
#     few that parse, which is how a gate gets bypassed rather than fixed. This
#     is therefore a deliberate fail-OPEN miss rather than an oversight, and it
#     is the one blind spot here with a known live instance:
#     `.gaia/scripts/check-main-root-derivation.sh` reads a `-n` record and
#     opens the path it extracts. That call site carries `-c core.quotepath=false`
#     as its own local repair, which closes the NON-ASCII arm of the quoting and
#     nothing else: that flag only stops bytes above 0x80 counting as unusual, so
#     a tracked name carrying a double quote or a backslash is still C-quoted
#     with it set, and a name carrying a colon defeats a `first-field` split
#     whatever the quoting does. `-z` is the only complete remedy for a parse
#     site, and it is unavailable to a `-n` caller without rewriting the split,
#     since `-z` changes the record's own delimiter. The flag is the right repair
#     THERE because the non-ASCII arm is the one with a live case in this tree;
#     it is not a general close of the shape, and a second parse site is not
#     made safe by copying one flag onto it.
#
# One FALSE POSITIVE the `grep` half adds, fail-CLOSED and stated with the
# others above rather than left to be discovered:
#   - `-z` written after `git grep`'s positional pattern (`git grep -l "$pat"
#     -z`) reads as missing, because the walk has already terminated at the
#     pattern. The repair is to move the flag into the option region, which is
#     where the fix hint puts it.
#
# Out of scope entirely: `-z` does not, on its own, survive a path containing a
# literal newline when the consumer re-splits on newlines via `tr`. That is a
# separate and far rarer class than the one this gate closes, and nothing here
# asserts otherwise.
# The class-detection program, concatenated after $GAIA_GUARD_AWK so it can call
# the shared fixture-versus-execution discriminator. Hoisted into a variable,
# unchanged character for character from its former inline form, because
# concatenation requires a variable rather than a literal awk argument.
# Single-quoted so every `$`, `$(` and awk field reference reaches awk as literal
# program text; the disable is targeted rather than file-wide, matching the two
# below it, so a genuine SC2016 anywhere else here still fires.
# shellcheck disable=SC2016
readonly OWN_AWK='
    # option_walk(window): walk the option region following a call, setting
    # has_z when a standalone -z appears in it, has_name_only when --name-only
    # does, existence_only when --error-unmatch does, and has_list when one of
    # the five spellings that make `git grep` print a path as the whole record
    # does; the header states why -n is not among them. All four are
    # deliberately global: awk has no other way to return a tuple. The walk
    # stops at the first token that is not an option, which is exactly where a
    # pathspec would begin, so a pathspec can never vouch for the call. It is
    # also where the positional PATTERN of a `git grep` begins, which is why
    # the fix hint for that verb puts -z ahead of the pattern. No apostrophe
    # anywhere in this block: it sits in a single-quoted string.
    function option_walk(window,   n, i, tok, arr) {
      has_z = 0
      has_name_only = 0
      existence_only = 0
      has_list = 0
      n = split(window, arr, "[ \t]+")
      for (i = 1; i <= n; i++) {
        tok = arr[i]
        # Leading whitespace in the window yields an empty first field; it is
        # not a token, and skipping it must not terminate the walk.
        if (tok == "") continue
        # Trailing shell punctuation is not part of the option. A substitution
        # that closes against its last option -- `$(git diff --cached
        # --name-only)`, `"$(git ls-files -z)"` -- yields `--name-only)` and
        # `-z)"`, which match no option the walk looks for and are not pathspecs
        # either, so without this the first is missed and the second is a false
        # positive on a compliant call. The double quote is in the class
        # BECAUSE the assigned-and-quoted form `x="$(...)"` is the common one,
        # and stripping every character except that one leaves the walk blind
        # to precisely the spelling most calls are written in. It cannot make a
        # quoted pathspec vouch for a call: `"-z"` still begins with a quote
        # after the strip, so it terminates the walk as a non-option. A literal
        # single quote is absent from the class because this awk program sits
        # inside a single-quoted shell string, and it is not needed: a command
        # substitution cannot close against one.
        sub(/[")`;|&]+$/, "", tok)
        if (tok == "--") break
        if (substr(tok, 1, 1) != "-") break
        if (tok == "-z") has_z = 1
        if (tok == "--name-only") has_name_only = 1
        if (tok == "--error-unmatch") existence_only = 1
        # The listing half of `git grep`. The short spellings are read inside a
        # cluster, because `-lIF` is how every real call in this tree writes
        # them; the leading `[^-]*` cannot cross a second dash, so a long option
        # never arms this arm by accident and the three long spellings are
        # matched in full below. -z stays standalone-only, one arm above: the
        # asymmetry is stated in the header, and it keeps the approximation a
        # cluster read makes on the fail-CLOSED side.
        if (tok ~ /^-[^-]*[lL]/) has_list = 1
        if (tok == "--files-with-matches" || tok == "--name-only") has_list = 1
        if (tok == "--files-without-match") has_list = 1
      }
    }
    BEGIN {
      gaia_scan_reset()
      # callname is what is matched in the text; calllabel is what the report
      # names. They differ for `diff` because the surface is the call PLUS the
      # --name-only the walk finds in its option region, and only the walk can
      # see that: the text between the two is an open set of selectors.
      # They differ for `grep` for the same reason and in the same way: the
      # surface is the call PLUS a listing flag the walk finds, and `-l` is the
      # spelling every call in this tree uses, so it is what the report names.
      ncalls = 3
      callname[1] = "diff";     calllabel[1] = "diff --name-only"
      callname[2] = "ls-files"; calllabel[2] = "ls-files"
      callname[3] = "grep";     calllabel[3] = "grep -l"
    }
    # Pass 1 of a two-pass `*.bats` invocation accumulates the prepass sets a
    # fixture constant bound far above its consuming helper call needs; every
    # other surface is single-pass, so this rule never matches there.
    is_bats && NR == FNR { gaia_scan_prepass($0); next }
    # Ahead of every next below, so the pragma reader sees the full-line
    # comments the fence and comment-skip rules discard.
    { gaia_scan_feed($0, is_bats) }
    # UAT-009s off-surface arm: a pragma naming this guard waives nothing
    # outside `*.bats`, so it is reported here regardless of whether its target
    # line also carries an instance, which the detector below may still print.
    !is_bats && gaia_scan_pragma_here("lint-git-path-quoting") {
      printf "%s:%d: gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here\n", file, FNR
    }
    # A fence delimiter changes the state and is never itself scanned; the
    # opening line carries the info string (```bash), which is not a call.
    #
    # A bare toggle is wrong in two ways that both fail OPEN, and both land on
    # the executed-instruction pages this half exists for. It closes on the
    # opener of a NESTED block, so a ```bash inside a ````markdown wrapper
    # reads as prose from there to the outer close, and the page still balances
    # so no parity check can see it. And it never opens on a fence carrying a
    # blockquote prefix, which is how a page quotes a prompt an agent is told to
    # run verbatim. So the delimiter is remembered rather than counted: a closer
    # must be the same character and at least as long as the opener that is
    # open, the rule CommonMark itself uses, and the leading run may carry `>`.
    # No apostrophe anywhere in this block: it sits in a single-quoted string.
    is_md {
      if (match($0, /^[[:space:]>]*(```+|~~~+)/)) {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]>]*/, "", delim)
        dchar = substr(delim, 1, 1)
        dlen = length(delim)
        # A closer carries no info string, which CommonMark requires and which
        # is the only thing separating a close from a nested open of the SAME
        # run length: inside a ```markdown block, a ```bash line is content.
        # Without this the scanner leaves the fence there and reads the nested
        # body as prose, and that page renders as one well-formed block, so
        # unlike an unbalanced page it never announces itself to its reader.
        tail = substr($0, RSTART + RLENGTH)
        if (!infence) { infence = 1; fencechar = dchar; fencelen = dlen }
        else if (dchar == fencechar && dlen >= fencelen && tail ~ /^[[:space:]]*$/) { infence = 0 }
        next
      }
    }
    # Outside a fence, markdown is prose in full: a paragraph naming a
    # path-listing command is documentation, not a call site, whether or not its
    # author wrapped it in a code span.
    is_md && !infence { next }
    /^[[:space:]]*#/ { next }
    {
      for (c = 1; c <= ncalls; c++) {
      call = callname[c]
      label = calllabel[c]
      calllen = length(call)
      consumed = 0
      rest = $0
      while ((pos = index(rest, call)) > 0) {
        abs = consumed + pos
        prefix = substr($0, 1, abs - 1)
        window = substr($0, abs + calllen)

        # Any leading git global option, not just -c/-C: `git --no-pager diff
        # --name-only` is as much an invocation as `git -C "$root" diff`, and a
        # selector naming two options by hand misses the rest of an open set.
        # An option token is anything starting with `-`; the optional following
        # token is the value form -c/-C take.
        invoked = (prefix ~ /(^|[^[:alnum:]_.-])git( +-[^ ]+( +[^- ][^ ]*)?)* +$/)

        ticks = gsub(/`/, "`", prefix)
        # Inside a fenced block the in-span test is not merely unnecessary, it is
        # wrong: a markdown code span cannot nest inside a fence, so an odd
        # backtick count there is a legacy command substitution or a literal
        # backtick in shell, never prose. Leaving the test on would hand every
        # fenced snippet a fail-open escape the shell surface does not have.
        inspan = (!infence && ticks % 2 == 1)
        # An odd backtick count alone cannot tell a markdown code span from a
        # LEGACY COMMAND SUBSTITUTION -- the two are textually identical, and
        # reading `changed=`git diff --name-only "$B"`` as prose is a fail-OPEN
        # miss rather than the fail-closed kind this scan is happy to make. A
        # backtick opening immediately after `=` or `(` is in command position,
        # so it is substitution rather than prose. Those two characters are the
        # whole rule, in both directions: every other opening position is missed
        # (fail-open) and parenthetical prose is flagged (fail-closed). The
        # blind-spot block above states that as a rule rather than enumerating
        # the shapes it produces.
        if (prefix ~ /[=(]`/) inspan = 0

        option_walk(window)
        if (call == "ls-files")
          quoted_ok = (has_z || existence_only)
        else if (call == "grep")
          # A `grep` with no listing flag in its option region prints match
          # lines rather than paths, so it is off the surface entirely rather
          # than a passing hit -- the same shape the `diff` arm below takes.
          quoted_ok = (!has_list || has_z)
        else
          # A `diff` with no --name-only in its option region is off the surface
          # entirely rather than a passing hit, so it can never be reported.
          quoted_ok = (!has_name_only || has_z)

        if (invoked && !inspan && !quoted_ok) {
          # In this order: a fixture-region line is data (skip), an honored
          # pragma is a deliberate waiver (suppressed), both inert when is_bats
          # is 0. The message deliberately does NOT put `git` in front of the
          # call name: with the binary name there, this very line matches the
          # detector and the gate flags its own diagnostic. Caught by running
          # the gate over its own tree, which is the cheapest possible proof
          # that the "invoked" discrimination works.
          if (!(is_bats && (gaia_scan_skip() || gaia_scan_suppressed("lint-git-path-quoting"))))
            printf "%s:%d: %s without -z: a C-quoted non-ASCII path stops matching in the consumer\n", file, FNR, label
        }
        consumed = abs + calllen - 1
        rest = substr($0, consumed + 1)
      }
      }
    }
    END { gaia_scan_end(file, is_bats, "lint-git-path-quoting", 1, 1) }
'

# scan_file <path>: print one `file:line: message` per unquoted call, on every
# non-bats surface. Single pass; is_bats=0 makes every gaia_scan_* accessor the
# library defines inert except the pragma reporter above.
scan_file() {
  local f="$1"
  # Fence gating applies to markdown alone. On every other file type is_md stays
  # 0, so infence never leaves 0 and both rules below are inert -- the shell and
  # YAML halves scan exactly the lines they always did.
  local is_md=0
  case "$f" in *.md) is_md=1 ;; esac
  "$GAIA_AWK" -v file="$f" -v is_md="$is_md" -v is_bats=0 -v scripts_dir="$_gaia_guard_lib_dir" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$f"
}

# scan_bats_file <path>: two-pass invocation over a tracked `*.bats` suite, the
# file named twice so the prepass sees a fixture constant bound above the
# helper call that consumes it. is_md is always 0: a bats file has no markdown
# fence state to track.
scan_bats_file() {
  local f="$1"
  "$GAIA_AWK" -v file="$f" -v is_md=0 -v is_bats=1 -v scripts_dir="$_gaia_guard_lib_dir" \
      "$GAIA_GUARD_AWK$OWN_AWK" "$f" "$f"
}

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f")
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for f in ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_bats_file "$f")
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
  # ONE awk pass, not a filtering grep feeding a quiet one. A quiet grep exits
  # at its first match and closes the pipe; the upstream grep then takes SIGPIPE
  # and returns 141, and `pipefail` promotes that to the pipeline's status, so
  # the test would answer FALSE on a report that does carry a class hit. A
  # single process cannot lose that race, and
  # .gaia/scripts/lint-sigpipe-readers.sh is the gate that keeps the shape out.
  if "$GAIA_AWK" '
      /gaia-lint-ignore/ { next }
      /: ERROR: /        { next }
      /[^[:space:]]/     { found = 1 }
      END { exit(found ? 0 : 1) }
    ' <<<"$report"; then
    # printf, not echo: the hint text carries backslash escapes (`tr` operands),
    # and echo may expand them depending on the shell (SC2028). The format string
    # is single-quoted so the `$(...)` and `${base}` inside it stay literal -- it
    # is sample code being printed, not code being run. Disabled on this line
    # rather than file-wide, so a genuine SC2016 anywhere else here still fires.
    # shellcheck disable=SC2016
    printf 'Fix a diff hit: changed="$(git diff --name-only -z "${base}...HEAD" | tr %s\\0%s %s\\n%s)"\n' "'" "'" "'" "'" >&2
    # The ls-files repair reads the NUL stream directly rather than translating it
    # back to newlines, so it needs no `tr` and survives a path containing one.
    # shellcheck disable=SC2016
    printf 'Fix an ls-files hit: while IFS= read -r -d %s%s f; do ...; done < <(git ls-files -z <pathspecs>)\n' "'" "'" >&2
    # The grep repair reads the same NUL stream, with -z placed AHEAD of the
    # positional pattern: the option walk terminates at the pattern, so a flag
    # written after it reads as missing. Hinting the wrong order would send the
    # operator around the loop a second time on a call they had already fixed.
    # shellcheck disable=SC2016
    printf 'Fix a grep -l hit: while IFS= read -r -d %s%s f; do ...; done < <(git grep -lIF -z <pattern> -- <pathspecs>)\n' "'" "'" >&2
  fi
  exit 1
fi

echo "lint-git-path-quoting: clean" >&2
exit 0
