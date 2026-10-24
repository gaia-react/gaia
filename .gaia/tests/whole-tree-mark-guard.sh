#!/usr/bin/env bash
# whole-tree-mark-guard.sh: flag a bats test that enumerates the tracked tree
# without carrying the whole-tree mark.
#
# A test is whole-tree when its outcome depends on tracked files it does not
# name. The change selector (.gaia/scripts/bats-suites-for-change.sh) picks a
# suite only when the suite names a changed file, so a whole-tree test is never
# picked by it. The mark makes the verification runner's branch whole-tree step
# run the test. It comes in two bats-native spellings: a test tag on the line
# above one `@test` marks that test, a file tag before the first `@test` marks
# every test in the suite. The canonical patterns the runner discovers are the
# verify_whole_tree_*_mark_pattern variables in
# .gaia/tests/helpers/verify-harness-bats-lib.sh, read from there, never
# restated here.
#
# Recognized idioms and calls (the ONLY ones this guard recognizes). First the
# suite's real-root variables are collected: a variable assigned from an expression
# containing $BATS_TEST_DIRNAME or $BATS_TEST_FILENAME, plus any variable whose
# assignment expression contains one already collected, repeated until no new
# variable joins. Then a statement, outside comments and outside the fixture
# data the shared scan library (.gaia/scripts/guard-awk-lib.sh) recognizes, is a
# hit when a real-root variable is the operand of:
#   1. git -C <root> ... ls-files   or   git -C <root> ... grep
#   2. find <root>   or   find <root>/<dir>
#   3. a glob loop: for <name> in <root>/<path>*...
# A backslash-continued statement is read joined, and its hit sits on its first
# physical line. A root that is a $BATS_TEST_TMPDIR-based or other fixture path
# is never a real root, so a fixture repository is never flagged. Neither is a
# root assigned from a path with a `fixtures` segment, nor a find or glob-loop
# operand under one: committed fixtures are the suite's own inputs, edited
# beside it, not the tracked tree it checks.
# An ls-files call is not enumeration when it uses --error-unmatch (a
# membership test) or when every operand is a literal path below the root that
# is not a tracked directory: it names those paths, so the change selector
# picks the suite when one changes. A glob, a magic pathspec, a variable, a
# tracked directory or a root-level operand still counts: the selector matches
# a root-level file as `/<name>`, which a bare operand never contains.
#
# A test also reaches the tree through a call that scans it. A real-root
# variable is read as the root itself when it expands to the scanned root (a
# path below it is a file the suite names). Each of these is a hit:
#   5. <root>, exactly, as an argument (`"$ROOT"`, `--root "$ROOT"`,
#      `-C "$ROOT"`) of a script run through bash, sh or as the command word.
#      cd, git, a test operator, an assignment, a file-building command or any
#      other command that is neither a script nor a function is no hop.
#   6. A script run in a statement that first changes into <root>, a
#      `bash -c` string included.
#   7. A tracked script, named through a real-root variable, run with no
#      argument, when the guard reads that script from the scanned root and
#      finds that it climbs to its own root (from its location, or through
#      `git rev-parse --show-toplevel`) and enumerates (ls-files, git grep,
#      find, a glob loop). A script that builds a temporary repository is a
#      fixture builder, not a scan.
#   8. <root> handed to a function the suite defines or a tracked file it
#      sources defines (by a literal or root-relative path, bats load, or a
#      file that one sources in turn), when the function applies an idiom,
#      hop 5 or 6 to that parameter, reads a file under it whose name is a
#      variable, or hands it on to a function that does. A function whose
#      definition the guard cannot read is a hit: fail closed.
#   9. A call to a suite function that prints a path under <root> whose last
#      segment is a parameter plus a literal suffix: the caller passes a name
#      the change selector cannot match to the file it reads.
# A call is not a hop when its statement points it at a fixture tree (an
# argument, a change of directory or an environment assignment naming a
# temp-directory path, a fixtures path, mktemp, or the output of a script or
# function that builds a temporary repository), when an earlier line of the
# same test or of setup reassigns the root variable to a fixture, or, for a
# no-argument script, when an earlier line of the same test or setup changes
# into or exports a fixture tree. A word that names a file (an extension on
# its last segment) or a PATH list is not a tree.
#
# Every hit is attributed to its scope, and the scan runs past the first one:
#   - Inside a `@test` body, that test needs the test mark, or the suite needs
#     the file mark. The finding names the test.
#   - Outside every test body (setup, setup_file, a helper, top level), the
#     suite needs the file mark, or every test in it marked, or a waiver on the
#     comment line(s) directly above the statement's first line, written as
#     `# gaia-lint-ignore whole-tree-mark-guard: <reason>`. A waiver above an
#     in-body hit is honored too.
# A waiver has two allowed reasons: every test that depends on the idiom
# carries the test mark, or the operand is not the tracked tree. The one
# recorded exception is the pre-push end-to-end suite's setup_file waiver,
# whose reason records the decision to keep that suite out of the whole-tree
# step because it duplicates coverage the step already runs. This guard does
# not read the reason: the shell-lint owner guard
# (.gaia/scripts/lint-git-path-quoting.sh) reports a waiver with no reason as
# malformed, and review, not this guard, checks that the reason is true. A
# waiver above a statement that holds no hit waives nothing and is reported as
# unused.
#
# Mark spelling and placement are checked against what bats itself applies (a
# comment line bats reads as a tag command, a test tag applying to the next
# `@test` and replaced by a later test tag before it, a file tag applying to
# every later test and replaced by a later file tag). Each of these is
# reported with its line, whatever the hits: a tag line bats honors as
# carrying whole-tree that the canonical pattern misses (the runner never
# discovers it), a canonical line whose tag list bats rejects, a file mark
# after the first `@test`, a file mark replaced by a later file tag line, a
# test mark replaced by a later test tag line before its `@test`, and a test
# mark with no `@test` after it.
#
# Residual limit: a test reaching the tracked tree through
# a path this guard cannot see is outside its claim, for example a script
# given a path below the root that it walks, a root assembled at run time, a
# helper reached through a variable command word, or a library sourced through
# a path built from values the guard cannot expand.
# The full run on push to main backstops it.
# An idiom or call inside a helper is an outside-body hit whichever tests
# call the helper. The reach of each call is bounded by the shapes above, so
# a suite calling a tracked script against a fixture tree it points the call
# at is not flagged.
#
# Maintainer-only: .gaia/tests is release-excluded wholesale.
#
# Usage:
#   bash .gaia/tests/whole-tree-mark-guard.sh [--root <repo>] [<suite>...]
# With no suite operands every tracked *.bats under the root is scanned.
# Exit: 0 no finding; 1 one or more found; 2 usage error, an empty discovery
# set (a guard over nothing is not clean), or a scan that could not run.

set -u

usage() {
  echo "usage: whole-tree-mark-guard.sh [--root <repo>] [<suite>...]" >&2
}

root=""
suites=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      root="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      suites+=("$1")
      shift
      ;;
  esac
done

