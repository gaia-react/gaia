#!/usr/bin/env bash
# SC2016 is intentional file-wide: every awk program below is single-quoted
# precisely so every `$` and awk field reference reaches awk as literal program
# text rather than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-sigpipe-readers.sh: flag a short-circuiting reader -- `grep` or `rg` told
# to stop early, whether by a `-q`-bearing flag cluster, `--quiet`, `--silent`,
# or a match count (`-m`, `--max-count`) -- standing downstream of a `|` where
# `pipefail` is armed: in a tracked shell script, and in an Actions `run:` body,
# which is shell by another name. Run it directly from the repo root:
# `bash .gaia/scripts/lint-sigpipe-readers.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. Three statuses say the gate never produced
# a verdict at all: 2 when it could not start (guard-awk-lib.sh missing beside
# this script, or no scratch directory), 3 when the scan-surface discovery
# failed, and 4 when a workflow carries a `defaults:` key, the one construct the
# shell oracle below refuses to resolve rather than answer wrongly about.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-sigpipe-readers.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh. Its arming
# takes MORE than that gate's `**/*.sh` paths-filter entry, which reaches only
# half of what this gate reads: the workflow, composite-action and adopter
# template entries beside it are what arm the other half, and each names this
# guard. A pull request touching only a workflow that skipped this gate would
# green it having read the very file it changed zero times. Also runnable
# directly: `bats .gaia/scripts/tests/lint-sigpipe-readers.bats`.
# gaia:maintainer-only:end
#
# Why: a short-circuiting reader INVERTS the truth value of the pipeline it
# terminates. `grep -q` exits at its first match and closes the read end of the
# pipe. When the upstream has written more than the pipe buffer (~64KB) and the
# match lands early, the upstream takes SIGPIPE and exits 141; `set -o pipefail`
# promotes that to the pipeline's status, so an `if` or an `&&` reading it takes
# the FALSE branch BECAUSE a match was found. Nothing surfaces it: the pipeline
# is well-formed, both commands did what they were asked, and the wrong branch
# looks exactly like the right one.
#
# Whether a given upstream can outrun the buffer is a data-flow property no
# static check can decide, so this gate does not try. It flags the SHAPE, with
# no discrimination, and that is affordable because the remedy is unconditional
# and free: each repair removes the pipeline outright rather than making the
# race safer, so the class cannot recur on the repaired line. A printf or echo
# feeding the reader becomes a here-string; a command feeding it is captured
# into a variable first; a filter feeding it folds into a single awk pass.
#
# That is the same trade .gaia/scripts/lint-hook-array-guard.sh already makes
# for a class it likewise cannot fully discriminate: a flagged site the author
# believes is genuinely safe takes the fix anyway, so the gate stays
# zero-exception rather than carrying an inline suppression. There is
# deliberately NO pragma.
#
# One trap in the repair itself, because `<<<` appends a newline. That is
# byte-identical to a `printf` of the same value with a trailing newline and
# harmless for an ordinary pattern, but an INVERTED reader (`grep -qv`) reads
# the extra trailing blank line as a non-matching line and then succeeds
# unconditionally. Trim the newline off the value, or fold the whole pipeline
# into one awk pass.
#
# Provenance: four known occurrences before this gate existed, three of them in
# guard machinery, where the failure mode is a guard reporting clean over a live
# defect. gaia-react/gaia#745 (`audit-success-present.sh`, fixed by
# gaia-react/gaia#748), gaia-react/gaia#757 and gaia-react/gaia#761 (two shapes
# in `audit-noop-detect.sh`), and the first draft of
# .gaia/scripts/lint-hook-advisory-classification.sh, which classified with a
# filtering grep feeding a quiet one and reported clean over the very defect it
# was written for, on its first run against the live tree. Each of the first
# three was patched in place with no gate left behind, which is why the fourth
# had nothing to catch it. gaia-react/gaia#1810 is the issue that replaced the
# patches with this tree-wide gate.
#
# Nothing else in the tree reaches the class. shellcheck at the `*.sh` severity
# floor .gaia/tests/shell-lint.sh sets returns exit 0 on a fixture carrying both
# shapes, and the `code-audit-maintainer-shell` agent has caught it once but is
# model-dispatched and advisory, so nothing enforced it.
#
# ---------------------------------------------------------------------------
# WHICH FILES RUN UNDER PIPEFAIL, which is a closure and not a per-file test
# ---------------------------------------------------------------------------
#
# `pipefail` is a shell OPTION, not a file attribute: it belongs to the process,
# and a sourced library therefore runs under whatever its caller armed. A gate
# that asked only whether the scanned file carries its own `set -o pipefail`
# would report every library clean, and `.claude/hooks/lib/` is exactly where
# three of the four historical occurrences above lived. That is an arming-stage
# hole in the sense .claude/rules/guards-must-fail.md names: correct wherever it
# runs, and never run on the surface that most needs it.
#
# So a file counts as running under pipefail when it arms pipefail itself, OR
# when it is reachable by `source` from a file that does. The seeds are the
# self-arming files; the edges are the `.`/`source` loads; the closure is
# transitive, because a library sourced by a library sourced by an armed entry
# point runs armed too.
#
# "Arms pipefail itself" means at command-substitution depth ZERO, the same test
# the workflow arm applies to a `run:` body and for the same reason: a
# `changed=$(set -o pipefail; ...)` arms its own subshell and nothing outside
# it, so a file whose only arming is that idiom is not a seed. The two arms
# share one arming test rather than two that agree by inspection
# (`arms_at_depth_zero` below); gaia-react/gaia#1941 is the round where the
# script arm got it. What that costs is stated with the depth test itself.
#
# An edge resolves by BASENAME against the tracked set, because a load names its
# target through a variable far more often than not
# (`. "$lib_dir/guard-awk-lib.sh"`), and no static reader can resolve that
# variable. Two consequences, both stated rather than hidden. A basename shared
# by two tracked files draws an edge to both, so one armed caller can mark a
# same-named file it never loads: that direction costs a correct edit and never
# a missed defect, which is the direction a guard may be wrong in. And a load
# whose target is built entirely from variables, with no literal `*.sh` token on
# the line, draws no edge at all; a file reachable only that way is not covered.
#
# ---------------------------------------------------------------------------
# Scan surface
# ---------------------------------------------------------------------------
#
# Two sets the shared library defines, read as two arms because they decide
# arming differently: tracked `*.sh` (`shell`), and the Actions workflows,
# composite actions and adopter workflow templates (`workflows`). Two surfaces
# are deliberately outside both:
#
#   *.bats            bats-core arms no pipefail by DEFAULT, so an ordinary
#                     suite does not run the class. A suite that arms pipefail
#                     itself does, and that is out of scope by choice rather
#                     than by impossibility: the suites doing it today arm it
#                     inside a command substitution or a `bash -c` fixture,
#                     where the shape is the fixture rather than the suite.
#   the husky hooks   `.husky/_/h` runs each one as `sh -e`, which arms no
#                     pipefail either.
#
# What this gate does NOT try to decide: whether the pipeline's status is read
# as a truth value at all. A status nobody reads makes the shape harmless rather
# than absent, and separating the two needs the surrounding control flow. The
# remedy costs the same either way, so the shape is reported wherever it stands.
#
# ---------------------------------------------------------------------------
# THE WORKFLOW ARM, whose arming is a shell oracle rather than a text test
# ---------------------------------------------------------------------------
#
# A `run:` body is shell by another name, and it carries this class exactly as a
# script does. What it does NOT carry is the script arm's arming signal: a body
# inherits pipefail from the step's RESOLVED SHELL rather than from any text in
# it. GitHub's default `run:` shell is `bash -e`, which arms no pipefail; an
# explicit `shell: bash` resolves to `bash --noprofile --norc -eo pipefail`,
# which does. So the body-text test alone would grade every block by whether its
# author happened to write a redundant `set -o pipefail`.
#
# A block is therefore armed when EITHER holds, and the two are independent:
#
#   the resolved shell   the step's own `shell:` value is `bash`, or is a custom
#                        invocation naming `pipefail`. Anything else, including
#                        the absent case that covers every workflow-file step in
#                        this tree, is the bare `bash -e` default and arms
#                        nothing. `shell:` is read at the STEP's own key column,
#                        so the `shell:` that names a dorny/paths-filter filter
#                        inside a `filters: |` block scalar is not mistaken for
#                        one (.github/workflows/shell-lint.yml has two).
#   the body text        the block's own `set -o pipefail`, in the spellings the
#                        script arm already reads. A body that arms pipefail is
#                        armed whatever its shell resolves to.
#
# The substitution-scoped form `changed=$(set -o pipefail; ...)` must NOT arm
# the block around it, and the distinction is not academic: it is the shape this
# tree writes, and reading it as block-level arming would report every one of
# those blocks. So the body-text test fires only at command-substitution depth
# zero, tracked by counting `$(` against `)` across the block and clamped at
# zero. A miscount can go either way, and the two ways are not equally safe. A
# stray `)` (a `case` pattern, an arithmetic `))`) pushes the depth DOWN, which
# reads a substitution-scoped `set` as block-level and reports a block that was
# not armed: that direction costs a correct edit, and the clamp keeps it from
# going below zero. A `$(` that is data rather than code pushes the depth UP,
# which reads a real arming as scoped and reports nothing: that is the missed
# defect this gate exists to prevent, and the carry below is built against it.
#
# The depth a line hands the next one is the LOWER of two counts over that
# line, both walked from the same carried-in depth: the raw line, and a copy
# with each single-quoted span removed, from one quote to the next, where an
# unterminated quote stays with everything after it. Single quotes are the
# tractable case because shell allows no escape inside them, so a literal `$(`
# in a single-quoted `grep -F` pattern drops out while a live `$(` inside double
# quotes stays. The stripped count alone is not safe: a strip cannot tell a
# quote that opens a span from an apostrophe inside a double-quoted string, so
# `x=$(echo "it's"); y='z'` strips to an unbalanced `$(` on a line whose raw
# count is balanced, and a stripped-only carry would read the next arming as
# scoped. The minimum cannot rise above the raw count: the depth walk is
# monotone in the depth it starts from, so from zero, by induction, every line
# ends at or below where the raw count would end it, and the strip can remove a
# false negative but never add one. The arming test itself reads the raw line.
#
# The script arm applies the same depth test to a FILE, and TWO shapes reach a
# false negative through it, the direction this gate must not be wrong in, so
# neither is left implied by the other.
#
# The first is a multi-line
#
#     out="$(
#       set -o pipefail
#       ...one pipeline into a quiet reader...
#     )"
#
# in a tracked script. It genuinely runs armed inside that subshell, and the
# depth test reads it as arming nothing, so the reader inside goes unreported.
# Before the depth test the script arm caught it by ACCIDENT, by over-arming the
# whole file on any arming it saw anywhere. This arm invents nothing here: the
# identical shape in a `run:` body already reads clean, so what changed is that
# the two arms now agree about it.
#
# The second is a literal `$(` that is DATA rather than code, sitting unbalanced
# on an earlier non-comment line: a `grep -F` pattern, a `printf` template. It
# holds the carry above zero until some later line spends a `)`, so a genuine
# file-level `set -euo pipefail` in between reads as scoped and every reader in
# the file goes unreported. It stands on both arms alike, since both carry
# through the one function. The single-quoted form is closed by the minimum
# above and pinned by a fixture on each arm. What the strip does not reach stays
# open on both: a literal `$(` in a trailing `#` comment (only a full-line
# comment is skipped), in a heredoc body (a body is scanned as code, whatever
# its delimiter's quoting), or escaped as `\$(` inside double quotes (a
# backslash is not read), and an unbalanced quoted `$(` on the SAME line as the
# arming, `grep -nF 'x=$(' f; set -euo pipefail`, because the arming test reads
# the raw line. Each needs a shell tokenizer rather than a character count.
#
# Neither shape changes what this tree reports, and the honest form of that is
# a differential rather than an absence. Run the gate with the cross-line carry
# disabled outright and the armed set and the report come back byte-identical,
# so nothing in this tree has an arming status that turns on the carry. That is
# the claim; it is cheap to re-check and it is the one that matters.
#
# Lines that end at a positive carry are common, and they are not this defect:
# nearly all are genuine multi-line substitutions, which the carry is right to
# scope, and every one is spent by a later `)`, so no tracked file reaches end
# of file still carrying depth. A repair that drove the carry to zero
# everywhere would stop scoping those to correct a handful of literals, which
# is why the strip only ever lowers the carry, and why a fixture pins the script
# arm's cross-line carry directly.
#
# The balanced case, a whole `$( ... )` inside one quoted argument, returns to
# zero on its own line under either count and is pinned by a fixture.
#
# `defaults.run.shell`, at job or workflow level, would move the resolved shell
# for every step under it. This gate REFUSES rather than resolves it: a
# BLOCK-STYLE `defaults:` key anywhere in the scanned YAML exits 4 naming
# gaia-react/gaia#1814. Block-style is the honest qualifier rather than a
# hedge, because it is exactly what the reader below sees: it takes one leading
# mapping key per line, so a flow-style `jobs: {j: {defaults: ...}}` reads as
# the key `jobs` and its nested `defaults:` is never seen. No flow-style
# workflow YAML exists here, and the same one-key-per-line reading is what every
# other structural answer this arm gives is built on. There are zero in this tree, so the refusal costs
# nothing today, and it converts an unimplemented precedence chain into a loud
# stop rather than a silent wrong answer. That is this tree's own idiom, the
# same shape gaia-react/gaia#1880's `--show-prefix` refusal takes ahead of
# discovery. Implementing the chain is a change for the day a `defaults:` key
# first appears, and this diagnostic is what will name it.
#
# BOTH `run:` spellings are scanned. A block scalar is graded when the block
# ends; an inline value is a single command, so it is its own one-line block and
# is graded on the spot. Grading only the block form would leave the inline one
# unscanned at every arming, and a composite step is precisely where that
# matters: the Actions schema makes `shell:` mandatory there, so a `shell: bash`
# arms an inline reader exactly as it arms a block one.
#
# Known blind spots on this surface, stated rather than discovered later, and
# both of them FALSE NEGATIVES. A `run:` whose value is a multi-line plain or
# quoted flow scalar has only its first line read, the rest being scanned as
# though they were not part of the value. A mustache partial include inside a
# body ends the scan there. Both mirror
# .gaia/scripts/lint-workflow-run-interpolation.sh, which states its own version
# of each and scans the same two arms, and neither shape appears in this tree.
#
# Bash 3.2 compatible. Never `cd`.

