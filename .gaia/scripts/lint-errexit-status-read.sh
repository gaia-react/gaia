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
#   - An assignment whose status an AND-OR list CONSUMES rather than lets fall
#     to the shell: `out=$(cmd) || rc=$?`, and the same in a pipeline. That is
#     exactly what the repair above builds, so flagging it would red the tree on
#     the fix. The exemption is positional and this bullet claims only the
#     position it covers: errexit spares the NON-FINAL commands of an AND-OR
#     list, so a trailing `cond && out=$(cmd)` does exit, and that shape is a
#     blind spot below rather than a semantic non-issue.
#   - An ENV-PREFIX assignment (`FOO=$(cmd) run_thing`). The status belongs to
#     the prefixed command, so a failing substitution in the prefix never trips
#     errexit; `set -e; FOO=$(false) echo hi` runs and survives.
#   - An assignment used as an `if`/`while`/`until` CONDITION, which never
#     matches the assignment shape below because the line begins with the
#     keyword.
#
# Known FAIL-OPEN blind spots, stated rather than discovered later:
#   - An assignment in the FINAL position of an AND-OR list (`cond && out=$(cmd)`
#     with a status read below it). The shell does exit there, so it is the
#     class, and it is missed because a control operator anywhere in the
#     statement disqualifies it with no position tracking. Widening this needs
#     the walk to know which side of the operator the assignment sits on, which
#     is real parsing rather than a looser test, and no tracked file here writes
#     the shape.
#   - A statement whose first word ends on a LATER line than the one the
#     assignment starts on. The env-prefix exclusion reads the first top-level
#     whitespace as an offset into a single line, so a continued statement is
#     classified as a bare assignment.
#   - A `$?` reached through a variable indirection, or a status stored by a
#     `trap` body that a later line then reads. Both are genuinely deferred
#     reads whose value depends on when the body runs, which a line-oriented
#     scan cannot resolve.
#   - More than one heredoc opened on a single line (`cat <<A <<B`): only the
#     first delimiter is recorded, so the second body is read as shell.
#   - A `<<` inside a bare `(( ))` arithmetic command, as opposed to the `$(( ))`
#     expansion the walk does track, is read as a heredoc redirection. No tracked
#     file here uses the bare form.
#   - A step whose `shell:` is not bash (`python`, `pwsh`). Its body is armed as
#     bash would be, but the shape below is bash syntax that such a body does not
#     carry, so the arming costs nothing.
#   - A `run:` written as a multi-line plain or quoted flow scalar rather than a
#     block scalar; only its first line is read, the same bound the sibling
#     run-interpolation gate carries and for the same reason.
#
# Known FALSE POSITIVES, a third direction and the one worth naming explicitly
# because each costs a correct line a wrong verdict. None occurs in this tree.
# Two distinct mechanisms, which the shapes below are grouped by rather than by
# how they are spelled; the split is measurable, by deleting the exclusion`s own
# `^[0-9]*[<>]` clause and seeing which shapes change verdict.
#
# The exclusion inspects a SINGLE TOKEN where the shell takes an arbitrary run
# of prefix words, so it stops at the first prefix word and never reaches the
# command behind it:
#   - A redirection standing between the value and the command it prefixes
#     (`out=$(cmd) > log run_thing`, and the same with `2>`, `2>&1`, or `>&`).
#     `>&` belongs here rather than below: its leading `>` matches the arming
#     test, so it is recognised as a redirection exactly as `>` is, and it fails
#     for the same reason every other shape in this bullet does.
#   - A further assignment before the command word (`out=$(cmd) FOO=1
#     run_thing`), which terminates the exclusion instead of being consumed.
#
# The ARMING TEST does not recognise the operator at all, so the exclusion never
# begins:
#   - `&> log`, whose leading `&` matches no part of `^[0-9]*[<>]`.
#
# The structural repair is one quote-aware loop consuming every assignment and
# redirection until a command word remains, tracked as gaia-react/gaia#1486. It
# closes the first group on its own; the second needs the arming test widened to
# reach `&>` as well, and the loop`s operator pattern has to consume `>&` whole
# or the leftover `&` reads as a control operator. It is deliberately not
# attempted here: the enumerate-one-more-shape approach produced four defects
# across four review rounds, the last of them a silent fail-open, so the repair
# gets its own change
# rather than a fifth widening.
#
# None of those fails SILENTLY. Tokenizer state is carried across lines, so any
# bound that loses sync leaves a quote, a substitution, or a heredoc open at the
# end of the region, and `check_desync` below reports the region as one this gate
# cannot certify rather than printing `clean` over lines it never read. That
# matters more than the bounds themselves: a line-oriented scan that desyncs
# swallows the REST OF THE FILE, not the rest of the statement, so the quiet
# failure is total rather than local.

