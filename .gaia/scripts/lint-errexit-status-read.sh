#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk programs below are single-quoted
# precisely so that `$?`, `$(`, and every awk field reference reach awk as
# literal program text. An expansion the shell performed here would delete the
# detector rather than help it.
# shellcheck disable=SC2016
#
# lint-errexit-status-read.sh: flag every read of `$?` that follows a bare
# command-substitution assignment while errexit is armed. Exit 1 with a
# file:line report on any hit, exit 0 when clean. Run it directly from the repo
# root: `bash .gaia/scripts/lint-errexit-status-read.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-errexit-status-read.bats, which the `Audit CI Tests`
# CI job runs, and folded into .gaia/tests/shell-lint.sh so every shell-lint
# caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-errexit-status-read.bats`.
# gaia:maintainer-only:end
#
# Why: an assignment takes the exit status of its command substitution, so under
# `set -e` a failing command terminates the script ON THE ASSIGNMENT LINE and
# the status read that follows never runs:
#
#     out="$(some_command ...)"
#     rc=$?                       # unreachable
#     if [[ $rc -ne 0 ]]; then    # dead, and so is everything it guards
#
# The observable outcome is a bare non-zero exit carrying none of the
# diagnostics the author wrote, and the branch that was supposed to handle the
# failure is never entered. Two instances of exactly this shape shipped in
# .github/actions/gaia-ci-merge-and-watch/action.yml (gaia-react/gaia#1477,
# gaia-react/gaia#1478); one of them silently disabled the whole post-merge
# revert escalation, because three later steps were gated on a step outcome that
# could no longer be reached, so a CI failure that could not be reverted
# escalated to nobody.
#
# The repair is always the same and never wrong -- move the status out of the
# assignment's way, so the shell has a chance to run the next line:
#
#     rc=0
#     out="$(some_command ...)" || rc=$?
#
# Why a repo-authored gate rather than a linter setting: three oracles were
# measured against the shape and none of them sees it.
#
#   - shellcheck 0.11.0 at severity `style`, the strictest floor
#     .gaia/tests/shell-lint.sh uses, exits 0 on the snippet above. SC2181 fires
#     on `if [ $? -ne 0 ]` after a PLAIN COMMAND and it does still fire on that
#     spelling here, but a capture into a variable draws nothing, and shellcheck
#     does not model `set -e` assignment status at all. The uncovered half is
#     therefore the capture, which is also the form both shipped instances took.
#   - actionlint v1.7 does not lint composite-action step bodies at all, which
#     .gaia/cli/test-fixtures/ci-shape/composite-actions.smoke.sh already
#     records.
#   - The `run:` bodies of workflows and composite actions are shell that no
#     `*.sh` glob reaches, so shell-lint's own discovery never opens the file
#     either shipped instance lived in.
#
# Scan surface, two halves that arm differently:
#
#   tracked `*.sh` and the extensionless husky hooks -- armed only where the
#     file turns errexit on, tracked line by line so a `set +e` disarms and a
#     later `set -e` re-arms. Off by default is the truthful model here: a
#     script with no `set -e` does not carry the class at all, and roughly
#     twenty legitimate assignment/`rc=$?` pairs in this tree sit in exactly
#     such files. Arming unconditionally would demand a rewrite of every one of
#     them with no defect behind any.
#
#   `.github/workflows/`, `.github/actions/*/action.yml`, and the adopter
#     workflow templates under .gaia/cli/src/automation/templates/workflows/ --
#     `run:` bodies only, armed BY DEFAULT. GitHub Actions runs a step body as
#     `bash -e {0}` (and `bash -eo pipefail {0}` under an explicit
#     `shell: bash`), so errexit is on whether or not the body says so, which is
#     precisely why both shipped instances were live. A `set +e` inside the body
#     still disarms from that point.
#
# The templates render into an ADOPTER's CI, where a status read the author
# expected to run is skipped on a machine neither this repo's review nor the
# adopter's ever watches. That is this class one distribution hop further out,
# and it is the same reason the sibling run-interpolation and grep-escape gates
# scan them.
#
# `.gaia/cli/templates/workflows/` is a build artifact copied from `src/` by
# `bundle:adopter` and is deliberately NOT scanned, so no hit is reported twice
# and no report names a file the repair must not hand-edit.
#
# Two file types are deliberately out of the surface:
#
#   *.bats  -- a suite is where this class is DEMONSTRATED. This gate's own
#              sibling suite writes fixture scripts through heredocs whose
#              bodies carry `set -e`, the assignment, and the status read as
#              literal tracked lines, and a scanner reading raw lines cannot
#              tell a fixture from an executed one. Including them would demand
#              "fixes" that delete the proof. This is a real FAIL-OPEN and worth
#              naming as one: bats runs a test body under errexit, so a suite is
#              exposed to the class rather than exempt from it. Every suite in
#              this tree is at zero for the class today, and the exclusion is
#              what buys the detector.
#   *.md    -- the sibling path-quoting gate scans the fenced blocks of tracked
#              markdown because several are executed instruction. The same
#              fixture problem applies with more force here: this file's own
#              class documentation, and the wiki page describing the gate, both
#              have to SHOW the broken shape to explain it.
#
# What is deliberately NOT claimed, each because the status the read sees comes
# from somewhere other than the substitution:
#
#   - A PREFIXED assignment (`local out=$(cmd)`, and the same for `declare`,
#     `readonly`, `typeset`, and `export`). There the exit status belongs to the
#     builtin rather than to the substitution, so errexit does not fire and the
#     read is reachable -- it just always reads zero. That is a real defect and a
#     different one, and shellcheck already carries it as SC2155.
#   - An assignment guarded by `||` or `&&`, or written as one member of a
#     pipeline or a `;`-separated list. Errexit exempts a command whose status is
#     consumed by an AND-OR list, which is exactly what the repair above builds,
#     so flagging it would red the tree on the fix.
#   - An assignment used as an `if`/`while`/`until` CONDITION, which never
#     matches the assignment shape below because the line begins with the
#     keyword.
#
# Known FAIL-OPEN blind spots, stated rather than discovered later:
#   - A `$?` reached through a variable indirection, or a status stored by a
#     `trap` body that a later line then reads. Both are genuinely deferred
#     reads whose value depends on when the body runs, which a line-oriented
#     scan cannot resolve.
#   - A command substitution containing an unbalanced `)` inside a quoted string
#     of its own. The substitution skip below counts parentheses without
#     tracking quotes, the same bounded approximation the sibling grep-escape
#     gate makes, so the walk leaves the region early and the rest of the
#     statement is read in the wrong state.
#   - A step whose `shell:` is not bash (`python`, `pwsh`). Its body is armed as
#     bash would be, but the shape below is bash syntax that such a body does not
#     carry, so the arming costs nothing.
#   - A `run:` written as a multi-line plain or quoted flow scalar rather than a
#     block scalar; only its first line is read, the same bound the sibling
#     run-interpolation gate carries and for the same reason.

