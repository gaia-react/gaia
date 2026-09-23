#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/knowledge-audit-clean.sh, the check that
# decides whether a zero-action /gaia-audit report may skip the decision gate.
#
# The store set is derived from the report template's `## Coverage` table in
# .claude/skills/gaia/references/audit.md, and the inventory `find` lines from
# its Step 1 block, so a store added to the playbook without the script
# learning it reds here instead of passing over a subset.
#
# Fixtures build a throwaway HOME and project root under $BATS_TEST_TMPDIR;
# nothing reads the real stores.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$THIS_DIR/../knowledge-audit-clean.sh"
  REPO_ROOT="$(cd "$THIS_DIR/../../.." && pwd)"
  AUDIT_MD="$REPO_ROOT/.claude/skills/gaia/references/audit.md"
  [ -f "$SCRIPT" ] || skip "knowledge-audit-clean.sh not present"

  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  PROJ="$BATS_TEST_TMPDIR/proj"
  # shellcheck disable=SC2001
  MEM="$FAKE_HOME/.claude/projects/$(echo "$PROJ" | sed 's|/|-|g')/memory"
  AGENT_MEM="$FAKE_HOME/.claude/agent-memory"
  REPORT="$BATS_TEST_TMPDIR/KNOWLEDGE-test.md"

  mkdir -p "$MEM" "$AGENT_MEM/some-agent" "$PROJ/.claude/agent-memory" \
    "$PROJ/.claude/rules" "$PROJ/wiki/concepts" "$PROJ/pkg" "$PROJ/node_modules/x"
  : >"$MEM/MEMORY.md"
  : >"$MEM/entry-a.md"
  : >"$AGENT_MEM/some-agent/notes.md"
  : >"$PROJ/.claude/agent-memory/a.md"
  : >"$PROJ/.claude/rules/r1.md"
  : >"$PROJ/.claude/rules/r2.md"
  : >"$PROJ/.claude/rules/r3.md"
  : >"$PROJ/wiki/index.md"
  : >"$PROJ/wiki/concepts/A.md"
  : >"$PROJ/CLAUDE.md"
  : >"$PROJ/pkg/CLAUDE.md"
  # Within -maxdepth 3 but inside node_modules, so Step 1's CLAUDE.md line must not count it.
  : >"$PROJ/node_modules/x/CLAUDE.md"

  DROP="" SHORT_INV="" SHORT_CLS="" ACTIONS="0" SCOPE="full" EXTRA="" FM_MEM="$MEM"
}

# The fixture's true file count per store id. An id the template names but
# this table does not know fails the calling test rather than guessing.
fixture_count() {
  case "$1" in
    memory) echo 2 ;;
    agent-memory) echo 1 ;;
    project-agent-memory) echo 1 ;;
    rules) echo 3 ;;
    wiki) echo 2 ;;
    claude-md) echo 2 ;;
    *)
      echo "fixture has no count for store '$1'" >&2
      return 1
      ;;
  esac
}

