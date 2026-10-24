#!/usr/bin/env bats

# Doc pins for closed-set decision prompts (.claude/rules/user-questions.md):
# each converted /gaia-spec and /gaia-plan site asks through AskUserQuestion and
# never says "plain prompt" again, every review or audit finding list is one
# accept-or-revise question rather than one question per finding, and no paragraph anywhere in the swept trees sends a
# question to a plain prompt without saying why its answer is open-ended. Each
# guard runs once on the real tree (must pass) and once on a mutated scratch
# copy (must fail).

bats_require_minimum_version 1.5.0

REFERENCES=.claude/skills/gaia/references
REVIEW_OPTION='Accept all as recommended (Recommended)'
PER_FINDING_ERE='question per finding|up to 4 questions per `AskUserQuestion` call'

# One site per row: file|start ERE|end ERE|converted|review. A site runs from
# its start line through the line before the next end match. A converted site
# asks through AskUserQuestion and never says "plain prompt"; a review site, a
# list of findings each carrying its own recommendation, offers the accept-all
# option and never asks one question per finding. Hard constraint 3 reviews but
# is not converted: it still sends open-ended clarify questions to a plain prompt.
SITES=(
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|yes|no"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|yes|no"
  "$REFERENCES/spec.md|^3\. \*\*One question at a time|^4\. \*\*Two-gate|no|yes"
  "$REFERENCES/spec/self-review-dispatch.md|^## 6b\.|^## 6c\.|yes|yes"
  "$REFERENCES/spec/audit.md|^\*\*Interactive\.\*\*|^$|yes|yes"
  "$REFERENCES/plan/decomposition-audit.md|^\*\*Interactive:\*\*|^$|yes|yes"
  "$REFERENCES/spec/clarify-loop.md|^- \*\*Error|^- \*\*Contradictory|yes|no"
)

# What each gate or review list must print before it asks, so the user can
# approve from the print alone. One pin per row: file|start ERE|end ERE|phrase,
# the phrase matched case-insensitively against the site with its line breaks
# folded to spaces. A gate that softens back to "Suggested text" drops its
# required print, so that phrase is forbidden at both gates.
PRINT_PINS=(
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|every UAT in the draft, one plain-language line each"
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|never summarize the UATs as a count or a theme list"
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|never point the user at the draft file"
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|terseness preferences do not shorten gate content"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|a synthesis of the draft and its AUDIT.md"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|never print the whole rendered artifact"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|every UAT in the draft, one line each, keeping its number"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|**Plan will"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|**You are signing off on:**"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|**Not settled"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|the draft path and the AUDIT.md path"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|at most 50 lines"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|never drops or merges a UAT, a sign-off item, or a not-settled item"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|terseness preferences do not shorten gate content"
  "$REFERENCES/spec/system-prompt.md|Gate 1: shape confirmation|Self-review before gate 2|every UAT as one plain-language line"
  "$REFERENCES/spec/system-prompt.md|Gate 1: shape confirmation|Self-review before gate 2|print the gate 2 brief"
  "$REFERENCES/spec/system-prompt.md|Gate 1: shape confirmation|Self-review before gate 2|never the whole rendered artifact"
  "$REFERENCES/spec/system-prompt.md|^- \*\*Plain language|^- \*\*Concision|never cite an id or label the human has not read"
  "$REFERENCES/spec/clarify-loop.md|^## 5a\.|^## 5b\.|never cite an id or label from them"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|no finding, lens, directive or section id"
  ".claude/rules/user-questions.md|^\*\*How a review list prints|^This covers|never a blockquote or a code fence"
  ".claude/rules/user-questions.md|^\*\*How a review list prints|^This covers|\`**Recommendation:**\` as its own paragraph"
  ".claude/rules/user-questions.md|^\*\*How a review list prints|^This covers|Internal finding ids stay in the decision list and are never printed"
  "$REFERENCES/spec/self-review-dispatch.md|^## 6b\.|^## 6c\.|How a review list prints"
  "$REFERENCES/spec/audit.md|^\*\*Interactive\.\*\*|^$|How a review list prints"
  "$REFERENCES/plan/decomposition-audit.md|^\*\*Interactive:\*\*|^$|How a review list prints"
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|never in a blockquote or a code fence"
  "$REFERENCES/spec/self-review-dispatch.md|^## 6b\.|^## 6c\.|never a count, a summary, or a pointer to a findings file"
  "$REFERENCES/spec/audit.md|^\*\*Interactive\.\*\*|^$|never a count, a summary, or a pointer to a findings file"
  "$REFERENCES/plan/decomposition-audit.md|^\*\*Interactive:\*\*|^$|never a count, a summary, or a pointer to a findings file"
)
FORBIDDEN_PRINT_PHRASE='Suggested text'
GATE_SITES=(
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\."
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\."
)