set -euo pipefail

# Shared detector, concatenated into both scan programs below so the matcher is
# written once and the two surfaces cannot drift apart. Single-quoted, and every
# literal quote inside is spelled as an escape (`\047` for `'`), so the shell
# passes the program through untouched.
readonly CORE_AWK='
# Tokenizer state, carried ACROSS lines so a command substitution or a quoted
# string spanning several lines is followed rather than guessed at:
#   W_q      the open quote character, "" outside quotes
#   W_qsave  the quote state to restore when a substitution closes
#   W_depth  open `$(` nesting depth
#   W_tick   1 inside a legacy backtick substitution
#   W_op     set by walk() when an unquoted control operator is seen at depth 0
#
# walk(line): advance the state across one line and return 1 when the statement
# continues onto the next one.
function walk(line,   n, i, c, prev) {
  W_op = 0
  W_stop = 0
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)

    if (W_tick) { if (c == "`") W_tick = 0; continue }

    # Inside a command substitution the text is a script of its own. It is
    # skipped wholesale with the parentheses counted, because the only thing
    # this walk needs from it is where it ENDS: an operator or a quote in there
    # belongs to the inner command, not to the assignment being classified.
    if (W_depth > 0) {
      if (c == "\\") { i++; continue }
      if (c == "(") { W_depth++; continue }
      if (c == ")") { W_depth--; if (W_depth == 0) W_q = W_qsave; continue }
      continue
    }

    # Single quotes make every byte literal, including a backslash, so this test
    # has to come before the escape handling below.
    if (W_q == "\047") { if (c == "\047") W_q = ""; continue }

    if (c == "\\") {
      if (i == n) return 1
      i++
      continue
    }

    # A substitution opens from inside double quotes too, which is the ordinary
    # spelling of the very shape this gate matches (`out="$(cmd)"`). Saving the
    # quote state is what returns the walk to the string when it closes.
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      W_qsave = W_q; W_q = ""; W_depth = 1; i++; continue
    }
    if (c == "`") { W_tick = 1; continue }

    if (W_q == "\"") { if (c == "\"") W_q = ""; continue }

    if (c == "\047") { W_q = "\047"; continue }
    if (c == "\"")   { W_q = "\"";   continue }

    # An unquoted `#` opens a comment only at the start of a word; mid-word it is
    # an ordinary character.
    if (c == "#") {
      prev = (i > 1) ? substr(line, i - 1, 1) : " "
      if (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|" || prev == "(") break
      continue
    }
    # `;` SEPARATES two commands rather than joining them into one, so errexit
    # still fires on the first: `out=$(cmd); rc=$?` is the same defect written on
    # one line. Stop the walk there and hand the caller the offset, so the
    # remainder is classified as the statement it is.
    if (c == ";") { W_stop = i + 1; return 0 }
    # `||`, `&&`, a pipeline, and a background `&` all mean the assignment is not
    # a bare simple command whose failure kills the shell. `||` in particular is
    # what the repair this gate advertises is built from, so marking the
    # statement here is what keeps the gate from redding the tree on its own fix.
    if (c == "|" || c == "&") { W_op = 1; continue }
  }
  return (W_q != "" || W_depth > 0 || W_tick) ? 1 : 0
}

