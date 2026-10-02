#!/usr/bin/env bats

# Static guard for the workflow doctrine sources: the always-loaded rule, the
# injected execution doctrine, the wiki page, the hook, and their registrations.
#
# Each guard is a helper that takes the file (or root) to check, so the same
# helper runs once on the real tree (must pass) and once on a mutated scratch
# copy (must fail). Helpers return explicitly (never lean on `set -e`, which is
# suppressed inside `if`/`||`); tests call them in `if` form so a red twin that
# stops failing fails the test.

bats_require_minimum_version 1.5.0

setup() {
  # Isolate the rates state and the price feed (token-rates-hermetic.bats).
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULE="$REPO_ROOT/.claude/rules/context-discipline.md"
  DOCTRINE_PATH="$REPO_ROOT/.claude/doctrine/execution.md"
  HOOK="$REPO_ROOT/.claude/hooks/workflow-doctrine-inject.sh"
  WIKI="$REPO_ROOT/wiki/concepts/Workflow Doctrine.md"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  TASK_ORCHESTRATION="$REPO_ROOT/wiki/concepts/Task Orchestration.md"
  PLANMD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  DEBTMD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  MODEL_RE='\b(opus|sonnet|haiku|fable)\b|claude-(opus|sonnet|haiku|fable)'
  BAN_TERMS=("executor" "commit" "git" "worktree" "branch" "quality gate" "push" "merge" "pull request")
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

rule_budget_ok() {
  local file_path="$1" nonblank_line_count
  [ -f "$file_path" ] || return 1
  [ "$(head -n 1 "$file_path")" = "---" ] && return 1
  grep -q '^paths:' "$file_path" && return 1
  nonblank_line_count="$(grep -c '[^[:space:]]' "$file_path")"
  [ "$nonblank_line_count" -le 8 ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 1200 ] || return 1
  return 0
}

BAN_VISITED=0
rule_ban_ok() {
  local file_path="$1" ban_term
  BAN_VISITED=0
  [ -f "$file_path" ] || return 1
  for ban_term in "${BAN_TERMS[@]}"; do
    BAN_VISITED=$((BAN_VISITED + 1))
    grep -qiF -- "$ban_term" "$file_path" && return 1
  done
  grep -qiE '\bPR\b' "$file_path" && return 1
  return 0
}

rule_directives_ok() {
  local file_path="$1" required_phrase
  [ -f "$file_path" ] || return 1
  for required_phrase in '.claude/rules/subagent-dispatch.md' 'wiki/concepts/Workflow Doctrine.md' \
    '.gaia/local/research/<topic>-<date>/' 'rewritten in place'; do
    grep -qF -- "$required_phrase" "$file_path" || return 1
  done
  grep -qiF -- 'never appended' "$file_path" || return 1
  return 0
}

document_shape_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 3584 ] || return 1
  [ "$(tail -c 1 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  [ "$(tail -c 2 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a0a" ] && return 1
  LC_ALL=C grep -q $'[\x01-\x09\x0b-\x1f\x7f]' "$file_path" && return 1
  return 0
}

document_placement_ok() {
  local root="$1"
  [ -f "$root/.claude/doctrine/execution.md" ] || return 1
  [ -z "$(find "$root/.claude/rules" -name 'execution.md' 2>/dev/null)" ] || return 1
  return 0
}

# key line the hook emits for a branch name, then the payload size with a doctrine file
payload_ok() {
  local file_path="$1" name keyline total
  name="feat/$(head -c 123 /dev/zero | tr '\0' a)"
  [ "${#name}" = 128 ] || return 1
  keyline="Branch key: branch:$name. Link its initiative once with: bash .gaia/scripts/usage.sh link branch:$name research:<topic>-<date> (or issue:<n>)"
  total=$(($(printf '%s\n' "$keyline" | wc -c) + $(wc -c <"$file_path")))
  PAYLOAD_TOTAL="$total"
  [ "$total" -le 4096 ] || return 1
  return 0
}

ANCHORS=(
  'F|wiki/concepts/Workflow Doctrine.md'
  'F|wiki/decisions/Quality Gate.md'
  'F|plan JSON'
  'I|never run git'
  'F|stage, commit, push, branch'
  'I|once per commit'
  'I|verifier'
  'F|depth-1'
  'F|edit-run-fix'
  'F|.gaia/local/runs/feat/9-sample/'
  'F|.gaia/local/runs/session-<session id>/'
  'F|STATE.md'
  'F|NEXT:'
  'F|4 KB'
  'F|<role>-<round>-<slug>.json'
  'F|log.md'
  'R|never read.*log\.md'
  'F|printf'
  'F|bash .gaia/scripts/usage.sh link branch:<normalized> research:<topic>-<date>'
  'F|issue:<n>'
  'F|bash .gaia/scripts/usage.sh declare research:<topic>-<date>'
  'F|.gaia/state-registry.json'
  'I|own contract governs'
  'I|read them back'
  'I|never through Edit or Write'
  'I|does not bind'
  'I|re-keys only'
  'I|needs the user'
  'I|cannot prompt'
  'F|audit-loop-unit'
  'I|sanctioned depth-2 orchestrator'
  'I|state-changing git and the Quality Gate'
)

anchors_ok() {
  local file_path="$1" anchor kind pattern
  [ -f "$file_path" ] || return 1
  for anchor in "${ANCHORS[@]}"; do
    kind="${anchor%%|*}"
    pattern="${anchor#*|}"
    case "$kind" in
      F) grep -qF -- "$pattern" "$file_path" || return 1 ;;
      I) grep -qiF -- "$pattern" "$file_path" || return 1 ;;
      R) grep -qiE -- "$pattern" "$file_path" || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