# Template Coverage rows as `<id> <classified|na>`, one per line, from the
# block between the template's `## Coverage` and `## Actions` headings.
template_stores() {
  awk '
    /^## Coverage$/ { on = 1; next }
    on && /^## / { exit }
    on && /^\| / {
      n = split($0, c, "|")
      id = c[2]; cls = c[4]
      gsub(/^[ \t]+|[ \t]+$/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", cls)
      if (id == "Store" || id ~ /^-+$/) next
      print id, (cls == "n/a" ? "na" : "classified")
    }
  ' "$AUDIT_MD"
}

# Step 1's inventory `find` lines, verbatim.
step1_find_lines() {
  awk '
    /^## Step 1, Inventory/ { on = 1; next }
    on && /^## Step 2/ { exit }
    on && /^find / { print }
  ' "$AUDIT_MD"
}

write_report() {
  {
    printf -- '---\ngenerated: 2026-01-01 00:00\nstatus: draft\n'
    printf 'project_root: %s\nmemory_dir: %s\nagent_memory_dir: %s\n' "$PROJ" "$FM_MEM" "$AGENT_MEM"
    printf -- '---\n\n# Knowledge Audit\n\n## Summary\n\n'
    printf -- '- Stores scanned: 11 files, 0 words total\n'
    [ "$ACTIONS" = "<none>" ] || printf -- '- Actions proposed: %s\n' "$ACTIONS"
    printf -- '- Applied scope: %s\n\n## Coverage\n\n' "$SCOPE"
    printf '| Store | Inventoried | Classified |\n| --- | --- | --- |\n'
    template_stores | while read -r id kind; do
      [ "$id" = "$DROP" ] && continue
      n="$(fixture_count "$id")" || exit 1
      inv="$n"
      [ "$id" = "$SHORT_INV" ] && inv=$((n - 1))
      if [ "$kind" = "na" ]; then
        cls="n/a"
      else
        cls="$n"
        [ "$id" = "$SHORT_CLS" ] && cls=$((n - 1))
      fi
      printf '| %s | %s | %s |\n' "$id" "$inv" "$cls"
    done
    printf '\n## Actions\n\n%s\n## Out-of-scope findings\n\nNone.\n' "$EXTRA"
  } >"$REPORT"
}

run_check() {
  run env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPT" "$@"
}

# Every store the template names, read once and counted, so a derivation that
# comes back short or empty stops the suite rather than shrinking it.
derived_stores() {
  stores="$(template_stores | awk '{ print $1 }')"
  rows="$(awk '/^## Coverage$/{on=1;next} on&&/^## /{exit} on&&/^\| /' "$AUDIT_MD" | grep -vc -e '^| Store ' -e '^| ---')"
  got="$(printf '%s\n' "$stores" | grep -c .)"
  [ "$rows" -gt 0 ] || return 1
  [ "$got" -eq "$rows" ] || return 1
}

@test "template has exactly one Coverage table and Step 1 a find line per store" {
  [ "$(grep -c '^## Coverage$' "$AUDIT_MD")" -eq 1 ]
  derived_stores
  finds="$(step1_find_lines | grep -c .)"
  [ "$finds" -eq "$(printf '%s\n' "$stores" | grep -c .)" ]
}

@test "every Step 1 find line appears verbatim in the script" {
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    grep -qF -- "$line" "$SCRIPT" || {
      echo "not in script: $line" >&2
      return 1
    }
  done < <(step1_find_lines)
  [ "$n" -gt 0 ]
}

@test "a complete record with zero actions and full scope is clean" {
  write_report
  run_check "$REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "each template store's missing Coverage row routes to the gate" {
  derived_stores
  for id in $stores; do
    DROP="$id"
    write_report
    run_check "$REPORT"
    [ "$status" -eq 1 ] || return 1
    grep -qF -- "no Coverage row for store $id" <<<"$output" || return 1
  done
}

@test "each template store's short Inventoried count routes to the gate" {
  derived_stores
  for id in $stores; do
    SHORT_INV="$id"
    write_report
    run_check "$REPORT"
    [ "$status" -eq 1 ] || return 1
    grep -qF -- "store $id: Inventoried" <<<"$output" || return 1
  done
}

@test "each classified store's short Classified count routes to the gate" {
  n=0
  while read -r id kind; do
    [ "$kind" = "classified" ] || continue
    n=$((n + 1))
    SHORT_CLS="$id"
    write_report
    run_check "$REPORT"
    [ "$status" -eq 1 ] || return 1
    grep -qF -- "store $id: Classified" <<<"$output" || return 1
  done < <(template_stores)
  [ "$n" -gt 0 ]
}

@test "a store that grew after Stage 1 routes to the gate" {
  write_report
  : >"$PROJ/.claude/rules/r4.md"
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "store rules: Inventoried '3' but Step 1 finds 4" <<<"$output"
}

@test "a report with no Coverage section routes to the gate" {
  write_report
  awk '/^## Coverage$/{skip=1;next} skip&&/^## /{skip=0} !skip' "$REPORT" >"$REPORT.tmp"
  mv "$REPORT.tmp" "$REPORT"
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "no Coverage row for store" <<<"$output"
}

@test "a missing Actions proposed line routes to the gate" {
  ACTIONS="<none>"
  write_report
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "Actions proposed is '<missing>', not 0" <<<"$output"
}

@test "a nonzero Actions proposed line routes to the gate" {
  ACTIONS="2"
  write_report
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "Actions proposed is '2', not 0" <<<"$output"
}

# Action kinds as the template's `<kind>-{nnn}` checkbox lines spell them, so
# a kind added to the playbook, or one dropped from the script's block regex,
# reds here instead of the suite exercising only the kind it names.
template_action_kinds() {
  # shellcheck disable=SC2016
  sed -n 's/^- \[ \] `\([a-z-]*\)-{nnn}`.*/\1/p' "$AUDIT_MD"
}

@test "each template action kind under a zero Summary line routes to the gate" {
  n=0
  while read -r kind; do
    n=$((n + 1))
    EXTRA="- [ ] \`${kind}-001\`"
    write_report
    run_check "$REPORT"
    [ "$status" -eq 1 ] || return 1
    grep -qF -- "report carries 1 action block(s)" <<<"$output" || return 1
  done < <(template_action_kinds)
  # Every checkbox action line the template carries, counted by a looser
  # pattern than the derivation, so a kind the derivation cannot spell reds
  # as a short read instead of dropping out of the loop.
  [ "$n" -gt 0 ]
  # shellcheck disable=SC2016
  [ "$n" -eq "$(grep -c '^- \[ \] `.*-{nnn}`' "$AUDIT_MD")" ]
}

@test "a scope-narrowed run routes to the gate" {
  SCOPE="rules only"
  write_report
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "Applied scope is 'rules only', not full" <<<"$output"
}

@test "a report whose recorded memory_dir differs from the resolved one routes to the gate" {
  FM_MEM="$BATS_TEST_TMPDIR/elsewhere/memory"
  write_report
  run_check "$REPORT"
  [ "$status" -eq 1 ]
  grep -qF -- "frontmatter memory_dir is '$FM_MEM'" <<<"$output"
}

@test "a missing report path is a usage error" {
  run_check "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 2 ]
  grep -qF -- "no report at" <<<"$output"
}

@test "no argument is a usage error" {
  run_check
  [ "$status" -eq 2 ]
  grep -qF -- "usage:" <<<"$output"
}