set -euo pipefail

readonly PROG="lint-sigpipe-readers"

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, the shape
# .gaia/scripts/lint-errexit-source-guard.sh demands for an unbracketed load in
# an errexit-reachable file.
_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf '%s: guard-awk-lib.sh is missing beside this script\n' "$PROG" >&2
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
# Each set is copied out of the library's one global before the next call
# overwrites it, because the two arms below ARM differently: the scripts by
# their own text and their source closure, the YAML by its steps' resolved
# shells. A single union call would hand both to one arm and, worse, would let a
# non-empty `shell` set carry an empty `workflows` set past the emptiness check,
# which is the fail-open discovery `.claude/rules/guards-must-fail.md` names.
gaia_guard_scan_files "$PROG" shell || exit $?
sh_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

gaia_guard_scan_files "$PROG" workflows || exit $?
yaml_files=(${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"})

# The class detector both arms share: what makes a reader short-circuiting,
# which segment of a pipeline it heads, what arms pipefail, and where a
# pipeline carries to the next line. Concatenated ahead of one of the two mains
# below rather than duplicated into each, so the two arms cannot drift on what
# the class IS while disagreeing only about which files carry it. The sibling
# .gaia/scripts/lint-errexit-status-read.sh joins its shared detector to a
# per-surface program the same way.
#
# Single-quoted, so every literal single quote inside is spelled \047 and no
# comment in it may carry an apostrophe.
readonly READER_AWK='
# A token that turns a reader into a short-circuiting one. TWO families, and
# both belong here because the class is the short circuit rather than the flag:
#
#   the quiet family  -q and every cluster carrying it (-qF, -qxF, -qvF, -nq),
#                     plus --quiet and --silent. The cluster form is what makes
#                     a plain substring test wrong.
#   the count family  -m and --max-count. A reader told to stop after N matches
#                     closes the pipe at the Nth exactly as a quiet one closes
#                     it at the first, so the upstream takes SIGPIPE and the
#                     pipeline status inverts identically. The count rides
#                     either inside the token (-m1, -nm1) or as the next
#                     argument (-m 1), and both spellings are the same defect.
function is_qflag(t) {
  if (t == "--quiet" || t == "--silent" || t == "--max-count") return 1
  if (t ~ /^--max-count=/) return 1
  if (t ~ /^-[A-Za-z]+$/ && t ~ /q/) return 1
  if (t ~ /^-[A-Za-z]*m[0-9]*$/) return 1
  return 0
}

# Read one pipeline SEGMENT and answer with the reader heading it, or the empty
# string. The command word is the segment head, so a -q sitting in the quoted
# argument of some other command is never read as a flag of a reader.
function segment_reader(s,   toks, m, j, t, w) {
  sub(/;.*$/, "", s)
  m = split(s, toks, /[[:space:]]+/)
  j = 1
  # Everything a reader can hide behind and still be the command that runs.
  # The assignment arm is the one that matters most in this tree: a locale or
  # encoding prefix is the ordinary spelling here, and without it the command
  # word reads as LC_ALL=C and the segment is graded as some other command. The
  # brace and paren arms cover a downstream compound command, where the wrapper
  # rather than the reader occupies the head: a pipeline into a brace group or
  # a subshell carries the class exactly as the bare form does.
  while (j <= m && (toks[j] == "" || toks[j] == "!" || toks[j] == "&" ||
                    toks[j] == "{" || toks[j] == "(" ||
                    toks[j] == "command" || toks[j] == "env" ||
                    toks[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) j++
  if (j > m) return ""
  w = toks[j]
  # A subshell may open with no space after the paren, so the wrapper arrives
  # fused to the command word rather than as a token of its own.
  sub(/^\(+/, "", w)
  sub(/^.*\//, "", w)
  if (w != "grep" && w != "rg") return ""
  for (t = j + 1; t <= m; t++)
    if (is_qflag(toks[t])) return w " " toks[t]
  return ""
}

# The `set` spellings that arm pipefail, as ONE string every reader shares: the
# arming test below that answers WHETHER a line arms it, and the locator inside
# that test that answers WHERE, so it can ask whether the occurrence sits inside
# a command substitution. Two copies with different trailing boundaries would
# let the predicate match one occurrence while the locator found an earlier one,
# and the depth test would then answer about a position the predicate never
# accepted, reading an armed block as unarmed. That is a false negative, the one
# direction this gate must not be wrong in, which is why the pattern is bound
# once rather than written twice.
#
# The option run before the -o that carries pipefail is optional and unbounded,
# and it admits both spellings a set line uses: a short flag cluster, and a
# long-form -o followed by its option NAME. So set -o pipefail, set -euo
# pipefail, set -e -o pipefail and set -o errexit -o pipefail all arm it. The
# bare option name is admitted only directly after a flag token, never on its
# own: set stops parsing options at its first non-option word, so
# set a b -o pipefail arms nothing and must not read as if it did.
#
# The trailing boundary admits a SEMICOLON alongside whitespace and end-of-line,
# so the one-line set -euo pipefail; cmd spelling arms what it really arms. What
# holds the substitution-scoped changed=$(set -o pipefail; ...) idiom back from
# arming the file or block around it is the depth test in arms_at_depth_zero
# below, and nothing else. A boundary narrow enough to exclude that idiom is
# narrow enough to miss the one-line spelling too: it excludes by accident what
# the depth test excludes on purpose, and a reader who repairs the accident
# without the depth test already in place reopens the very gap the depth test
# closes. That is the trade gaia-react/gaia#1941 records.
BEGIN {
  PIPEFAIL_RE = "(^|[^A-Za-z0-9_])set([[:space:]]+-[A-Za-z]+([[:space:]]+[A-Za-z]+)?)*[[:space:]]+-[A-Za-z]*o[[:space:]]+pipefail([[:space:]]|;|$)"
}

# Split one line into pipeline segments and fill hitbuf with the reader heading
# each downstream one, answering how many there were. A doubled bar is a logical
# OR, not a pipe: masking it before the split is what keeps the command after
# one from reading as a downstream segment. Segment 1 is downstream only when
# the PREVIOUS line left a pipeline open, which the caller carries in prev_pipe.
function scan_pipeline(l,   work, k, seg, i, hit) {
  hitn = 0
  work = l
  gsub(/\|\|/, "\002", work)
  k = split(work, seg, "|")
  for (i = 1; i <= k; i++) {
    if (i == 1 && !prev_pipe) continue
    hit = segment_reader(seg[i])
    if (hit != "") { hitn++; hitbuf[hitn] = hit }
  }
  return hitn
}

# Whether this line leaves a pipeline open for the next one. A trailing
# backslash after the bar is redundant in bash but legal, so it is stripped
# before the test.
function carries_pipe(l,   tail) {
  tail = l
  sub(/[[:space:]]+$/, "", tail)
  sub(/\\$/, "", tail)
  sub(/[[:space:]]+$/, "", tail)
  return (tail ~ /\|$/ && tail !~ /\|\|$/)
}

# The command-substitution nesting depth at character `upto` of `s`, starting
# from the carried-in `subdepth` and clamped at zero. Clamped, not merely
# bounded: the header states why that direction is the safe one. Both arms carry
# `subdepth` from one line to the next through carry_at below, and each resets
# it where its own unit of arming begins: the workflow arm at every run: key,
# the shell arm never, since that arm is handed one file per awk invocation and
# the file IS the unit.
function depth_at(s, upto,   i, d, c) {
  d = subdepth
  for (i = 1; i < upto; i++) {
    c = substr(s, i, 1)
    if (c == "$" && substr(s, i + 1, 1) == "(") { d++; i++ }
    else if (c == ")" && d > 0) d--
  }
  return d
}

# The line with every single-quoted span removed, a quote through the next
# quote. An unterminated quote stays, with everything after it, so that tail
# counts as raw. Double-quoted text is left alone, since a `$( )` inside double
# quotes is live.
function strip_squoted(s,   out, q, rest, e) {
  out = ""
  while ((q = index(s, "\047")) > 0) {
    rest = substr(s, q + 1)
    e = index(rest, "\047")
    if (e == 0) break
    out = out substr(s, 1, q - 1)
    s = substr(rest, e + 1)
  }
  return out s
}

# The depth this line hands the next one: the LOWER of the raw count and the
# count over the stripped copy, both walked from the same carried-in depth. The
# stripped count alone can rise above the raw one; the header states why only
# the lower of the two keeps the carry from disarming anything the raw count
# arms.
function carry_at(l,   raw, t, cut) {
  raw = depth_at(l, length(l) + 1)
  t = strip_squoted(l)
  cut = depth_at(t, length(t) + 1)
  return (cut < raw) ? cut : raw
}

# Whether this line arms pipefail for the file or block AROUND it, which is the
# only arming either arm asks about: an arming inside a command substitution
# belongs to that subshell and dies with it.
#
# EVERY occurrence on the line is walked, not merely the first, and that is the
# whole reason this is a loop rather than one match(). match() answers with the
# leftmost occurrence, so a line carrying a substitution-scoped arming AHEAD of
# a real one, x=$(set -o pipefail; true); set -o pipefail, would be graded on
# the leftmost, the depth test would answer 1, and a genuinely armed block would
# read as unarmed. That is the false negative gaia-react/gaia#1936 closed, and
# the only thing that kept the shipped single-match form from reopening it was a
# trailing boundary narrow enough to reject the leftmost occurrence outright:
# the same boundary gaia-react/gaia#1941 had to widen. Walking every occurrence
# is what makes the boundary and the depth test independent of each other.
function arms_at_depth_zero(l,   s, off, pos) {
  s = l
  off = 0
  while (match(s, PIPEFAIL_RE)) {
    pos = off + RSTART
    if (depth_at(l, pos) == 0) return 1
    off = pos
    s = substr(l, pos + 1)
  }
  return 0
}
'

# The `*.sh` arm. One pass per file, emitting three tab-separated record kinds
# rather than a verdict, because no file can be graded until the whole closure
# is known:
#
#   #armed  <file>                     the file arms pipefail itself (a seed)
#   #source <file> <basename>          the file loads that basename (an edge)
#   #hit    <file> <line> <message>    a candidate, graded later
readonly SHELL_AWK='
{
  line = $0
  bare = line
  sub(/^[[:space:]]+/, "", bare)

  # A full-line comment neither arms pipefail nor carries an executed reader,
  # and it does NOT close an open pipeline: bash accepts a comment line between
  # a trailing pipe and the command that follows it, so the carry is left alone.
  if (bare ~ /^#/) next

  # The arming test is handed `line`, not the whitespace-stripped `bare` the
  # rest of this block reads, because its locator indexes the string it was
  # given: a stripped one would place every occurrence a few characters early
  # and answer the depth question about the wrong position. The depth is carried
  # to the next line the way the workflow arm carries it, and for the same
  # reason: a substitution opened on one line and closed on another scopes every
  # arming between them.
  if (!armed && arms_at_depth_zero(line)) armed = 1
  subdepth = carry_at(line)

  # A source edge. The load token is recognized anywhere a command may start,
  # not at line start only, because the bracketed load this tree uses for an
  # errexit-armed file puts it after a semicolon and an &&.
  if (bare ~ /(^|[^A-Za-z0-9_${}\/.-])(\.|source)[[:space:]]/) {
    if (match(bare, /[A-Za-z0-9_.-]+\.sh/))
      printf "#source\t%s\t%s\n", file, substr(bare, RSTART, RLENGTH)
  }

  n = scan_pipeline(line)
  for (i = 1; i <= n; i++)
    printf "#hit\t%s\t%d\t`%s` short-circuits a pipeline under pipefail\n", file, FNR, hitbuf[i]

  prev_pipe = carries_pipe(line)
}

# At END, not inline: a file may arm pipefail on a line BELOW a pipeline, so
# where the set sits says nothing about whether the file runs armed.
END { if (armed) printf "#armed\t%s\n", file }
'

# The workflow-YAML arm, and the whole of the shell oracle the header describes.
# Two passes over the same file, named twice on the command line, because a
# step\047s `shell:` key may sit either side of its `run:` key and the block
# cannot be graded until both have been read. Pass one resolves each step\047s
# shell and finds any `defaults:` key; pass two scans the bodies.
#
# Two record kinds, both already graded, because this arm needs no closure:
#
#   #defaults <file> <line>            a construct this gate refuses to resolve
#   #hit      <file> <line> <message>  a reader in a block that runs armed
readonly YAML_AWK='
# The YAML structure both passes walk, reduced to the two questions this gate
# asks of it: which mapping key is this line, and is this line inside a block
# scalar rather than a key at all. Sets keyname, keycol and islist; answers 0
# when the line carries no key to read.
#
# The block-scalar half is load-bearing rather than tidiness, and which cases
# need it is a criterion rather than a list: any caller that acts on this
# answer without the step-column test gating it reads a key at ANY column, so
# it has nothing to fall back on, and a `run:` body carrying whatever shape
# that caller keys on, a quoted keyword or a dash-led item alike, would be
# taken for the key itself. Both passes below carry such callers, the `islist`
# arm among them, since the arm that sets the step column necessarily runs
# ahead of the test against it, and it keys on the dash rather than on any
# word. Take them off the call sites rather than off a list here, which goes
# stale the round another one is added. It is NOT what saves the two lines
# spelled `shell:` inside the `filters: |` body of
# .github/workflows/shell-lint.yml, tempting as that reading is. Block-scalar
# content is necessarily indented deeper than the key that opened it, and that
# key is already deeper than the step column, so the step-column test decides
# those two on its own and would still decide them with this half removed.
function yaml_key(l,   col, rest) {
  if (l ~ /^[[:space:]]*$/) return 0
  col = match(l, /[^ ]/)
  if (blockcol >= 0) {
    if (col > blockcol) return 0
    blockcol = -1
  }
  # A mustache section tag sits at column 1 in the adopter templates and renders
  # as a blank line, so it is neither a key nor a dedent. A partial include is
  # deliberately not spared: it splices a whole document region.
  rest = substr(l, col)
  if (substr(rest, 1, 3) ~ /^\{\{[#^\/]/) return 0
  # A list item opens a step, and the key after its dash is the first key of
  # that step. The dash and its following run of spaces are part of the
  # indentation for column purposes, so the key column is measured past them.
  islist = 0
  if (match(l, /^[[:space:]]*-[[:space:]]+/)) {
    islist = 1
    col = RLENGTH + 1
    rest = substr(l, col)
  }
  if (rest !~ /^[A-Za-z_][A-Za-z0-9_.-]*:([[:space:]]|$)/) return 0
  keyname = rest
  sub(/:.*$/, "", keyname)
  keycol = col
  keyval = rest
  sub(/^[A-Za-z_][A-Za-z0-9_.-]*:/, "", keyval)
  # A block scalar header carries nothing but the indicator, its optional
  # chomping and indentation digits in either order, and an optional comment.
  # Anything else on the line is inline content, which is a single command and
  # so cannot carry a two-line shape.
  isblock = (keyval ~ /^[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/)
  if (isblock) blockcol = keycol
  return 1
}

# A step is armed by its resolved shell when it names bash outright, or names a
# custom invocation carrying pipefail. Everything else, the absent case
# included, is GitHub\047s bare `bash -e` default, which arms nothing.
function shell_arms(v) {
  sub(/^[[:space:]]+/, "", v)
  sub(/[[:space:]]+$/, "", v)
  gsub(/^["\047]|["\047]$/, "", v)
  if (v == "bash") return 1
  return (v ~ /pipefail/)
}

# Close the step pass one is holding: a step that carried a `run:` block and
# resolved to an arming shell hands pass two a pre-armed block, keyed by the
# line its `run:` sits on. An array rather than a record, because the two passes
# are one awk invocation and pass two reads it directly.
function flush_step() {
  if (steprun > 0 && shell_arms(stepshell)) shellarm[steprun] = 1
  steprun = 0
  stepshell = ""
}

BEGIN { blockcol = -1; steprun = 0; stepkeycol = -1 }

# --- pass one: resolve each step\047s shell, and find any defaults: key ------
NR == FNR {
  if (!yaml_key($0)) next
  if (keyname == "defaults") printf "#defaults\t%s\t%d\n", file, FNR
  # A list item opens a step, and its own key column is the column every other
  # key of that step sits at.
  if (islist) { flush_step(); stepkeycol = keycol }
  if (keycol != stepkeycol) next
  # Both `run:` spellings register, block scalar and inline alike. The resolved
  # shell of the step arms whichever one it carries, so grading only the block
  # form would leave the inline one unscanned at every arming.
  if (keyname == "shell") stepshell = keyval
  else if (keyname == "run") steprun = FNR
  next
}

# --- pass two: scan the run: bodies -----------------------------------------
# Reached only on pass two, because the rule above ends in `next`. The last step
# of pass one is still open here, so this is where it closes.
FNR == 1 { flush_step(); blockcol = -1; inrun = 0 }

{
  if (inrun) {
    col = match($0, /[^ ]/)
    tag = substr($0, col ? col : 1)
    # A blank line, and a mustache section tag rendering as one, belong to the
    # block scalar rather than ending it.
    if ($0 ~ /^[[:space:]]*$/ || substr(tag, 1, 3) ~ /^\{\{[#^\/]/) { body($0, FNR); next }
    if (col > runcol) { body($0, FNR); next }
    endrun()
    # Fall through: this same line may itself be the next run: key.
  }
  if (yaml_key($0) && keyname == "run") {
    armed = shellarm[FNR]
    subdepth = 0
    prev_pipe = 0
    pend = 0
    if (isblock) {
      inrun = 1
      runcol = keycol
    } else {
      # An inline value is a single command, so it is its own one-line block and
      # is graded on the spot. It needs the same arming as the block form and
      # nothing else: a composite step, where the schema makes `shell:`
      # mandatory, is exactly where a `shell: bash` puts the class on a key\047s
      # own line. The sibling run-interpolation gate scans this arm too, so
      # skipping it here would leave the two disagreeing about the same value.
      body(keyval, FNR)
      endrun()
    }
  }
}

END { if (inrun) endrun() }

# body: one line of a run: block. Hits are BUFFERED rather than printed, because
# a block may arm pipefail on a line below a pipeline exactly as a file may.
function body(l, n,   i, k) {
  bare = l
  sub(/^[[:space:]]+/, "", bare)
  # A full-line comment neither arms pipefail nor carries an executed reader,
  # and it does NOT close an open pipeline. It is skipped before the depth walk
  # too: this tree\047s comments quote `$(...)` as prose, and counting those
  # would drift the depth against real code.
  if (bare ~ /^#/) return
  if (!armed && arms_at_depth_zero(l)) armed = 1
  subdepth = carry_at(l)
  k = scan_pipeline(l)
  for (i = 1; i <= k; i++) { pend++; pline[pend] = n; ptext[pend] = hitbuf[i] }
  prev_pipe = carries_pipe(l)
}

# endrun: the block just ended, so this is where it is graded.
function endrun(   i) {
  if (armed)
    for (i = 1; i <= pend; i++)
      printf "#hit\t%s\t%d\t`%s` short-circuits a pipeline under pipefail\n", file, pline[i], ptext[i]
  inrun = 0
  pend = 0
}
'

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PROG.XXXXXX")" || {
  printf '%s: could not create a scratch directory; nothing was scanned\n' "$PROG" >&2
  exit 2
}
# Three arms, not one shared arm: bash resumes at the point of interruption once
# a trapped handler returns, so a single arm that only cleans up would leave
# Ctrl-C printing a verdict as if uninterrupted.
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The basename-to-path record is emitted here rather than by the awk pass,
# because awk is handed the file CONTENT and this is a fact about its name. It
# rides the same stream as the awk records, so the loop opens one output file
# and forks nothing per file: `${f##*/}` is what `basename` would have returned.
#
# `LC_ALL=C` on both arms, so awk reads BYTES rather than characters. See the
# YAML loop below for the hazard; it is if anything stronger here, because far
# more tracked `*.sh` carry a non-ASCII byte than workflow YAML does. Every
# construct either arm matches on is ASCII, so reading bytes costs neither of
# them anything, and the two per-file invocations do not disagree about a
# hazard this file argues is real.
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  [ -f "$f" ] || continue
  printf '#file\t%s\t%s\n' "${f##*/}" "$f"
  LC_ALL=C awk -v file="$f" "$READER_AWK$SHELL_AWK" "$f"
done > "$WORK_DIR/records"

# The YAML arm, into its own record stream: its hits arrive already graded, so
# they must not reach the closure machinery below, which grades by file rather
# than by block. Each file is named TWICE, which is what makes the two passes
# two: pass one resolves the steps, pass two scans the bodies.
#
# `LC_ALL=C` for the reason the `*.sh` loop above also takes it: the prose in
# these files is not ASCII (an arrow in a comment of the code-review-audit
# template is enough), and awk aborts the whole file on a multibyte conversion
# failure, which would leave the arm scanning nothing and saying so only as a
# warning on stderr. Every construct this arm matches on -- YAML indentation,
# `run:`, `shell:`, the pipe, the reader flags -- is ASCII.
for f in ${yaml_files[@]+"${yaml_files[@]}"}; do
  [ -f "$f" ] || continue
  LC_ALL=C awk -v file="$f" "$READER_AWK$YAML_AWK" "$f" "$f"
done > "$WORK_DIR/yaml-records"

# The refusal, ahead of any verdict. A `defaults:` key moves the resolved shell
# for every step under it, which is the one thing the oracle above does not
# resolve, so the gate stops rather than answer for a surface it has graded on
# the wrong default. Read with a single awk pass rather than a quiet grep
# downstream of a pipe: this file arms pipefail, and that is the class it
# exists to catch.
defaults_seen="$(awk -F'\t' '$1 == "#defaults" { printf "%s:%s\n", $2, $3 }' "$WORK_DIR/yaml-records")"
if [ -n "$defaults_seen" ]; then
  printf '%s\n' "$defaults_seen" >&2
  cat >&2 <<REFUSAL
$PROG: a \`defaults:\` key is present in the scanned workflow YAML, at the
line(s) above. It moves the resolved shell for every \`run:\` step beneath it,
and this gate resolves a step's own \`shell:\` key only. Grading these steps
would answer from the wrong default, so nothing was graded. Implementing the
step-over-job-over-workflow precedence chain is tracked as gaia-react/gaia#1814.
REFUSAL
  exit 4
fi

# Split the one record stream into the three inputs the closure needs. No `||`
# guard is owed on any of them: awk exits 0 over a file holding no matching
# record, so a record kind the tree never produced yields an empty file rather
# than a failure under this script's own errexit.
awk -F'\t' '$1 == "#armed"  { print $2 }' "$WORK_DIR/records" | LC_ALL=C sort -u > "$WORK_DIR/closure"
awk -F'\t' '$1 == "#source" { printf "%s\t%s\n", $2, $3 }' "$WORK_DIR/records" > "$WORK_DIR/edges"
awk -F'\t' '$1 == "#hit"    { print }' "$WORK_DIR/records" > "$WORK_DIR/hits"
awk -F'\t' '$1 == "#file"   { printf "%s\t%s\n", $2, $3 }' "$WORK_DIR/records" | LC_ALL=C sort -u > "$WORK_DIR/index"

# Transitive closure over the source edges. A fixed-point loop rather than a
# recursive walk, because bash 3.2 has no associative array to memoize with and
# the tracked set is small enough that re-resolving the whole frontier each
# round is cheaper than the bookkeeping that would avoid it.
while : ; do
  awk -F'\t' 'NR == FNR { seed[$0] = 1; next } ($1 in seed) { print $2 }' \
    "$WORK_DIR/closure" "$WORK_DIR/edges" | LC_ALL=C sort -u > "$WORK_DIR/bases"
  awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($1 in want) { print $2 }' \
    "$WORK_DIR/bases" "$WORK_DIR/index" | LC_ALL=C sort -u > "$WORK_DIR/reached"
  LC_ALL=C comm -13 "$WORK_DIR/closure" "$WORK_DIR/reached" > "$WORK_DIR/added"
  [ -s "$WORK_DIR/added" ] || break
  LC_ALL=C sort -u "$WORK_DIR/closure" "$WORK_DIR/added" > "$WORK_DIR/closure.next"
  mv "$WORK_DIR/closure.next" "$WORK_DIR/closure"
done

report=""
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  grep -qxF -- "$f" "$WORK_DIR/closure" || continue
  hits="$(awk -F'\t' -v f="$f" '$2 == f { printf "%s:%s: %s\n", $2, $3, $4 }' "$WORK_DIR/hits")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

# No closure test on this arm: a `run:` body is its own script, so it is graded
# by its own step and inherits nothing from the file around it.
for f in ${yaml_files[@]+"${yaml_files[@]}"}; do
  hits="$(awk -F'\t' -v f="$f" '$1 == "#hit" && $2 == f { printf "%s:%s: %s\n", $2, $3, $4 }' "$WORK_DIR/yaml-records")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The remedy is written as prose rather than as sample pipelines, so the
  # footer this gate prints cannot read as an instance of the class it reports.
  cat >&2 <<'REMEDY'
Fix each by removing the pipeline rather than making the race safer:
    a printf or echo feeding the reader  ->  grep -q RE <<<"$var"
    a command feeding the reader         ->  out="$(some_command)"
                                             grep -q RE <<<"$out"
    a filter feeding the reader          ->  one awk pass over <<<"$var"
An inverted reader (grep -qv, grep -qvF) additionally needs the newline <<< appends
trimmed off the value, or it succeeds on the trailing blank line unconditionally.
A file with no `set -o pipefail` of its own still counts when an armed file sources it.
REMEDY
  exit 1
fi

printf '%s: clean\n' "$PROG" >&2
exit 0