no_model_names_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -niE "$MODEL_RE" "$file_path" >/dev/null && return 1
  return 0
}

# prints "<start> <end>" of the first contiguous `|` block after the Model table heading
wiki_model_block() {
  awk '
    $0 == "## Model table" { on = 1; next }
    on && /^## / { exit }
    on && /^\|/ { if (!block_start) block_start = NR; block_end = NR; next }
    on && block_start && !/^\|/ { exit }
    END { print block_start, block_end }
  ' "$1"
}

WIKI_MATCHES=0
wiki_models_ok() {
  local file_path="$1" block_start_line block_end_line line_number rows
  [ -f "$file_path" ] || return 1
  read -r block_start_line block_end_line <<<"$(wiki_model_block "$file_path")"
  [ -n "$block_start_line" ] && [ -n "$block_end_line" ] || return 1
  WIKI_MATCHES=0
  while IFS= read -r line_number; do
    WIKI_MATCHES=$((WIKI_MATCHES + 1))
    [ "$line_number" -ge "$block_start_line" ] && [ "$line_number" -le "$block_end_line" ] || return 1
  done < <(grep -niE "$MODEL_RE" "$file_path" | cut -d: -f1)
  [ $((block_end_line - block_start_line + 1 - 2)) -eq 3 ] || return 1
  rows="$(sed -n "${block_start_line},${block_end_line}p" "$file_path" | awk -F'|' 'NR > 2 { gsub(/^ +| +$/, "", $2); print $2 }')"
  [ "$rows" = "$(printf 'sweep\nscoped implementation\nsynthesis')" ] || return 1
  return 0
}

WIKI_HEADINGS=(
  '## Roles' '## Inline floor' '## Model table' '## Run folder and checkpoint' '## Resume'
  '## Concurrency limits' '## Initiative linking' '## Research attribution' '## Injection hook'
  '## Measurements' '## Post-landing success check' '## See also'
)
START_MARK='<!-- gaia:maintainer-only:start -->'
END_MARK='<!-- gaia:maintainer-only:end -->'

line_of() { grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1; }

