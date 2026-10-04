#!/usr/bin/env bats
# Static and executable checks over the /update-deps skill's security
# remediation text: `.claude/skills/update-deps/SKILL.md`, its security recipe
# `references/security.md`, and the override audit `references/override-audit.md`.
#
# What this suite pins: the Security preview section heads the preview, a run
# with no outdated package but an open advisory is a real run, the security
# phase's batch gate and per-resolution revert, every still-open reason literal,
# the Phase 7 Security section's source line, dismissed-alert exclusion,
# introduced marker, and cache rewrite, the Phase 8 security-only subject, the
# flag refusal, the frontmatter triggers, acceptance only after a per-advisory
# question, the release-age and trust settings rule, no fixed /tmp scratch path,
# the worktree state line's null-versus-zero read, the report-only reading,
# the security phase's own snapshot directories, and baseline conversion.
#
# Each check is a function over a file path, so every test that proves the
# real page passes has a twin that runs the same function over a scratch copy
# with the guarded content removed or altered and asserts it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SKILL="${REPO_ROOT}/.claude/skills/update-deps/SKILL.md"
  SECURITY="${REPO_ROOT}/.claude/skills/update-deps/references/security.md"
  OVERRIDE_AUDIT="${REPO_ROOT}/.claude/skills/update-deps/references/override-audit.md"
  local file
  for file in "$SKILL" "$SECURITY" "$OVERRIDE_AUDIT"; do
    [ -f "$file" ] || {
      echo "an audited page is absent: ${file}" >&2
      return 1
    }
  done
}

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# remove_fixed <file> <fixed-string>: delete every occurrence of a fixed
# string in place (no regex, so backticks, dollars, and brackets are literal).
remove_fixed() {
  replace_fixed "$1" "$2" ""
}

# replace_fixed <file> <fixed-string> <replacement>: replace every occurrence
# of a fixed string in place, and fail when the string was not there, so a
# twin can never pass because its mutation silently missed.
replace_fixed() {
  local file="$1" needle="$2" replacement="$3" mutated="${1}.mutated"
  grep -qF -- "$needle" "$file" || {
    echo "mutation target not found: ${needle}" >&2
    return 1
  }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    BEGIN { needle = ENVIRON["NEEDLE"]; replacement = ENVIRON["REPLACEMENT"] }
    {
      line = $0; out = ""
      while ((position = index(line, needle)) > 0) {
        out = out substr(line, 1, position - 1) replacement
        line = substr(line, position + length(needle))
      }
      print out line
    }
  ' "$file" >"$mutated"
  mv "$mutated" "$file"
}

# section <file> <start-heading> <next-heading>: print the lines from the
# start heading (exact line) up to, not including, the next heading.
section() {
  START="$2" STOP="$3" awk '
    $0 == ENVIRON["START"] { inside = 1; print; next }
    inside && $0 == ENVIRON["STOP"] { exit }
    inside { print }
  ' "$1"
}

phase7() { section "$1" "## Phase 7: Final report" "## Phase 8: Publish"; }

# ---------------------------------------------------------------------------
# 1. The Security section heads the preview
# ---------------------------------------------------------------------------

check_security_before_major() {
  local preview security_line major_line
  preview="$(section "$1" "### Preview" "### Decision")"
  security_line="$(grep -nF -- '**Security**' <<<"$preview" | head -n 1 | cut -d: -f1)"
  major_line="$(grep -nF -- '**Major**' <<<"$preview" | head -n 1 | cut -d: -f1)"
  [ -n "$security_line" ] && [ -n "$major_line" ] || {
    echo "the preview names no Security or no Major section" >&2
    return 1
  }
  [ "$security_line" -lt "$major_line" ] || {
    echo "the Security section does not come before Major" >&2
    return 1
  }
}

@test "the preview places the Security section above Major" {
  check_security_before_major "$SKILL"
}