# arm(s): update the errexit state from a `set` line. Only an `e` in a short
# option bundle or an explicit `-o errexit` counts, so `set -u` and
# `set -o pipefail` leave the state alone.
function arm(s,   n, t, i, w) {
  n = split(s, t, /[ \t]+/)
  for (i = 2; i <= n; i++) {
    w = t[i]
    if (w == "-o") { if (t[i + 1] == "errexit") armed = 1; i++; continue }
    if (w == "+o") { if (t[i + 1] == "errexit") armed = 0; i++; continue }
    if (substr(w, 1, 2) == "--") continue
    if (substr(w, 1, 1) == "-" && index(w, "e") > 0) armed = 1
    if (substr(w, 1, 1) == "+" && index(w, "e") > 0) armed = 0
  }
}

function reset_state() {
  W_q = ""; W_qsave = ""; W_depth = 0; W_tick = 0
  cont = 0; pending = 0; cand = 0; stmt_op = 0
}

# has_status_read(line): 1 when the line reads `$?`, quote-aware.
#
# A `$?` inside SINGLE quotes is literal text at this point in the script and is
# not a read at all. That discrimination is load-bearing rather than cosmetic:
# the ordinary way to capture an exit status for a cleanup handler is
# `trap \047rc=$?; ...\047 EXIT`, whose body the shell stores unexpanded and
# runs when the trap fires. Five such traps sit in this tree, each on the line
# after a `mktemp` assignment, and reading them as status reads would red the
# tree on correct code. Inside DOUBLE quotes a `$?` does expand, so `echo "rc
# $?"` is a read like any other, and a single quote appearing inside a
# double-quoted string is an ordinary character rather than a quote.
function has_status_read(line,   n, i, c, q) {
  q = ""
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q == "\047") { if (c == "\047") q = ""; continue }
    if (c == "\\") { i++; continue }
    if (q == "") {
      if (c == "\047") { q = "\047"; continue }
      if (c == "\"") { q = "\""; continue }
    } else if (c == "\"") { q = ""; continue }
    if (c == "$" && substr(line, i + 1, 1) == "?") return 1
  }
  return 0
}

function report(n, aline) {
  printf "%s:%d: `$?` read after the command-substitution assignment at line %d, with errexit armed: the assignment takes the substitution status, so a failure exits there and this line and every branch it feeds are dead\n", file, n, aline
}

