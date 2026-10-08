#!/usr/bin/env bash
#
# Deterministic half of /gaia-audit (.claude/skills/gaia/references/audit.md):
# what the knowledge stores hold, who owns a file an action targets, and
# whether a 0-action report may finalize without a human. The playbook's
# model stages call this rather than computing any of it themselves.
#
# Usage:
#   bash .gaia/scripts/knowledge-inventory.sh list     [--root <project-root>]
#   bash .gaia/scripts/knowledge-inventory.sh counts   [--root <project-root>]
#   bash .gaia/scripts/knowledge-inventory.sh classify [--root <project-root>] <path>...
#   bash .gaia/scripts/knowledge-inventory.sh verify   [--root <project-root>] <report> [--scope-hint <text>]
#
# With no --root the project is the git top level of the working directory.
# The memory dir derives from the root the same way Claude Code keys it, so a
# root given through a symlink names a different memory dir than its target.
#
# list      one `<store>\t<path>\t<words>\t<mtime-epoch>` row per markdown file.
# counts    one line, `<store>=<n>` per store, space separated. Stage 1 copies
#           it verbatim into the report's `store_counts:` frontmatter field.
# classify  one `<class>\t<path>` line per input, in input order:
#             project-memory  under the project's memory dir or its
#                             .claude/agent-memory/ (gitignored, yet the
#                             project's own)
#             user-memory     under ~/.claude/agent-memory/, which every
#                             project on the machine shares
#           anything else is answered by .gaia/scripts/fitness-ownership.sh
#           (third-party, ignored, gaia-shipped, adopter), whose exit status
#           passes through: on a non-zero exit nothing is printed.
# verify    exit 0 and `verified: <counts>` when the report may auto-apply:
#           full scope, no scope hint, no action block, a Summary reading
#           `Actions proposed: 0`, an `## Out-of-scope findings` section (a
#           report cut short lacks its last section), and every store count
#           equal to a fresh recount. Otherwise exit 1 with one `refuse:` line
#           per failed condition.
#
# Exit 2: usage error. Exit 3: an input could not be read.

set -uo pipefail

STORES="memory user_agent_memory project_agent_memory rules wiki claude_md"

fail_usage() {
  printf 'knowledge-inventory: %s\n' "$1" >&2
  exit 2
}

fail_input() {
  printf 'knowledge-inventory: %s\n' "$1" >&2
  exit 3
}

[ "$#" -ge 1 ] || fail_usage "usage: knowledge-inventory.sh list|counts|classify|verify [--root <project-root>] ..."
subcommand="$1"
shift
case "$subcommand" in
  list | counts | classify | verify) ;;
  *) fail_usage "unknown subcommand: $subcommand" ;;
esac

root=""
scope_hint=""
arguments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fail_usage "--root needs a directory"
      root="$2"
      shift 2
      ;;
    --scope-hint)
      [ "$#" -ge 2 ] || fail_usage "--scope-hint needs a value"
      scope_hint="$2"
      shift 2
      ;;
    -*) fail_usage "unknown option: $1" ;;
    *)
      arguments+=("$1")
      shift
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_input "not inside a git work tree; pass --root"
fi
root="${root%/}"
memory_dir="$HOME/.claude/projects/$(printf %s "$root" | sed 's|/|-|g')/memory"
user_agent_memory_dir="$HOME/.claude/agent-memory"

# store_files <store>: the store's markdown files, one per line, sorted.
store_files() {
  case "$1" in
    memory) find "$memory_dir" -type f -name '*.md' 2>/dev/null ;;
    user_agent_memory) find "$user_agent_memory_dir" -type f -name '*.md' 2>/dev/null ;;
    project_agent_memory) find "$root/.claude/agent-memory" -type f -name '*.md' 2>/dev/null ;;
    rules) find "$root/.claude/rules" -type f -name '*.md' 2>/dev/null ;;
    wiki) find "$root/wiki" -type f -name '*.md' 2>/dev/null ;;
    # Depth 3 reaches a package's CLAUDE.md (frontend/CLAUDE.md) without
    # descending into .claude/worktrees/, where each linked tree's own copy sits.
    claude_md) find "$root" -maxdepth 3 -name CLAUDE.md -not -path '*/node_modules/*' 2>/dev/null ;;
  esac | LC_ALL=C sort
}

