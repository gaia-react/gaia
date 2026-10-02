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
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULE="$REPO_ROOT/.claude/rules/context-discipline.md"
  DOC="$REPO_ROOT/.claude/doctrine/execution.md"
  HOOK="$REPO_ROOT/.claude/hooks/workflow-doctrine-inject.sh"
  WIKI="$REPO_ROOT/wiki/concepts/Workflow Doctrine.md"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  TASKORCH="$REPO_ROOT/wiki/concepts/Task Orchestration.md"
  PLANMD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  DEBTMD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  MODEL_RE='\b(opus|sonnet|haiku|fable)\b|claude-(opus|sonnet|haiku|fable)'
  BAN_TERMS=("executor" "commit" "git" "worktree" "branch" "quality gate" "push" "merge" "pull request")
  T="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

rule_budget_ok() {
  local f="$1" n
  [ -f "$f" ] || return 1
  [ "$(head -n 1 "$f")" = "---" ] && return 1
  grep -q '^paths:' "$f" && return 1
  n="$(grep -c '[^[:space:]]' "$f")"
  [ "$n" -le 8 ] || return 1
  [ "$(wc -c <"$f" | tr -d ' ')" -le 1200 ] || return 1
  return 0
}

BAN_VISITED=0
rule_ban_ok() {
  local f="$1" t
  BAN_VISITED=0
  [ -f "$f" ] || return 1
  for t in "${BAN_TERMS[@]}"; do
    BAN_VISITED=$((BAN_VISITED + 1))
    grep -qiF -- "$t" "$f" && return 1
  done
  grep -qiE '\bPR\b' "$f" && return 1
  return 0
}

rule_directives_ok() {
  local f="$1" l
  [ -f "$f" ] || return 1
  for l in '.claude/rules/subagent-dispatch.md' 'wiki/concepts/Workflow Doctrine.md' \
    '.gaia/local/research/<topic>-<date>/' 'rewritten in place'; do
    grep -qF -- "$l" "$f" || return 1
  done
  grep -qiF -- 'never appended' "$f" || return 1
  return 0
}

doc_shape_ok() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ "$(wc -c <"$f" | tr -d ' ')" -le 3584 ] || return 1
  [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  [ "$(tail -c 2 "$f" | od -An -tx1 | tr -d ' \n')" = "0a0a" ] && return 1
  LC_ALL=C grep -q $'[\x01-\x09\x0b-\x1f\x7f]' "$f" && return 1
  return 0
}

doc_placement_ok() {
  local root="$1"
  [ -f "$root/.claude/doctrine/execution.md" ] || return 1
  [ -z "$(find "$root/.claude/rules" -name 'execution.md' 2>/dev/null)" ] || return 1
  return 0
}

# key line the hook emits for a branch name, then the payload size with a doctrine file
payload_ok() {
  local f="$1" name keyline total
  name="feat/$(head -c 123 /dev/zero | tr '\0' a)"
  [ "${#name}" = 128 ] || return 1
  keyline="Branch key: branch:$name. Link its initiative once with: bash .gaia/scripts/usage.sh link branch:$name research:<topic>-<date> (or issue:<n>)"
  total=$(($(printf '%s\n' "$keyline" | wc -c) + $(wc -c <"$f")))
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
  local f="$1" a kind pat
  [ -f "$f" ] || return 1
  for a in "${ANCHORS[@]}"; do
    kind="${a%%|*}"
    pat="${a#*|}"
    case "$kind" in
      F) grep -qF -- "$pat" "$f" || return 1 ;;
      I) grep -qiF -- "$pat" "$f" || return 1 ;;
      R) grep -qiE -- "$pat" "$f" || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

no_model_names_ok() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -niE "$MODEL_RE" "$f" >/dev/null && return 1
  return 0
}

# prints "<start> <end>" of the first contiguous `|` block after the Model table heading
wiki_model_block() {
  awk '
    $0 == "## Model table" { on = 1; next }
    on && /^## / { exit }
    on && /^\|/ { if (!s) s = NR; e = NR; next }
    on && s && !/^\|/ { exit }
    END { print s, e }
  ' "$1"
}