wiki_structure_ok() {
  local file_path="$1" heading previous_line_number=0 line_number measurements_heading_line success_check_heading_line start_marker_line end_marker_line
  [ -f "$file_path" ] || return 1
  for heading in "${WIKI_HEADINGS[@]}"; do
    line_number="$(line_of "$file_path" "$heading")"
    [ -n "$line_number" ] || return 1
    [ "$line_number" -gt "$previous_line_number" ] || return 1
    previous_line_number="$line_number"
  done
  grep -qF '.claude/doctrine/execution.md' "$file_path" || return 1
  grep -qF '.claude/rules/context-discipline.md' "$file_path" || return 1
  [ "$(grep -cxF -- "$START_MARK" "$file_path")" = 1 ] || return 1
  [ "$(grep -cxF -- "$END_MARK" "$file_path")" = 1 ] || return 1
  start_marker_line="$(line_of "$file_path" "$START_MARK")"
  end_marker_line="$(line_of "$file_path" "$END_MARK")"
  measurements_heading_line="$(line_of "$file_path" '## Measurements')"
  success_check_heading_line="$(line_of "$file_path" '## Post-landing success check')"
  [ "$start_marker_line" -lt "$measurements_heading_line" ] || return 1
  [ "$measurements_heading_line" -lt "$success_check_heading_line" ] || return 1
  [ "$success_check_heading_line" -lt "$end_marker_line" ] || return 1
  return 0
}

wiki_exception_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -qiF 'sanctioned depth-2 orchestrator' "$file_path" || return 1
  grep -qF 'audit-loop-unit' "$file_path" || return 1
  grep -qiF 'state-changing git' "$file_path" || return 1
  return 0
}

no_ids_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -nE 'UAT-[0-9]+|SPEC-[0-9]+' "$file_path" >/dev/null && return 1
  return 0
}

presence_ok() {
  local root="$1" relative_path
  shift
  [ "$#" -gt 0 ] || return 1
  for relative_path in "$@"; do
    [ -e "$root/$relative_path" ] || return 1
  done
  return 0
}

ledger_names_ok() {
  local file_path
  [ "$#" -gt 0 ] || return 1
  for file_path in "$@"; do
    [ -f "$file_path" ] || return 1
    grep -nE 'links\.jsonl|usage\.jsonl' "$file_path" >/dev/null && return 1
  done
  return 0
}