count_line() {
  local store line=""
  for store in $STORES; do
    line+="$store=$(store_files "$store" | grep -c .)"$' '
  done
  printf '%s\n' "${line% }"
}

modification_epoch() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

list_rows() {
  local store file words
  for store in $STORES; do
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      words="$(wc -w <"$file" | tr -d '[:space:]')"
      printf '%s\t%s\t%s\t%s\n' "$store" "$file" "$words" "$(modification_epoch "$file")"
    done < <(store_files "$store")
  done
}

# memory_class <path>: project-memory or user-memory for a path inside a
# memory store, nothing otherwise. A `..` segment never matches, so a path
# that climbs out of a store falls through to the ownership classifier.
memory_class() {
  case "/$1/" in */../*) return 0 ;; esac
  case "$1" in
    "$memory_dir"/* | "$root"/.claude/agent-memory/* | .claude/agent-memory/*) printf 'project-memory' ;;
    "$user_agent_memory_dir"/*) printf 'user-memory' ;;
  esac
}

classify_paths() {
  [ "${#arguments[@]}" -gt 0 ] || fail_usage "usage: knowledge-inventory.sh classify [--root <project-root>] <path>..."
  local given class delegated=() classified="" index=0 line
  for given in "${arguments[@]}"; do
    [ -n "$(memory_class "$given")" ] || delegated+=("$given")
  done
  if [ "${#delegated[@]}" -gt 0 ]; then
    classified="$(bash "${KNOWLEDGE_OWNERSHIP_CLASSIFIER:-$(dirname "$0")/fitness-ownership.sh}" --root "$root" -- "${delegated[@]}")" || exit "$?"
  fi
  local classified_lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && classified_lines+=("$line")
  done <<<"$classified"
  for given in "${arguments[@]}"; do
    class="$(memory_class "$given")"
    if [ -n "$class" ]; then
      case "$given" in
        "$root"/*) given="${given#"$root"/}" ;;
      esac
      printf '%s\t%s\n' "$class" "$given"
    else
      printf '%s\n' "${classified_lines[$index]}"
      index=$((index + 1))
    fi
  done
}

# frontmatter_value <report> <key>: the value of <key> in the report's
# leading `---` block, or nothing.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ":") == 1 { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

verify_report() {
  [ "${#arguments[@]}" -eq 1 ] || fail_usage "usage: knowledge-inventory.sh verify [--root <project-root>] <report> [--scope-hint <text>]"
  local report="${arguments[0]}"
  [ -f "$report" ] && [ -r "$report" ] || fail_input "cannot read report $report"

  local refusals=() scope action_blocks recorded recomputed store report_count recomputed_count
  [ -z "$scope_hint" ] || refusals+=("scope hint given ($scope_hint); a scoped run never auto-applies")
  scope="$(frontmatter_value "$report" scope)"
  [ "$scope" = "full" ] || refusals+=("report scope is ${scope:-unset}, not full")
  action_blocks="$(grep -cE '^- \[.\] `' "$report")"
  [ "$action_blocks" -eq 0 ] || refusals+=("report carries $action_blocks action block(s)")
  grep -qxE -- '- Actions proposed: 0' "$report" || refusals+=("Summary does not read Actions proposed: 0")
  grep -qx '## Out-of-scope findings' "$report" || refusals+=("report has no ## Out-of-scope findings section")

  recorded=" $(frontmatter_value "$report" store_counts) "
  recomputed="$(count_line)"
  for store in $STORES; do
    report_count="$(tr ' ' '\n' <<<"$recorded" | sed -n "s/^$store=//p")"
    recomputed_count="$(tr ' ' '\n' <<<"$recomputed" | sed -n "s/^$store=//p")"
    [ "$report_count" = "$recomputed_count" ] ||
      refusals+=("store $store: report ${report_count:-none}, recomputed $recomputed_count")
  done

  if [ "${#refusals[@]}" -gt 0 ]; then
    printf 'refuse: %s\n' "${refusals[@]}"
    exit 1
  fi
  printf 'verified: %s\n' "$recomputed"
}

case "$subcommand" in
  list) list_rows ;;
  counts) count_line ;;
  classify) classify_paths ;;
  verify) verify_report ;;
esac
