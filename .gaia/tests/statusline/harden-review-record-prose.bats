#!/usr/bin/env bats

# Pins the /gaia-harden playbook's review-completion contract mechanically:
# the start-of-run tally save, the single combined record-and-clear block that
# lives once inside "## Record the review (end of run)" (record, capture its
# exit status, then a guarded cache clear, all inside one fenced Bash block so
# it runs as one Bash call), the all-clear early stop's reference to that same
# section rather than a copy of it, that section's placement ahead of Publish,
# and the --audited-pr-count flag on both ledger record call sites (decline
# and the unclassified signal). .gaia/tests/statusline/ is already armed by
# harden.md edits in .github/workflows/audit-ci-tests.yml.

setup() {
  HARDEN_MARKDOWN=$(cd "$BATS_TEST_DIRNAME/../../../.claude/skills/gaia/references" && pwd)/harden.md
}

# swap_lines <file> <first_line_number> <second_line_number>
#   In-place swaps the content of two 1-indexed lines in <file>.
swap_lines() {
  local file="$1" first_line_number="$2" second_line_number="$3"
  awk -v first_line_number="$first_line_number" -v second_line_number="$second_line_number" '
    NR==first_line_number { first_text=$0 }
    NR==second_line_number { second_text=$0 }
    { lines[NR]=$0 }
    END {
      lines[first_line_number]=second_text
      lines[second_line_number]=first_text
      for (i=1; i<=NR; i++) print lines[i]
    }
  ' "$file" > "${file}.swap" && mv "${file}.swap" "$file"
}

# delete_first_match_in_range <file> <start> <end> <needle>
#   Deletes the first line containing the literal <needle> within the
#   1-indexed [start, end] range.
delete_first_match_in_range() {
  local file="$1" start="$2" end="$3" needle="$4"
  awk -v start="$start" -v end="$end" -v needle="$needle" '
    BEGIN { done = 0 }
    {
      if (!done && NR >= start && NR <= end && index($0, needle) > 0) { done = 1; next }
      print
    }
  ' "$file" > "${file}.del" && mv "${file}.del" "$file"
}

# insert_after <file> <line_number> <text_file>
#   Inserts every line of <text_file> into <file> immediately after the
#   1-indexed line <line_number>.
insert_after() {
  local file="$1" line_number="$2" text_file="$3"
  awk -v line_number="$line_number" -v text_file="$text_file" '
    { print }
    NR==line_number {
      while ((getline inserted_line < text_file) > 0) print inserted_line
    }
  ' "$file" > "${file}.ins" && mv "${file}.ins" "$file"
}