WIKI_MATCHES=0
wiki_models_ok() {
  local f="$1" s e ln rows
  [ -f "$f" ] || return 1
  read -r s e <<<"$(wiki_model_block "$f")"
  [ -n "$s" ] && [ -n "$e" ] || return 1
  WIKI_MATCHES=0
  while IFS= read -r ln; do
    WIKI_MATCHES=$((WIKI_MATCHES + 1))
    [ "$ln" -ge "$s" ] && [ "$ln" -le "$e" ] || return 1
  done < <(grep -niE "$MODEL_RE" "$f" | cut -d: -f1)
  [ $((e - s + 1 - 2)) -eq 3 ] || return 1
  rows="$(sed -n "${s},${e}p" "$f" | awk -F'|' 'NR > 2 { gsub(/^ +| +$/, "", $2); print $2 }')"
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
  local f="$1" h prev=0 ln ms me sl el
  [ -f "$f" ] || return 1
  for h in "${WIKI_HEADINGS[@]}"; do
    ln="$(line_of "$f" "$h")"
    [ -n "$ln" ] || return 1
    [ "$ln" -gt "$prev" ] || return 1
    prev="$ln"
  done
  grep -qF '.claude/doctrine/execution.md' "$f" || return 1
  grep -qF '.claude/rules/context-discipline.md' "$f" || return 1
  [ "$(grep -cxF -- "$START_MARK" "$f")" = 1 ] || return 1
  [ "$(grep -cxF -- "$END_MARK" "$f")" = 1 ] || return 1
  sl="$(line_of "$f" "$START_MARK")"
  el="$(line_of "$f" "$END_MARK")"
  ms="$(line_of "$f" '## Measurements')"
  me="$(line_of "$f" '## Post-landing success check')"
  [ "$sl" -lt "$ms" ] || return 1
  [ "$ms" -lt "$me" ] || return 1
  [ "$me" -lt "$el" ] || return 1
  return 0
}

wiki_exception_ok() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qiF 'sanctioned depth-2 orchestrator' "$f" || return 1
  grep -qF 'audit-loop-unit' "$f" || return 1
  grep -qiF 'state-changing git' "$f" || return 1
  return 0
}

no_ids_ok() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -nE 'UAT-[0-9]+|SPEC-[0-9]+' "$f" >/dev/null && return 1
  return 0
}

presence_ok() {
  local root="$1" p
  shift
  [ "$#" -gt 0 ] || return 1
  for p in "$@"; do
    [ -e "$root/$p" ] || return 1
  done
  return 0
}

ledger_names_ok() {
  local f
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    [ -f "$f" ] || return 1
    grep -nE 'links\.jsonl|usage\.jsonl' "$f" >/dev/null && return 1
  done
  return 0
}

settings_ok() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq -e '[.hooks.SessionStart[]
      | select(((.matcher // "") as $m
          | ($m == "" or ((["startup","resume","clear","compact"] - ($m | split("|"))) | length == 0)))
        and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$f" >/dev/null || return 1
  jq -e '[.hooks.SessionStart[] | select(any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$f" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "EnterWorktree" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$f" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Bash" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$f" >/dev/null || return 1
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
  local f="$1"
  [ -f "$f" ] || return 1
  jq -e '[.entries[] | select(.path == "runs/" and .scope == "shared"
      and (.keyed_by | type == "string" and length > 0) and has("reaped_by"))] | length == 1' "$f" >/dev/null || return 1
  jq -e '[.entries[] | select(.path == "cache/doctrine-injected.*" and .scope == "main-only"
      and .keyed_by == null and has("reaped_by"))] | length == 1' "$f" >/dev/null || return 1
  return 0
}