settings_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  jq -e '[.hooks.SessionStart[]
      | select(((.matcher // "") as $m
          | ($m == "" or ((["startup","resume","clear","compact"] - ($m | split("|"))) | length == 0)))
        and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.SessionStart[] | select(any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "EnterWorktree" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Bash" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  return 0
}

not_excluded_ok() {
  local exclude="$1" path="$2" line
  [ -f "$exclude" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    line="${line%/}"
    [ -n "$line" ] || continue
    case "$path" in
      "$line" | "$line"/*) return 1 ;;
    esac
  done <"$exclude"
  return 0
}

registry_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  jq -e '[.entries[] | select(.path == "runs/" and .scope == "shared"
      and (.keyed_by | type == "string" and length > 0) and has("reaped_by"))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.entries[] | select(.path == "cache/doctrine-injected.*" and .scope == "main-only"
      and .keyed_by == null and has("reaped_by"))] | length == 1' "$file_path" >/dev/null || return 1
  return 0
}

task_orchestration_links_ok() {
  local file_path="$1" first_paragraph
  [ -f "$file_path" ] || return 1
  first_paragraph="$(awk '
    !in_heading && /^# / { in_heading = 1; next }
    in_heading && !in_paragraph && /^[[:space:]]*$/ { next }
    in_heading && /^[[:space:]]*$/ { exit }
    in_heading { in_paragraph = 1; print }
  ' "$file_path")"
  [ -n "$first_paragraph" ] || return 1
  case "$first_paragraph" in *'[[Workflow Doctrine]]'*) ;; *) return 1 ;; esac
  grep -qxF '## Plan artifacts' "$file_path" || return 1
  grep -qxF '## Execution lifecycle' "$file_path" || return 1
  return 0
}

plan_pointer_ok() {
  local file_path="$1" first rule
  [ -f "$file_path" ] || return 1
  first="$(grep -n 'Workflow Doctrine' "$file_path" | head -n 1 | cut -d: -f1)"
  rule="$(grep -n '^---$' "$file_path" | head -n 1 | cut -d: -f1)"
  [ -n "$first" ] || return 1
  if [ -n "$rule" ]; then [ "$first" -lt "$rule" ] || return 1; fi
  return 0
}

no_model_rows_ok() {
  local file_path="$1" row_prefix
  [ -f "$file_path" ] || return 1
  grep -qF 'Workflow Doctrine' "$file_path" || return 1
  for row_prefix in '| sweep' '| scoped implementation' '| synthesis'; do
    grep -qF -- "$row_prefix" "$file_path" && return 1
  done
  return 0
}

pad_to() { # pad_to <src> <dst> <total bytes>: src plus filler so dst ends in one newline at <total> bytes
  local base
  base="$(wc -c <"$1" | tr -d ' ')"
  { cat "$1"; head -c $(($3 - base - 1)) /dev/zero | tr '\0' x; printf '\n'; } >"$2"
}

# ----------------------------------------------------------- 1. rule budget

@test "rule budget: the real rule is within 8 lines, 1200 bytes, no frontmatter" {
  rule_budget_ok "$RULE"
}

@test "rule budget red twins: frontmatter, 1201 bytes, and 9 lines each fail" {
  printf -- '---\npaths:\n  - "x"\n---\n' | cat - "$RULE" >"$TEMPORARY_DIRECTORY/fm.md"
  if rule_budget_ok "$TEMPORARY_DIRECTORY/fm.md"; then return 1; fi
  printf 'paths: x\n' | cat - "$RULE" >"$TEMPORARY_DIRECTORY/paths.md"
  if rule_budget_ok "$TEMPORARY_DIRECTORY/paths.md"; then return 1; fi
  pad_to "$RULE" "$TEMPORARY_DIRECTORY/big.md" 1201
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/big.md" | tr -d ' ')" -eq 1201 ]
  if rule_budget_ok "$TEMPORARY_DIRECTORY/big.md"; then return 1; fi
  cp "$RULE" "$TEMPORARY_DIRECTORY/nine.md"
  while [ "$(grep -c '[^[:space:]]' "$TEMPORARY_DIRECTORY/nine.md")" -lt 9 ]; do printf '%s\n' '- x' >>"$TEMPORARY_DIRECTORY/nine.md"; done
  [ "$(grep -c '[^[:space:]]' "$TEMPORARY_DIRECTORY/nine.md")" -eq 9 ]
  if rule_budget_ok "$TEMPORARY_DIRECTORY/nine.md"; then return 1; fi
}

# ------------------------------------------------------------ 2. ban list

@test "rule ban list: none of the nine terms or \\bPR\\b appear in the real rule" {
  [ "${#BAN_TERMS[@]}" -eq 9 ]
  rule_ban_ok "$RULE"
  [ "$BAN_VISITED" -eq 9 ]
}

@test "rule ban list red twins: every term, a PR token, and the substring 'digit' are each caught" {
  local ban_term i=0
  [ "${#BAN_TERMS[@]}" -eq 9 ]
  for ban_term in "${BAN_TERMS[@]}"; do
    i=$((i + 1))
    { cat "$RULE"; printf 'a line about %s here\n' "$ban_term"; } >"$TEMPORARY_DIRECTORY/ban-$i.md"
    if rule_ban_ok "$TEMPORARY_DIRECTORY/ban-$i.md"; then return 1; fi
  done
  [ "$i" -eq 9 ]
  { cat "$RULE"; printf 'a line about PR here\n'; } >"$TEMPORARY_DIRECTORY/pr.md"
  if rule_ban_ok "$TEMPORARY_DIRECTORY/pr.md"; then return 1; fi
  { cat "$RULE"; printf 'the digit seven\n'; } >"$TEMPORARY_DIRECTORY/digit.md"
  if rule_ban_ok "$TEMPORARY_DIRECTORY/digit.md"; then return 1; fi
}

# ------------------------------------------------------- 3. rule directives

@test "rule directives: the five C4 literals are present" {
  rule_directives_ok "$RULE"
}

@test "rule directives red twin: dropping the dispatch pointer line fails" {
  grep -vF 'subagent-dispatch.md' "$RULE" >"$TEMPORARY_DIRECTORY/nodispatch.md"
  [ "$(wc -l <"$TEMPORARY_DIRECTORY/nodispatch.md" | tr -d ' ')" -lt "$(wc -l <"$RULE" | tr -d ' ')" ]
  if rule_directives_ok "$TEMPORARY_DIRECTORY/nodispatch.md"; then return 1; fi
}

# ------------------------------------------------- 4. execution.md budget

@test "execution.md: size, single trailing newline, no control characters" {
  document_shape_ok "$DOCTRINE_PATH"
}

@test "execution.md placement: lives under .claude/doctrine, not under .claude/rules" {
  document_placement_ok "$REPO_ROOT"
  mkdir -p "$TEMPORARY_DIRECTORY/bad/.claude/rules" "$TEMPORARY_DIRECTORY/bad/.claude/doctrine"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/bad/.claude/doctrine/execution.md"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/bad/.claude/rules/execution.md"
  if document_placement_ok "$TEMPORARY_DIRECTORY/bad"; then return 1; fi
  mkdir -p "$TEMPORARY_DIRECTORY/moved/.claude/rules"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/moved/.claude/rules/execution.md"
  if document_placement_ok "$TEMPORARY_DIRECTORY/moved"; then return 1; fi
}

@test "execution.md red twins: 3585 bytes, trailing blank line, and a control character each fail" {
  pad_to "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/over.md" 3585
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/over.md" | tr -d ' ')" -eq 3585 ]
  if document_shape_ok "$TEMPORARY_DIRECTORY/over.md"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf '\n'; } >"$TEMPORARY_DIRECTORY/blank.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/blank.md"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf 'tab\there\n'; } >"$TEMPORARY_DIRECTORY/tab.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/tab.md"; then return 1; fi
}

# -------------------------------------------------------- 5. payload cap

@test "payload cap: key line for a 128-character branch plus execution.md is at most 4096 bytes" {
  payload_ok "$DOCTRINE_PATH"
  [ "$PAYLOAD_TOTAL" -gt "$(wc -c <"$DOCTRINE_PATH" | tr -d ' ')" ]
}

@test "payload cap red twin: an oversize doctrine copy fails the same check" {
  pad_to "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/big.md" 3800
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/big.md" | tr -d ' ')" -eq 3800 ]
  if payload_ok "$TEMPORARY_DIRECTORY/big.md"; then return 1; fi
}

# ----------------------------------------------------------- 6. anchors

@test "execution.md anchors: all 32 C3 literals are present" {
  [ "${#ANCHORS[@]}" -eq 32 ]
  anchors_ok "$DOCTRINE_PATH"
}

@test "execution.md anchors red twins: NEXT:, the never-read line, and the Edit-or-Write clause each fail" {
  sed 's/NEXT://g' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/nonext.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/nonext.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/nonext.md"; then return 1; fi
  grep -viE 'never read.*log\.md' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/noread.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/noread.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/noread.md"; then return 1; fi
  sed 's/never through Edit or Write//g' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/noewr.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/noewr.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/noewr.md"; then return 1; fi
}

@test "execution.md exception red twin: dropping the audit-loop-unit sentence fails the anchors, and the real file names it" {
  grep -qF 'audit-loop-unit' "$DOCTRINE_PATH"
  grep -vF 'audit-loop-unit' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/noexc.md"
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/noexc.md" | tr -d ' ')" -lt "$(wc -c <"$DOCTRINE_PATH" | tr -d ' ')" ]
  if anchors_ok "$TEMPORARY_DIRECTORY/noexc.md"; then return 1; fi
  sed 's/sanctioned depth-2 orchestrator/orchestrator/' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/nosanction.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/nosanction.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/nosanction.md"; then return 1; fi
}

@test "wiki exception: Workflow Doctrine names audit-loop-unit as the sanctioned depth-2 exception, twin without it fails" {
  wiki_exception_ok "$WIKI"
  grep -vF 'audit-loop-unit' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-noexc.md"
  if wiki_exception_ok "$TEMPORARY_DIRECTORY/wiki-noexc.md"; then return 1; fi
}

# -------------------------------------------------------- 7. model names

@test "model names: none in the rule or execution.md; wiki mentions sit in the three-row table" {
  no_model_names_ok "$RULE"
  no_model_names_ok "$DOCTRINE_PATH"
  wiki_models_ok "$WIKI"
  [ "$WIKI_MATCHES" -gt 0 ]
}

@test "model names red twins: Opus under Resume, Haiku in the rule, and a fourth table row each fail" {
  awk '{ print } /^## Resume$/ { print "Opus is mentioned here." }' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-opus.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-opus.md"; then return 1; fi
  if wiki_models_ok "$TEMPORARY_DIRECTORY/wiki-opus.md"; then return 1; fi
  { cat "$RULE"; printf 'Haiku\n'; } >"$TEMPORARY_DIRECTORY/rule-haiku.md"
  if no_model_names_ok "$TEMPORARY_DIRECTORY/rule-haiku.md"; then return 1; fi
  awk '{ print } /^\| synthesis/ { print "| extra | Sonnet | why | note |" }' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-row.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-row.md"; then return 1; fi
  if wiki_models_ok "$TEMPORARY_DIRECTORY/wiki-row.md"; then return 1; fi
}

# ------------------------------------------------ 8. wiki headings and markers

@test "wiki structure: C5 headings in order, source links, maintainer markers bracket both sections" {
  [ "${#WIKI_HEADINGS[@]}" -eq 12 ]
  wiki_structure_ok "$WIKI"
}

@test "wiki structure red twin: the end marker moved above Post-landing success check fails" {
  awk -v end_marker="$END_MARK" '
    $0 == end_marker { next }
    $0 == "## Post-landing success check" { print end_marker }
    { print }
  ' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-marker.md"
  [ "$(grep -cxF -- "$END_MARK" "$TEMPORARY_DIRECTORY/wiki-marker.md")" -eq 1 ]
  if wiki_structure_ok "$TEMPORARY_DIRECTORY/wiki-marker.md"; then return 1; fi
}

# ------------------------------------------------------- 9. no working-doc ids

@test "no working-doc ids: rule, execution.md, wiki page, and hook carry no SPEC or UAT id" {
  no_ids_ok "$RULE"
  no_ids_ok "$DOCTRINE_PATH"
  no_ids_ok "$WIKI"
  no_ids_ok "$HOOK"
}

@test "no working-doc ids red twin: a hook copy with a SPEC reference fails" {
  { cat "$HOOK"; printf '# see SPEC-123\n'; } >"$TEMPORARY_DIRECTORY/hook-id.sh"
  if no_ids_ok "$TEMPORARY_DIRECTORY/hook-id.sh"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf 'see UAT-9\n'; } >"$TEMPORARY_DIRECTORY/doc-id.md"
  if no_ids_ok "$TEMPORARY_DIRECTORY/doc-id.md"; then return 1; fi
}

# ------------------------------------------ 10. presence and ledger internals

PRESENCE_PATHS=(
  '.claude/rules/context-discipline.md'
  '.claude/doctrine/execution.md'
  '.claude/hooks/workflow-doctrine-inject.sh'
  '.gaia/tests/hooks/workflow-doctrine-inject.bats'
  '.gaia/scripts/tests/usage-research-binding.bats'
  '.gaia/tests/hooks/workflow-doctrine-timing.sh'
  'wiki/concepts/Workflow Doctrine.md'
  '.gaia/tests/hooks/workflow-doctrine-sources.bats'
  '.claude/rules/wiki-style.md'
  '.claude/settings.json'
  '.gaia/state-registry.json'
  '.gaia/tests/hooks/block-worktree-path-mismatch.bats'
  '.gaia/scripts/tests/state-registry-lib.bats'
  '.gaia/tests/hooks/verb-arming-cost.bats'
  'wiki/concepts/Task Orchestration.md'
  '.claude/skills/gaia/references/plan.md'
  '.claude/skills/gaia/references/debt.md'
  'wiki/index.md'
  'wiki/concepts/Claude Hooks.md'
  'wiki/decisions/Quality Gate.md'
)

@test "presence: all 20 files this change adds or edits exist" {
  [ "${#PRESENCE_PATHS[@]}" -eq 20 ]
  presence_ok "$REPO_ROOT" "${PRESENCE_PATHS[@]}"
}

@test "presence red twin: a list with one nonexistent path fails" {
  if presence_ok "$REPO_ROOT" "${PRESENCE_PATHS[@]}" '.claude/doctrine/does-not-exist.md'; then return 1; fi
  if presence_ok "$REPO_ROOT"; then return 1; fi
}

@test "ledger names: files this change creates never name links.jsonl or usage.jsonl" {
  local created=("${PRESENCE_PATHS[@]:0:7}") files=() relative_path file_path
  [ "${#created[@]}" -eq 7 ]
  for relative_path in "${created[@]}"; do files+=("$REPO_ROOT/$relative_path"); done
  if [ -d "$REPO_ROOT/.gaia/scripts/tests/fixtures/usage/research-binding" ]; then
    while IFS= read -r file_path; do files+=("$file_path"); done < <(find "$REPO_ROOT/.gaia/scripts/tests/fixtures/usage/research-binding" -type f)
  fi
  [ "${#files[@]}" -ge 7 ]
  ledger_names_ok "${files[@]}"
}

@test "ledger names red twin: execution.md with usage.jsonl appended fails" {
  { cat "$DOCTRINE_PATH"; printf 'reads usage.jsonl directly\n'; } >"$TEMPORARY_DIRECTORY/doc-ledger.md"
  if ledger_names_ok "$TEMPORARY_DIRECTORY/doc-ledger.md"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf 'reads links.jsonl directly\n'; } >"$TEMPORARY_DIRECTORY/doc-links.md"
  if ledger_names_ok "$TEMPORARY_DIRECTORY/doc-links.md"; then return 1; fi
  if ledger_names_ok; then return 1; fi
}

# --------------------------------------------------------- 11. registrations

@test "registrations: SessionStart covers all four sources; EnterWorktree and Bash groups include the hook" {
  settings_ok "$SETTINGS"
}

@test "registrations: every registered hook command is rooted" {
  bash "$REPO_ROOT/.gaia/scripts/check-hook-command-rooting.sh" "$REPO_ROOT"
}

@test "registrations red twins: a three-source matcher and a Bash-group removal each fail" {
  jq '(.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact") | .matcher) = "startup|resume|clear"' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-matcher.json"
  if cmp -s "$SETTINGS" "$TEMPORARY_DIRECTORY/settings-matcher.json"; then return 1; fi
  if settings_ok "$TEMPORARY_DIRECTORY/settings-matcher.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "Bash" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-bash.json"
  if cmp -s "$SETTINGS" "$TEMPORARY_DIRECTORY/settings-bash.json"; then return 1; fi
  if settings_ok "$TEMPORARY_DIRECTORY/settings-bash.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "EnterWorktree" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-ew.json"
  if settings_ok "$TEMPORARY_DIRECTORY/settings-ew.json"; then return 1; fi
}

# ----------------------------------------------------- 12. release exclusion

@test "release-exclude: none of the four source paths is excluded" {
  local source_path checked_count=0
  for source_path in .claude/rules/context-discipline.md .claude/doctrine/execution.md \
    .claude/hooks/workflow-doctrine-inject.sh "wiki/concepts/Workflow Doctrine.md"; do
    checked_count=$((checked_count + 1))
    not_excluded_ok "$EXCLUDE" "$source_path"
  done
  [ "$checked_count" -eq 4 ]
}

@test "release-exclude red twin: a .claude/doctrine entry, or the exact path, is caught" {
  { cat "$EXCLUDE"; printf '.claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-dir"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-dir" .claude/doctrine/execution.md; then return 1; fi
  { cat "$EXCLUDE"; printf 'wiki/concepts/Workflow Doctrine.md\n'; } >"$TEMPORARY_DIRECTORY/exclude-exact"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-exact" "wiki/concepts/Workflow Doctrine.md"; then return 1; fi
  { cat "$EXCLUDE"; printf '# .claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-comment"
  not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-comment" .claude/doctrine/execution.md
}

# ------------------------------------------------------------- 13. registry

@test "registry: runs/ (shared) and cache/doctrine-injected.* (main-only) entries carry reaped_by" {
  registry_ok "$REGISTRY"
}

@test "registry red twins: dropping either entry fails" {
  jq '.entries |= map(select(.path != "runs/"))' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-runs.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-runs.json"; then return 1; fi
  jq '.entries |= map(select(.path != "cache/doctrine-injected.*"))' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-marker.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-marker.json"; then return 1; fi
  jq '.entries |= map(if .path == "runs/" then del(.reaped_by) else . end)' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-reaped.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-reaped.json"; then return 1; fi
}

# --------------------------------------------------------------- 14. links

@test "links: Task Orchestration opens with the doctrine link and keeps its plan sections" {
  task_orchestration_links_ok "$TASK_ORCHESTRATION"
}

@test "links: plan.md and debt.md point at the doctrine, plan.md above its first rule, no model rows" {
  plan_pointer_ok "$PLANMD"
  no_model_rows_ok "$PLANMD"
  no_model_rows_ok "$DEBTMD"
  grep -qF 'Workflow Doctrine' "$DEBTMD"
}

@test "links red twins: link removed, pointer below a rule, and a model row each fail" {
  sed 's/\[\[Workflow Doctrine\]\]/the doctrine/g' "$TASK_ORCHESTRATION" >"$TEMPORARY_DIRECTORY/to-nolink.md"
  if cmp -s "$TASK_ORCHESTRATION" "$TEMPORARY_DIRECTORY/to-nolink.md"; then return 1; fi
  if task_orchestration_links_ok "$TEMPORARY_DIRECTORY/to-nolink.md"; then return 1; fi
  { printf -- '---\n'; cat "$PLANMD"; } >"$TEMPORARY_DIRECTORY/plan-rule.md"
  if plan_pointer_ok "$TEMPORARY_DIRECTORY/plan-rule.md"; then return 1; fi
  { cat "$DEBTMD"; printf '| sweep | x |\n'; } >"$TEMPORARY_DIRECTORY/debt-row.md"
  if no_model_rows_ok "$TEMPORARY_DIRECTORY/debt-row.md"; then return 1; fi
  grep -v 'Workflow Doctrine' "$DEBTMD" >"$TEMPORARY_DIRECTORY/debt-nolink.md"
  if no_model_rows_ok "$TEMPORARY_DIRECTORY/debt-nolink.md"; then return 1; fi
}
