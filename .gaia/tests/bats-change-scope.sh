#!/usr/bin/env bash
#
# Classifies a change for the change-scoped bats legs of the audit CI workflow.
# Two classes, one output line per changed path that falls in a class:
#
#   harness<TAB><path>     harness machinery (a fixed path list) or a shared
#                          shell library. A leg runs its whole shard.
#   dependency<TAB><path>  a dependency install input. A leg also runs the
#                          suites marked as reading installed dependencies.
#
# A path in both classes prints both lines. A path in neither prints nothing.
#
# Why shared shell libraries fail closed: a library reached through a built
# path (`source "$library_path"` after `library_path="$DIR/../x/name.sh"`)
# cannot be mapped to the suites that read it, so a change to one runs the
# whole shard. The rule is dynamic, on top of the static `lib/` and `*-lib.sh`
# globs. Candidate files are every tracked `*.sh` and every tracked
# extensionless file whose first line is a bash or sh shebang. Outside comments
# and heredoc bodies, each `source` or `.` operand contributes the basename of
# its trailing literal segment (a lone variable operand contributes the
# trailing `.sh` segment of every assignment to it in the same file), and each
# `# shellcheck source=<path>` directive contributes its basename. A changed
# path whose basename is in that set is harness. Matching on the basename
# over-matches on purpose: it costs time, never coverage.
#
# Residual limit: an operand that still has no literal trailing segment after
# the one-assignment follow (`. "$file"` with `$file` from a loop or a computed
# string) maps nothing. The static globs and the full run on every push to main
# backstop it.
#
# Usage:
#   bash .gaia/tests/bats-change-scope.sh --dir <repo> <git-diff-arg>...
#   bash .gaia/tests/bats-change-scope.sh --dir <repo> --paths <file>
#   bash .gaia/tests/bats-change-scope.sh --list-install-inputs
#   bash .gaia/tests/bats-change-scope.sh --list-harness-paths
#
# Changed paths are read the way the suite selector reads them: NUL-delimited,
# rename detection off, so a renamed file lists both paths. `--paths` takes a
# newline-delimited list instead.
#
# Exit: 0 classified (possibly empty output), 2 usage error, 3 the change could
# not be read. Nothing is printed on 3, so an empty stdout on exit 0 always
# means "no harness or dependency path".
#
# Maintainer-only: `.gaia/tests` is release-excluded.

set -uo pipefail

install_inputs=(
  "package.json"
  "pnpm-lock.yaml"
  "pnpm-workspace.yaml"
  ".npmrc"
  ".node-version"
  "frontend/package.json"
  ".gaia/cli/package.json"
)

# picomatch-style globs with dot on: `**/` is zero or more whole directories,
# a trailing `/**` is everything below, `*` stops at `/`.
harness_globs=(
  ".github/workflows/audit-ci-tests.yml"
  ".gaia/tests/bats-shards.sh"
  ".gaia/tests/bats-change-scope.sh"
  ".gaia/scripts/bats-suites-for-change.sh"
  ".gaia/tests/install-bats.sh"
  ".gaia/tests/vendor/**"
  ".gaia/tests/helpers/**"
  ".gaia/tests/**/helpers/**"
  ".gaia/scripts/tests/helpers/**"
  ".github/actions/**"
  ".gaia/release-exclude"
  ".claude/hooks/**/lib/**"
  ".gaia/scripts/**/lib/**"
  "**/*-lib.sh"
)

usage_error() {
  printf 'bats-change-scope: %s\n' "$1" >&2
  exit 2
}

unreadable() {
  printf 'bats-change-scope: %s\n' "$1" >&2
  exit 3
}

directory="."
paths_file=""
diff_arguments=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list-install-inputs)
      printf '%s\n' ${install_inputs[@]+"${install_inputs[@]}"}
      exit 0
      ;;
    --list-harness-paths)
      printf '%s\n' ${harness_globs[@]+"${harness_globs[@]}"}
      exit 0
      ;;
    --dir)
      [ "$#" -ge 2 ] || usage_error "--dir needs a value"
      directory="$2"
      shift 2
      ;;
    --paths)
      [ "$#" -ge 2 ] || usage_error "--paths needs a value"
      paths_file="$2"
      shift 2
      ;;
    --)
      shift
      diff_arguments+=("$@")
      break
      ;;
    --*)
      usage_error "unknown option $1"
      ;;
    *)
      diff_arguments+=("$1")
      shift
      ;;
  esac
