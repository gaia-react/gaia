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
  HARDEN_MD=$(cd "$BATS_TEST_DIRNAME/../../../.claude/skills/gaia/references" && pwd)/harden.md
}

# swap_lines <file> <line1> <line2>
#   In-place swaps the content of two 1-indexed lines in <file>.
swap_lines() {
  local file="$1" l1="$2" l2="$3"
  awk -v l1="$l1" -v l2="$l2" '
    NR==l1 { a=$0 }
    NR==l2 { b=$0 }
    { lines[NR]=$0 }
    END {
      lines[l1]=b
      lines[l2]=a
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

# insert_after <file> <line_no> <text_file>
#   Inserts every line of <text_file> into <file> immediately after the
#   1-indexed line <line_no>.
insert_after() {
  local file="$1" line_no="$2" text_file="$3"
  awk -v line_no="$line_no" -v text_file="$text_file" '
    { print }
    NR==line_no {
      while ((getline l < text_file) > 0) print l
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
  local rs_record_rel rs_status_rel rs_guard_rel rs_clear_rel
  rs_record_rel=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -n "harden-ledger snapshot record --tally-file" | head -1 | cut -d: -f1)
  if [ -z "$rs_record_rel" ]; then
    echo "Record section missing the snapshot record literal"
    return 1
  fi
  rs_status_rel=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF 'record_status=$?' | head -1 | cut -d: -f1)
  if [ -z "$rs_status_rel" ]; then
    echo "Record section missing the record_status capture"
    return 1
  fi
  rs_guard_rel=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF '"$record_status" -eq 0' | head -1 | cut -d: -f1)
  if [ -z "$rs_guard_rel" ]; then
    echo "Record section missing the record_status -eq 0 guard"
    return 1
  fi
  rs_clear_rel=$(sed -n "${record_heading_line},${publish_line}p" "$file" | grep -nF '.hardenNudgeReason = ""' | head -1 | cut -d: -f1)
  if [ -z "$rs_clear_rel" ]; then
    echo "Record section missing the cache-clear literal"
    return 1
  fi

  local rs_record_abs rs_status_abs rs_guard_abs rs_clear_abs
  rs_record_abs=$((record_heading_line + rs_record_rel - 1))
  rs_status_abs=$((record_heading_line + rs_status_rel - 1))
  rs_guard_abs=$((record_heading_line + rs_guard_rel - 1))
  rs_clear_abs=$((record_heading_line + rs_clear_rel - 1))

  if [ "$rs_status_abs" -le "$rs_record_abs" ] || [ "$rs_guard_abs" -le "$rs_status_abs" ] || [ "$rs_clear_abs" -le "$rs_guard_abs" ]; then
    echo "Record section's record/status/guard/clear literals are out of order"
    return 1
  fi

  # 5. The record literal and the cache-clear literal sit inside the same
  #    fenced bash block (no ``` fence boundary between them), so they run
  #    together as one Bash call: shell variables do not persist across
  #    separate calls.
  local between_fence_count
  between_fence_count=$(sed -n "$((rs_record_abs + 1)),$((rs_clear_abs - 1))p" "$file" | grep -c '^```')
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
  run check_record_prose "$HARDEN_MD"
  [ "$status" -eq 0 ]
}

@test "harden.md no longer contains the retired defer/unclassified phrasing" {
  run check_no_stale_phrasing "$HARDEN_MD"
  [ "$status" -eq 0 ]
}

# --- (b) refusal cases ---

