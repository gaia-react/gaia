#!/usr/bin/env bats
#
# Every library an entry script of the usage ledger loads is loaded at top
# level, unconditionally, and its absence is fatal: a readout or a hook that ran
# without one would print figures that look whole. Per entry script this suite
# derives the library list from the script's own `.`/`source` lines (never a
# hard-coded list), copies the scripts and hooks trees to a temporary directory,
# removes one library at a time, runs the entry script and asserts a non-zero
# exit, a stderr line naming the missing file, and nothing on stdout.
#
# The run per entry script is fixed so a reader knows what each case drives:
#   usage.sh            initiative, represented and record, for every library it
#                       loads (all libraries load before dispatch, so every
#                       subcommand must fail; represented is the one most
#                       tempting to load lazily)
#   usage-flush.sh      --session <id>
#   usage-merge.sh      an armed `gh pr merge` payload on stdin
#   pr-merge-cost.sh   the same payload, through the hook
# usage-record-lib.sh is sourced by usage.sh, not run, and holds no `.`/`source`
# line of its own; the record case above is its coverage, and a source line
# appearing in it fails the derivation case below so it is brought under the
# same rules.
#
# A control run against the unmodified copy proves each command reaches past the
# load stage, so a pass is not an entry script that fails for another reason.
#
# Function-level lazy loads (`_gaia_usage_load` inside usage-lib.sh) are out of
# this rule; a subcommand that avoids expensive work proves it by a call trace in
# its own suite.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  TREE="$SCRATCH/tree"
  MAIN="$SCRATCH/main"
  mkdir -p "$TREE/.gaia" "$TREE/.claude" "$MAIN" "$SCRATCH/telemetry" "$SCRATCH/projects" "$SCRATCH/bin"
  # A merge hook that survives the load stage must not reach the network.
  printf '#!/bin/sh\nexit 1\n' >"$SCRATCH/bin/gh"
  chmod +x "$SCRATCH/bin/gh"
  git -C "$MAIN" init -q -b main
  PAYLOAD='{"session_id":"sess-1","cwd":"'"$MAIN"'","tool_name":"Bash","tool_input":{"command":"gh pr merge 5 --squash"},"tool_response":{"stdout":"","stderr":""}}'
}

copy_trees() {
  rsync -a --exclude=tests "$REPO_ROOT/.gaia/scripts" "$TREE/.gaia/"
  rsync -a "$REPO_ROOT/.claude/hooks" "$TREE/.claude/"
}

# A `.` or `source` that loads a path, wherever the command sits on the line
# (line start, after a `;`, `&&`, `||`, `{`, `(`, or `then`), so a guarded or
# nested load is derived and then rejected rather than missed. A `. as $x` jq
# fragment names no path and does not match.
SOURCE_PATTERN='(^|[;&|{(][[:space:]]*|then[[:space:]]+|else[[:space:]]+|do[[:space:]]+|^[[:space:]]+)(\.|source)[[:space:]]+["$]'

# source_lines <file>: every line that loads a path by `.` or `source`.
source_lines() {
  grep -E "$SOURCE_PATTERN" "$1" || true
}

# library_files <entry file in $TREE>: the absolute path of each library the
# entry's source lines name, one per line, resolved inside the scratch tree.
library_files() {
  local entry="$1" entry_directory line relative resolved
  entry_directory="$(dirname "$entry")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    relative="$(printf '%s\n' "$line" | grep -o -E '\$\{?[A-Za-z_0-9]+\}?/[^" ]+\.sh' | head -n 1 | sed -E 's#^\$\{?[A-Za-z_0-9]+\}?/##')"
    case "$relative" in
      *.sh) ;;
      *) printf 'cannot derive a library path from: %s\n' "$line" >&2; return 1 ;;
    esac
    resolved="$(cd "$entry_directory/$(dirname "$relative")" && pwd -P)/$(basename "$relative")" || return 1
    [ -f "$resolved" ] || { printf 'derived library missing: %s\n' "$resolved" >&2; return 1; }
    printf '%s\n' "$resolved"
  done <<<"$(source_lines "$entry")"
}

# run_entry <name>: runs the fixed command set for one entry script inside the
# scratch main checkout, collecting every command's status, stdout and stderr in
# RESULT_STATUS, RESULT_STDOUT and RESULT_STDERR (one entry per command).
run_command() {
  # run_command <stdin-text> <command...>: bash env pinned to the scratch tree.
  local stdin_text="$1"
  shift
  (
    cd "$MAIN" || exit 99
    env -u GITHUB_ACTIONS -u CI -u GAIA_USAGE_HOOKS_DISABLE -u CLAUDE_PROJECT_DIR \
      PATH="$SCRATCH/bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-1 "$@" <<<"$stdin_text"
  )
}

entry_commands() {
  case "$1" in
    .gaia/scripts/usage.sh)
      printf '%s\n' \
        "initiative spec:SPEC-001 --main-root $MAIN --telemetry-dir $SCRATCH/telemetry" \
        "represented spec:SPEC-001 --workflow gaia-spec --main-root $MAIN --telemetry-dir $SCRATCH/telemetry" \
        "record spec:SPEC-001 --workflow gaia-spec --main-root $MAIN --projects-root $SCRATCH/projects"
      ;;
    .gaia/scripts/usage-flush.sh)
      printf '%s\n' "--session sess-1 --main-root $MAIN --telemetry-dir $SCRATCH/telemetry --projects-root $SCRATCH/projects"
      ;;
    .gaia/scripts/usage-merge.sh | .claude/hooks/pr-merge-cost.sh)
      printf '%s\n' ""
      ;;
  esac
}