# check_record_prose <file>
#   Returns 0 only when every condition below holds against <file>; prints
#   one line naming the first failed condition and returns 1 otherwise.
check_record_prose() {
  local file="$1"

  local fetch_start judge_line
  fetch_start=$(grep -n "^## Fetch the live candidate list" "$file" | head -1 | cut -d: -f1)
  judge_line=$(grep -n "^## Judge-the-form logic" "$file" | head -1 | cut -d: -f1)
  if [ -z "$fetch_start" ] || [ -z "$judge_line" ]; then
    echo "missing the Fetch or Judge-the-form heading"
    return 1
  fi

  # 1. Fetch section saves the tally to review-tally.json.
  sed -n "${fetch_start},${judge_line}p" "$file" \
    | grep -qE "harden-tally >.*\.gaia/local/harden/review-tally\.json" \
    || { echo "Fetch section missing the harden-tally > review-tally.json save"; return 1; }

  # 2. All-clear bullet (one unwrapped paragraph line): references the Record
  #    section, and carries no copy of either the record literal or the
  #    cache-clear literal (single-source). Scoped to that one line, not the
  #    wider region down to Judge-the-form, so a mutation here is not masked
  #    by the neighboring non-null bullet's own "Record the review" mention.
  local allclear_start
  allclear_start=$(grep -n 'candidate_count.*is .0.*unclassified.*is .null' "$file" | head -1 | cut -d: -f1)
  if [ -z "$allclear_start" ]; then
    echo "missing the candidate_count 0 / unclassified null all-clear line"
    return 1
  fi
  sed -n "${allclear_start}p" "$file" | grep -qF "Record the review" \
    || { echo "all-clear bullet missing a reference to Record the review"; return 1; }
  sed -n "${allclear_start}p" "$file" | grep -qF "harden-ledger snapshot record --tally-file" \
    && { echo "all-clear bullet carries its own copy of the snapshot record literal"; return 1; }
  sed -n "${allclear_start}p" "$file" | grep -qF '.hardenNudgeReason = ""' \
    && { echo "all-clear bullet carries its own copy of the cache-clear literal"; return 1; }

  # 3. Record the review heading exists, between Unclassified and Publish.
  local unclassified_line record_heading_line publish_line
  unclassified_line=$(grep -n "^## Unclassified recurrence signal" "$file" | head -1 | cut -d: -f1)
  record_heading_line=$(grep -n "^## Record the review (end of run)" "$file" | head -1 | cut -d: -f1)
  publish_line=$(grep -n "^## Publish approved changes (end of run)" "$file" | head -1 | cut -d: -f1)
  if [ -z "$unclassified_line" ] || [ -z "$record_heading_line" ] || [ -z "$publish_line" ]; then
    echo "missing one of the Unclassified / Record / Publish headings"
    return 1
  fi
  if [ "$record_heading_line" -le "$unclassified_line" ] || [ "$record_heading_line" -ge "$publish_line" ]; then
    echo "the Record the review heading is not between Unclassified and Publish"
    return 1
  fi

  # 4. Inside the Record section: the record literal, then the captured exit
  #    status, then the exit-0 guard, then the cache-clear literal, in that
  #    order, so the combined block reads as one runnable sequence.
  local record_line_relative status_line_relative guard_line_relative clear_line_relative
  record_line_relative=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -n "harden-ledger snapshot record --tally-file" | head -1 | cut -d: -f1)
  if [ -z "$record_line_relative" ]; then
    echo "Record section missing the snapshot record literal"
    return 1
  fi
  status_line_relative=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF 'record_status=$?' | head -1 | cut -d: -f1)
  if [ -z "$status_line_relative" ]; then
    echo "Record section missing the record_status capture"
    return 1
  fi
  guard_line_relative=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF '"$record_status" -eq 0' | head -1 | cut -d: -f1)
  if [ -z "$guard_line_relative" ]; then
    echo "Record section missing the record_status -eq 0 guard"
    return 1
  fi
  clear_line_relative=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF '.hardenNudgeReason = ""' | head -1 | cut -d: -f1)
  if [ -z "$clear_line_relative" ]; then
    echo "Record section missing the cache-clear literal"
    return 1
  fi

  local record_line_absolute status_line_absolute guard_line_absolute clear_line_absolute
  record_line_absolute=$((record_heading_line + record_line_relative - 1))
  status_line_absolute=$((record_heading_line + status_line_relative - 1))
  guard_line_absolute=$((record_heading_line + guard_line_relative - 1))
  clear_line_absolute=$((record_heading_line + clear_line_relative - 1))

  if [ "$status_line_absolute" -le "$record_line_absolute" ] || [ "$guard_line_absolute" -le "$status_line_absolute" ] || [ "$clear_line_absolute" -le "$guard_line_absolute" ]; then
    echo "Record section's record/status/guard/clear literals are out of order"
    return 1
  fi

  # 5. The record literal and the cache-clear literal sit inside the same
  #    fenced bash block (no ``` fence boundary between them), so they run
  #    together as one Bash call: shell variables do not persist across
  #    separate calls.
  local between_fence_count
  between_fence_count=$(sed -n "$((record_line_absolute + 1)),$((clear_line_absolute - 1))p" "$file" | grep -c '^```')
  if [ "$between_fence_count" -ne 0 ]; then
    echo "Record section's record and clear literals are not inside one fenced bash block"
    return 1
  fi

  # 6. The cache-clear jq expression is single-sourced across the whole file.
  local clear_count
  clear_count=$(grep -cF '.hardenNudgeReason = "" | .checkedAt = 0' "$file")
  if [ "$clear_count" -ne 1 ]; then
    echo "the cache-clear jq expression appears $clear_count times, expected exactly 1"
    return 1
  fi

  # 7. Both ledger record call sites carry --audited-pr-count.
  local decline_start defer_start
  decline_start=$(grep -n "^### decline" "$file" | head -1 | cut -d: -f1)
  defer_start=$(grep -n "^### defer" "$file" | head -1 | cut -d: -f1)
  if [ -z "$decline_start" ] || [ -z "$defer_start" ]; then
    echo "missing the decline or defer heading"
    return 1
  fi
  sed -n "${decline_start},${defer_start}p" "$file" | grep -qF -- "--audited-pr-count" \
    || { echo "the decline call site is missing --audited-pr-count"; return 1; }
  sed -n "${unclassified_line},${record_heading_line}p" "$file" | grep -qF -- "--audited-pr-count" \
    || { echo "the unclassified-signal call site is missing --audited-pr-count"; return 1; }

  return 0
}

# check_no_stale_phrasing <file>
#   Returns 0 only when neither retired defer/unclassified phrase is present.
check_no_stale_phrasing() {
  local file="$1"

  grep -qF "simply nudges again" "$file" && return 1
  grep -qF "nagged for it for up to ninety days" "$file" && return 1
  return 0
}

# --- (a) the real file passes ---

@test "check_record_prose passes on the real harden.md" {
  run check_record_prose "$HARDEN_MARKDOWN"
  [ "$status" -eq 0 ]
}