# Gate 2 approves a brief, not the artifact: a SPEC printed whole is too long to
# read in a session. Each phrase is a spelling of the whole-artifact print, so
# none may appear in the gate 2 site. One row per phrase: file|start|end|phrase.
WHOLE_ARTIFACT_PINS=(
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|<full rendered artifact>"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|full draft artifact in markdown form"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|Here is the rendered SPEC"
)

# A print template written as a blockquote renders with a bar down its left
# edge, so no gate 1 or review-list site holds a blockquote line.
# One row per site: file|start ERE|end ERE.
BLOCKQUOTE_FREE_SITES=(
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\."
  "$REFERENCES/spec/self-review-dispatch.md|^## 6b\.|^## 6c\."
  "$REFERENCES/spec/audit.md|^\*\*Interactive\.\*\*|^$"
  "$REFERENCES/plan/decomposition-audit.md|^\*\*Interactive:\*\*|^$"
)

# The trees the user-questions rule governs, minus the vendored playwright-cli
# skill, plus the wiki pages Claude executes that exist in an adopter tree.
# Keep in step with the rule's paths: frontmatter.
SWEPT_DIRS=(
  .claude/skills
  .claude/commands
  .claude/agents
  frontend/.claude/skills
  frontend/.claude/agents
)
SWEPT_WIKI_PAGES=(
  "wiki/concepts/PR Merge Workflow.md"
  "wiki/concepts/Audit Round Procedure.md"
  "wiki/concepts/Audit Gate Reference.md"
  "wiki/concepts/Audit Disposition and Debt Fix.md"
  "wiki/concepts/Code Review Audit Agent.md"
  "wiki/concepts/Workflow Doctrine.md"
  "wiki/decisions/Quality Gate.md"
)
PLAIN_PROMPT_ERE='plain (prose )?(prompts?|questions?|follow-ups?|chat messages?)'
OPEN_ENDED_ERE='open-ended|free[- ]text|what to change|not present'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$SCRATCH_ROOT"
}

# site_text <file> <start ERE> <end ERE>: prints the site's lines. The EREs
# travel through ENVIRON because awk -v expands backslash escapes, which would
# strip the \. and \* the patterns rely on.
site_text() {
  SITE_START="$2" SITE_END="$3" awk '
    inside && $0 ~ ENVIRON["SITE_END"] { exit }
    !inside && $0 ~ ENVIRON["SITE_START"] { inside = 1 }
    inside { print }
  ' "$1"
}

# sites_ok <root>: checks every site under <root>; prints each failure on
# stderr and returns 1 when any site fails.
sites_ok() {
  local root="$1" row file start end converted review text failed=0 checked=0
  for row in "${SITES[@]}"; do
    IFS='|' read -r file start end converted review <<<"$row"
    text="$(site_text "$root/$file" "$start" "$end")"
    if [ -z "$text" ]; then
      echo "site not found: $file /$start/" >&2
      failed=1
      continue
    fi
    checked=$((checked + 1))
    if [ "$converted" = yes ] && grep -qi -- 'plain prompt' <<<"$text"; then
      echo "says plain prompt: $file /$start/" >&2
      failed=1
    fi
    if [ "$converted" = yes ] && ! grep -qF -- 'AskUserQuestion' <<<"$text"; then
      echo "no AskUserQuestion: $file /$start/" >&2
      failed=1
    fi
    if [ "$review" = yes ] && ! grep -qF -- "$REVIEW_OPTION" <<<"$text"; then
      echo "lost the accept-all option: $file /$start/" >&2
      failed=1
    fi
    if [ "$review" = yes ] && grep -qE -- "$PER_FINDING_ERE" <<<"$text"; then
      echo "asks per finding: $file /$start/" >&2
      failed=1
    fi
  done
  if [ "$checked" -ne "${#SITES[@]}" ]; then
    echo "checked $checked of ${#SITES[@]} sites" >&2
    failed=1
  fi
  return "$failed"
}