@test "the preview-order check fails when Security and Major swap" {
  local copy
  copy="$(scratch_copy "$SKILL" "swap.md")"
  replace_fixed "$copy" '**Security**' '@@SWAP@@'
  replace_fixed "$copy" '**Major**' '**Security**'
  replace_fixed "$copy" '@@SWAP@@' '**Major**'
  run check_security_before_major "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 2. Zero outdated with an advisory is a real run
# ---------------------------------------------------------------------------

check_zero_outdated_with_advisory() {
  grep -qF -- '**A zero `total_count` with at least one advisory**' "$1" || return 1
  grep -qF -- 'is a real run, not "nothing to do"' "$1" || {
    echo "the zero-outdated advisory branch no longer refuses nothing-to-do" >&2
    return 1
  }
}

@test "a zero-outdated run with an advisory does not exit as nothing to do" {
  check_zero_outdated_with_advisory "$SKILL"
}

@test "the zero-outdated check fails with the branch sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "zero.md")"
  remove_fixed "$copy" 'is a real run, not "nothing to do"'
  run check_zero_outdated_with_advisory "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 3. Per-resolution revert and the re-gate cap
# ---------------------------------------------------------------------------

check_revert_and_cap() {
  grep -qF -- 'A failure reverts that resolution alone from its own `$resolution_snapshot`' "$1" || {
    echo "the per-resolution revert is not stated" >&2
    return 1
  }
  grep -qF -- 'Stop after 5 individual re-gates' "$1" || {
    echo "the 5 re-gate cap is not stated" >&2
    return 1
  }
}

@test "the security recipe states the per-resolution revert and the 5 re-gate cap" {
  check_revert_and_cap "$SECURITY"
}

@test "the revert check fails with the revert sentence deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "revert.md")"
  remove_fixed "$copy" 'A failure reverts that resolution alone from its own `$resolution_snapshot`'
  run check_revert_and_cap "$copy"
  [ "$status" -ne 0 ]
}

@test "the revert check fails with the re-gate cap deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "cap.md")"
  remove_fixed "$copy" 'Stop after 5 individual re-gates'
  run check_revert_and_cap "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 4. Every still-open reason literal is stated
# ---------------------------------------------------------------------------

# reason_literals: one literal per line, each opened by its backtick so a
# literal that is a prefix of another (quality gate failed) stays distinct.
reason_literals() {
  printf '%s\n' \
    '`no patch`' \
    '`acceptance declined`' \
    '`quality gate failed`' \
    '`quality gate failed (batch not isolated)`' \
    '`wave reverted (' \
    '`chain-head major declined`' \
    '`dismissal refused (' \
    '`patch inside release-age window (eligible ' \
    '`report-only run`' \
    '`held by config (' \
    '`still installed in vulnerable range (' \
    '`introduced by this run`'
}

# check_reason_literals <skill> <security>
check_reason_literals() {
  local literal count=0
  while IFS= read -r literal; do
    count=$((count + 1))
    grep -qF -- "$literal" "$1" "$2" || {
      echo "reason literal absent: ${literal}" >&2
      return 1
    }
  done < <(reason_literals)
  [ "$count" -eq 12 ] || {
    echo "expected 12 reason literals, read ${count}" >&2
    return 1
  }
}

@test "every still-open reason literal appears in the skill or the security recipe" {
  check_reason_literals "$SKILL" "$SECURITY"
}

@test "the reason-literal check fails on each literal deleted" {
  local literal count=0 skill_copy security_copy
  while IFS= read -r literal; do
    count=$((count + 1))
    skill_copy="$(scratch_copy "$SKILL" "reason-skill-${count}.md")"
    security_copy="$(scratch_copy "$SECURITY" "reason-security-${count}.md")"
    grep -qF -- "$literal" "$skill_copy" && remove_fixed "$skill_copy" "$literal"
    grep -qF -- "$literal" "$security_copy" && remove_fixed "$security_copy" "$literal"
    run check_reason_literals "$skill_copy" "$security_copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with ${literal} deleted" >&2
      return 1
    }
  done < <(reason_literals)
  [ "$count" -eq 12 ]
}

# ---------------------------------------------------------------------------
# 5, 13, 14, 15. The Phase 7 Security section
# ---------------------------------------------------------------------------

check_not_run_source_line() {
  grep -qF -- 'Dependabot alerts: Not run (' <<<"$(phase7 "$1")"
}

@test "the Phase 7 Security instructions carry the alerts Not run source line" {
  check_not_run_source_line "$SKILL"
}