done

if [ -z "$paths_file" ] && [ "${#diff_arguments[@]}" -eq 0 ]; then
  usage_error "a diff argument or --paths is required"
fi

root="$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null)" \
  || unreadable "not a git checkout: $directory"

work_directory="$(mktemp -d)" || unreadable "cannot create a temporary directory"
trap 'rm -rf "$work_directory"' EXIT
changed_list="$work_directory/changed"
candidate_list="$work_directory/candidates"
library_names="$work_directory/libraries"
glob_list="$work_directory/globs"
install_list="$work_directory/installs"

if [ -n "$paths_file" ]; then
  [ -r "$paths_file" ] || unreadable "cannot read $paths_file"
  grep -v '^$' "$paths_file" > "$changed_list" || [ "$?" -eq 1 ] || unreadable "cannot read $paths_file"
else
  git -C "$root" diff --name-only --no-renames -z ${diff_arguments[@]+"${diff_arguments[@]}"} -- \
    | tr '\0' '\n' > "$changed_list"
  [ "${PIPESTATUS[0]}" -eq 0 ] || unreadable "git diff ${diff_arguments[*]} failed"
fi

printf '%s\n' ${harness_globs[@]+"${harness_globs[@]}"} > "$glob_list"
printf '%s\n' ${install_inputs[@]+"${install_inputs[@]}"} > "$install_list"

git -C "$root" ls-files -z | tr '\0' '\n' > "$work_directory/tracked" \
  || unreadable "listing tracked files failed"
[ "${PIPESTATUS[0]}" -eq 0 ] || unreadable "listing tracked files failed"