# prints_ok <root>: checks every print pin and gate under <root>; prints each
# failure on stderr and returns 1 when any fails.
prints_ok() {
  local root="$1" row file start end phrase text failed=0
  for row in "${PRINT_PINS[@]}"; do
    IFS='|' read -r file start end phrase <<<"$row"
    text="$(site_text "$root/$file" "$start" "$end" | tr '\n' ' ' | tr -s ' ')"
    if [ -z "$text" ]; then
      echo "site not found: $file /$start/" >&2
      failed=1
    elif ! grep -qiF -- "$phrase" <<<"$text"; then
      echo "print pin missing: $file /$start/: $phrase" >&2
      failed=1
    fi
  done
  for row in "${GATE_SITES[@]}"; do
    IFS='|' read -r file start end <<<"$row"
    if site_text "$root/$file" "$start" "$end" | grep -qiF -- "$FORBIDDEN_PRINT_PHRASE"; then
      echo "gate print is only suggested: $file /$start/" >&2
      failed=1
    fi
  done
  for row in "${WHOLE_ARTIFACT_PINS[@]}"; do
    IFS='|' read -r file start end phrase <<<"$row"
    if site_text "$root/$file" "$start" "$end" | grep -qiF -- "$phrase"; then
      echo "gate prints the whole artifact: $file /$start/: $phrase" >&2
      failed=1
    fi
  done
  for row in "${BLOCKQUOTE_FREE_SITES[@]}"; do
    IFS='|' read -r file start end <<<"$row"
    if site_text "$root/$file" "$start" "$end" | grep -qE -- '^[[:space:]]*>'; then
      echo "print template is a blockquote: $file /$start/" >&2
      failed=1
    fi
  done
  return "$failed"
}

# copy_print_pin_files_into_scratch: copies every print-pin file to the scratch root.
copy_print_pin_files_into_scratch() {
  local row file
  for row in "${PRINT_PINS[@]}"; do
    file="${row%%|*}"
    mkdir -p "$(dirname "$SCRATCH_ROOT/$file")"
    cp "$REPO_ROOT/$file" "$SCRATCH_ROOT/$file"
  done
}

# swept_files <root>: prints every Markdown file the rule governs, one per line.
swept_files() {
  local root="$1" directory page
  for directory in "${SWEPT_DIRS[@]}"; do
    [ -d "$root/$directory" ] || continue
    find "$root/$directory" -name '*.md' -not -path '*/playwright-cli/*'
  done
  for page in "${SWEPT_WIKI_PAGES[@]}"; do
    if [ -f "$root/$page" ]; then
      printf '%s\n' "$root/$page"
    fi
  done
}

# unjustified_plain_prompts <root>: prints "<file>: <first line>" for each
# paragraph that sends a question to a plain prompt without naming why its
# answer is open-ended, and "checked <n>" on stderr for the plain-prompt
# paragraphs it read. Returns 1 when any paragraph is unjustified.
unjustified_plain_prompts() {
  local root="$1" file found count checked=0 failed=0
  while IFS= read -r file; do
    found="$(PLAIN="$PLAIN_PROMPT_ERE" OPEN="$OPEN_ENDED_ERE" awk '
      BEGIN { RS = "" }
      tolower($0) ~ ENVIRON["PLAIN"] {
        checked++
        if (tolower($0) !~ ENVIRON["OPEN"]) {
          split($0, lines, "\n")
          print "UNJUSTIFIED " lines[1]
        }
      }
      END { print "CHECKED " checked + 0 }
    ' "$file")"
    count="$(sed -n 's/^CHECKED //p' <<<"$found")"
    checked=$((checked + count))
    if grep -q '^UNJUSTIFIED ' <<<"$found"; then
      sed -n "s|^UNJUSTIFIED |${file#"$root"/}: |p" <<<"$found"
      failed=1
    fi
  done < <(swept_files "$root")
  echo "checked $checked" >&2
  return "$failed"
}

# copy_swept_trees_into_scratch: copies every swept file to the scratch root.
copy_swept_trees_into_scratch() {
  local file relative
  while IFS= read -r file; do
    relative="${file#"$REPO_ROOT"/}"
    mkdir -p "$(dirname "$SCRATCH_ROOT/$relative")"
    cp "$file" "$SCRATCH_ROOT/$relative"
  # gaia-lint-ignore whole-tree-mark-guard: every test that calls this helper carries the test mark
  done < <(swept_files "$REPO_ROOT")
}

# copy_tree_into_scratch: copies every site file to the scratch root.
copy_tree_into_scratch() {
  local row file
  for row in "${SITES[@]}"; do
    file="${row%%|*}"
    mkdir -p "$(dirname "$SCRATCH_ROOT/$file")"
    cp "$REPO_ROOT/$file" "$SCRATCH_ROOT/$file"
  done
}

# bats test_tags=whole-tree
@test "real tree: every converted site asks through AskUserQuestion, and review lists ask once" {
  sites_ok "$REPO_ROOT"
}

# bats test_tags=whole-tree
@test "real tree: every gate and review list prints what it asks to approve before asking" {
  prints_ok "$REPO_ROOT"
}