@test "the source-line check fails with the Not run literal deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "not-run.md")"
  remove_fixed "$copy" 'Dependabot alerts: Not run ('
  run check_not_run_source_line "$copy"
  [ "$status" -ne 0 ]
}

check_dismissed_exclusion() {
  grep -qF -- 'is in the opening `dismissedGhsas`, or that this run dismissed, is accepted, not open: it gets no Still open row and no `introduced by this run` marker' <<<"$(phase7 "$1")"
}

@test "Phase 7 excludes dismissed alerts from Still open and from the introduced marker" {
  check_dismissed_exclusion "$SKILL"
}

@test "the dismissed-alert check fails with the exclusion sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "dismissed.md")"
  remove_fixed "$copy" 'is in the opening `dismissedGhsas`, or that this run dismissed, is accepted, not open: it gets no Still open row and no `introduced by this run` marker'
  run check_dismissed_exclusion "$copy"
  [ "$status" -ne 0 ]
}

check_cache_rewrite() {
  local body
  body="$(phase7 "$1")"
  grep -qF -- '.gaia/cli/gaia update-deps write-security-cache --count' <<<"$body" || {
    echo "Phase 7 does not call write-security-cache" >&2
    return 1
  }
  grep -qF -- '.gaia/cli/gaia update-deps advisories --emit "$count_json" --count-only' <<<"$body" || {
    echo "the cache count does not come from advisories --count-only" >&2
    return 1
  }
  grep -qF -- "never from the report's tables" <<<"$body" || {
    echo "the cache count is not barred from the report tables" >&2
    return 1
  }
  grep -qF -- 'never in CI: there the rewrite is skipped entirely' <<<"$body" || {
    echo "the CI skip of the cache rewrite is not stated" >&2
    return 1
  }
}

@test "Phase 7 rewrites the security cache from advisories --count-only, skipped in CI" {
  check_cache_rewrite "$SKILL"
}

@test "the cache-rewrite check fails with the write-security-cache call deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "cache-call.md")"
  remove_fixed "$copy" '.gaia/cli/gaia update-deps write-security-cache --count'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

@test "the cache-rewrite check fails with the --count-only call deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "cache-count.md")"
  remove_fixed "$copy" '.gaia/cli/gaia update-deps advisories --emit "$count_json" --count-only'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

@test "the cache-rewrite check fails with the CI skip sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "cache-ci.md")"
  remove_fixed "$copy" 'never in CI: there the rewrite is skipped entirely'
  run check_cache_rewrite "$copy"
  [ "$status" -ne 0 ]
}

check_no_bare_none_and_introduced() {
  local body
  body="$(phase7 "$1")"
  grep -qF -- 'never a bare `None`' <<<"$body" || {
    echo "Phase 7 no longer states the section never reads a bare None" >&2
    return 1
  }
  grep -qF -- 'Mark `introduced by this run` on a row whose key is not in the opening advisory set; that set is the opening payload'"'"'s `advisories[].key` plus its `dismissedGhsas`' <<<"$body" || {
    echo "the introduced marker is not tied to the opening-set comparison" >&2
    return 1
  }
}

@test "Phase 7 never reads a bare None and ties the introduced marker to the opening set" {
  check_no_bare_none_and_introduced "$SKILL"
}

@test "the no-bare-None check fails with that sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "bare-none.md")"
  remove_fixed "$copy" 'never a bare `None`'
  run check_no_bare_none_and_introduced "$copy"
  [ "$status" -ne 0 ]
}

@test "the introduced-marker check fails with the comparison clause deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "introduced.md")"
  remove_fixed "$copy" '; that set is the opening payload'"'"'s `advisories[].key` plus its `dismissedGhsas`'
  run check_no_bare_none_and_introduced "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 7. Phase 8 publishes security-only runs under chore(deps):
# ---------------------------------------------------------------------------

check_phase8_security_only() {
  local body
  body="$(section "$1" "## Phase 8: Publish" "@@end-of-file@@")"
  grep -qF -- 'Phase 8 runs when the only landed work is security resolutions.' <<<"$body" || {
    echo "Phase 8 does not run for security-only work" >&2
    return 1
  }
  grep -qF -- 'only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`' <<<"$body" || {
    echo "the security-only subject is not chore(deps):" >&2
    return 1
  }
}