set -euo pipefail

# Shared detector, concatenated into both scan programs below so the matcher is
# written once and the two surfaces cannot drift apart. Single-quoted, and every
# literal quote inside is spelled as an escape (`\047` for `'`), so the shell
# passes the program through untouched.
readonly CORE_AWK='
# Tokenizer state, carried ACROSS lines so a command substitution, a quoted
# string, or a heredoc body spanning several lines is followed rather than
# guessed at:
#   W_q       the open quote character, "" outside quotes
#   W_qstack  the quote state to restore as each nesting level closes
#   W_depth   open `$(` / `(` nesting depth
#   W_tick    1 inside a legacy backtick substitution
#   W_heredoc the delimiter of an open heredoc, "" when none
#   W_hd_tabs 1 when that heredoc was opened with `<<-`, which strips tabs
#   W_op      set by walk() when an unquoted control operator is seen at depth 0
#   W_stop    offset just past a top-level `;`, so the caller can resume there
#   W_sub     set by walk() when the line opens a real command substitution
#
# Quoting is tracked INSIDE a substitution with the same machinery as outside
# it. Skipping the region and counting bare parentheses is the cheaper reading
# and it is wrong in the one direction that matters: a `)` inside a quoted
# string closes the region early, the walk resumes mid-string, and a lone
# apostrophe in the remaining literal opens a quote state that never closes.
# Because state is carried across lines, the rest of the FILE is then swallowed
# as quoted text and never classified, while this gate still prints `clean`.
# `.claude/hooks/block-env-read.sh` is the exemplar, where a `sed -E` pattern
# carries a `)` inside a bracket expression. No count is given: how many files
# reach the shape depends entirely on which counterfactual is measured, and three
# defensible readings give three different answers, so a number here would read
# as a measurement while naming none. The desync guard below is the second half of the answer: even a
# correct tokenizer has bounds, and a gate that cannot read a file has to say so
# rather than certify it.
#
# walk(line): advance the state across one line and return 1 when the statement
# continues onto the next one.
function walk(line,   n, i, c, j, ch, delim, prev) {
  W_op = 0
  W_stop = 0
  W_sub = 0
  W_space_at = 0
  W_word = 0
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)

    # Where the first word of this statement ends, recorded only while the walk
    # is at a clean top level so whitespace inside a quoted string or a
    # substitution never counts. feed() reads it to tell an env-prefix apart from
    # a bare assignment.
    #
    # The `W_word` term is what makes it the FIRST WORD`s end rather than the
    # first whitespace on the line. Without it the latch fires on leading
    # indentation, `tail` becomes the whole statement, and since a statement that
    # got this far starts with `NAME=`, the exclusion sees an assignment and
    # skips itself. That is inert in the one direction nobody notices: every line
    # of a YAML `run:` body carries indentation, and that surface is the one
    # armed by DEFAULT, so the exclusion was dead across every workflow,
    # composite action, and adopter template, plus any shell inside a function or
    # a loop.
    if (W_depth == 0 && W_q == "" && !W_tick) {
      if (c == " " || c == "\t") {
        if (W_word && W_space_at == 0) W_space_at = i
      } else {
        W_word = 1
      }
    }

    # Single quotes make every byte literal, backslash included, so this test
    # comes before the escape handling below.
    if (W_q == "\047") { if (c == "\047") W_q = ""; continue }

    if (c == "\\") {
      if (i == n) return 1
      i++
      continue
    }

    if (W_tick) { if (c == "`") W_tick = 0; continue }

    # A substitution opens from inside double quotes too, which is the ordinary
    # spelling of the very shape this gate matches (`out="$(cmd)"`). The saved
    # quote state is what returns the walk to the string when it closes.
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      W_qstack[W_depth] = W_q
      W_depth++
      W_q = ""
      i++
      # `$((` is ARITHMETIC EXPANSION, not a command substitution. It runs no
      # command, so it cannot carry a non-zero status into the assignment and
      # errexit never fires on it; a `rc=$?` after `x=$((1 + 2))` is reachable
      # and simply always reads zero, which is a different thing from dead code
      # and would earn a message and a repair that make no sense. Consume the
      # second paren as its own level so the closing `))` balances by
      # construction rather than by coincidence, and leave W_sub unset.
      if (substr(line, i + 1, 1) == "(") {
        W_qstack[W_depth] = ""
        W_depth++
        W_ar[W_depth] = 1
        W_narith++
        i++
      } else {
        W_sub = 1
      }
      continue
    }
    if (c == "`") { W_tick = 1; W_sub = 1; continue }

    if (W_q == "\"") { if (c == "\"") W_q = ""; continue }

    if (c == "\047") { W_q = "\047"; continue }
    if (c == "\"")   { W_q = "\"";   continue }

    # A heredoc body is DATA the shell hands to a command, not shell it runs, so
    # it is swallowed rather than read. Without this the body of a fixture a
    # test script writes is classified as executed code: a `set +e` in there
    # disarms the detector for the rest of the real script, an apostrophe blanks
    # the rest of the file through the carry above, and a body deliberately
    # carrying the defect is reported as one. That is the same fixture-versus-
    # executed-line argument the header makes for excluding `*.bats` and `*.md`,
    # and `*.sh` is scanned, so it has to be answered here rather than by
    # dropping the surface.
    #
    # This runs at ANY substitution depth, above the depth guard below, because
    # a heredoc body occupies lines of this file no matter what opened it.
    # `AUDIT_GLOBAL_RULES_PATHS="$(cat <<\047EOF\047` is the live shape here,
    # and two tracked files reach it: gated at depth zero the body is read as
    # shell inside the substitution, and in one of them a Python docstring in
    # that body opens a quote that never closes, so the rest of the file goes
    # unclassified. Skipped inside `$(( ))`, where `<<` is a left shift rather
    # than a redirection.
    if (c == "<" && substr(line, i + 1, 1) == "<" && W_narith == 0) {
      # `<<<` is a herestring: its operand is a word on this same line, not a
      # body on the lines below.
      if (substr(line, i + 2, 1) == "<") { i += 2; continue }
      j = i + 2
      W_hd_tabs = 0
      if (substr(line, j, 1) == "-") { W_hd_tabs = 1; j++ }
      while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
      delim = ""
      ch = substr(line, j, 1)
      # A quoted delimiter (`<<'"'"'EOF'"'"'`) suppresses expansion in the body; either
      # spelling names the same terminator.
      if (ch == "\047" || ch == "\"") {
        j++
        while (j <= n && substr(line, j, 1) != ch) { delim = delim substr(line, j, 1); j++ }
        j++
      } else {
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.\/-]/) { delim = delim substr(line, j, 1); j++ }
      }
      if (delim != "") W_heredoc = delim
      i = j - 1
      continue
    }

    if (W_depth > 0) {
      if (c == "(") { W_qstack[W_depth] = ""; W_depth++; continue }
      if (c == ")") {
        if (W_ar[W_depth]) { delete W_ar[W_depth]; W_narith-- }
        W_depth--
        W_q = W_qstack[W_depth]
        continue
      }
      # Everything else inside a substitution belongs to the inner command: its
      # operators and its comments belong to it, not to the outer statement.
      # Its HEREDOCS are
      # handled above rather than here, because a heredoc body occupies lines of
      # THIS file whatever nesting opened it.
      continue
    }

    # An unquoted `#` opens a comment only at the start of a word; mid-word it is
    # an ordinary character.
    if (c == "#") {
      if (i == 1) break
      ch = substr(line, i - 1, 1)
      if (ch == " " || ch == "\t" || ch == ";" || ch == "&" || ch == "|" || ch == "(") break
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
    #
    # A `&` that belongs to a REDIRECTION is none of those. `&>log`, `2>&1`, and
    # `<&3` are file-descriptor syntax on the same simple command, so the
    # assignment still stands alone and errexit still fires on it. Read as a
    # control operator they disqualify the statement and the defect goes
    # unreported. The three spellings are distinguishable by their neighbours:
    # `&` before a `>`, or after a `>` or `<`.
    if (c == "&") {
      ch = substr(line, i + 1, 1)
      prev = (i > 1) ? substr(line, i - 1, 1) : ""
      if (ch == ">" || prev == ">" || prev == "<") continue
      W_op = 1
      continue
    }
    if (c == "|") { W_op = 1; continue }
  }
  return (W_q != "" || W_depth > 0 || W_tick) ? 1 : 0
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
function has_status_read(line,   n, i, c, q, prev) {
  q = ""
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (q == "\047") { if (c == "\047") q = ""; continue }
    if (c == "\\") { i++; continue }
    if (q == "") {
      # A TRAILING COMMENT is not a status read, and reading one as a hit is a
      # wrong verdict on reachable code: `some_cmd   # returns $? to the caller`
      # holds no read at all, and the line runs whenever the assignment above it
      # succeeded. walk() already strips a word-start `#`; this function is what
      # decides the hit, so it has to strip one too or the two disagree about
      # what the line even contains. Carrying a pending assignment across
      # comment-only lines, which is deliberate, widens the window rather than
      # narrowing it.
      if (c == "#") {
        prev = (i > 1) ? substr(line, i - 1, 1) : " "
        if (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|" || prev == "(") return 0
      }
      if (c == "\047") { q = "\047"; continue }
      if (c == "\"") { q = "\""; continue }
    } else if (c == "\"") { q = ""; continue }
    if (c == "$" && substr(line, i + 1, 1) == "?") return 1
  }
  return 0
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

function reset_state(  d) {
  W_q = ""; W_depth = 0; W_tick = 0; W_narith = 0
  W_heredoc = ""; W_hd_tabs = 0
  cont = 0; pending = 0; isname = 0; stmt_op = 0; stmt_sub = 0
  for (d in W_qstack) delete W_qstack[d]
  for (d in W_ar) delete W_ar[d]
}

# check_desync(what): report a region the scan could not read to its end.
#
# An open quote, an unclosed substitution, or an unterminated heredoc left
# standing when the region ends means the tokenizer lost sync somewhere inside
# it, and everything after that point was carried as quoted text rather than
# classified. That failure is silent in the worst direction: the gate prints
# `clean` over lines it never read. A well-formed region always closes what it
# opens, so this fires only where the answer is genuinely unavailable, and
# saying so is the honest verdict.
function check_desync(what) {
  if (W_q != "" || W_depth > 0 || W_tick || cont || W_heredoc != "")
    printf "%s: ERROR: the scan lost track of shell state before the end of %s, so the remainder was never classified and this gate cannot certify it clean\n", file, what
}

function report(n, aline) {
  printf "%s:%d: `$?` read after the command-substitution assignment at line %d, with errexit armed: the assignment takes the substitution status, so a failure exits there and this line and every branch it feeds are dead\n", file, n, aline
}

# feed(line, n): run one line of shell through the detector.
function feed(line, n,   stripped, probe, tail) {
  # An open heredoc swallows whole lines until its terminator: the body is data,
  # so nothing in it arms, disarms, or classifies. The terminator comparison
  # tolerates trailing whitespace deliberately. Bash does not, but the two
  # failure directions are not symmetric: ending a heredoc one line early costs
  # a few lines read as shell that were not, while never ending one swallows
  # every remaining line of the file and reports clean over all of them.
  if (W_heredoc != "") {
    probe = line
    if (W_hd_tabs) sub(/^\t+/, "", probe)
    sub(/[ \t]+$/, "", probe)
    if (probe == W_heredoc) W_heredoc = ""
    return
  }

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

    # A NAME (optionally subscripted) directly followed by `=`. A `local`/
    # `export`/`declare`/`readonly`/`typeset` prefix fails this test by
    # construction, which is the exclusion the header describes. Whether the
    # VALUE is a command substitution is walk()`s answer rather than a second
    # regex here, so `$((` arithmetic is told apart from `$(` by the same state
    # machine that has to tell them apart anyway.
    isname = (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/)
    cand_line = n
    stmt_op = 0
    stmt_sub = 0
    stmt_space_at = -1
  }

  if (walk(line)) {
    if (W_op) stmt_op = 1
    if (W_sub) stmt_sub = 1
    if (stmt_space_at == -1) stmt_space_at = W_space_at
    cont = 1
    return
  }
  if (W_op) stmt_op = 1
  if (W_sub) stmt_sub = 1
  # Only the statement`s FIRST line contributes the word break. A continued
  # statement`s later lines have their own leading whitespace, which belongs to
  # no first word, so reading one would exempt a real defect. That a continued
  # statement is therefore never env-prefix-tested is the bound the header names.
  if (stmt_space_at == -1) stmt_space_at = W_space_at
  cont = 0
  # An ENV-PREFIX assignment (`FOO=$(cmd) run_thing`) is not this class: the
  # status the shell takes is the prefixed COMMAND, so a failing substitution in
  # the prefix does not trip errexit at all (`set -e; FOO=$(false) echo hi` runs
  # and survives). Reported anyway it would be a wrong verdict carrying a repair
  # that makes no sense, which is the direction that gets a gate bypassed rather
  # than obeyed. Detect it from the tokenizer own record of the first top-level
  # whitespace: whatever follows is another word of the same simple command. A
  # further ASSIGNMENT there is still read as the class, which is right only when
  # no command word stands behind it (`FOO=$(false) BAR=1` does exit) and wrong
  # when one does; a redirection and a statement separator are read the same way,
  # with the same qualification. Those are the false positives the header
  # enumerates under `Known FALSE POSITIVES`, and they are why this reads only
  # the first token rather than claiming to find the command word. Bounded to a
  # statement that ends on its own line, since W_space_at indexes into that
  # line.
  if (isname && stmt_space_at > 0) {
    tail = substr(line, stmt_space_at)
    sub(/^[ \t]+/, "", tail)
    # This test reads ONE token and stops. That is a deliberate retreat from a
    # consumption loop, not an oversight, and the header records the bounds it
    # leaves standing under `Known FALSE POSITIVES`.
    #
    # The loop that consumed redirections and their operands was correct for the
    # shapes it enumerated and silently wrong for the first one it did not: its
    # operand matcher was whitespace-delimited, so `out=$(cmd) > "my log"`
    # consumed `"my` and left `log"`, which reads as a command word and exempted
    # a genuine defect. Reporting a correct line is loud and the author sees it;
    # certifying a broken one is invisible, and this gate exists to not do that.
    #
    # Four defects landed on this one test across four review rounds, every one
    # of them the same root cause: it inspects a single token where the shell
    # takes an arbitrary run of prefix words. Widening it by one more shape is
    # what produced this regression. The structural repair, one quote-aware loop
    # consuming every assignment and redirection until a command word remains,
    # is gaia-react/gaia#1486 rather than a fifth widening bolted on here.
    #
    # `^[0-9]*[<>]` rather than a bare `<`/`>` in the character set: a
    # redirection may carry an explicit file descriptor (`2> log`, `1>&2`), and
    # reading the digit as the first letter of a command word is what made
    # `out=$(cmd) 2> log` exempt itself while the identical `> log` was reported.
    if (tail != "" \
        && tail !~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/ \
        && tail !~ /^[0-9]*[<>]/ \
        && index(";|&#()", substr(tail, 1, 1)) == 0)
      isname = 0
  }
  if (isname && stmt_sub && !stmt_op && armed) { pending = 1; pending_line = cand_line }
  isname = 0

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
BEGIN { armed = armed_init; reset_state() }
{ feed($0, FNR) }
END { check_desync("the file") }
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
    # The body just ended, so this is where its state has to balance. A `run:`
    # body is its own script and the state resets on entry, which means an
    # unclosed region in one body cannot be inherited from the last, and neither
    # can it be certified.
    check_desync("a run: body")
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
END { if (inrun) check_desync("the last run: body") }
'

# `git ls-files` rather than a filesystem walk, so an untracked scratch script is
# never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these scripts
# run on stock macOS /bin/bash (3.2.57). NUL-delimited and `core.quotepath=false`
# so a path carrying a non-ASCII byte is not handed over C-quoted and silently
# dropped by the `[ -f ]` test below.
sh_files=()
while IFS= read -r -d '' f; do
  sh_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '*.sh' ':(exclude).husky/*' | LC_ALL=C sort -z)

# The husky hooks are collected separately from `*.sh` because they ARM
# differently, not merely because the glob misses them. `.husky/_/h` invokes
# every hook as `sh -e "$s"`, so errexit is on there whether or not the hook says
# so, exactly as it is inside an Actions `run:` body; `.husky/pre-commit` carries
# no `set -e` and is live for the class today. Reading them off-by-default with
# the ordinary scripts is what left that whole surface certified clean.
#
# The `*.sh` set EXCLUDES `.husky/*` explicitly. A git pathspec glob is matched
# without FNM_PATHNAME, so its `*` crosses `/` and a `.husky/helper.sh` would
# otherwise be returned by both sets, scanned once armed and once not, and
# double-listed in the report. No such file exists today; the only tracked hook
# is extensionless.
husky_files=()
while IFS= read -r -d '' f; do
  husky_files+=("$f")
done < <(git -c core.quotepath=false ls-files -z '.husky/*' | LC_ALL=C sort -z)

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
if [ "${#sh_files[@]}" -eq 0 ] || [ "${#yaml_files[@]}" -eq 0 ]; then
  echo "lint-errexit-status-read: ERROR: no tracked *.sh or no tracked workflows matched the scan surface; nothing was scanned" >&2
  exit 1
fi

report=""
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" -v armed_init=0 "$CORE_AWK$SHELL_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done
# The husky set is allowed to be empty and is simply skipped, mirroring the way
# .gaia/tests/shell-lint.sh treats its own *.bats set: an adopter clone may
# legitimately carry no hooks, while every real tree carries tracked *.sh, which
# is why only that set and the workflows are hard preconditions above.
for f in ${husky_files[@]+"${husky_files[@]}"}; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" -v armed_init=1 "$CORE_AWK$SHELL_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done
for f in ${yaml_files[@]+"${yaml_files[@]}"}; do
  [ -f "$f" ] || continue
  hits="$(awk -v file="$f" -v armed_init=1 "$CORE_AWK$YAML_AWK" "$f")"
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # The repair hint answers a status-read finding. A desync ERROR is a different
  # verdict with a different (and unknown) repair, so printing the hint under a
  # report carrying only those would name a fix the operator does not need.
  if printf '%s' "$report" | grep -qv ': ERROR: the scan lost track of shell state'; then
    # printf, not echo: the hint carries `$` and backslashes that echo may expand
    # depending on the shell (SC2028). The format string is single-quoted so the
    # sample code inside stays literal -- it is being printed, not run.
    # shellcheck disable=SC2016
    printf 'Fix each by letting the assignment hand its status on instead of dying on it:\n    rc=0\n    out="$(some_command ...)" || rc=$?\n' >&2
  fi
  exit 1
fi

echo "lint-errexit-status-read: clean" >&2
exit 0