taskorch_links_ok() {
  local f="$1" para
  [ -f "$f" ] || return 1
  para="$(awk '
    !h && /^# / { h = 1; next }
    h && !p && /^[[:space:]]*$/ { next }
    h && /^[[:space:]]*$/ { exit }
    h { p = 1; print }
  ' "$f")"
  [ -n "$para" ] || return 1
  case "$para" in *'[[Workflow Doctrine]]'*) ;; *) return 1 ;; esac
  grep -qxF '## Plan artifacts' "$f" || return 1
  grep -qxF '## Execution lifecycle' "$f" || return 1
  return 0
}

plan_pointer_ok() {
  local f="$1" first rule
  [ -f "$f" ] || return 1
  first="$(grep -n 'Workflow Doctrine' "$f" | head -n 1 | cut -d: -f1)"
  rule="$(grep -n '^---$' "$f" | head -n 1 | cut -d: -f1)"
  [ -n "$first" ] || return 1
  if [ -n "$rule" ]; then [ "$first" -lt "$rule" ] || return 1; fi
  return 0
}

no_model_rows_ok() {
  local f="$1" r
  [ -f "$f" ] || return 1
  grep -qF 'Workflow Doctrine' "$f" || return 1
  for r in '| sweep' '| scoped implementation' '| synthesis'; do
    grep -qF -- "$r" "$f" && return 1
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
  printf -- '---\npaths:\n  - "x"\n---\n' | cat - "$RULE" >"$T/fm.md"
  if rule_budget_ok "$T/fm.md"; then return 1; fi
  printf 'paths: x\n' | cat - "$RULE" >"$T/paths.md"
  if rule_budget_ok "$T/paths.md"; then return 1; fi
  pad_to "$RULE" "$T/big.md" 1201
  [ "$(wc -c <"$T/big.md" | tr -d ' ')" -eq 1201 ]
  if rule_budget_ok "$T/big.md"; then return 1; fi
  cp "$RULE" "$T/nine.md"
  while [ "$(grep -c '[^[:space:]]' "$T/nine.md")" -lt 9 ]; do printf '%s\n' '- x' >>"$T/nine.md"; done
  [ "$(grep -c '[^[:space:]]' "$T/nine.md")" -eq 9 ]
  if rule_budget_ok "$T/nine.md"; then return 1; fi
}

# ------------------------------------------------------------ 2. ban list

@test "rule ban list: none of the nine terms or \\bPR\\b appear in the real rule" {
  [ "${#BAN_TERMS[@]}" -eq 9 ]
  rule_ban_ok "$RULE"
  [ "$BAN_VISITED" -eq 9 ]
}

@test "rule ban list red twins: every term, a PR token, and the substring 'digit' are each caught" {
  local t i=0
  [ "${#BAN_TERMS[@]}" -eq 9 ]
  for t in "${BAN_TERMS[@]}"; do
    i=$((i + 1))
    { cat "$RULE"; printf 'a line about %s here\n' "$t"; } >"$T/ban-$i.md"
    if rule_ban_ok "$T/ban-$i.md"; then return 1; fi
  done
  [ "$i" -eq 9 ]
  { cat "$RULE"; printf 'a line about PR here\n'; } >"$T/pr.md"
  if rule_ban_ok "$T/pr.md"; then return 1; fi
  { cat "$RULE"; printf 'the digit seven\n'; } >"$T/digit.md"
  if rule_ban_ok "$T/digit.md"; then return 1; fi
}

# ------------------------------------------------------- 3. rule directives

@test "rule directives: the five C4 literals are present" {
  rule_directives_ok "$RULE"
}

@test "rule directives red twin: dropping the dispatch pointer line fails" {
  grep -vF 'subagent-dispatch.md' "$RULE" >"$T/nodispatch.md"
  [ "$(wc -l <"$T/nodispatch.md" | tr -d ' ')" -lt "$(wc -l <"$RULE" | tr -d ' ')" ]
  if rule_directives_ok "$T/nodispatch.md"; then return 1; fi
}

# ------------------------------------------------- 4. execution.md budget

@test "execution.md: size, single trailing newline, no control characters" {
  doc_shape_ok "$DOC"
}

