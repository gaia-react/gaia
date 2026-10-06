#!/usr/bin/env bash
# SC2016 is intentional file-wide: OWN_AWK below is single-quoted precisely so
# every `$` and awk field reference reaches awk as literal program text rather
# than being expanded by this shell first.
# shellcheck disable=SC2016
#
# lint-hook-cwd-relative-loads.sh: flag every place a hook under
# `.claude/hooks/**` locates FRAMEWORK CODE by a bare repository-root-relative
# path, which resolves against the process working directory rather than
# against the hook's own checkout. It roots itself at its own on-disk location,
# so it can be run from anywhere:
# `bash .gaia/scripts/lint-hook-cwd-relative-loads.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty or short. Exit 2 says the gate never ran:
# git is unavailable, its own root is unresolvable, the discovery command
# failed, or awk could not read a file in the surface.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-hook-cwd-relative-loads.bats, which the `Audit CI
# Tests` scripts shard runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-hook-cwd-relative-loads.bats`.
# gaia:maintainer-only:end
#
# Why: a hook is registered in .claude/settings.json by an absolute path, so it
# runs with the working directory of whatever tool call triggered it, which is
# the agent's session cwd and persists for the whole session. A load written as
#
#     [ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
#     type red_ledger_path >/dev/null 2>&1 || exit 0
#
# is therefore false from any directory below the repository root, and the
# capability probe behind it stands the hook down. That `exit 0` is a deliberate
# fail-open written for a BROKEN or ABSENT library, and it is correct for that
# case; a cwd-relative load is what makes a MOVED WORKING DIRECTORY
# indistinguishable from a missing file, so a single `cd` buys the fail-open.
# Two of the hooks carrying the shape are blocking guards (the RED-before-GREEN
# commit gate and the worthiness merge gate), and neither emits a diagnostic
# when it stands down, so the disarm is indistinguishable from a clean pass.
#
# The repair, which the tree already used correctly in several places before
# this gate existed, roots the path at the hook's own on-disk location:
#
#     _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=''
#     [ -n "$_library_directory" ] && [ -f "$_library_directory/red-ledger.sh" ] && . "$_library_directory/red-ledger.sh"
#
# `${BASH_SOURCE[0]}` is the path the registration invoked, so it names the
# ACTING tree: a worktree session loads that worktree's libraries, and the main
# checkout loads its own. `$PWD` and a bare relative path do not have that
# property, and neither does `$CLAUDE_PROJECT_DIR`, which holds the session's
# original project directory and does not follow entry into a linked worktree.
#
# Scope: tracked `*.sh` under `.claude/hooks/**`, the surface whose files are
# invoked by absolute path from a working directory nobody controls. It scans
# no other directory, so it needs neither the shared scan-surface library nor
# its bats-fixture discriminator. A path this gate reports is repo-relative
# because the discovery is `git ls-files` scoped to this gate's own root.
#
# Both the quoted and the unquoted spelling of each position are read. The
# distinction that decides a hit is literal-versus-variable-rooted, never
# quoted-versus-unquoted: `[ -f ".claude/hooks/lib/x.sh" ]` is the same defect
# as its bare spelling, while `[ -f "$_library_directory/x.sh" ]` is the repair.
#
# The file-test position is read on a second axis too: a NEGATED spelling is
# the same defect as its unnegated twin, so `[ ! -f .claude/hooks/lib/x.sh ]
# && exit 0` reports exactly as `[ -f .claude/hooks/lib/x.sh ] || exit 0` does.
# That negated form is the idiomatic spelling of the capability-probe
# stand-down in the motivating example above, which is why it is named here
# rather than left to a reader to infer from the arm.
#
# WHAT COUNTS AS A HIT, four positions, each one a place a bare literal is
# resolved against the working directory at run time:
#
#   [ -f .claude/hooks/lib/x.sh ]        a file-test operand naming a code file
#   . .gaia/scripts/x.sh                 a `.` or `source` operand
#   bash .gaia/scripts/x.sh              an interpreter's script argument
#   library=".gaia/scripts/x.mjs"            an assignment naming a code file
#
# WHAT IS DELIBERATELY NOT A HIT, and why each exclusion is the right call
# rather than a gap this gate wishes it could close:
#
#   - A per-tree STATE path (`marker=".claude/example-session-marker"`,
#     `config=".gaia/local/example-state.json"`). Those name mutable state rather than
#     code, and `${BASH_SOURCE[0]}` is the WRONG root for them: which tree a
#     hook's state belongs to comes from a resolved root (main-root-lib.sh, or
#     a caller-supplied root in a library), never from the script's own directory,
#     so rooting one at `${BASH_SOURCE[0]}` would make a `main-only` marker
#     follow a linked worktree. They are cwd-sensitive too, and the repair
#     needs each site read against its own resolved root; the file-test and
#     assignment arms are both pinned to a code extension for exactly that
#     reason, so neither one hands a state path the wrong root. What that pin
#     costs each arm is under KNOWN BLIND SPOTS below.
#   - A git PATHSPEC or revision path (`git rev-parse "HEAD:$p"`). That syntax
#     is resolved by git against the repository root, never against cwd, so a
#     bare literal there is already correct and rewriting it would be churn.
#   - An interpreter argument on a line that `cd`s first
#     (`cd "$root" && bash .gaia/scripts/x.sh`). The `cd` is the rooting, and
#     it is the shape a caller uses when the target tree is deliberately not
#     this hook's own.
#   - A trailing comment that mentions one of the four positions after real
#     code on the same line. `code_prefix()` cuts the line at the first
#     unquoted `#` preceded by whitespace and the match arms read only what is
#     left, so the mention is quiet. That is the same call the whole-line
#     comment arm makes, and it is the right one for a documentation mention;
#     it is listed here rather than left unsaid because a reader who expects
#     the scan to read the raw line would expect the opposite.
#
# KNOWN BLIND SPOTS, split by which way each one fails, because that is the
# part that matters.
#
# FAIL-OPEN, each a construct the line-oriented scan cannot read:
#   - A path reached through a variable the scan cannot follow
#     (`binary_path=".gaia/cli/gaia-maintainer"` then `[ -x "$binary_path" ]`). The assignment arm
#     catches this only where the literal carries a code extension, so an
#     extensionless binary or a data file passes. Both live instances of that
#     shape were repaired by hand when this gate landed.
#   - A bare literal in a FILE TEST carrying no extension from the pinned set
#     the arm requires, which is the same set the assignment arm requires and
#     is narrower than "a code file": a directory (`[ -d .claude/hooks ]`), an
#     extensionless executable, a code file written without its suffix, and a
#     code file whose extension is simply not in the set (`.ts`, `.zsh`, `.rb`)
#     all pass. That operand resolves against
#     the working directory like any other, so this is a real miss rather than
#     a shape the gate disagrees is a defect. It is the price of the code-
#     extension pin on that arm, and the pin is worth it: unpinned, the arm
#     cannot tell code from per-tree state, and the remedy it prints is wrong
#     for state in the specific way the STATE exclusion above describes. A gate
#     that stays silent on a defect costs a missed repair, while one that
#     prescribes the wrong root manufactures the class it exists to prevent, so
#     the pin fails in the cheaper direction. No hook currently tests a bare
#     state path directly; every live site tests through a variable, which is
#     why this arm went unpinned as long as it did.
#   - The same indirection where the variable is not assigned a literal at all
#     but computed per iteration, which no assignment arm can reach: a
#     repo-relative path derived from a diff listing and then tested
#     (`relative_path=$(... "$path"); [ -f "$relative_path" ]`) resolves against the working
#     directory exactly like a literal would. This is the shape that survived
#     the first pass of the conversion this gate shipped with, in the
#     worthiness gate, where the failing test read as "the file was deleted"
#     and emptied the scan into a clean pass. Reaching it needs data-flow
#     analysis rather than a line scan, so it stays a blind spot named here;
#     the runtime arms in .gaia/tests/hooks/ that drive each blocking hook from
#     a subdirectory are what cover it, and they are the reason it was found.
#   - A path assembled by expansion (`"$directory/${name}.sh"`), which is
#     tokenizer-bound the same way every sibling gate says of its own class.
#   - A load inside a heredoc body that a `bash -c` later executes. Heredoc
#     bodies are skipped outright, because the tree carries the class in them
#     only as documentation an operator reads.
#
# FAIL-CLOSED, so each costs a correct edit and never a missed defect:
#   - A mention inside a QUOTED span on a line of real code. A `#` inside the
#     quotes does not cut the line, because `code_prefix()` tracks quoting, so
#     the arms read the mention as the code it is indistinguishable from and it
#     reports. No such line exists in this tree.
#
# Provenance: the class was repaired across the hook family in
# gaia-react/gaia#1854, which found it standing behind
# .claude/rules/shell-cwd.md's `cd` prohibition as that rule's real, previously
# unwritten justification. Until this gate existed, that prose rule was the
# only thing holding the class down.