# Candidates: every *.sh, plus extensionless files (their shebang is checked by
# the scan below). A .bats suite is never a candidate.
awk '
  { name = $0; sub(/^.*\//, "", name) }
  name ~ /\.sh$/ { print; next }
  name !~ /\./ { print "?" $0 }
' "$work_directory/tracked" > "$candidate_list"

# One pass over every candidate: prints the basename set.
awk -v root="$root" -v candidate_file="$candidate_list" '
  function basename_of(path,   copy) {
    copy = path
    sub(/^.*\//, "", copy)
    return copy
  }
  function trim_quotes(text) {
    gsub(/^["\047]+/, "", text)
    gsub(/["\047]+$/, "", text)
    return text
  }
  # The trailing literal segment of an operand, or "" when there is none.
  function literal_segment(operand,   segment, has_slash) {
    operand = trim_quotes(operand)
    if (operand ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) return ""
    has_slash = (index(operand, "/") > 0)
    if (!has_slash && operand !~ /\.sh$/) return ""
    segment = basename_of(operand)
    if (segment ~ /^[A-Za-z0-9_.+@-]+$/) return segment
    return ""
  }
  function lone_variable(operand) {
    operand = trim_quotes(operand)
    if (operand !~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) return ""
    gsub(/[${}]/, "", operand)
    return operand
  }
  function operand_of(rest,   operand) {
    operand = rest
    sub(/[[:space:]]*[;&|].*$/, "", operand)
    sub(/[[:space:]]+#.*$/, "", operand)
    sub(/[[:space:]]+$/, "", operand)
    if (index(operand, "(") == 0) sub(/\)+$/, "", operand)
    return operand
  }
  function flush_file(   variable, assigned) {
    for (variable in pending_variables) {
      if (variable in assignments) {
        split(assignments[variable], assigned, "\n")
        for (index_number in assigned) if (assigned[index_number] != "") names[assigned[index_number]] = 1
      }
    }
    delete pending_variables
    delete assignments
  }
  function scan_line(line,   rest, position, operand, variable, segment, value, marker) {
    # shellcheck directive
    if (line ~ /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]].*source=/) {
      position = index(line, "source=")
      value = substr(line, position + 7)
      sub(/[[:space:]].*$/, "", value)
      value = trim_quotes(value)
      if (value != "" && value != "/dev/null") names[basename_of(value)] = 1
      return
    }
    if (line ~ /^[[:space:]]*#/) return

    # assignment: VAR=value
    if (match(line, /^[[:space:]]*((local|readonly|export|declare)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?)?[A-Za-z_][A-Za-z0-9_]*=/)) {
      value = substr(line, RLENGTH + 1)
      variable = substr(line, 1, RLENGTH - 1)
      sub(/^.*[[:space:]]/, "", variable)
      value = trim_quotes(value)
      sub(/[[:space:]]*[;&|].*$/, "", value)
      value = trim_quotes(value)
      if (value ~ /\.sh$/) {
        segment = basename_of(value)
        if (segment ~ /^[A-Za-z0-9_.+@-]+$/) assignments[variable] = assignments[variable] "\n" segment
      }
    }

    # source / . statements, possibly several per line
    rest = line
    while (match(rest, /(^|[[:space:];&|({])(source|\.)[[:space:]]+/)) {
      marker = substr(rest, RSTART + RLENGTH)
      rest = marker
      operand = operand_of(marker)
      if (operand == "") continue
      variable = lone_variable(operand)
      if (variable != "") { pending_variables[variable] = 1; continue }
      segment = literal_segment(operand)
      if (segment != "") names[segment] = 1
    }
  }
  function scan_file(path,   line, first_line, in_heredoc, terminator, stripped, heredoc_word) {
    first_line = 1
    in_heredoc = 0
    while ((getline line < (root "/" path)) > 0) {
      if (first_line) {
        first_line = 0
        if (extensionless && line !~ /^#!.*(bash|[\/ ]sh)([[:space:]]|$)/) { close(root "/" path); return }
      }
      if (in_heredoc) {
        stripped = line
        sub(/^\t+/, "", stripped)
        if (stripped == terminator) in_heredoc = 0
        continue
      }
      scan_line(line)
      if (line !~ /<<</ && match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        heredoc_word = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*/, "", heredoc_word)
        terminator = trim_quotes(heredoc_word)
        in_heredoc = 1
      }
    }
    close(root "/" path)
    flush_file()
  }
  BEGIN {
    while ((getline candidate < candidate_file) > 0) {
      extensionless = 0
      if (substr(candidate, 1, 1) == "?") { extensionless = 1; candidate = substr(candidate, 2) }
      scan_file(candidate)
    }
    for (name in names) print name
  }
' > "$library_names" \
  || unreadable "scanning shell files failed"

# Classify: static globs and library basenames, then install inputs.
awk -v glob_file="$glob_list" -v library_file="$library_names" -v install_file="$install_list" '
  function glob_to_regex(glob,   result, position, character, pair) {
    result = "^"
    position = 1
    while (position <= length(glob)) {
      character = substr(glob, position, 1)
      pair = substr(glob, position, 2)
      if (pair == "**") {
        if (substr(glob, position + 2, 1) == "/") { result = result "(.*/)?"; position += 3 }
        else { result = result ".*"; position += 2 }
      } else if (character == "*") { result = result "[^/]*"; position++ }
      else if (character ~ /[.+?()\[\]{}|^$\\]/) { result = result "\\" character; position++ }
      else { result = result character; position++ }
    }
    return result "$"
  }
  BEGIN {
    while ((getline glob < glob_file) > 0) patterns[++pattern_count] = glob_to_regex(glob)
    while ((getline name < library_file) > 0) libraries[name] = 1
    while ((getline input < install_file) > 0) installs[input] = 1
  }
  {
    path = $0
    base = path
    sub(/^.*\//, "", base)
    harness = (base in libraries)
    for (i = 1; !harness && i <= pattern_count; i++) if (path ~ patterns[i]) harness = 1
    if (harness) print "harness\t" path
    if (path in installs) print "dependency\t" path
  }
' "$changed_list" | LC_ALL=C sort -u