@test "execution.md placement: lives under .claude/doctrine, not under .claude/rules" {
  doc_placement_ok "$REPO_ROOT"
  mkdir -p "$T/bad/.claude/rules" "$T/bad/.claude/doctrine"
  cp "$DOC" "$T/bad/.claude/doctrine/execution.md"
  cp "$DOC" "$T/bad/.claude/rules/execution.md"
  if doc_placement_ok "$T/bad"; then return 1; fi
  mkdir -p "$T/moved/.claude/rules"
  cp "$DOC" "$T/moved/.claude/rules/execution.md"
  if doc_placement_ok "$T/moved"; then return 1; fi
}

@test "execution.md red twins: 3585 bytes, trailing blank line, and a control character each fail" {
  pad_to "$DOC" "$T/over.md" 3585
  [ "$(wc -c <"$T/over.md" | tr -d ' ')" -eq 3585 ]
  if doc_shape_ok "$T/over.md"; then return 1; fi
  { cat "$DOC"; printf '\n'; } >"$T/blank.md"
  if doc_shape_ok "$T/blank.md"; then return 1; fi
  { cat "$DOC"; printf 'tab\there\n'; } >"$T/tab.md"
  if doc_shape_ok "$T/tab.md"; then return 1; fi
}

# -------------------------------------------------------- 5. payload cap

@test "payload cap: key line for a 128-character branch plus execution.md is at most 4096 bytes" {
  payload_ok "$DOC"
  [ "$PAYLOAD_TOTAL" -gt "$(wc -c <"$DOC" | tr -d ' ')" ]
}

@test "payload cap red twin: an oversize doctrine copy fails the same check" {
  pad_to "$DOC" "$T/big.md" 3800
  [ "$(wc -c <"$T/big.md" | tr -d ' ')" -eq 3800 ]
  if payload_ok "$T/big.md"; then return 1; fi
}

# ----------------------------------------------------------- 6. anchors

@test "execution.md anchors: all 32 C3 literals are present" {
  [ "${#ANCHORS[@]}" -eq 32 ]
  anchors_ok "$DOC"
}

@test "execution.md anchors red twins: NEXT:, the never-read line, and the Edit-or-Write clause each fail" {
  sed 's/NEXT://g' "$DOC" >"$T/nonext.md"
  if cmp -s "$DOC" "$T/nonext.md"; then return 1; fi
  if anchors_ok "$T/nonext.md"; then return 1; fi
  grep -viE 'never read.*log\.md' "$DOC" >"$T/noread.md"
  if cmp -s "$DOC" "$T/noread.md"; then return 1; fi
  if anchors_ok "$T/noread.md"; then return 1; fi
  sed 's/never through Edit or Write//g' "$DOC" >"$T/noewr.md"
  if cmp -s "$DOC" "$T/noewr.md"; then return 1; fi
  if anchors_ok "$T/noewr.md"; then return 1; fi
}

@test "execution.md exception red twin: dropping the audit-loop-unit sentence fails the anchors, and the real file names it" {
  grep -qF 'audit-loop-unit' "$DOC"
  grep -vF 'audit-loop-unit' "$DOC" >"$T/noexc.md"
  [ "$(wc -c <"$T/noexc.md" | tr -d ' ')" -lt "$(wc -c <"$DOC" | tr -d ' ')" ]
  if anchors_ok "$T/noexc.md"; then return 1; fi
  sed 's/sanctioned depth-2 orchestrator/orchestrator/' "$DOC" >"$T/nosanction.md"
  if cmp -s "$DOC" "$T/nosanction.md"; then return 1; fi
  if anchors_ok "$T/nosanction.md"; then return 1; fi
}

@test "wiki exception: Workflow Doctrine names audit-loop-unit as the sanctioned depth-2 exception, twin without it fails" {
  wiki_exception_ok "$WIKI"
  grep -vF 'audit-loop-unit' "$WIKI" >"$T/wiki-noexc.md"
  if wiki_exception_ok "$T/wiki-noexc.md"; then return 1; fi
}