set -euo pipefail

command -v git >/dev/null 2>&1 || {
  printf 'lint-hook-cwd-relative-loads: git is not on PATH, so the scan surface cannot be discovered\n' >&2
  exit 2
}

# This gate's own root, from its own on-disk location rather than from the
# process working directory. A gate that flags cwd-resolved paths must not
# resolve its own scan surface that way: run from a subdirectory it would find
# nothing and blame the tree, and run from another checkout entirely it would
# scan that one. Every git call and every file read below is scoped to this.
gate_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || gate_root=''
if [ -z "$gate_root" ] || [ ! -d "$gate_root/.claude/hooks" ]; then
  printf 'lint-hook-cwd-relative-loads: cannot resolve this gate own repository root from %s, so no file was scanned\n' \
    "${BASH_SOURCE[0]}" >&2
  exit 2
fi

# The scan surface, from the index rather than from a filesystem walk, so an
# untracked build artifact or a live worktree under .claude/worktrees/ cannot
# enter the set. NUL-delimited, so a path carrying whitespace or a non-ASCII
# byte stays one element rather than arriving C-quoted.
#
# Written to a temp file FIRST, and the discovery's status read there, because a
# discovery that FAILED must be distinguishable from one that found nothing. Two
# shapes cannot do that and both look like they can: `while read; done < <(git
# ...)` reports the LOOP's status, so a git failure inside the process
# substitution is invisible, and a command substitution silently drops the NUL
# bytes that are the whole point of `-z`, which turns a healthy listing into an
# empty one. Either way the gate would fall through to the surface floor below
# and blame the tree for a git that never answered.
#
# The pathspec is one pattern rather than two, because a git pathspec `*`
# already spans `/`, so `.claude/hooks/*.sh` reaches the shared libraries under
# `lib/` as well as the top level. A second `**` pattern would only add
# duplicate entries.
surface_file="$(mktemp -t lint-hook-cwd-relative-loads.XXXXXX)" || {
  printf 'lint-hook-cwd-relative-loads: cannot create a scratch file for the discovery, so no file was scanned\n' >&2
  exit 2
}
# One arm per disposition: a handler shared between EXIT and a terminating
# signal returns and lets the script carry on, which deletes the disposition it
# replaced.
trap 'rm -f -- "$surface_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! git -C "$gate_root" ls-files -z -- '.claude/hooks/*.sh' >"$surface_file" 2>/dev/null; then
  printf 'lint-hook-cwd-relative-loads: the tracked-file discovery failed, so no file was scanned\n' >&2
  exit 2
fi

files=()
while IFS= read -r -d '' script_path; do
  files+=("$script_path")
done <"$surface_file"

# An empty or short surface reads exactly like a clean pass, so it is a hard
# error instead. The floor is a lower bound on a directory that holds dozens of
# registered hooks plus their shared libraries, not a count of them: it exists
# to catch a discovery that silently collapsed (a wrong pathspec, a run from
# outside the repository), and it is deliberately far below the real size so
# that deleting a hook never reds this gate.
readonly SURFACE_FLOOR=10
if [ "${#files[@]}" -lt "$SURFACE_FLOOR" ]; then
  printf 'lint-hook-cwd-relative-loads: ERROR: the scan surface holds %d file(s), fewer than the floor of %d; the discovery did not read .claude/hooks/ (run this from the repository root)\n' \
    "${#files[@]}" "$SURFACE_FLOOR" >&2
  exit 1
fi

# The class detector. Single-quoted, so every literal single quote inside is
# spelled `\047` and no comment in it may carry an apostrophe.
#
# Three context trackers run ahead of the match arms, because the same byte
# sequence is code in one place and prose in another, and this tree carries both
# forms. Each tracker only ever SUPPRESSES a match, so a tracker that loses its
# place costs a missed defect rather than a false report on correct code.
readonly OWN_AWK='
    # code_prefix(shell_line): the part of the line before an unquoted `#` comment
    # word, with single-quoted and double-quoted spans left in place. Used both
    # to feed the match arms and to advance the multi-line string tracker, so a
    # comment cannot open a string span that swallows the rest of the file.
    function code_prefix(shell_line,   i, character, in_single_quote, in_double_quote, previous_character) {
      in_single_quote = 0
      in_double_quote = 0
      for (i = 1; i <= length(shell_line); i++) {
        character = substr(shell_line, i, 1)
        if (character == "\\") { i++; continue }
        if (in_single_quote) { if (character == "\047") in_single_quote = 0; continue }
        if (in_double_quote) { if (character == "\"") in_double_quote = 0; continue }
        if (character == "\047") { in_single_quote = 1; continue }
        if (character == "\"") { in_double_quote = 1; continue }
        # A `#` starts a comment word only at the start of the line or after
        # whitespace. Anywhere else it is a parameter-expansion operator
        # (`${x#y}`) or part of a word, and cutting there would truncate code.
        if (character == "#") {
          previous_character = (i > 1) ? substr(shell_line, i - 1, 1) : " "
          if (previous_character ~ /[[:space:]]/) return substr(shell_line, 1, i - 1)
        }
      }
      return shell_line
    }

    # advance_double_quote_tracker(shell_line): toggle the file-level double-quote tracker across a line of
    # code, so a string opened on one line and closed on a later one is known to
    # be open in between. Escapes and single-quoted spans are honored; anything
    # else is ignored.
    function advance_double_quote_tracker(shell_line,   i, character, in_single_quote) {
      in_single_quote = 0
      for (i = 1; i <= length(shell_line); i++) {
        character = substr(shell_line, i, 1)
        if (character == "\\") { i++; continue }
        if (in_multiline_double_quote) { if (character == "\"") in_multiline_double_quote = 0; continue }
        if (in_single_quote) { if (character == "\047") in_single_quote = 0; continue }
        if (character == "\047") { in_single_quote = 1; continue }
        if (character == "\"") { in_multiline_double_quote = 1 }
      }
    }

    # heredoc_delimiter(shell_line): the delimiter word a heredoc opener on this line
    # introduces, or the empty string when the line opens none. A `<<<` herestring
    # opens no body and is excluded by the negative lookahead the two patterns
    # spell out longhand, awk having none.
    function heredoc_delimiter(shell_line,   opener_tail, delimiter_word) {
      if (shell_line !~ /<<-?[[:space:]]*[A-Za-z_\047"]/) return ""
      if (shell_line ~ /<<</) return ""
      opener_tail = shell_line
      sub(/^.*<<-?[[:space:]]*/, "", opener_tail)
      delimiter_word = opener_tail
      sub(/[^A-Za-z0-9_].*$/, "", delimiter_word)
      if (delimiter_word == "") {
        # A quoted delimiter (`<<\047EOF\047`, `<<"EOF"`) disables expansion in
        # the body but names the same word.
        delimiter_word = opener_tail
        sub(/^[\047"]/, "", delimiter_word)
        sub(/[^A-Za-z0-9_].*$/, "", delimiter_word)
      }
      return delimiter_word
    }

    # bare_operand(shell_line, pattern): 1 when `pattern` is followed by a repository-root-
    # relative LITERAL. The distinction this gate enforces is literal versus
    # variable-rooted, NOT quoted versus unquoted: `[ -f ".claude/x.sh" ]` is
    # the same defect as its unquoted spelling, while `[ -f "$_library_directory/x.sh" ]`
    # is the repair. So every arm admits an optional surrounding quote and then
    # requires a literal dot, which a variable-rooted path can never satisfy
    # because a `$` stands where that dot would be.
    function bare_operand(shell_line, pattern) {
      return (shell_line ~ pattern)
    }

    BEGIN {
      # `[\"\047]?` is the optional opening quote, double or single. It sits
      # before the literal dot in all three arms, so the quoted and unquoted
      # spellings of one defect are read the same way.
      # Pinned to a code extension, the same set ASSIGN_PATTERN requires and for the
      # same reason: without the pin this arm also matches a per-tree STATE path
      # (`[ -f .claude/example-session-marker ]`) and hands it the
      # `${BASH_SOURCE[0]}` remedy, which is the root the header above rules out
      # for state, because a `main-only` marker rooted at the directory of the
      # script follows a linked worktree. A gate cannot hand out the defect it
      # exists to prevent, so this arm gives up the operands it cannot tell
      # apart. What that costs is written under KNOWN BLIND SPOTS above.
      # The optional `(![[:space:]]+)?` admits an in-bracket negation, so
      # `[ ! -f <library> ] && exit 0` is read as the same defect as its unnegated
      # twin. That spelling is the idiomatic capability-probe stand-down this
      # gate exists to prevent, and the negation displaces the test primary, so
      # without it the arm matched nothing at all. It sits ahead of the primary
      # and changes nothing after it, so the code-extension pin still decides
      # which operands the arm gives up: a negated state path stays as quiet as
      # its unnegated spelling.
      TEST_PATTERN   = "(\\[|\\[\\[)[[:space:]]+(![[:space:]]+)?-[a-zA-Z][[:space:]]+[\"\047]?\\.(claude|gaia)/[^\"\047[:space:]]*\\.(sh|bash|mjs|cjs|js|py)[\"\047]?([[:space:]]|;|$)"
      # The `^[[:space:]]*` branch is what reaches an INDENTED load, which is
      # the idiomatic spelling of this class: a `.` on its own line inside an
      # `if`/`while`/`case` body. A bare `^` would require the operator at
      # column 1, and the other branches all demand a separator token, so the
      # arm would be blind to every load nested one level deep. The sibling
      # patterns are unanchored and never had the gap.
      SOURCE_PATTERN = "(^[[:space:]]*|[;&|(){}][[:space:]]*|&&[[:space:]]*|\\|\\|[[:space:]]*|then[[:space:]]+|do[[:space:]]+|else[[:space:]]+)(\\.|source)[[:space:]]+[\"\047]?\\.(claude|gaia)/"
      RUN_PATTERN    = "(bash|sh|zsh|node|python3?|awk[[:space:]]+-f|\\}\")[[:space:]]+(-[A-Za-z][[:space:]]+)?[\"\047]?\\.(claude|gaia)/"
      ASSIGN_PATTERN = "=[[:space:]]*\"?\\.(claude|gaia)/[^\"[:space:]]*\\.(sh|bash|mjs|cjs|js|py)\"?([[:space:]]|;|$)"
      in_multiline_double_quote = 0
      open_heredoc_delimiter = ""
    }

    FNR == 1 { in_multiline_double_quote = 0; open_heredoc_delimiter = "" }

    # A heredoc body is data. It is skipped whole, and it cannot advance either
    # of the other trackers, which is why this arm comes first.
    open_heredoc_delimiter != "" {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if ($0 == open_heredoc_delimiter || line == open_heredoc_delimiter) open_heredoc_delimiter = ""
      next
    }

    # Inside a string opened on an earlier line: prose, not code. The tracker
    # still has to advance across it to find the closing quote.
    in_multiline_double_quote {
      advance_double_quote_tracker($0)
      next
    }

    # A full-line comment carries neither code nor string state.
    /^[[:space:]]*#/ { next }

    {
      code = code_prefix($0)

      if (bare_operand(code, TEST_PATTERN))
        printf "%s:%d: a file-test operand names a bare repo-relative path, so it resolves against the process working directory: root it at ${BASH_SOURCE[0]} instead\n", file, FNR
      else if (bare_operand(code, SOURCE_PATTERN))
        printf "%s:%d: a source operand names a bare repo-relative path, so a working directory below the repository root loads nothing and the capability probe behind it reads that as a missing library: root it at ${BASH_SOURCE[0]} instead\n", file, FNR
      else if (bare_operand(code, RUN_PATTERN) && code !~ /(^|[[:space:]&|;(])cd[[:space:]]/)
        printf "%s:%d: an interpreter argument names a bare repo-relative path, so it resolves against the process working directory: root it at ${BASH_SOURCE[0]}, or cd to the intended tree first\n", file, FNR
      else if (bare_operand(code, ASSIGN_PATTERN))
        printf "%s:%d: this assignment names a bare repo-relative path to a code file, so wherever it is later tested or run it resolves against the process working directory: root it at ${BASH_SOURCE[0]} instead\n", file, FNR

      # Advance the string tracker last, over the code part only, so a match on
      # this line is decided before the line can change the context.
      advance_double_quote_tracker(code)
      open_heredoc_delimiter = heredoc_delimiter(code)
    }
'

report=""
# The offset guard `${a[@]+"${a[@]}"}` rather than a bare `"${files[@]}"`: on
# stock macOS /bin/bash 3.2 a bare expansion of an empty array aborts under
# `set -u`. The floor check above already returns on an empty set, so this is
# belt-and-braces against a later edit moving the loop ahead of it.
for script_path in ${files[@]+"${files[@]}"}; do
  # `$script_path` stays repo-relative, because that is what a report has to print; the
  # read is rooted at $gate_root, so it does not depend on the cwd either.
  [ -f "$gate_root/$script_path" ] || continue
  # awk's status is READ, not discarded. Swallowing it would let a file awk
  # cannot open or parse count as clean, which is the same "reports clean over
  # input it never read" failure the surface floor above refuses on; leaving it
  # only here would put the whole guard's remaining blind spot in the one place
  # the floor cannot see.
  if ! hits=$(awk -v file="$script_path" "$OWN_AWK" "$gate_root/$script_path"); then
    printf 'lint-hook-cwd-relative-loads: ERROR: awk could not scan %s, so this file was not checked\n' "$script_path" >&2
    exit 2
  fi
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # printf, not echo: the format string is single-quoted so the sample code
  # inside stays literal -- it is being printed, not run.
  # shellcheck disable=SC2016
  printf 'Fix by deriving the directory from the hook file itself, never from the working directory:\n    _library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _library_directory=%s%s\n    [ -n "$_library_directory" ] && [ -f "$_library_directory/x.sh" ] && . "$_library_directory/x.sh"\n' \
    "'" "'" >&2
  exit 1
fi

echo "lint-hook-cwd-relative-loads: clean" >&2
exit 0