# Script-relative, never cwd-relative: every fixture test runs this guard from
# a throwaway directory. The shared scan library lives in .gaia/scripts, one
# directory over; its pragma token resolution also tries .gaia/tests, where
# this guard lives.
_gaia_guard_script_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_script_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_script_directory="."; fi
_gaia_guard_library_directory="$_gaia_guard_script_directory/../scripts"
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
[ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null
type gaia_guard_bats_files >/dev/null 2>&1 || {
  echo "whole-tree-mark-guard: guard-awk-lib.sh is missing from $_gaia_guard_library_directory" >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    echo "whole-tree-mark-guard: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present" >&2
    exit 2
    ;;
  6)
    echo "whole-tree-mark-guard: GAIA_AWK resolved to an unsanctioned interpreter ($GAIA_AWK_IDENTITY); the sanctioned set is mawk and BWK one-true-awk" >&2
    exit 2
    ;;
esac

# shellcheck source=.gaia/tests/helpers/verify-harness-bats-lib.sh
. "$_gaia_guard_script_directory/helpers/verify-harness-bats-lib.sh" 2>/dev/null
if [ -z "${verify_whole_tree_file_mark_pattern:-}" ] || [ -z "${verify_whole_tree_test_mark_pattern:-}" ]; then
  echo "whole-tree-mark-guard: the mark patterns did not load from $_gaia_guard_script_directory/helpers/verify-harness-bats-lib.sh" >&2
  exit 2
fi

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "whole-tree-mark-guard: not inside a git repository; pass --root <repo>" >&2
    exit 2
  }
fi

scan_paths=()
if [ "${#suites[@]}" -gt 0 ]; then
  scan_paths=(${suites[@]+"${suites[@]}"})
else
  while IFS= read -r -d '' tracked_suite; do
    scan_paths+=("$root/$tracked_suite")
  done < <(git -C "$root" ls-files -z '*.bats' 2>/dev/null)
fi

if [ "${#scan_paths[@]}" -eq 0 ]; then
  echo "whole-tree-mark-guard: no tracked *.bats suite found under $root; a guard over nothing is not clean" >&2
  exit 2
fi