# feed(line, n): run one line of shell through the detector.
function feed(line, n,   stripped) {
  # A line can hold several statements. The loop walks them one at a time,
  # re-entering at each top-level `;` with the remainder, so an assignment and
  # the status read that follows it are seen the same way whether they sit on
  # two lines or one.
  while (1) {
  if (cont == 0) {
    stripped = line
    sub(/^[ \t]+/, "", stripped)

    # A blank or comment-only line executes nothing, so it neither breaks the
    # association between an assignment and the status read that follows it nor
    # changes the errexit state. That is what makes an intervening comment --
    # usually the one explaining what the dead branch is for -- still a hit.
    if (stripped == "" || substr(stripped, 1, 1) == "#") return

    if (stripped ~ /^set[ \t]/) arm(stripped)

    if (pending) {
      if (has_status_read(line)) report(n, pending_line)
      pending = 0
    }

    # A bare assignment: a NAME (optionally subscripted) directly followed by
    # `=`, with a command substitution somewhere in its value. A `local`/
    # `export`/`declare`/`readonly`/`typeset` prefix fails this test by
    # construction, which is the exclusion the header describes.
    cand = (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?=/) && (stripped ~ /[$]\(|`/)
    cand_line = n
    stmt_op = 0
  }

  if (walk(line)) { if (W_op) stmt_op = 1; cont = 1; return }
  if (W_op) stmt_op = 1
  cont = 0
  if (cand && !stmt_op && armed) { pending = 1; pending_line = cand_line }
  cand = 0

  # The walk stopped at a `;` with text after it: that text is the next
  # statement, and it shrinks by at least one character each time round, so the
  # loop always terminates.
  if (W_stop > 0 && W_stop <= length(line)) { line = substr(line, W_stop); continue }
  return
  }
}
'

# scan_shell: the *.sh and husky half. Errexit starts OFF, because a script that
# never turns it on does not carry the class.
readonly SHELL_AWK='
BEGIN { armed = 0; reset_state() }
{ feed($0, FNR) }
'

# scan_yaml: the workflow / composite-action / template half. The `run:` body is
# located structurally rather than by scanning the whole file, because the shape
# is only shell inside a body; the surrounding YAML is not shell at all. The
# locator is the one the sibling lint-workflow-run-interpolation.sh uses,
# including its mustache-section handling, for the same reasons its comments
# give. Errexit starts ON for every body, per `bash -e {0}`.
readonly YAML_AWK='
BEGIN { inrun = 0 }
{
  if (inrun) {
    # A blank line belongs to the block scalar rather than ending it.
    if ($0 ~ /^[[:space:]]*$/) { feed($0, FNR); next }
    # A mustache SECTION tag sits at column 1 in the adopter templates and
    # renders as a blank line, so reading it as a dedent would end the block and
    # leave the rest of the body unscanned while this gate still printed clean.
    # A partial include is deliberately not given the same treatment: it splices
    # a whole document region, so latching across one would carry `inrun` into
    # the mappings that follow it.
    tag = $0
    sub(/^[[:space:]]+/, "", tag)
    if (substr(tag, 1, 2) == "{{") {
      c = substr(tag, 3, 1)
      if (c == "#" || c == "^" || c == "/") { feed($0, FNR); next }
    }
    col = match($0, /[^ ]/)
    if (col > runcol) { feed($0, FNR); next }
    inrun = 0
    # Fall through: this same line may itself be the next `run:` key.
  }
  if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/) {
    runcol = index($0, "run:")
    value = substr($0, runcol + 4)
    # A block scalar header carries nothing but the indicator, its optional
    # chomping and indentation digits in either order, and an optional comment.
    # Anything else on the line is inline content, which is a single command and
    # so cannot carry a two-line shape.
    if (value ~ /^[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
      inrun = 1
      armed = 1
      reset_state()
    } else {
      inrun = 0
    }
  }
}
'

# `git ls-files` rather than a filesystem walk, so an untracked scratch script is
# never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these scripts
# run on stock macOS /bin/bash (3.2.57). NUL-delimited and `core.quotepath=false`
# so a path carrying a non-ASCII byte is not handed over C-quoted and silently
# dropped by the `[ -f ]` test below.
shell_files=()
while IFS= read -r -d '' f; do
  shell_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '*.sh' '.husky/*' | LC_ALL=C sort -z)

yaml_files=()
while IFS= read -r -d '' f; do
  yaml_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z \
                      '.github/workflows/*.yml' '.github/workflows/*.yaml' \
                      '.github/actions/*/action.yml' '.github/actions/*/action.yaml' \
                      '.gaia/cli/src/automation/templates/workflows/*.tmpl' \
           | LC_ALL=C sort -z)

# An empty scan set is a hard error, never a clean tree. The loops above read
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the arrays empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is the lie-green
# failure gates exist to stop. Every real tree carries both sets, so an empty
# result means the discovery is wrong rather than the tree.
if [ "${#shell_files[@]}" -eq 0 ] || [ "${#yaml_files[@]}" -eq 0 ]; then
  echo "lint-errexit-status-read: ERROR: no tracked shell or no tracked workflows matched the scan surface; nothing was scanned" >&2
  exit 1
fi

report=""
for f in ${shell_files[@]+"${shell_files[@]}"}; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" "$CORE_AWK$SHELL_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for f in ${yaml_files[@]+"${yaml_files[@]}"}; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" "$CORE_AWK$YAML_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # printf, not echo: the hint carries `$` and backslashes that echo may expand
  # depending on the shell (SC2028). The format string is single-quoted so the
  # sample code inside stays literal -- it is being printed, not run.
  # shellcheck disable=SC2016
  printf 'Fix each by letting the assignment hand its status on instead of dying on it:\n    rc=0\n    out="$(some_command ...)" || rc=$?\n' >&2
  exit 1
fi

echo "lint-errexit-status-read: clean" >&2
exit 0