# bats test_tags=whole-tree
@test "red twin: a gate 1 that stops requiring every UAT line fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  sed 's/every UAT in the draft, one plain-language line each/the UATs in brief/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing"*"every UAT in the draft"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate 1 that may point at the draft file fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  sed 's/never point the user at the draft file/point the user at the draft file when long/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing"*"never point the user at the draft file"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate whose print goes back to suggested text fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  awk '{ print } /^### 4\. Gate 1/ { print "Suggested text:" }' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate print is only suggested"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate 2 that goes back to printing the whole artifact fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  awk '{ print } /^### 8\. Gate 2/ { print "> <full rendered artifact>" }' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate prints the whole artifact"*"<full rendered artifact>"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate 2 brief that drops the sign-off section fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  sed 's/\*\*You are signing off on:\*\*/**Risks:**/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing"*"You are signing off on"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate 2 brief that lets length drop a UAT fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  sed 's/never drops or merges a UAT, a sign-off item, or a not-settled item/may trim UATs when long/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing"*"never drops or merges a UAT"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a gate 2 brief with no length bound fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  sed 's/at most 50 lines/as long as it needs/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing"*"at most 50 lines"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a clarify question that may cite a finding id fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec/clarify-loop.md"
  sed 's/never cite an id or label from them/cite finding ids where helpful/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing: $REFERENCES/spec/clarify-loop.md"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a review-list template that goes back to a blockquote fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec/self-review-dispatch.md"
  awk '{ print } /^## 6b\./ { print "  > Self-review flagged a concern in `<location>`:" }' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print template is a blockquote: $REFERENCES/spec/self-review-dispatch.md"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a review-list format that may print finding ids fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/.claude/rules/user-questions.md"
  sed 's/Internal finding ids stay in the decision list and are never printed/Each finding shows its id/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing: .claude/rules/user-questions.md"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a review list that may print a count fails" {
  copy_print_pin_files_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/plan/decomposition-audit.md"
  sed 's/never a count, a summary, or a pointer to a findings file/a count is enough/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run prints_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"print pin missing: $REFERENCES/plan/decomposition-audit.md"* ]]
}

@test "real tree: the open-ended prompts stay plain" {
  grep -qE -- 'What do you want to spec\?.*use a plain prompt' "$REPO_ROOT/$REFERENCES/spec.md"
  grep -qF -- 'ask: **"What do you want me to orchestrate?"** and wait' "$REPO_ROOT/$REFERENCES/plan.md"
}

@test "red twin: a gate that says plain prompt again fails" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  awk '{ print } /^### 8\. Gate 2/ { print "Use a plain prompt, not `AskUserQuestion`." }' \
    "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"says plain prompt"* ]]
}

@test "red twin: a review list that loses its accept-all option fails" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec/audit.md"
  sed 's/Accept all as recommended (Recommended)/Apply the fix (Recommended)/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lost the accept-all option"* ]]
}

@test "red twin: a review list that goes back to one question per finding fails" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec/self-review-dispatch.md"
  awk '{ print } /^## 6b\./ { print "Ask one question per finding." }' "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"asks per finding"* ]]
}

@test "red twin: a site whose heading moved fails as not found" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/plan/decomposition-audit.md"
  sed 's/^\*\*Interactive:\*\*/**Interactive mode:**/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"site not found"* ]]
}

# bats test_tags=whole-tree
@test "real tree: every plain-prompt paragraph in the swept trees says why it is open-ended" {
  run --separate-stderr unjustified_plain_prompts "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Non-vacuous: the scan read plain-prompt paragraphs, the known open-ended
  # spec prompt among them.
  [[ "$stderr" =~ checked\ ([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -gt 0 ]
  grep -qE -- 'What do you want to spec\?.*use a plain prompt' "$REPO_ROOT/$REFERENCES/spec.md"
}

# bats test_tags=whole-tree
@test "red twin: a closed-set confirmation sent to a plain prompt fails" {
  copy_swept_trees_into_scratch
  local file="$SCRATCH_ROOT/.claude/commands/gaia-init.md"
  printf '\nThen echo the resolved choice back as a plain chat message, e.g. `Look right?`\n' >>"$file"
  run --separate-stderr unjustified_plain_prompts "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/commands/gaia-init.md: Then echo the resolved choice back"* ]]
}

# bats test_tags=whole-tree
@test "red twin: a plain prompt that names its open-ended answer passes" {
  copy_swept_trees_into_scratch
  local file="$SCRATCH_ROOT/.claude/commands/gaia-init.md"
  printf '\nAsk for the project description as a plain prompt: the answer is free text.\n' >>"$file"
  run --separate-stderr unjustified_plain_prompts "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