@test "harden.md no longer contains the retired defer/unclassified phrasing" {
  run check_no_stale_phrasing "$HARDEN_MARKDOWN"
  [ "$status" -eq 0 ]
}

# --- (b) refusal cases ---

@test "refuses when the Record section is moved after Publish" {
  local copy="$BATS_TEST_TMPDIR/harden-record-after-publish.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  local record_line publish_line
  record_line=$(grep -n "^## Record the review (end of run)" "$copy" | head -1 | cut -d: -f1)
  publish_line=$(grep -n "^## Publish approved changes (end of run)" "$copy" | head -1 | cut -d: -f1)
  swap_lines "$copy" "$record_line" "$publish_line"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the cache clear is placed before the record line" {
  local copy="$BATS_TEST_TMPDIR/harden-clear-before-record.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  local record_heading_line publish_line record_relative_line clear_relative_line record_absolute_line clear_absolute_line
  record_heading_line=$(grep -n "^## Record the review (end of run)" "$copy" | head -1 | cut -d: -f1)
  publish_line=$(grep -n "^## Publish approved changes (end of run)" "$copy" | head -1 | cut -d: -f1)
  record_relative_line=$(sed -n "${record_heading_line},${publish_line}p" "$copy" | grep -n "harden-ledger snapshot record --tally-file" | head -1 | cut -d: -f1)
  clear_relative_line=$(sed -n "${record_heading_line},${publish_line}p" "$copy" | grep -nF '.hardenNudgeReason = ""' | head -1 | cut -d: -f1)
  record_absolute_line=$((record_heading_line + record_relative_line - 1))
  clear_absolute_line=$((record_heading_line + clear_relative_line - 1))
  swap_lines "$copy" "$record_absolute_line" "$clear_absolute_line"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the all-clear region no longer references Record the review" {
  local copy="$BATS_TEST_TMPDIR/harden-allclear-no-reference.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  local allclear_start
  allclear_start=$(grep -n 'candidate_count.*is .0.*unclassified.*is .null' "$copy" | head -1 | cut -d: -f1)
  sed -i.bak "${allclear_start}s/Record the review/XXXXXXXXXX/" "$copy"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the all-clear region regains a duplicate copy of the record-and-clear block" {
  local copy="$BATS_TEST_TMPDIR/harden-allclear-duplicated-block.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  local allclear_start duplicate_block_file
  allclear_start=$(grep -n 'candidate_count.*is .0.*unclassified.*is .null' "$copy" | head -1 | cut -d: -f1)
  duplicate_block_file="$BATS_TEST_TMPDIR/duplicate_block_file-block.txt"
  cat > "$duplicate_block_file" <<'EOF'
.gaia/cli/gaia harden-ledger snapshot record --tally-file .gaia/local/harden/review-tally.json
record_status=$?
if [ "$record_status" -eq 0 ]; then
  jq '.hardenNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp" && mv "$tmp" "$CACHE"
fi
EOF
  insert_after "$copy" "$allclear_start" "$duplicate_block_file"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the cache-clear jq expression is duplicated elsewhere in the file" {
  local copy="$BATS_TEST_TMPDIR/harden-jq-duplicated.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  cat >> "$copy" <<'EOF'

jq '.hardenNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp"
EOF
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when --audited-pr-count is stripped from the decline call" {
  local copy="$BATS_TEST_TMPDIR/harden-decline-no-audited.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  local decline_start defer_start line_relative line_absolute
  decline_start=$(grep -n "^### decline" "$copy" | head -1 | cut -d: -f1)
  defer_start=$(grep -n "^### defer" "$copy" | head -1 | cut -d: -f1)
  line_relative=$(sed -n "${decline_start},${defer_start}p" "$copy" | grep -n -- "--audited-pr-count" | head -1 | cut -d: -f1)
  line_absolute=$((decline_start + line_relative - 1))
  sed -i.bak "${line_absolute}s/ --audited-pr-count <audited_pr_count>//" "$copy"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "check_no_stale_phrasing refuses a copy carrying the retired unclassified phrasing" {
  local copy="$BATS_TEST_TMPDIR/harden-stale-phrasing.md"
  cp "$HARDEN_MARKDOWN" "$copy"
  printf '\nnagged for it for up to ninety days\n' >> "$copy"
  run check_no_stale_phrasing "$copy"
  [ "$status" -ne 0 ]
}

# --- existing pins from harden-unclassified-segment.bats stay green ---

@test "still binds the top-level unclassified field" {
  grep -qF "bind the top-level \`unclassified\` field" "$HARDEN_MARKDOWN"
}

@test "still carries the Unclassified recurrence signal heading" {
  grep -qF "## Unclassified recurrence signal (seed-a-class-or-investigate)" "$HARDEN_MARKDOWN"
}

@test "still states the unclassified signal is excluded from the draftable candidate set" {
  grep -qF "It is NEVER placed in the draftable candidate set." "$HARDEN_MARKDOWN"
}