# -------------------------------------------------------- 7. model names

@test "model names: none in the rule or execution.md; wiki mentions sit in the three-row table" {
  no_model_names_ok "$RULE"
  no_model_names_ok "$DOC"
  wiki_models_ok "$WIKI"
  [ "$WIKI_MATCHES" -gt 0 ]
}

@test "model names red twins: Opus under Resume, Haiku in the rule, and a fourth table row each fail" {
  awk '{ print } /^## Resume$/ { print "Opus is mentioned here." }' "$WIKI" >"$T/wiki-opus.md"
  if cmp -s "$WIKI" "$T/wiki-opus.md"; then return 1; fi
  if wiki_models_ok "$T/wiki-opus.md"; then return 1; fi
  { cat "$RULE"; printf 'Haiku\n'; } >"$T/rule-haiku.md"
  if no_model_names_ok "$T/rule-haiku.md"; then return 1; fi
  awk '{ print } /^\| synthesis/ { print "| extra | Sonnet | why | note |" }' "$WIKI" >"$T/wiki-row.md"
  if cmp -s "$WIKI" "$T/wiki-row.md"; then return 1; fi
  if wiki_models_ok "$T/wiki-row.md"; then return 1; fi
}

# ------------------------------------------------ 8. wiki headings and markers

@test "wiki structure: C5 headings in order, source links, maintainer markers bracket both sections" {
  [ "${#WIKI_HEADINGS[@]}" -eq 12 ]
  wiki_structure_ok "$WIKI"
}

@test "wiki structure red twin: the end marker moved above Post-landing success check fails" {
  awk -v em="$END_MARK" '
    $0 == em { next }
    $0 == "## Post-landing success check" { print em }
    { print }
  ' "$WIKI" >"$T/wiki-marker.md"
  [ "$(grep -cxF -- "$END_MARK" "$T/wiki-marker.md")" -eq 1 ]
  if wiki_structure_ok "$T/wiki-marker.md"; then return 1; fi
}

# ------------------------------------------------------- 9. no working-doc ids

@test "no working-doc ids: rule, execution.md, wiki page, and hook carry no SPEC or UAT id" {
  no_ids_ok "$RULE"
  no_ids_ok "$DOC"
  no_ids_ok "$WIKI"
  no_ids_ok "$HOOK"
}