@test "Phase 8 runs for security-only work and its subject begins chore(deps):" {
  check_phase8_security_only "$SKILL"
}

@test "the Phase 8 check fails with the security-only run clause deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "phase8-run.md")"
  remove_fixed "$copy" 'Phase 8 runs when the only landed work is security resolutions.'
  run check_phase8_security_only "$copy"
  [ "$status" -ne 0 ]
}

@test "the Phase 8 check fails with the chore(deps): subject clause deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "phase8-subject.md")"
  remove_fixed "$copy" 'only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`'
  run check_phase8_security_only "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 8. --security with --scope refuses naming both
# ---------------------------------------------------------------------------

check_flag_refusal() {
  grep -qF -- '`/update-deps: --security and --scope cannot be combined; pass one or the other.`' "$1"
}

@test "--security with --scope refuses with a message naming both flags" {
  check_flag_refusal "$SKILL"
}

@test "the flag-refusal check fails with one flag removed from the message" {
  local copy
  copy="$(scratch_copy "$SKILL" "flags.md")"
  replace_fixed "$copy" '--security and --scope cannot be combined' '--security cannot be combined'
  run check_flag_refusal "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 9. Frontmatter description
# ---------------------------------------------------------------------------

# description_phrases: phrases the description must carry.
description_phrases() {
  printf '%s\n' 'Dependabot' 'security updates' 'fix Dependabot alerts' 'fix security advisories'
}

check_description() {
  local description phrase count=0
  description="$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside && /^description:/' "$1")"
  [ -n "$description" ] || {
    echo "no frontmatter description" >&2
    return 1
  }
  while IFS= read -r phrase; do
    count=$((count + 1))
    grep -qF -- "$phrase" <<<"$description" || {
      echo "description lacks: ${phrase}" >&2
      return 1
    }
  done < <(description_phrases)
  [ "$count" -eq 4 ] || return 1
  if grep -qF -- 'Autonomous Dependabot' <<<"$description"; then
    echo "description still says Autonomous Dependabot" >&2
    return 1
  fi
}

@test "UAT-025: the description names Dependabot, security updates, and both security triggers" {
  check_description "$SKILL"
}

@test "the description check fails on each phrase removed" {
  local phrase count=0 copy
  while IFS= read -r phrase; do
    count=$((count + 1))
    copy="$(scratch_copy "$SKILL" "description-${count}.md")"
    remove_fixed "$copy" "$phrase"
    run check_description "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with ${phrase} removed" >&2
      return 1
    }
  done < <(description_phrases)
  [ "$count" -eq 4 ]
}

@test "the description check fails with Autonomous Dependabot put back" {
  local copy
  copy="$(scratch_copy "$SKILL" "description-autonomous.md")"
  replace_fixed "$copy" 'description: Dependency remediation' 'description: Autonomous Dependabot, dependency remediation'
  run check_description "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 10. Acceptance asks per advisory and never runs in CI
# ---------------------------------------------------------------------------

check_acceptance() {
  local body
  body="$(section "$1" "#### 7. Acceptance" "#### Return value")"
  grep -qF -- 'Ask with `AskUserQuestion`, one advisory per question' <<<"$body" || {
    echo "acceptance does not ask per advisory" >&2
    return 1
  }
  grep -qF -- 'dismiss-alert --alert <n> --reason <tolerable_risk|not_used> --comment' <<<"$body" || return 1
  grep -qF -- '`--confirmed` is passed only after that advisory'"'"'s `AskUserQuestion` was answered yes' <<<"$body" || {
    echo "--confirmed is not tied to the per-advisory question" >&2
    return 1
  }
  grep -qF -- 'Never dismiss in CI' <<<"$body" || {
    echo "acceptance does not state it never runs in CI" >&2
    return 1
  }
}

@test "acceptance dismisses with --confirmed only after a per-advisory question, never in CI" {
  check_acceptance "$SECURITY"
}

@test "the acceptance check fails with the CI sentence deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "acceptance-ci.md")"
  remove_fixed "$copy" 'Never dismiss in CI'
  run check_acceptance "$copy"
  [ "$status" -ne 0 ]
}