# The detector, concatenated after $GAIA_GUARD_AWK and run once per suite with
# the suite named twice. Pass 1 feeds the library prepass and joins logical
# lines to find every hit; pass 2 feeds the library line by line, so scope and
# waivers are read on the physical line each hit starts on, the only line its
# waiver block is active for. Exit 0 clean, 1 findings printed.
# shellcheck disable=SC2016
readonly OWN_AWK='
    function is_comment(text) { return text ~ /^[ \t]*#/ }
    function refers(text, name) {
      return text ~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")
    }
    function names_only(rest,   tail, token_count, tokens, t, token, operand_count) {
      if (rest ~ /(^|[ \t])--error-unmatch([ \t]|$)/) { return 1 }
      tail = rest
      sub(/^.*(^|[ \t])ls-files([ \t]|$)/, "", tail)
      if (match(tail, /[|)<>;&]/)) { tail = substr(tail, 1, RSTART - 1) }
      operand_count = 0
      token_count = split(tail, tokens, /[ \t]+/)
      for (t = 1; t <= token_count; t++) {
        token = tokens[t]
        gsub(/["\047]/, "", token)
        if (token == "" || token ~ /^-/) { continue }
        if (token ~ /[$*?[]/ || token ~ /^:/ || token ~ /\/$/ || token !~ /\// || (token in is_directory)) { return 0 }
        operand_count++
      }
      return operand_count > 0
    }

    # Pass 1: one physical line into the logical-line store, joining a
    # backslash continuation onto the line it continues.
    function collect_line(raw) {
      if (pending == "") { pending_start = FNR }
      if (raw ~ /\\[ \t]*$/ && !is_comment(raw)) {
        sub(/\\[ \t]*$/, " ", raw)
        pending = pending raw
        return
      }
      logical_count++
      logical_text[logical_count] = pending raw
      logical_start[logical_count] = pending_start
      pending = ""
    }

    # The idiom one real root is the operand of on one logical line, as a
    # priority (1 git listing, 2 git grep, 3 find, 4 glob loop) so the verdict
    # does not depend on the order awk walks the root set in; 0 for none.
    function idiom_priority(text, name,   git_call, rest, find_call, fixture_find, loop_call, fixture_loop) {
      if (text !~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")) { return 0 }
      git_call = "git[ \t]+(.*[ \t])?-C[ \t]+\"?" "\\$\\{?" name "([^A-Za-z0-9_]|$)"
      if (match(text, git_call)) {
        rest = substr(text, RSTART + RLENGTH)
        if (rest ~ /(^|[ \t])ls-files([ \t]|$)/ && names_only(rest)) { return 0 }
        if (rest ~ /(^|[ \t])ls-files([ \t]|$)/) { return 1 }
        if (rest ~ /(^|[ \t])grep([ \t]|$)/) { return 2 }
      }
      find_call = "(^|[^A-Za-z0-9_-])find[ \t]+\"?\\$\\{?" name "([^A-Za-z0-9_]|$)"
      fixture_find = "find[ \t]+\"?\\$\\{?" name "\\}?/([^ \t\"]*/)?fixtures([/\" \t]|$)"
      if (text ~ find_call && text !~ fixture_find) { return 3 }
      loop_call = "(^|[^A-Za-z0-9_])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+[^;]*\"?\\$\\{?" name "\\}?\"?[^ \t;]*\\*"
      fixture_loop = "in[ \t]+\"?\\$\\{?" name "\\}?\"?/([^ \t;\"]*/)?fixtures/"
      if (text ~ loop_call && text !~ fixture_loop) { return 4 }
      return 0
    }

    # ---- calls that reach the tracked tree ---------------------------------

    function normalize_path(path,   part_count, parts, i, kept, kept_count, result) {
      if (path == FAILED) { return FAILED }
      part_count = split(path, parts, "/")
      kept_count = 0
      for (i = 1; i <= part_count; i++) {
        if (parts[i] == "" || parts[i] == ".") { continue }
        if (parts[i] == "..") {
          if (kept_count == 0) { return FAILED }
          kept_count--
          continue
        }
        kept[++kept_count] = parts[i]
      }
      result = ""
      for (i = 1; i <= kept_count; i++) { result = result (i > 1 ? "/" : "") kept[i] }
      return result
    }
    function parent_of(path) {
      if (path == FAILED || path == "") { return FAILED }
      if (index(path, "/") == 0) { return "" }
      sub(/\/[^\/]*$/, "", path)
      return path
    }
    function joined_path(base, rest) {
      if (base == FAILED) { return FAILED }
      if (rest == "") { return base }
      if (rest !~ /^\// || rest ~ /[$*?`]/) { return FAILED }
      return normalize_path(base rest)
    }

    # The repository-relative path a suite expression names, expanded the way
    # the shell would from the suite location: the rooting shapes only
    # ($BATS_TEST_DIRNAME, $BATS_TEST_FILENAME, a variable assigned in the
    # suite, `$(cd X && pwd)`, `$(dirname X)`, `$(git ... --show-toplevel)`),
    # each followed by a literal tail. FAILED for anything else, and for every
    # shape when the suite sits outside the scanned root.
    function evaluated_path(expression, depth,   level, i, character, inner, rest, base, name) {
      if (depth > 8) { return FAILED }
      gsub(/["\047]/, "", expression)
      sub(/^[ \t]+/, "", expression)
      sub(/[ \t]+$/, "", expression)
      if (substr(expression, 1, 2) == "$(") {
        level = 0
        for (i = 2; i <= length(expression); i++) {
          character = substr(expression, i, 1)
          if (character == "(") { level++ } else if (character == ")") { level--; if (level == 0) { break } }
        }
        if (level != 0) { return FAILED }
        inner = substr(expression, 3, i - 3)
        rest = substr(expression, i + 1)
        sub(/^[ \t]+/, "", inner)
        sub(/[ \t]+$/, "", inner)
        if (inner ~ /^cd[ \t]/ && match(inner, /&&[ \t]*pwd([ \t]+-P)?$/)) {
          inner = substr(inner, 1, RSTART - 1)
          sub(/^cd[ \t]+(--[ \t]+)?(-P[ \t]+)?/, "", inner)
          base = evaluated_path(inner, depth + 1)
        } else if (inner ~ /^dirname[ \t]/) {
          sub(/^dirname[ \t]+(--[ \t]+)?/, "", inner)
          base = parent_of(evaluated_path(inner, depth + 1))
        } else if (inner ~ /rev-parse[ \t]+--show-toplevel$/) {
          base = ""
        } else {
          return FAILED
        }
        return joined_path(base, rest)
      }
      # ${NAME:-default}: the default, the value a suite run without the
      # override sees.
      if (match(expression, /^\$\{[A-Za-z_][A-Za-z0-9_]*:?-/)) {
        level = 0
        for (i = 2; i <= length(expression); i++) {
          character = substr(expression, i, 1)
          if (character == "{") { level++ } else if (character == "}") { level--; if (level == 0) { break } }
        }
        if (level != 0) { return FAILED }
        inner = substr(expression, RLENGTH + 1, i - RLENGTH - 1)
        return joined_path(evaluated_path(inner, depth + 1), substr(expression, i + 1))
      }
      if (!match(expression, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) { return FAILED }
      name = substr(expression, RSTART, RLENGTH)
      rest = substr(expression, RLENGTH + 1)
      gsub(/[${}]/, "", name)
      if (name == "BATS_TEST_DIRNAME") { base = suite_known ? suite_directory : FAILED }
      else if (name == "BATS_TEST_FILENAME") { base = suite_known ? suite_relative : FAILED }
      else if (name in first_value) { base = evaluated_path(first_value[name], depth + 1) }
      else { return FAILED }
      return joined_path(base, rest)
    }

    # The literal text after the last expansion in an expression: the part a
    # path keeps however its variables expand. Empty when the tail is itself
    # computed.
    function literal_tail(expression,   rest) {
      gsub(/["\047\\]/, "", expression)
      sub(/[ \t]+$/, "", expression)
      rest = expression
      while (match(rest, /\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\)/)) { rest = substr(rest, RSTART + RLENGTH) }
      if (rest ~ /[$*?` \t(]/) { return "" }
      return rest
    }

    function load_tracked(   path) {
      if (tracked_loaded) { return }
      tracked_loaded = 1
      tracked_count = 0
      while ((getline path < tracked_list) > 0) { is_tracked[path] = 1; tracked_order[++tracked_count] = path }
      close(tracked_list)
    }

    # Fills resolved[1..resolved_count] with the tracked files an expression
    # can name: its exact expansion when the rooting shapes give one, else its
    # literal tail read from the directory it is written in and each directory
    # above, else every tracked file ending in that tail.
    function resolve_paths(expression, from_directory, as_load,   path, tail, stripped, directory, candidate, p, suffix_length) {
      load_tracked()
      resolved_count = 0
      if (expression ~ /^["\047]?\$/) {
        path = evaluated_path(expression, 0)
        if (path != FAILED && (path in is_tracked)) { resolved[++resolved_count] = path; return resolved_count }
        if (as_load && path != FAILED && ((path ".bash") in is_tracked)) { resolved[++resolved_count] = path ".bash"; return resolved_count }
      }
      # A path held in a suite variable reads through to the value of that variable.
      gsub(/["\047]/, "", expression)
      for (p = 0; p < 5 && match(expression, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/); p++) {
        candidate = substr(expression, RSTART, RLENGTH)
        gsub(/[${}]/, "", candidate)
        if (!(candidate in first_value)) { break }
        stripped = first_value[candidate]
        gsub(/["\047]/, "", stripped)
        expression = stripped substr(expression, RLENGTH + 1)
      }
      tail = literal_tail(expression)
      if (tail == "") { return 0 }
      directory = from_directory
      while (directory != FAILED) {
        candidate = normalize_path(directory "/" tail)
        if (candidate != FAILED && (candidate in is_tracked)) { resolved[++resolved_count] = candidate; return resolved_count }
        if (as_load && candidate != FAILED && ((candidate ".bash") in is_tracked)) { resolved[++resolved_count] = candidate ".bash"; return resolved_count }
        directory = parent_of(directory)
      }
      stripped = tail
      while (sub(/^(\.\.?\/|\/)/, "", stripped)) { }
      if (stripped == "") { return 0 }
      suffix_length = length(stripped) + 1
      for (p = 1; p <= tracked_count; p++) {
        path = tracked_order[p]
        if (path == stripped || (length(path) > suffix_length && substr(path, length(path) - suffix_length + 1) == "/" stripped)) {
          resolved[++resolved_count] = path
        }
      }
      return resolved_count
    }

    # 1 when the tracked script finds its own root without an argument and
    # enumerates the tree from it.
    # A script that makes a temporary repository builds a fixture tree, so
    # calling it is not a scan of the real one.
    function scans_own_tree(path,   line, own_root, enumerates, file_path, temporary, initializes) {
      if (path in scans_cache) { return scans_cache[path] }
      own_root = 0
      enumerates = 0
      temporary = 0
      initializes = 0
      file_path = root "/" path
      while ((getline line < file_path) > 0) {
        if (line ~ /^[ \t]*#/) { continue }
        # Its own root: an assignment that climbs from its own location or
        # asks git for the top level, not a library sourced beside it.
        if (line ~ /[A-Za-z_][A-Za-z0-9_]*=/ && (line ~ /--show-toplevel/ \
            || (line ~ /BASH_SOURCE|dirname[ \t]+(--[ \t]+)?["\047]?\$\{?0|\$\{0%/ && line ~ /\/\.\./))) { own_root = 1 }
        if (line ~ /git[ \t].*[ \t]ls-files([ \t]|$)|git[ \t].*[ \t]grep([ \t]|$)|(^|[^A-Za-z0-9_.-])find[ \t]+[^ \t-]|(^|[^A-Za-z0-9_])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t][^;]*\*/) { enumerates = 1 }
        if (line ~ /mktemp/) { temporary = 1 }
        if (line ~ /(^|[^A-Za-z0-9_-])git[ \t]+(.*[ \t])?init([ \t]|$)/) { initializes = 1 }
      }
      close(file_path)
      builds_fixture_cache[path] = (temporary && initializes)
      scans_cache[path] = (own_root && enumerates && !builds_fixture_cache[path])
      return scans_cache[path]
    }

    # Function definitions, from the suite and from every tracked file it
    # sources (by a literal or root-relative path, or bats load), followed into
    # the files those source in turn. A definition the suite makes wins.
    function read_functions(file_path, directory, is_suite, depth,   line, in_body, body, function_name, indent, rest, definition, heredoc_end, heredoc_dash, operand, queue_count, queue, q, r, closing, heredoc_text) {
      if (depth > 3 || (file_path in functions_read)) { return }
      functions_read[file_path] = 1
      in_body = 0
      heredoc_end = ""
      queue_count = 0
      while ((getline line < file_path) > 0) {
        sub(/\r$/, "", line)
        if (heredoc_end != "") {
          heredoc_text = line
          if (heredoc_dash) { sub(/^\t+/, "", heredoc_text) }
          if (heredoc_text == heredoc_end) { heredoc_end = "" }
          if (in_body) { body = body line "\n" }
          continue
        }
        if (line !~ /^[ \t]*#/) {
          heredoc_end = heredoc_word(line)
          heredoc_dash = heredoc_word_dash
          if (match(line, (is_suite ? "(^|&&|;|\\$\\(|\\()[ \t]*(source|\\.|load)[ \t]+[^ \t;&|)]+" : "(^|&&|;|\\$\\(|\\()[ \t]*(source|\\.)[ \t]+[^ \t;&|)]+"))) {
            operand = substr(line, RSTART, RLENGTH)
            sub(/^.*(source|\.|load)[ \t]+/, "", operand)
            if (operand != "" && operand != ".") {
              resolve_paths(operand, directory, is_suite && line ~ /(^|[ \t;&])load[ \t]/)
              for (r = 1; r <= resolved_count; r++) { queue[++queue_count] = resolved[r] }
            }
          }
        }
        if (in_body) {
          if (line ~ ("^" indent closing "[ \t]*$")) {
            if (!(function_name in function_body)) { function_body[function_name] = body; function_suite[function_name] = is_suite }
            in_body = 0
          } else {
            body = body line "\n"
          }
          continue
        }
        if (line ~ /^[ \t]*#/) { continue }
        if (match(line, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/) || (line ~ /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*(\{|$)/ && match(line, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*/))) {
          definition = substr(line, RSTART, RLENGTH)
          rest = substr(line, RSTART + RLENGTH)
          indent = definition
          sub(/[^ \t].*$/, "", indent)
          function_name = definition
          sub(/^[ \t]*(function[ \t]+)?/, "", function_name)
          sub(/[ \t]*\(\)$/, "", function_name)
          closing = (rest ~ /^[ \t]*\(/) ? ")" : "}"
          if (rest ~ /[{(]/ && rest ~ /[})][ \t]*(;[ \t]*)?$/ && rest !~ /^[ \t]*[{(][ \t]*$/) {
            if (!(function_name in function_body)) { function_body[function_name] = rest "\n"; function_suite[function_name] = is_suite }
          } else {
            in_body = 1
            body = ""
          }
        }
      }
      close(file_path)
      for (q = 1; q <= queue_count; q++) { read_functions(root "/" queue[q], parent_of(queue[q]), 0, depth + 1) }
    }

    # The delimiter of a heredoc this line opens, or empty; sets
    # heredoc_word_dash for the <<- form. A << inside a quoted literal (a
    # fixture line) opens nothing.
    function heredoc_word(text,   stripped, word, before, single_count, double_count) {
      heredoc_word_dash = 0
      stripped = text
      gsub(/<<</, "", stripped)
      if (!match(stripped, /<<-?[ \t]*\\?["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) { return "" }
      before = substr(stripped, 1, RSTART - 1)
      single_count = gsub(/\047/, "", before)
      double_count = gsub(/"/, "", before)
      if (single_count % 2 || double_count % 2) { return "" }
      word = substr(stripped, RSTART, RLENGTH)
      if (word ~ /^<<-/) { heredoc_word_dash = 1 }
      sub(/^<<-?[ \t]*/, "", word)
      gsub(/["\047\\]/, "", word)
      return word
    }

    # 1 when the variable holds the scanned root itself, not a path below it.
    # Read from the expansion when the rooting shapes give one; otherwise (a
    # suite outside the scanned root) from the shape alone: a `cd ... && pwd`
    # or `--show-toplevel` capture, or a variable followed only by `..` steps.
    function names_root(name,   path, value) {
      if (name in root_cache) { return root_cache[name] }
      root_cache[name] = 0
      if (!(name in first_value)) { return 0 }
      value = first_value[name]
      path = evaluated_path(value, 0)
      if (path != FAILED) {
        root_cache[name] = (path == "")
      } else {
        gsub(/["\047]/, "", value)
        sub(/[ \t]+$/, "", value)
        root_cache[name] = (value ~ /(&&[ \t]*pwd([ \t]+-P)?|--show-toplevel)[ \t]*\)$/ \
          || value ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\/\.\.)+\/?$/)
      }
      return root_cache[name]
    }

    # The text with every single-quoted literal outside double quotes blanked:
    # the shell expands nothing inside one, so no separator or variable there
    # belongs to the statement.
    function masked_single_quotes(text,   result, i, character, in_double, in_single) {
      result = ""
      in_double = 0
      in_single = 0
      for (i = 1; i <= length(text); i++) {
        character = substr(text, i, 1)
        if (in_single) {
          if (character == "\047") { in_single = 0; result = result character } else { result = result "_" }
          continue
        }
        if (character == "\\" && i < length(text)) { result = result character substr(text, i + 1, 1); i++; continue }
        if (character == "\"") { in_double = !in_double }
        if (character == "\047" && !in_double) { in_single = 1 }
        result = result character
      }
      return result
    }

    function fixture_expression(value,   command, r) {
      if (value ~ /\$\{?(BATS_TEST_TMPDIR|BATS_FILE_TMPDIR|BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR|TMPDIR)([^A-Za-z0-9_]|$)/ \
          || value ~ /mktemp/ || value ~ /(^|\/)fixtures(\/|$)/) { return 1 }
      if (value !~ /^\$\(/) { return 0 }
      command = substr(value, 3)
      sub(/^[ \t]*(bash[ \t]+)?/, "", command)
      sub(/[ \t)].*$/, "", command)
      if (command in function_body) {
        if (function_body[command] ~ /mktemp|BATS_TEST_TMPDIR|BATS_FILE_TMPDIR/ \
            && function_body[command] ~ /(^|[^A-Za-z0-9_-])git[ \t]+(.*[ \t])?init([ \t]|$)|(^|[ \t])cp[ \t]+-[A-Za-z]*[rRa]/) { return 1 }
        # A wrapper whose body runs a fixture-building script.
        command = function_body[command]
        sub(/^[ \t\n]*/, "", command)
        sub(/[ \t\n].*$/, "", command)
        gsub(/"/, "", command)
      }
      if (command !~ /^\$/) { return 0 }
      resolve_paths(command, suite_known ? suite_directory : FAILED, 0)
      for (r = 1; r <= resolved_count; r++) {
        scans_own_tree(resolved[r])
        if (builds_fixture_cache[resolved[r]]) { return 1 }
      }
      return 0
    }

    # A word that starts at a fixture: a temp-directory variable or mktemp, a
    # path with a fixtures segment, or a variable assigned one of those.
    function fixture_reference(value,   known) {
      if (value ~ /^\$\{?(BATS_TEST_TMPDIR|BATS_FILE_TMPDIR|BATS_RUN_TMPDIR|BATS_SUITE_TMPDIR|TMPDIR)([^A-Za-z0-9_]|$)/) { return 1 }
      if (value ~ /^\$\(mktemp/ || value ~ /(^|\/)fixtures(\/|$)/) { return 1 }
      for (known in is_fixture) {
        if (value ~ ("^\\$\\{?" known "([^A-Za-z0-9_]|$)")) { return 1 }
      }
      return 0
    }
    # A fixture word that names a tree: not a PATH list, not a file.
    function fixture_tree(value) {
      if (!fixture_reference(value) || value ~ /:/) { return 0 }
      sub(/\/+$/, "", value)
      return value !~ /\/[^\/]*\.[A-Za-z0-9]+$/
    }

    # 1 when a word of the statement (an argument, a cd target, an
    # environment assignment) points at a fixture tree.
    function statement_points_at_fixture(text,   word_count, words, w, word, skip_next) {
      word_count = split(text, words, /[ \t]+/)
      skip_next = 0
      for (w = 1; w <= word_count; w++) {
        word = words[w]
        if (skip_next) { skip_next = 0; continue }
        if (word ~ /^([0-9]*|&)[<>]+$/) { skip_next = 1; continue }
        if (word ~ /^([0-9]*|&)[<>]/) { continue }
        gsub(/["\047\\();]/, "", word)
        sub(/^(export)?[A-Za-z_][A-Za-z0-9_]*=/, "", word)
        sub(/^-[-A-Za-z]*=/, "", word)
        if (fixture_tree(word)) { return 1 }
      }
      return 0
    }

    # 1 when an earlier line of the same test, or of setup or setup_file,
    # changes into a fixture tree or exports one.
    function earlier_points_at_fixture(i,   block, j, text, target) {
      block = line_block[i]
      for (j = 1; j < i; j++) {
        if (line_block[j] != block && line_block[j] != "function:setup" && line_block[j] != "function:setup_file") { continue }
        if (logical_heredoc[j] || is_comment(logical_text[j])) { continue }
        text = logical_text[j]
        if (match(text, /(^|;|&&)[ \t]*(cd|pushd)[ \t]+(--[ \t]+)?[^ \t;&|)]+/)) {
          target = substr(text, RSTART, RLENGTH)
          sub(/^.*(cd|pushd)[ \t]+(--[ \t]+)?/, "", target)
          gsub(/["\047]/, "", target)
          if (fixture_tree(target)) { return 1 }
        }
        if (match(text, /(^|[ \t;])export[ \t]+[A-Za-z_][A-Za-z0-9_]*=[^ \t;]+/)) {
          target = substr(text, RSTART, RLENGTH)
          sub(/^.*export[ \t]+[A-Za-z_][A-Za-z0-9_]*=/, "", target)
          gsub(/["\047]/, "", target)
          if (fixture_tree(target)) { return 1 }
        }
      }
      return 0
    }

    # 1 when an earlier line of the same test, or of setup, reassigns the root
    # variable to a fixture or builds a repository or copy at it.
    function root_reassigned(i, name,   block, j, text, value) {
      block = line_block[i]
      for (j = 1; j < i; j++) {
        if (line_block[j] != block && line_block[j] != "function:setup" && line_block[j] != "function:setup_file") { continue }
        text = logical_text[j]
        if (!refers(text, name) || logical_heredoc[j] || is_comment(text)) { continue }
        if (match(text, ("(^|[ \t;])" name "="))) {
          value = substr(text, RSTART + RLENGTH)
          gsub(/["\047]/, "", value)
          if (fixture_reference(value)) { return 1 }
        }
        if (text ~ ("git[ \t].*init.*\\$\\{?" name) || text ~ ("(^|[ \t])cp[ \t]+-[A-Za-z]*[rRa].*\\$\\{?" name "\\}?[\"\047]?[ \t]*$")) { return 1 }
      }
      return 0
    }

    # For the first occurrence of the variable as a whole argument word that
    # is handed to a script or a function: 1 a script, 2 a function (name in
    # handed_command, argument position in handed_position); 0 for none. A
    # command that is neither (cd, git, a test, an assignment, a file-building
    # command) is not a hand-off.
    function handed_to(text, name,   pattern, rest, offset, segment, word_count, words, w, word, command, position, after_prefix, original, inline, inline_name, string_word) {
      pattern = "(^|[ \t=])\\\\?[\"\047]?\\$\\{?" name "\\}?\\\\?[\"\047]?([ \t;|&)]|$)"
      original = text
      text = masked_single_quotes(text)
      rest = text
      offset = 0
      while (match(rest, pattern)) {
        segment = substr(text, 1, offset + RSTART)
        offset += RSTART + RLENGTH - 1
        rest = substr(text, offset + 1)
        while (match(segment, /;|&&|\|\||\||\$\(|`|(^|[^\\$])\(|-c[ \t]+\\?"/)) { segment = substr(segment, RSTART + RLENGTH) }
        word_count = split(segment, words, /[ \t]+/)
        command = ""
        position = 0
        after_prefix = 0
        string_word = 0
        for (w = 1; w <= word_count; w++) {
          word = words[w]
          if (word == "") { continue }
          if (command == "") {
            if (word ~ /^(run|!|if|then|do|else|elif|while|until|command|exec|time|builtin|env|timeout)$/) { after_prefix = 1; continue }
            if (after_prefix && (word ~ /^-/ || word ~ /^[0-9]+[smh]?$/)) { continue }
            if (word ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { continue }
            command = word
            continue
          }
          position++
          if (word == "-c" && position == 1) { string_word = 1 }
        }
        if (command == "") { continue }
        gsub(/["\047\\]/, "", command)
        # bash -c <string> <$0> <args>: the string is an inline helper, and
        # the root is its positional parameter; read it as a helper body.
        if (command ~ /(^|\/)(bash|sh|zsh|dash|ksh)$/ && string_word && position >= 3 \
            && match(substr(original, 1, offset), /-c[ \t]+\047[^\047]*\047/)) {
          inline = substr(original, RSTART, RLENGTH)
          sub(/^-c[ \t]+\047/, "", inline)
          sub(/\047$/, "", inline)
          inline_name = "\001inline" (++inline_count)
          function_body[inline_name] = inline "\n"
          if (helper_reaches(inline_name, position - 2, 1)) { return 1 }
          continue
        }
        # A variable command word is a script only when it holds a path from
        # the real root; one holding a function name is outside the claim.
        if (command ~ /^(bash|sh|zsh|dash|ksh)$/ || command ~ /\//) { return 1 }
        if (command ~ /^\$/) {
          word = command
          gsub(/[${}]/, "", word)
          if (word in is_root) { return 1 }
        }
        if (command ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && ((command in function_body) || index(command, "_"))) {
          handed_command = command
          handed_position = position + (segment ~ /=$/ ? 0 : 1)
          return 2
        }
      }
      return 0
    }

    # A script run after the statement changes into the variable.
    function runs_from(text, name,   pattern, rest) {
      pattern = "(cd|pushd)[ \t]+(--[ \t]+)?\\\\?[\"\047]?\\$\\{?" name "\\}?\\\\?[\"\047]?[ \t]*(&&|;)"
      if (!match(text, pattern)) { return 0 }
      rest = substr(text, RSTART + RLENGTH)
      return rest ~ /(^|[ \t;&|(])(bash|sh|zsh)[ \t]+[^- \t]/ || rest ~ /(^|[ \t;&|(])\.\/[A-Za-z0-9_]/ \
        || rest ~ /^[ \t]*\\?["\047]?\$\{?[A-Za-z_]/ || rest ~ /git[ \t].*[ \t](ls-files|grep)([ \t]|$)/
    }

    # The names a function body binds its n-th positional parameter to,
    # the parameter itself included, space-separated.
    function parameter_aliases(body, n,   names, rest, name, pattern) {
      names = " " n " "
      pattern = "[A-Za-z_][A-Za-z0-9_]*=[\"\047]?\\$\\{?" n "([^0-9A-Za-z_]|$)"
      rest = body
      while (match(rest, pattern)) {
        name = substr(rest, RSTART, RLENGTH)
        sub(/=.*/, "", name)
        names = names name " "
        rest = substr(rest, RSTART + RLENGTH)
      }
      return names
    }

    # 1 when the function applies an idiom, a script hand-off or a change of
    # directory to its n-th parameter, reads a file under it whose name is a
    # variable (`"$root/$path"`, a name no caller spells), or hands it to a
    # function that does (followed a few calls deep; a function it cannot
    # read counts, failing closed).
    function helper_reaches(function_name, n, depth,   key, alias_count, alias_list, a, line_count, lines, l, text, saved_command, saved_position, kind) {
      key = function_name SUBSEP n
      if (key in reach_cache) { return reach_cache[key] }
      reach_cache[key] = 0
      if (depth > 4) { return 0 }
      saved_command = handed_command
      saved_position = handed_position
      alias_count = split(parameter_aliases(function_body[function_name], n), alias_list, " ")
      line_count = split(function_body[function_name], lines, "\n")
      for (l = 1; l <= line_count; l++) {
        text = lines[l]
        if (is_comment(text)) { continue }
        for (a = 1; a <= alias_count; a++) {
          if (!refers(text, alias_list[a])) { continue }
          if (idiom_priority(text, alias_list[a]) > 0 || runs_from(text, alias_list[a]) \
              || text ~ ("\\$\\{?" alias_list[a] "\\}?/\\$\\{?[A-Za-z_]")) {
            reach_cache[key] = 1
            break
          }
          kind = handed_to(text, alias_list[a])
          if (kind == 1 || (kind == 2 && (!(handed_command in function_body) \
              || (handed_command != function_name && helper_reaches(handed_command, handed_position, depth + 1))))) {
            reach_cache[key] = 1
            break
          }
        }
        if (reach_cache[key]) { break }
      }
      handed_command = saved_command
      handed_position = saved_position
      return reach_cache[key]
    }

    # A script run through bash or as the command word with no argument after
    # it, which reads its own tree.
    function default_tree_script(text, name,   pattern, matched, after, tail, value, r) {
      pattern = "(bash|sh|zsh)[ \t]+(-[A-Za-z]+[ \t]+)*\\\\?[\"\047]?\\$\\{?" name "\\}?(/[^ \t\"\047;|&)]*)?\\\\?[\"\047]?"
      if (!match(text, pattern)) {
        pattern = "(^[ \t]*|[;&|][ \t]*|(^|[^=])\\([ \t]*|(^|[ \t])(run|exec|then|do)[ \t]+)\\\\?[\"\047]?\\$\\{?" name "\\}?(/[^ \t\"\047;|&)]*)?\\\\?[\"\047]?"
        if (!match(text, pattern)) { return 0 }
      }
      matched = substr(text, RSTART, RLENGTH)
      after = substr(text, RSTART + RLENGTH)
      # -c runs a string, not the file; -n only parses it.
      if (matched ~ /[ \t]-[cn][ \t]/) { return 0 }
      if (after !~ /^[ \t]*($|[;|&)]|[0-9]*[<>]|&>|["\047][ \t]*($|[;|&)]))/) { return 0 }
      # A change of directory earlier in the statement, to anything but a real
      # root, points a script that reads its root from the working directory
      # away from the real tree.
      if (moves_away(substr(text, 1, RSTART - 1))) { return 0 }
      match(matched, ("\\$\\{?" name "\\}?"))
      tail = substr(matched, RSTART + RLENGTH)
      gsub(/["\047\\]/, "", tail)
      value = first_value[name]
      gsub(/["\047]/, "", value)
      resolve_paths(value tail, suite_known ? suite_directory : FAILED, 0)
      for (r = 1; r <= resolved_count; r++) {
        if (resolved[r] ~ /\/[^\/.]+\.[A-Za-z0-9]+$/ && resolved[r] !~ /\.(sh|bash)$/) { continue }
        if (scans_own_tree(resolved[r])) { return 1 }
      }
      return 0
    }

    function moves_away(prefix,   target, known) {
      if (!match(prefix, /(^|[;&|(\"])[ \t]*(cd|pushd)[ \t]+(--[ \t]+)?[^ \t;&|)]+/)) { return 0 }
      target = substr(prefix, RSTART, RLENGTH)
      sub(/^.*(cd|pushd)[ \t]+(--[ \t]+)?/, "", target)
      gsub(/["\047\\]/, "", target)
      for (known in is_root) {
        if (target ~ ("^\\$\\{?" known "\\}?$") && names_root(known)) { return 0 }
      }
      return 1
    }

    # 1 when a suite function prints a path under the real root whose last
    # segment is a parameter plus a literal suffix.
    function builds_suffix_path(function_name,   line_count, lines, l, text, aliases, alias_count, alias_list, a, n, known, has_root) {
      line_count = split(function_body[function_name], lines, "\n")
      aliases = ""
      for (n = 1; n <= 3; n++) { aliases = aliases parameter_aliases(function_body[function_name], n) }
      alias_count = split(aliases, alias_list, " ")
      for (l = 1; l <= line_count; l++) {
        text = lines[l]
        if (is_comment(text) || text !~ /(^|[ \t;&|(])(printf|echo)[ \t]/) { continue }
        has_root = 0
        for (known in is_root) {
          if (names_root(known) && refers(text, known)) { has_root = 1; break }
        }
        if (!has_root) { continue }
        for (a = 1; a <= alias_count; a++) {
          if (!refers(text, alias_list[a])) { continue }
          if (text ~ /%s\/[^ \t"\047]*%s\.[A-Za-z0-9_]+/ || text ~ ("\\$\\{?" alias_list[a] "\\}?\\.[A-Za-z0-9_]+")) { return 1 }
        }
      }
      return 0
    }

    # The call hop a logical line makes, as an idiom_label index; 0 for none.
    function call_hop(i,   text, best, name, kind, fired, word_name) {
      text = logical_text[i]
      best = 0
      fired = ""
      for (name in is_root) {
        if (!refers(text, name) || (name in is_fixture)) { continue }
        if (names_root(name)) {
          if (runs_from(text, name) && (best == 0 || best > 5)) { best = 5; fired = name }
          kind = handed_to(text, name)
          if (kind == 1 && (best == 0 || best > 6)) { best = 6; fired = name }
          if (kind == 2) {
            if (!(handed_command in function_body)) {
              if (best == 0 || best > 8) { best = 8; fired = name }
            } else if (helper_reaches(handed_command, handed_position, 0) && (best == 0 || best > 7)) {
              best = 7; fired = name
            }
          }
        }
        if ((best == 0 || best > 9) && default_tree_script(text, name)) { best = 9; fired = name }
      }
      if (best == 0) {
        for (word_name in suffix_builder) {
          if (line_block[i] == ("function:" word_name)) { continue }
          if (text ~ ("(^|[ \t;&|(])" word_name "([ \t;)|&\"]|$)") && text !~ ("(^|[ \t])" word_name "[ \t]*\\(\\)")) { best = 10; break }
        }
      }
      if (best == 0 || statement_points_at_fixture(text)) { return 0 }
      if (best == 9 && earlier_points_at_fixture(i)) { return 0 }
      if (fired != "" && root_reassigned(i, fired)) { return 0 }
      return best
    }

    # Which block each logical line sits in: a test, a function, or the top
    # level. Read over logical lines, skipping heredoc bodies.
    function assign_blocks(   i, text, block, definition, name) {
      block = ""
      for (i = 1; i <= logical_count; i++) {
        text = logical_text[i]
        if (logical_heredoc[i]) { line_block[i] = block; continue }
        if (block == "") {
          if (text ~ /^@test[ \t]/) {
            block = "test:" i
          } else if (match(text, /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/) || (text ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*(\{|$)/ && match(text, /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*/))) {
            name = substr(text, RSTART, RLENGTH)
            sub(/^(function[ \t]+)?/, "", name)
            sub(/[ \t]*\(\)$/, "", name)
            block = "function:" name
            line_block[i] = block
            if (text ~ /[})][ \t]*(;[ \t]*)?$/ && text !~ /[{(][ \t]*$/) { block = "" }
            continue
          }
          line_block[i] = block
          continue
        }
        line_block[i] = block
        if (text ~ /^[})][ \t]*$/) { block = "" }
      }
    }

    # End of pass 1: the real-root fixpoint, then every hit keyed by the first
    # physical line of its logical line.
    function find_hits(   i, statement, equals_position, assigned_count, assigned_name, assigned_value, a, name, value, joins, known, changed, best, priority, function_name) {
      if (pending != "") {
        logical_count++
        logical_text[logical_count] = pending
        logical_start[logical_count] = pending_start
        pending = ""
      }
      if (heredoc_open != "") {
        for (i = heredoc_open_line; i <= FNR_last; i++) { delete line_is_heredoc[i] }
      }
      for (i = 1; i <= logical_count; i++) { logical_heredoc[i] = (logical_start[i] in line_is_heredoc) }
      assigned_count = 0
      for (i = 1; i <= logical_count; i++) {
        if (is_comment(logical_text[i])) { continue }
        statement = logical_text[i]
        sub(/^[ \t]*/, "", statement)
        sub(/^(local|export|readonly|declare)[ \t]+(-[A-Za-z]+[ \t]+)?/, "", statement)
        if (statement !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { continue }
        equals_position = index(statement, "=")
        assigned_count++
        assigned_name[assigned_count] = substr(statement, 1, equals_position - 1)
        assigned_value[assigned_count] = substr(statement, equals_position + 1)
        if (!(assigned_name[assigned_count] in first_value)) {
          first_value[assigned_name[assigned_count]] = assigned_value[assigned_count]
        }
      }
      changed = 1
      while (changed) {
        changed = 0
        for (a = 1; a <= assigned_count; a++) {
          name = assigned_name[a]
          if (name in is_root) { continue }
          value = assigned_value[a]
          if (value ~ /\/fixtures([\/" \t]|$)/) { continue }
          joins = 0
          if (index(value, "$BATS_TEST_DIRNAME") || index(value, "${BATS_TEST_DIRNAME") \
              || index(value, "$BATS_TEST_FILENAME") || index(value, "${BATS_TEST_FILENAME")) {
            joins = 1
          } else {
            for (known in is_root) {
              if (refers(value, known)) { joins = 1; break }
            }
          }
          if (joins) { is_root[name] = 1; changed = 1 }
        }
      }
      for (i = 1; i <= logical_count; i++) {
        if (is_comment(logical_text[i])) { continue }
        best = 0
        for (name in is_root) {
          priority = idiom_priority(logical_text[i], name)
          if (priority > 0 && (best == 0 || priority < best)) { best = priority }
        }
        if (best > 0) { hit_idiom[logical_start[i]] = idiom_label[best] }
      }
      assign_blocks()
      read_functions(FILENAME, suite_known ? suite_directory : FAILED, 1, 0)
      # Fixture variables: assigned a temp directory, mktemp, a fixtures path,
      # the output of a script or function that builds a temporary
      # repository, or a variable already collected. A real-root variable
      # joins only when every non-empty assignment it has is one of those; a
      # single fixture reassignment is local to its test, which
      # root_reassigned reads.
      changed = 1
      while (changed) {
        changed = 0
        delete fixture_assignments
        delete other_assignments
        for (a = 1; a <= assigned_count; a++) {
          name = assigned_name[a]
          if (name in is_fixture) { continue }
          value = assigned_value[a]
          gsub(/["\047]/, "", value)
          if (value == "") { continue }
          joins = fixture_expression(value)
          if (!joins) {
            for (known in is_fixture) {
              if (refers(value, known)) { joins = 1; break }
            }
          }
          if (joins) { fixture_assignments[name]++ } else { other_assignments[name]++ }
        }
        for (name in fixture_assignments) {
          if ((name in is_root) && (name in other_assignments)) { continue }
          is_fixture[name] = 1
          changed = 1
        }
      }
      for (function_name in function_body) {
        if (function_suite[function_name] && builds_suffix_path(function_name)) { suffix_builder[function_name] = 1 }
      }
      for (i = 1; i <= logical_count; i++) {
        if (is_comment(logical_text[i]) || logical_heredoc[i] || (logical_start[i] in hit_idiom)) { continue }
        best = call_hop(i)
        if (best > 0) { hit_idiom[logical_start[i]] = idiom_label[best] }
      }
      hits_found = 1
    }

    # 1 when bats applies the whole-tree tag from this tag list: the list
    # passes the bats tag-list syntax (an invalid list applies no tag at all)
    # and one comma element, trimmed of spaces, is whole-tree.
    function bats_applies_whole_tree(tag_list,   element_count, elements, e, element) {
      if (tag_list !~ /^ *([-_:A-Za-z0-9]+)?( *, *[-_:A-Za-z0-9]+)* *$/) { return 0 }
      element_count = split(tag_list, elements, ",")
      for (e = 1; e <= element_count; e++) {
        element = elements[e]
        gsub(/^ +/, "", element)
        gsub(/ +$/, "", element)
        if (element == "whole-tree") { return 1 }
      }
      return 0
    }

    # The test name bats reads from an @test line: the text between @test and
    # the last blank-preceded opening brace, one outer quote stripped from each
    # end. Empty when the line is not a test line.
    function test_name_of(text,   rest, i, candidate) {
      if (text !~ /^[ \t]*@test[ \t]+.*[^ \t][ \t]+\{/) { return "" }
      rest = text
      sub(/^[ \t]*@test[ \t]+/, "", rest)
      for (i = length(rest); i > 1; i--) {
        if (substr(rest, i, 1) != "{" || substr(rest, i - 1, 1) !~ /[ \t]/) { continue }
        candidate = substr(rest, 1, i - 1)
        sub(/[ \t]+$/, "", candidate)
        if (candidate == "") { continue }
        sub(/^["\047]/, "", candidate)
        sub(/["\047]$/, "", candidate)
        return candidate
      }
      return ""
    }

    function finding(line_number, reason) {
      printf "%s:%d: %s\n", file, line_number, reason
      findings++
    }

    # One tag command line, tracked the way bats applies it.
    function read_tag_line(text, command,   kind, tag_list, honored, canonical) {
      if (command ~ /^test_tags=/) { kind = "test" } else if (command ~ /^file_tags=/) { kind = "file" } else { return }
      tag_list = command
      sub(/^[a-z]+_tags=/, "", tag_list)
      honored = bats_applies_whole_tree(tag_list)
      canonical = (text ~ (kind == "test" ? test_mark_pattern : file_mark_pattern))
      if (honored && !canonical) {
        finding(FNR, "bats applies this whole-tree " kind " tag, but the runner discovers only the canonical spelling (column 0, \047# bats " kind "_tags=\047, no spaces around = or commas), so it never runs the suite for it")
      }
      if (canonical && !honored) {
        finding(FNR, "the canonical whole-tree " kind " tag is in a tag list bats rejects, so bats applies no tag from this line")
      }
      if (kind == "test") {
        if (test_mark_line && !honored) {
          finding(test_mark_line, "the whole-tree test mark is replaced by the test_tags line at line " FNR " before its @test, so bats never applies it")
        }
        pending_test_marked = honored
        test_mark_line = (honored || canonical) ? FNR : 0
        return
      }
      if ((honored || canonical) && test_count > 0) {
        finding(FNR, "the whole-tree file mark sits after the first @test, so bats leaves it off every test above it; move it before the first test")
      }
      if (file_mark_line && !honored) {
        finding(file_mark_line, "the whole-tree file mark is replaced by the file_tags line at line " FNR ", so bats leaves it off every test below that line")
      }
      file_tag_whole_tree = honored
      file_mark_line = (honored || canonical) ? FNR : 0
    }

    BEGIN {
      gaia_scan_reset()
      while ((getline directory < directory_list) > 0) { is_directory[directory] = 1 }
      close(directory_list)
      # Split so the path-quoting lint does not read the label as a listing.
      idiom_label[1] = "git -C <root> ls-" "files"
      idiom_label[2] = "git -C <root> grep"
      idiom_label[3] = "find <root>"
      idiom_label[4] = "glob loop over <root>"
      idiom_label[5] = "a script run from <root>"
      idiom_label[6] = "<root> handed to a script"
      idiom_label[7] = "<root> handed to a helper that scans it"
      idiom_label[8] = "<root> handed to a helper this guard cannot read"
      idiom_label[9] = "a script that scans its own tree, run with no argument"
      idiom_label[10] = "a path built from <root> and a name"
      FAILED = "\001"
      heredoc_open = ""
      tracked_loaded = 0
      suite_known = (suite_relative != "")
      suite_directory = suite_known ? parent_of(suite_relative) : FAILED
      pending = ""; logical_count = 0; hits_found = 0; findings = 0
      test_count = 0; current_test = ""; current_test_marked = 0
      every_test_marked = 1; every_test_file_marked = 1
      pending_test_marked = 0; test_mark_line = 0
      file_tag_whole_tree = 0; file_mark_line = 0
      hit_count = 0
    }
    NR == FNR {
      gaia_scan_prepass($0)
      FNR_last = FNR
      if (heredoc_open != "") {
        line_is_heredoc[FNR] = 1
        heredoc_line_text = $0
        sub(/\r$/, "", heredoc_line_text)
        if (heredoc_open_dash) { sub(/^\t+/, "", heredoc_line_text) }
        if (heredoc_line_text == heredoc_open) { heredoc_open = "" }
      } else if (!is_comment($0)) {
        heredoc_open = heredoc_word($0)
        heredoc_open_dash = heredoc_word_dash
        heredoc_open_line = FNR + 1
      }
      collect_line($0)
      next
    }
    FNR == 1 && !hits_found { find_hits() }
    {
      gaia_scan_feed($0, 1)
      physical = $0
      sub(/\r$/, "", physical)
      name = test_name_of(physical)
      if (name == "" && physical ~ /[ \t]*[^ \t()]+[ \t]*\(?\)?[ \t]+\{[ \t]+#[ \t]*@test[ \t]*$/) {
        name = physical
        sub(/^[ \t]*/, "", name)
        sub(/[ \t(].*$/, "", name)
      }
      if (name != "") {
        test_count++
        current_test = name
        current_test_marked = (pending_test_marked || file_tag_whole_tree)
        if (!current_test_marked) { every_test_marked = 0 }
        if (!file_tag_whole_tree) { every_test_file_marked = 0 }
        pending_test_marked = 0
        test_mark_line = 0
      } else if (physical ~ /^[ \t]*#[ \t]*bats[ \t]+/) {
        command = physical
        sub(/^[ \t]*#[ \t]*bats[ \t]+/, "", command)
        read_tag_line(physical, command)
      }
      if (!(FNR in hit_idiom) || gaia_scan_skip()) { next }
      hit_count++
      hit_line[hit_count] = FNR
      hit_label[hit_count] = hit_idiom[FNR]
      hit_in_test[hit_count] = gaia_scan_in_test()
      hit_test[hit_count] = current_test
      hit_test_marked[hit_count] = current_test_marked
      hit_waived[hit_count] = gaia_scan_suppressed("whole-tree-mark-guard")
    }
    END {
      if (test_mark_line) {
        finding(test_mark_line, "the whole-tree test mark has no @test after it, so bats never applies it")
      }
      if (gaia_scan_end(file, 1, "whole-tree-mark-guard", 0, 0)) { findings++ }
      file_marked = (test_count > 0) ? every_test_file_marked : file_tag_whole_tree
      for (h = 1; h <= hit_count; h++) {
        if (hit_waived[h] || file_marked) { continue }
        if (hit_in_test[h]) {
          if (hit_test_marked[h]) { continue }
          printf "%s: test \"%s\" enumerates the tracked tree (%s, line %d) without the whole-tree mark; add \047# bats test_tags=whole-tree\047 on the line above it\n", file, hit_test[h], hit_label[h], hit_line[h]
          findings++
          continue
        }
        if (test_count > 0 && every_test_marked) { continue }
        printf "%s: enumerates the tracked tree outside any test body (%s, line %d) without the file-level whole-tree mark; add \047# bats file_tags=whole-tree\047 before the first test, mark every test with \047# bats test_tags=whole-tree\047, or put a waiver \047# gaia-lint-ignore whole-tree-mark-guard: <reason>\047 on the comment line directly above the statement\n", file, hit_label[h], hit_line[h]
        findings++
      }
      exit (findings > 0) ? 1 : 0
    }
'

# Every directory holding a tracked file, so a literal ls-files operand naming
# one still counts as enumeration. Empty when the root is not a repository.
directory_list="$(mktemp)" || { echo "whole-tree-mark-guard: cannot create a temporary file" >&2; exit 2; }
tracked_list="$(mktemp)" || { rm -f "$directory_list"; echo "whole-tree-mark-guard: cannot create a temporary file" >&2; exit 2; }
trap 'rm -f "$directory_list" "$tracked_list"' EXIT
git -C "$root" ls-files -z 2>/dev/null \
  | tr '\0' '\n' \
  | awk -F/ '{ path = $1; for (i = 2; i <= NF; i++) { print path; path = path "/" $i } }' \
  | sort -u >"$directory_list"
# The files a called script or a sourced library is read from. A root that is
# not a repository (a fixture tree) lists its files instead.
git -C "$root" ls-files -z 2>/dev/null | tr '\0' '\n' >"$tracked_list"
if [ ! -s "$tracked_list" ] && [ -d "$root" ]; then
  (cd "$root" && find . -type f ! -path './.git/*' 2>/dev/null) | sed 's|^\./||' >"$tracked_list"
fi

flagged=0
for suite_path in ${scan_paths[@]+"${scan_paths[@]}"}; do
  if [ ! -f "$suite_path" ]; then
    echo "whole-tree-mark-guard: not a file: $suite_path" >&2
    exit 2
  fi
  display="$suite_path"
  suite_relative=""
  case "$suite_path" in
    "$root"/*)
      display="${suite_path#"$root"/}"
      suite_relative="$display"
      ;;
  esac
  "$GAIA_AWK" -v file="$display" -v is_bats=1 -v scripts_directory="$_gaia_guard_library_directory" \
    -v directory_list="$directory_list" -v tracked_list="$tracked_list" \
    -v root="$root" -v suite_relative="$suite_relative" \
    -v file_mark_pattern="$verify_whole_tree_file_mark_pattern" \
    -v test_mark_pattern="$verify_whole_tree_test_mark_pattern" \
    "$GAIA_GUARD_AWK$OWN_AWK" "$suite_path" "$suite_path"
  scan_status=$?
  case "$scan_status" in
    0) ;;
    1) flagged=$((flagged + 1)) ;;
    *)
      echo "whole-tree-mark-guard: the scan of $display failed (awk exited $scan_status); this guard cannot certify it" >&2
      exit 2
      ;;
  esac
done

if [ "$flagged" -gt 0 ]; then
  echo "whole-tree-mark-guard: $flagged suite(s) flagged. Only the idioms and calls in this script's header are recognized (git -C <root> listing tracked files or grep, find <root>, a glob loop over <root>; <root> handed to a script or a scanning helper, a script run from <root>, a no-argument script that scans its own tree, a path built from <root> and a name); a test reaching the tracked tree through a path this guard cannot see is outside its claim, and the full run on push to main backstops it."
  exit 1
fi

echo "whole-tree-mark-guard: no unmarked test uses a recognized idiom or call (a test reaching the tracked tree through a path this guard cannot see is outside its claim; the full run on push to main backstops it)"
exit 0