@test "no working-doc ids red twin: a hook copy with a SPEC reference fails" {
  { cat "$HOOK"; printf '# see SPEC-123\n'; } >"$T/hook-id.sh"
  if no_ids_ok "$T/hook-id.sh"; then return 1; fi
  { cat "$DOC"; printf 'see UAT-9\n'; } >"$T/doc-id.md"
  if no_ids_ok "$T/doc-id.md"; then return 1; fi
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
  local created=("${PRESENCE_PATHS[@]:0:7}") files=() p f
  [ "${#created[@]}" -eq 7 ]
  for p in "${created[@]}"; do files+=("$REPO_ROOT/$p"); done
  if [ -d "$REPO_ROOT/.gaia/scripts/tests/fixtures/usage/research-binding" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$REPO_ROOT/.gaia/scripts/tests/fixtures/usage/research-binding" -type f)
  fi
  [ "${#files[@]}" -ge 7 ]
  ledger_names_ok "${files[@]}"
}

@test "ledger names red twin: execution.md with usage.jsonl appended fails" {
  { cat "$DOC"; printf 'reads usage.jsonl directly\n'; } >"$T/doc-ledger.md"
  if ledger_names_ok "$T/doc-ledger.md"; then return 1; fi
  { cat "$DOC"; printf 'reads links.jsonl directly\n'; } >"$T/doc-links.md"
  if ledger_names_ok "$T/doc-links.md"; then return 1; fi
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
  jq '(.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact") | .matcher) = "startup|resume|clear"' "$SETTINGS" >"$T/settings-matcher.json"
  if cmp -s "$SETTINGS" "$T/settings-matcher.json"; then return 1; fi
  if settings_ok "$T/settings-matcher.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "Bash" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$T/settings-bash.json"
  if cmp -s "$SETTINGS" "$T/settings-bash.json"; then return 1; fi
  if settings_ok "$T/settings-bash.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "EnterWorktree" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$T/settings-ew.json"
  if settings_ok "$T/settings-ew.json"; then return 1; fi
}

# ----------------------------------------------------- 12. release exclusion

@test "release-exclude: none of the four source paths is excluded" {
  local p n=0
  for p in .claude/rules/context-discipline.md .claude/doctrine/execution.md \
    .claude/hooks/workflow-doctrine-inject.sh "wiki/concepts/Workflow Doctrine.md"; do
    n=$((n + 1))
    not_excluded_ok "$EXCLUDE" "$p"
  done
  [ "$n" -eq 4 ]
}

@test "release-exclude red twin: a .claude/doctrine entry, or the exact path, is caught" {
  { cat "$EXCLUDE"; printf '.claude/doctrine\n'; } >"$T/exclude-dir"
  if not_excluded_ok "$T/exclude-dir" .claude/doctrine/execution.md; then return 1; fi
  { cat "$EXCLUDE"; printf 'wiki/concepts/Workflow Doctrine.md\n'; } >"$T/exclude-exact"
  if not_excluded_ok "$T/exclude-exact" "wiki/concepts/Workflow Doctrine.md"; then return 1; fi
  { cat "$EXCLUDE"; printf '# .claude/doctrine\n'; } >"$T/exclude-comment"
  not_excluded_ok "$T/exclude-comment" .claude/doctrine/execution.md
}

# ------------------------------------------------------------- 13. registry

@test "registry: runs/ (shared) and cache/doctrine-injected.* (main-only) entries carry reaped_by" {
  registry_ok "$REGISTRY"
}

@test "registry red twins: dropping either entry fails" {
  jq '.entries |= map(select(.path != "runs/"))' "$REGISTRY" >"$T/reg-runs.json"
  if registry_ok "$T/reg-runs.json"; then return 1; fi
  jq '.entries |= map(select(.path != "cache/doctrine-injected.*"))' "$REGISTRY" >"$T/reg-marker.json"
  if registry_ok "$T/reg-marker.json"; then return 1; fi
  jq '.entries |= map(if .path == "runs/" then del(.reaped_by) else . end)' "$REGISTRY" >"$T/reg-reaped.json"
  if registry_ok "$T/reg-reaped.json"; then return 1; fi
}

# --------------------------------------------------------------- 14. links

@test "links: Task Orchestration opens with the doctrine link and keeps its plan sections" {
  taskorch_links_ok "$TASKORCH"
}

@test "links: plan.md and debt.md point at the doctrine, plan.md above its first rule, no model rows" {
  plan_pointer_ok "$PLANMD"
  no_model_rows_ok "$PLANMD"
  no_model_rows_ok "$DEBTMD"
  grep -qF 'Workflow Doctrine' "$DEBTMD"
}

@test "links red twins: link removed, pointer below a rule, and a model row each fail" {
  sed 's/\[\[Workflow Doctrine\]\]/the doctrine/g' "$TASKORCH" >"$T/to-nolink.md"
  if cmp -s "$TASKORCH" "$T/to-nolink.md"; then return 1; fi
  if taskorch_links_ok "$T/to-nolink.md"; then return 1; fi
  { printf -- '---\n'; cat "$PLANMD"; } >"$T/plan-rule.md"
  if plan_pointer_ok "$T/plan-rule.md"; then return 1; fi
  { cat "$DEBTMD"; printf '| sweep | x |\n'; } >"$T/debt-row.md"
  if no_model_rows_ok "$T/debt-row.md"; then return 1; fi
  grep -v 'Workflow Doctrine' "$DEBTMD" >"$T/debt-nolink.md"
  if no_model_rows_ok "$T/debt-nolink.md"; then return 1; fi
}