@test "the acceptance check fails with the --confirmed ordering deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "acceptance-confirmed.md")"
  remove_fixed "$copy" '`--confirmed` is passed only after that advisory'"'"'s `AskUserQuestion` was answered yes'
  run check_acceptance "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 11. The release-age and trust settings stay untouched
# ---------------------------------------------------------------------------

RELEASE_AGE_RULE='never add a `minimumReleaseAgeExclude` entry, and never change `minimumReleaseAge`, `minimumReleaseAgeStrict`, `minimumReleaseAgeExclude`, `trustPolicy`, or `trustPolicyExclude`'

check_release_age_rule() {
  grep -qF -- "$RELEASE_AGE_RULE" "$1"
}

@test "the security recipe forbids touching the five release-age and trust settings" {
  check_release_age_rule "$SECURITY"
}

@test "the release-age check fails with the rule deleted" {
  local copy
  copy="$(scratch_copy "$SECURITY" "release-age.md")"
  remove_fixed "$copy" "$RELEASE_AGE_RULE"
  run check_release_age_rule "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 12. No fixed /tmp scratch path
# ---------------------------------------------------------------------------

check_no_tmp() {
  local file
  for file in "$@"; do
    if grep -qF -- '/tmp/' "$file"; then
      echo "/tmp/ path in ${file}" >&2
      return 1
    fi
  done
}

@test "no /tmp/ path remains in the skill, the security recipe, or the override audit" {
  check_no_tmp "$SKILL" "$SECURITY" "$OVERRIDE_AUDIT"
}

@test "the /tmp check fails on a /tmp/ path inserted into each file" {
  local source count=0 copy
  for source in "$SKILL" "$SECURITY" "$OVERRIDE_AUDIT"; do
    count=$((count + 1))
    copy="$(scratch_copy "$source" "tmp-${count}.md")"
    printf '\nmkdir -p /tmp/update-deps-scratch\n' >>"$copy"
    run check_no_tmp "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with /tmp/ inserted into a copy of ${source}" >&2
      return 1
    }
  done
  [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 16. The worktree state line reads null apart from zero
# ---------------------------------------------------------------------------

# state_line_body <file>: the gaia_update_deps_state_line definition, from its
# opening line to the first line that is exactly a closing brace.
state_line_body() {
  awk '
    $0 == "gaia_update_deps_state_line() {" { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

check_state_line_reads_null() {
  local body
  body="$(state_line_body "$1")"
  [ -n "$body" ] || {
    echo "no gaia_update_deps_state_line definition" >&2
    return 1
  }
  grep -qF -- '.securityCount' <<<"$body" || {
    echo "the state line does not read securityCount" >&2
    return 1
  }
  if grep -qE -- 'securityCount[[:space:]]*\|?[[:space:]]*//' <<<"$body"; then
    echo "the state line defaults securityCount with //" >&2
    return 1
  fi
  grep -qF -- 'security advisories unavailable' <<<"$body" || {
    echo "the state line has no unavailable branch" >&2
    return 1
  }
}

@test "the state line reads securityCount with no // default and an unavailable branch" {
  check_state_line_reads_null "$SKILL"
}

@test "the state-line check fails with a // 0 default substituted" {
  local copy
  copy="$(scratch_copy "$SKILL" "state-default.md")"
  replace_fixed "$copy" '(.securityCount | tostring)' '(.securityCount // 0 | tostring)'
  run check_state_line_reads_null "$copy"
  [ "$status" -ne 0 ]
}

# run_state_line <cache-json>: source the extracted function and run it over
# a fixture cache.
run_state_line() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required to run the state line" >&2
    return 1
  }
  local function_file="${BATS_TEST_TMPDIR}/state-line.sh" cache="${BATS_TEST_TMPDIR}/update-check.json"
  state_line_body "$SKILL" >"$function_file"
  [ -s "$function_file" ] || return 1
  printf '%s\n' "$1" >"$cache"
  run bash -c '. "$1" && gaia_update_deps_state_line "$2"' _ "$function_file" "$cache"
}

@test "the state line prints security advisories unavailable for a null count" {
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":null,\"securitySource\":\"unavailable\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, security advisories unavailable (last checked' <<<"$output"
  grep -qF -- '0 open security advisories' <<<"$output" && return 1
  true
}

@test "the state line prints 0 open security advisories for a zero count" {
  run_state_line "{\"outdatedCount\":3,\"checkedAt\":$(date +%s),\"securityCount\":0,\"securitySource\":\"dependabot\"}"
  [ "$status" -eq 0 ]
  grep -qF -- 'Cached on main: 3 packages outdated, 0 open security advisories (last checked' <<<"$output"
}

# ---------------------------------------------------------------------------
# 17. Report-only is a property of the security phase
# ---------------------------------------------------------------------------

REPORT_ONLY_SECURITY='the security phase adds, edits, and removes no `overrides:` key and applies no advisory-driven bump'
REPORT_ONLY_AUDIT='The existing Phase 0 and Phase 6 override audit is unchanged in those runs'

check_report_only_reading() {
  grep -qF -- "$REPORT_ONLY_SECURITY" "$1" || {
    echo "report-only no longer states the security phase leaves overrides alone" >&2
    return 1
  }
  grep -qF -- "$REPORT_ONLY_AUDIT" "$1" || {
    echo "report-only no longer states the Phase 0/6 audit is unchanged" >&2
    return 1
  }
}

@test "report-only runs leave overrides to the unchanged Phase 0/6 audit" {
  check_report_only_reading "$SKILL"
}

@test "the report-only check fails with the security-phase sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "report-only.md")"
  remove_fixed "$copy" "$REPORT_ONLY_SECURITY"
  run check_report_only_reading "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 18. The security phase keeps its own snapshot directories
# ---------------------------------------------------------------------------

RESOLUTION_MKTEMP='resolution_snapshot="$(mktemp -d .gaia/local/cache/shared/.update-deps-security-resolution.XXXXXX)"'

check_own_snapshots() {
  grep -qF -- 'batch_snapshot="$(mktemp -d .gaia/local/cache/shared/' "$1" || {
    echo "no batch snapshot under .gaia/local/cache/shared/" >&2
    return 1
  }
  grep -qF -- 'resolution_snapshot="$(mktemp -d .gaia/local/cache/shared/' "$1" || {
    echo "no per-resolution snapshot under .gaia/local/cache/shared/" >&2
    return 1
  }
  if grep -qF -- 'update-deps-refresh' "$1"; then
    echo "the security recipe reuses the transitive refresh directory" >&2
    return 1
  fi
}

@test "the security recipe takes its own batch and per-resolution snapshots" {
  check_own_snapshots "$SECURITY"
}

@test "the snapshot check fails with the per-resolution snapshot moved to the refresh directory" {
  local copy
  copy="$(scratch_copy "$SECURITY" "snapshot.md")"
  replace_fixed "$copy" "$RESOLUTION_MKTEMP" 'resolution_snapshot=/tmp/update-deps-refresh'
  run check_own_snapshots "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 19. Conversion with several baseline entries
# ---------------------------------------------------------------------------

CONVERSION_REFUSAL='Refuse the conversion only when no baseline entry maps to the GHSA'

check_conversion() {
  local paragraph
  paragraph="$(grep -F -- '**Conversion.**' "$1")"
  grep -qF -- "$CONVERSION_REFUSAL" <<<"$paragraph" || {
    echo "conversion is not refused only when no entry maps" >&2
    return 1
  }
  grep -qF -- 'derive the proposed comment from the entry with the lowest id' <<<"$paragraph" || return 1
  grep -qF -- 'confirm once for that advisory' <<<"$paragraph" || return 1
  if grep -qF -- 'more than one' <<<"$paragraph"; then
    echo "conversion refuses when more than one entry maps" >&2
    return 1
  fi
}

@test "conversion refuses only when no entry maps, and uses the lowest id when several do" {
  check_conversion "$SECURITY"
}

@test "the conversion check fails with more than one restored as a refusal condition" {
  local copy
  copy="$(scratch_copy "$SECURITY" "conversion.md")"
  replace_fixed "$copy" "$CONVERSION_REFUSAL" "${CONVERSION_REFUSAL}, or when more than one entry maps"
  run check_conversion "$copy"
  [ "$status" -ne 0 ]
}