@test "refuses when the Record section is moved after Publish" {
  local copy="$BATS_TEST_TMPDIR/harden-record-after-publish.md"
  cp "$HARDEN_MD" "$copy"
  local rec_line pub_line
  rec_line=$(grep -n "^## Record the review (end of run)" "$copy" | head -1 | cut -d: -f1)
  pub_line=$(grep -n "^## Publish approved changes (end of run)" "$copy" | head -1 | cut -d: -f1)
  swap_lines "$copy" "$rec_line" "$pub_line"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the cache clear is placed before the record line" {
  local copy="$BATS_TEST_TMPDIR/harden-clear-before-record.md"
  cp "$HARDEN_MD" "$copy"
  local record_heading_line publish_line rec_rel clear_rel rec_abs clear_abs
  record_heading_line=$(grep -n "^## Record the review (end of run)" "$copy" | head -1 | cut -d: -f1)
  publish_line=$(grep -n "^## Publish approved changes (end of run)" "$copy" | head -1 | cut -d: -f1)
  rec_rel=$(sed -n "${record_heading_line},${publish_line}p" "$copy" | grep -n "harden-ledger snapshot record --tally-file" | head -1 | cut -d: -f1)
  clear_rel=$(sed -n "${record_heading_line},${publish_line}p" "$copy" | grep -nF '.hardenNudgeReason = ""' | head -1 | cut -d: -f1)
  rec_abs=$((record_heading_line + rec_rel - 1))
  clear_abs=$((record_heading_line + clear_rel - 1))
  swap_lines "$copy" "$rec_abs" "$clear_abs"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the all-clear region no longer references Record the review" {
  local copy="$BATS_TEST_TMPDIR/harden-allclear-no-reference.md"
  cp "$HARDEN_MD" "$copy"
  local allclear_start
  allclear_start=$(grep -n 'candidate_count.*is .0.*unclassified.*is .null' "$copy" | head -1 | cut -d: -f1)
  sed -i.bak "${allclear_start}s/Record the review/XXXXXXXXXX/" "$copy"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the all-clear region regains a duplicate copy of the record-and-clear block" {
  local copy="$BATS_TEST_TMPDIR/harden-allclear-duplicated-block.md"
  cp "$HARDEN_MD" "$copy"
  local allclear_start dup
  allclear_start=$(grep -n 'candidate_count.*is .0.*unclassified.*is .null' "$copy" | head -1 | cut -d: -f1)
  dup="$BATS_TEST_TMPDIR/dup-block.txt"
  cat > "$dup" <<'EOF'
.gaia/cli/gaia harden-ledger snapshot record --tally-file .gaia/local/harden/review-tally.json
record_status=$?
if [ "$record_status" -eq 0 ]; then
  jq '.hardenNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp" && mv "$tmp" "$CACHE"
fi
EOF
  insert_after "$copy" "$allclear_start" "$dup"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when the cache-clear jq expression is duplicated elsewhere in the file" {
  local copy="$BATS_TEST_TMPDIR/harden-jq-duplicated.md"
  cp "$HARDEN_MD" "$copy"
  cat >> "$copy" <<'EOF'

jq '.hardenNudgeReason = "" | .checkedAt = 0' "$CACHE" > "$tmp"
EOF
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "refuses when --audited-pr-count is stripped from the decline call" {
  local copy="$BATS_TEST_TMPDIR/harden-decline-no-audited.md"
  cp "$HARDEN_MD" "$copy"
  local decline_start defer_start line_rel line_abs
  decline_start=$(grep -n "^### decline" "$copy" | head -1 | cut -d: -f1)
  defer_start=$(grep -n "^### defer" "$copy" | head -1 | cut -d: -f1)
  line_rel=$(sed -n "${decline_start},${defer_start}p" "$copy" | grep -n -- "--audited-pr-count" | head -1 | cut -d: -f1)
  line_abs=$((decline_start + line_rel - 1))
  sed -i.bak "${line_abs}s/ --audited-pr-count <audited_pr_count>//" "$copy"
  run check_record_prose "$copy"
  [ "$status" -ne 0 ]
}

@test "check_no_stale_phrasing refuses a copy carrying the retired unclassified phrasing" {
  local copy="$BATS_TEST_TMPDIR/harden-stale-phrasing.md"
  cp "$HARDEN_MD" "$copy"
  printf '\nnagged for it for up to ninety days\n' >> "$copy"
  run check_no_stale_phrasing "$copy"
  [ "$status" -ne 0 ]
}

# --- existing pins from harden-unclassified-segment.bats stay green ---

@test "still binds the top-level unclassified field" {
  grep -qF "bind the top-level \`unclassified\` field" "$HARDEN_MD"
}

@test "still carries the Unclassified recurrence signal heading" {
  grep -qF "## Unclassified recurrence signal (seed-a-class-or-investigate)" "$HARDEN_MD"
}

@test "still states the unclassified signal is excluded from the draftable candidate set" {
  grep -qF "It is NEVER placed in the draftable candidate set." "$HARDEN_MD"
}