# drive_entry <relative entry> <expect: control|missing> <missing path>
# Runs every command of the entry; on `missing`, asserts the hard-error shape,
# on `control`, asserts the load stage was passed.
drive_entry() {
  local entry="$1" mode="$2" missing="${3:-}" arguments stdout_file stderr_file status
  stdout_file="$SCRATCH/out.txt"
  stderr_file="$SCRATCH/err.txt"
  while IFS= read -r arguments; do
    # shellcheck disable=SC2086  # the argument line is a fixed, space-separated set
    status=0
    run_command "$PAYLOAD" bash "$TREE/$entry" $arguments >"$stdout_file" 2>"$stderr_file" || status=$?
    if [ "$mode" = "missing" ]; then
      if [ "$status" -eq 0 ]; then
        printf '%s [%s]: exited 0 with %s missing\n' "$entry" "$arguments" "$missing" >&2
        return 1
      fi
      if ! grep -q -F -- "$(basename "$missing")" "$stderr_file"; then
        printf '%s [%s]: stderr does not name %s:\n' "$entry" "$arguments" "$(basename "$missing")" >&2
        cat "$stderr_file" >&2
        return 1
      fi
      if [ -s "$stdout_file" ]; then
        printf '%s [%s]: printed on stdout with %s missing:\n' "$entry" "$arguments" "$missing" >&2
        cat "$stdout_file" >&2
        return 1
      fi
    else
      if grep -q -E 'cannot load|No such file or directory' "$stderr_file"; then
        printf '%s [%s]: control run failed to load a library:\n' "$entry" "$arguments" >&2
        cat "$stderr_file" >&2
        return 1
      fi
    fi
  done <<<"$(entry_commands "$entry")"
}

check_entry_hard_errors() {
  local entry="$1" libraries library holding
  copy_trees
  # Derive from the copy: it is byte-identical to the tracked script.
  libraries="$(library_files "$TREE/$entry")"
  [ -n "$libraries" ] || { printf '%s names no library\n' "$entry" >&2; return 1; }
  drive_entry "$entry" control
  while IFS= read -r library; do
    holding="$library.removed"
    mv "$library" "$holding"
    if ! drive_entry "$entry" missing "$library"; then
      mv "$holding" "$library"
      return 1
    fi
    mv "$holding" "$library"
  done <<<"$libraries"
}

@test "usage.sh fails loud on each missing library, for every subcommand it drives" {
  check_entry_hard_errors .gaia/scripts/usage.sh
}

@test "usage-flush.sh fails loud on each missing library" {
  check_entry_hard_errors .gaia/scripts/usage-flush.sh
}

@test "usage-merge.sh fails loud on each missing library" {
  check_entry_hard_errors .gaia/scripts/usage-merge.sh
}

@test "pr-merge-cost.sh fails loud on each missing library" {
  check_entry_hard_errors .claude/hooks/pr-merge-cost.sh
}

@test "usage-record-lib.sh loads nothing itself: it is sourced by usage.sh" {
  [ -z "$(source_lines "$REPO_ROOT/.gaia/scripts/usage-record-lib.sh")" ]
  # usage.sh must source it, which the usage.sh case above covers by deriving it.
  grep -q -E 'usage-record-lib\.sh' "$REPO_ROOT/.gaia/scripts/usage.sh"
}

@test "no library source line is swallowed, guarded, indented or conditional" {
  local entry file line count=0 previous
  for entry in .gaia/scripts/usage.sh .gaia/scripts/usage-merge.sh .gaia/scripts/usage-flush.sh \
    .gaia/scripts/usage-record-lib.sh .claude/hooks/pr-merge-cost.sh; do
    file="$REPO_ROOT/$entry"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      count=$((count + 1))
      # A trailing swallow turns a missing library into a quiet success.
      case "$line" in
        *'2>/dev/null || true'* | *'|| true'*) printf '%s: source line swallows failure: %s\n' "$entry" "$line" >&2; return 1 ;;
      esac
      # Top level only: an indented line sits inside a function, case or if.
      case "$line" in
        [[:space:]]*) printf '%s: source line is not at top level: %s\n' "$entry" "$line" >&2; return 1 ;;
      esac
      # A presence guard on the same line.
      case "$line" in
        *'[ -f'* | *'[ -r'*) printf '%s: source line sits behind a presence guard: %s\n' "$entry" "$line" >&2; return 1 ;;
      esac
    done <<<"$(source_lines "$file")"
    # A guard on the line before: `[ -f x ] && ` continued, or an `if`/`case` opener.
    while IFS= read -r previous; do
      [ -n "$previous" ] || continue
      printf '%s: source line follows a condition opener: %s\n' "$entry" "$previous" >&2
      return 1
    done <<<"$(grep -B1 -E "$SOURCE_PATTERN" "$file" | grep -E '^[[:space:]]*(if|elif|case|while|for)[[:space:]]|&&[[:space:]]*\\?$|\|\|[[:space:]]*\\?$' || true)"
  done
  # An empty discovery would pass every assertion above.
  [ "$count" -gt 0 ]
}
