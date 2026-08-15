#!/usr/bin/env bats
#
# The tech-debt provenance contract's deterministic guard.
#
# What this suite proves: exactly one file states the provenance contract
# (`.claude/skills/file-tech-debt/SKILL.md`, the implementation in
# `.gaia/scripts/debt-origin-lib.sh` exempt as its execution rather than a
# second statement of it); each of the five emitting routes carries an
# instruction pointing at that owner file; the dedup key's deterministic
# consumers still match against an issue body carrying both the dedup-key and
# the provenance comment lines; the documented brake query selects the
# intended set; and the pre-provenance cohort label changes no displayed
# count.
#
# What this suite does NOT prove: nothing here verifies that a route actually
# EMITTED the provenance line at run time. Gating on provenance is forbidden
# by the contract itself, so if that gap is ever closed it has to be a
# periodic check rather than a merge gate. Every prose-pointing assertion
# below proves an instruction exists in the shipped surface; none of them
# proves any agent followed it on a given run.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-origin-contract.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# Every expected value is a literal rather than a value this suite
# recomputes from the same source it is checking.

require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "jq not present on a CI runner; every jq-backed probe here would report green. Check the runner image and the job's install step." >&2
    return 1
  fi
  skip "jq required"
}

setup() {
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  require_jq
  # GitHub Actions exports GITHUB_HEAD_REF on a pull_request event, and
  # .gaia/scripts/tests/ runs there. Nothing below resolves a real branch
  # (test 9's degraded states are synthetic stubs), but unsetting it here
  # matches the sibling debt-origin-lib.bats precedent and costs nothing.
  unset GITHUB_HEAD_REF
  # The frozen exclusion pathspec (README.md C7 / this task's "Files to
  # touch" note): `.gaia/scripts/tests/` is load-bearing and distinct from
  # `.gaia/tests/` (both listed separately in `.gaia/release-exclude`).
  # Without it, this suite's own needles and debt-origin-lib.bats's own
  # fixtures would count as third copies of the contract.
  EXCLUDE_PATHSPEC=(':!.gaia/local/' ':!.gaia/tests/' ':!.gaia/scripts/tests/')
}

# ---------- shared extraction helpers ----------

# extract_fenced_bash_after_heading <file> <heading>
#   Prints the sole ```bash fence found in the section bounded by the exact
#   heading line <heading> and the next `## ` heading (or EOF). Exits 1
#   unless the heading occurs exactly once in the file and exactly one fence
#   occurs in its section, so a heading rename or a section carrying more
#   than one fence surfaces as an extraction failure rather than a passing
#   test of the wrong program.
#
#   Anchoring on the heading rather than on fence CONTENT is load-bearing
#   here specifically: the owner file's C9 rollout command and C10 brake
#   query open with a byte-identical `gh issue list --label tech-debt
#   --state open --limit 1000 --json number,body` prefix, so a
#   content-anchored extractor cannot tell them apart.
extract_fenced_bash_after_heading() {
  local file="$1" heading="$2"
  awk -v heading="$heading" '
    /^## / { in_section = ($0 == heading) ? 1 : 0; if ($0 == heading) heading_count++; next }
    in_section && /^```bash$/ { infence = 1; buf = ""; next }
    in_section && /^```$/ { if (infence) { block_count++; printf "%s", buf }; infence = 0; next }
    in_section && infence { buf = buf $0 "\n" }
    END { if (heading_count != 1 || block_count != 1) exit 1 }
  ' "$file"
}

# extract_sole_bash_fence_matching <file> <ere-pattern>
#   Prints the single ```bash ... ``` fence (fence markers matched regardless
#   of leading indentation, since CHANGELOG.md nests its fence inside a list
#   item) anywhere in <file> whose body carries at least one LINE matching
#   <ere-pattern>. Exits 1 unless exactly one such fence exists in the whole
#   file, the same "exactly one candidate" discipline as the heading-anchored
#   extractor above, for content that needs no heading to disambiguate (each
#   marker used below is unique to one fence in its file).
extract_sole_bash_fence_matching() {
  local file="$1" pattern="$2"
  awk -v pat="$pattern" '
    /^[[:space:]]*```bash[[:space:]]*$/ { infence = 1; buf = ""; has = 0; next }
    /^[[:space:]]*```[[:space:]]*$/ { if (infence) { if (has) { found++; printf "%s", buf } }; infence = 0; next }
    infence { buf = buf $0 "\n"; if ($0 ~ pat) has = 1 }
    END { if (found != 1) exit 1 }
  ' "$file"
}

# strip_common_indent
#   Reads stdin, computes the minimum leading-space count across its
#   non-blank lines, and strips exactly that many leading spaces from every
#   line. CHANGELOG.md nests its rollout fence inside a list item, so its
#   copy of the command is uniformly indented by two spaces; this is what
#   lets test 8 compare it against the owner's column-0 copy after removing
#   only the indentation the list item itself imposes.
strip_common_indent() {
  awk '
    { lines[NR] = $0; if ($0 !~ /^[[:space:]]*$/) { n = match($0, /[^ ]/); if (min == "" || n - 1 < min) min = n - 1 } }
    END { for (i = 1; i <= NR; i++) print substr(lines[i], min + 1) }
  '
}

# ========== 1. exactly one file states the contract ==========

@test "1a. the closed mode vocabulary is stated only by the owner and the exempt helper" {
  # The owner (.claude/skills/file-tech-debt/SKILL.md) backtick-wraps each
  # value individually ("`drain`, `plan`, ..."); the exempt implementation
  # (.gaia/scripts/debt-origin-lib.sh) states the same five-value list as
  # plain comma-joined prose in a comment. No single fixed string spans both
  # phrasings byte-for-byte (verified by hand before writing this test), so
  # this needle is the OR of the two exact statements: either phrasing
  # drifting, or a third file adopting either one verbatim, reds this test.
  local got expected
  got="$(git -C "$REPO_ROOT" grep -lF \
    -e '`drain`, `plan`, `maintenance`, `adhoc`, `unknown`' \
    -e 'drain, plan, maintenance, adhoc, unknown' \
    -- "${EXCLUDE_PATHSPEC[@]}" | LC_ALL=C sort)"
  expected="$(printf '%s\n%s\n' ".gaia/scripts/debt-origin-lib.sh" ".claude/skills/file-tech-debt/SKILL.md" | LC_ALL=C sort)"
  [ "$got" = "$expected" ] || {
    printf 'mode-vocabulary needle matched:\n%s\nexpected exactly:\n%s\n' "$got" "$expected" >&2
    return 1
  }
}

@test "1b. the convention table's rows are stated only by the owner and the exempt helper" {
  # Row 1's full text is the needle: distinctive enough that a paraphrase
  # would have to reproduce it verbatim, and it appears nowhere else on the
  # tree once .gaia/scripts/tests/ is excluded (verified: a bare
  # `wiki-sync/` needle returns 19 tracked files under this exclusion, and a
  # bare `-batch` needle returns more than the owner+helper pair; this row's
  # full text returns exactly two).
  local got expected
  got="$(git -C "$REPO_ROOT" grep -lF -- 'debt/<members>-batch' -- "${EXCLUDE_PATHSPEC[@]}" | LC_ALL=C sort)"
  expected="$(printf '%s\n%s\n' ".gaia/scripts/debt-origin-lib.sh" ".claude/skills/file-tech-debt/SKILL.md" | LC_ALL=C sort)"
  [ "$got" = "$expected" ] || {
    printf 'convention-table-row needle matched:\n%s\nexpected exactly:\n%s\n' "$got" "$expected" >&2
    return 1
  }
}

# ========== 2. every emitting route carries the instruction ==========

@test "2a. each of the five emitting routes carries the gaia-debt-origin token" {
  # This assertion has a phase-2 obligation behind it: the frontend agent,
  # the CI workflow (and its two template copies), the knowledge-audit
  # reference, and the pre-merge orchestrator wiki page must each carry the
  # literal token, or this test would pass against files satisfied only by
  # `$origin`/`gaia-debt-key`, which the token check below could not tell
  # apart from a real emission point.
  local f
  for f in \
    ".claude/agents/code-audit-frontend.md" \
    ".github/workflows/code-review-audit.yml" \
    ".gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" \
    ".claude/skills/gaia/references/audit.md" \
    "wiki/concepts/PR Merge Workflow.md" \
    ".claude/skills/file-tech-debt/SKILL.md"; do
    grep -qF -- "gaia-debt-origin" "$REPO_ROOT/$f" || {
      printf '%s does not carry the gaia-debt-origin token\n' "$f" >&2
      return 1
    }
  done
}

@test "2b. the token's presence across the tree is exhaustively accounted for" {
  # The other direction of 2a: every tracked file naming the token is either
  # one of the five routes above, the owner, the exempt helper, the wiki
  # concept page, or CHANGELOG.md. A new emitter appearing with no decision
  # made about it is exactly what this half catches.
  #
  # CHANGELOG.md carries the token because task-docs must reproduce the
  # rollout command byte-identically, and that command's --jq program
  # contains the literal `<!-- gaia-debt-origin:`. It is a release note
  # quoting a command, not an emitting route; do not "clean up" this entry.
  #
  # check-debt-issue-metadata.sh is a READER, not an emitter: it tests for the
  # line's presence to calibrate when provenance began writing in a given
  # repository, so that the pre-provenance cohort marker can be told apart from
  # a backfill without hardcoding a date that is wrong on every clone but one.
  # It writes no provenance and restates none of the field vocabulary.
  local got f
  got="$(git -C "$REPO_ROOT" grep -lF -- "gaia-debt-origin" -- "${EXCLUDE_PATHSPEC[@]}")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      ".claude/agents/code-audit-frontend.md" | \
        ".github/workflows/code-review-audit.yml" | \
        ".gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl" | \
        ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" | \
        ".claude/skills/gaia/references/audit.md" | \
        "wiki/concepts/PR Merge Workflow.md" | \
        ".claude/skills/file-tech-debt/SKILL.md" | \
        ".gaia/scripts/debt-origin-lib.sh" | \
        ".gaia/scripts/check-debt-issue-metadata.sh" | \
        "wiki/concepts/Audit Disposition and Debt Fix.md" | \
        "CHANGELOG.md") ;;
      *)
        printf 'unaccounted-for file names gaia-debt-origin: %s\n' "$f" >&2
        return 1
        ;;
    esac
  done <<EOF
$got
EOF
}

# ========== 3. the pointer rule ==========

@test "3. every instruction surface naming the token also points at the owner" {
  # Same shape and reasoning as assertion 2 of check-audit-key-callers.sh: a
  # token-presence net over the whole file, so descriptive prose satisfies it
  # exactly as an executable reference does.
  local got f
  got="$(git -C "$REPO_ROOT" grep -lF -- "gaia-debt-origin" -- "${EXCLUDE_PATHSPEC[@]}")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      ".claude/skills/file-tech-debt/SKILL.md" | ".gaia/scripts/debt-origin-lib.sh")
        continue # the owner and its exempt implementation owe no pointer
        ;;
      "CHANGELOG.md")
        # Exempted by name and required, not cosmetic: task-docs mandates the
        # rollout command verbatim here, which drags the token in, while the
        # same task forbids file-path names in a Keep a Changelog entry
        # (states what changed and why, never implementation paths). Test 3
        # without this exemption and task-docs cannot both be satisfied.
        continue
        ;;
    esac
    grep -qF -- ".claude/skills/file-tech-debt/SKILL.md" "$REPO_ROOT/$f" || {
      printf '%s names gaia-debt-origin but never points at the owner file\n' "$f" >&2
      return 1
    }
  done <<EOF
$got
EOF
}

# ========== 4. the dedup key still matches (deterministic-consumer safety) ==========

FIXTURE_KEY_INNER='v1 class=holistic/unclassified path=app/services/foo.ts line=42'
FIXTURE_BODY='<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/services/foo.ts line=42 -->
<!-- gaia-debt-origin: branch=debt/1121-marker-sep mode=drain unit=1121 changed=1 head=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 -->
Additional body prose.
Handler: prompt'

@test "4a. the wrapped-key substring test still matches with a provenance line present" {
  # Reproduces the real reader in .claude/hooks/lib/audit-dispositions.sh
  # (disposition_offenders, the `filed` arm): reconstruct the wrapped needle
  # and run the identical jq shape over a JSON array holding the fixture.
  local needle result
  needle="<!-- gaia-debt-key: ${FIXTURE_KEY_INNER} -->"
  result="$(jq -n --arg body "$FIXTURE_BODY" --arg k "$needle" '[{number: 1, body: $body}] | any(.[]?; (.body // "") | contains($k))')"
  [ "$result" = "true" ] || {
    printf 'wrapped-key substring test did not match with a provenance line present: %s\n' "$result" >&2
    return 1
  }
}

@test "4b. the real capture regex from debt.md still yields class, path, and line" {
  # Extracted from .claude/skills/gaia/references/debt.md rather than
  # retyped, so this reds when the documented capture pattern drifts. The
  # provenance line sits between the dedup-key line and the body prose, so
  # this also proves it does not capture first or interfere.
  local capture_call result got_class got_path got_line
  capture_call="$(grep -oE 'capture\("[^"]*"\)' "$REPO_ROOT/.claude/skills/gaia/references/debt.md" | head -1)"
  [ -n "$capture_call" ] || {
    echo "no capture(...) call found in debt.md; the extraction anchor drifted" >&2
    return 1
  }
  result="$(jq -n --arg body "$FIXTURE_BODY" "\$body | ${capture_call}")"
  got_class="$(jq -r '.class' <<<"$result")"
  got_path="$(jq -r '.path' <<<"$result")"
  got_line="$(jq -r '.line' <<<"$result")"
  [ "$got_class" = "holistic/unclassified" ] || {
    printf 'captured class was %s, want holistic/unclassified\n' "$got_class" >&2
    return 1
  }
  [ "$got_path" = "app/services/foo.ts" ] || {
    printf 'captured path was %s, want app/services/foo.ts\n' "$got_path" >&2
    return 1
  }
  [ "$got_line" = "42" ] || {
    printf 'captured line was %s, want 42\n' "$got_line" >&2
    return 1
  }
}

@test "4c. the keyless path:line fallback cannot false-match a provenance field" {
  # No provenance field can legitimately carry <path>:<line>-shaped text, but
  # this test pins the PROPERTY rather than restating the field vocabulary:
  # an adversarial branch value engineered to look like one, using an
  # already-percent-encoded slash rather than a raw one (the encoder
  # gaia_debt_origin_encode never DEcodes an existing %2F back to `/`, it
  # only ever adds escaping), must not false-match a keyless scan for a
  # DIFFERENT finding's real app/x.ts:42. Anchored per the recipe
  # (.claude/skills/file-tech-debt/SKILL.md step 2.3): the line number
  # followed by a non-digit or end of string.
  local adversarial_body
  adversarial_body='<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/other-finding.ts line=99 -->
<!-- gaia-debt-origin: branch=fix/app%2Fx.ts:42-thing mode=adhoc unit=unknown changed=unknown head=unknown -->
Some other finding entirely.'

  grep -qE 'app/x\.ts:42([^0-9]|$)' <<<"$adversarial_body" && {
    echo "the adversarial provenance line false-matched a keyless scan for app/x.ts:42" >&2
    return 1
  }

  # Sanity: the same anchored pattern DOES match a genuine keyless mention,
  # so the assertion above is proving absence, not a broken pattern.
  grep -qE 'app/x\.ts:42([^0-9]|$)' <<<'Body mentions app/x.ts:42 as a keyless location.' || {
    echo "the anchored keyless pattern failed to match a genuine mention; the pattern itself is broken" >&2
    return 1
  }
}

@test "4d. line=4 versus line=42 stays collision-safe with a provenance line present" {
  # The wrapped form's trailing ` -->` is what prevents a line=4 key from
  # digit-prefix-matching a sibling line=42 body (the same collision
  # .claude/hooks/lib/audit-dispositions.sh's "Key relationship" comment
  # documents); this pins that it still holds with a provenance line riding
  # beside the dedup key.
  local collision_key needle result
  collision_key='v1 class=holistic/unclassified path=app/services/foo.ts line=4'
  needle="<!-- gaia-debt-key: ${collision_key} -->"
  result="$(jq -n --arg body "$FIXTURE_BODY" --arg k "$needle" '[{number: 1, body: $body}] | any(.[]?; (.body // "") | contains($k))')"
  [ "$result" = "false" ] || {
    printf 'line=4 falsely matched a line=42 body with a provenance line present: %s\n' "$result" >&2
    return 1
  }
}

# ========== 5. the brake query selects the intended set ==========

@test "5. the brake query selects per field, in any order, and skips a null body" {
  local block jq_prog fixture result
  block="$(extract_fenced_bash_after_heading "$REPO_ROOT/.claude/skills/file-tech-debt/SKILL.md" "## Brake self-check")" || {
    echo "expected exactly one heading match and one fenced block under '## Brake self-check'" >&2
    return 1
  }
  jq_prog="$(sed -n "/--jq/,\$p" <<<"$block" | sed "1s/.*--jq '//" | sed "\$s/'\$//")"

  fixture='[
    {"number":1,"body":"<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/a.ts line=1 -->\n<!-- gaia-debt-origin: branch=debt/1-x mode=drain unit=1 changed=1 head=unknown -->"},
    {"number":2,"body":"<!-- gaia-debt-origin: branch=debt/2-x mode=drain unit=2 changed=0 head=unknown -->"},
    {"number":3,"body":"<!-- gaia-debt-origin: branch=fix/x mode=adhoc unit=unknown changed=1 head=unknown -->"},
    {"number":4,"body":"<!-- gaia-debt-origin: unit=4 changed=1 branch=debt/4-x mode=drain head=unknown -->"},
    {"number":5,"body":null},
    {"number":6,"body":"no provenance line here at all"},
    {"number":7,"body":"<!-- gaia-debt-origin: branch=debt/7-x mode=drainage unit=7 changed=1 head=unknown -->"}
  ]'
  result="$(jq -c "$jq_prog" <<<"$fixture")"
  # Written as a literal: recomputing the query's own arithmetic here would
  # test nothing but this test's own copy of it.
  #   #1 mode=drain changed=1               -> selected
  #   #2 mode=drain changed=0                -> not selected
  #   #3 mode=adhoc changed=1                -> not selected
  #   #4 fields in a different order         -> still selected (per-field match)
  #   #5 null body                           -> query completes, not selected
  #   #6 no provenance line at all           -> not selected
  #   #7 mode=drainage (substring of drain)  -> not selected (whitespace boundary)
  [ "$result" = "[1,4]" ] || {
    printf 'brake query returned %s, want [1,4]\n' "$result" >&2
    return 1
  }
}

# ========== 6. the cohort label changes no displayed count ==========

@test "6. debt:pre-provenance is counted while debt:in-progress and debt:spec-pending are not" {
  local jq_filter fixture result
  # The filter is declared once, as COUNT_FILTER, and both the local-jq arm and
  # the `gh --jq` fallback arm read that one variable. Scraping the declaration
  # rather than a call site is what keeps this test pinned to a single spelling:
  # when the filter lived inline at each call site, an arm could change without
  # this scraper noticing, and adding an arm meant adding a copy it could miss.
  jq_filter="$(grep -oE -- "^COUNT_FILTER='[^']*'" "$REPO_ROOT/.gaia/scripts/debt-count-refresh.sh" | sed "s/^COUNT_FILTER='//; s/'\$//")"
  [ -n "$jq_filter" ] || {
    echo "no COUNT_FILTER declaration found in debt-count-refresh.sh; the extraction anchor drifted" >&2
    return 1
  }

  fixture='[
    {"number":1,"labels":[{"name":"tech-debt"}]},
    {"number":2,"labels":[{"name":"tech-debt"},{"name":"debt:pre-provenance"}]},
    {"number":3,"labels":[{"name":"tech-debt"},{"name":"debt:in-progress"}]},
    {"number":4,"labels":[{"name":"tech-debt"},{"name":"debt:spec-pending"}]},
    {"number":5,"labels":[{"name":"tech-debt"},{"name":"debt:pre-provenance"},{"name":"debt:in-progress"}]}
  ]'
  result="$(jq "$jq_filter" <<<"$fixture")"
  # #1 no debt: label -> counted; #2 debt:pre-provenance -> counted;
  # #3 debt:in-progress -> not counted; #4 debt:spec-pending -> not counted;
  # #5 both pre-provenance and in-progress -> not counted. Expected: 2.
  [ "$result" = "2" ] || {
    printf 'cohort-label count was %s, want 2\n' "$result" >&2
    return 1
  }
}

# ========== 7. the changed derivation, both properties ==========

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

@test "7a. the eligibility set carries no pathspec: a non-TypeScript file resolves changed=1" {
  local fence repo out
  fence="$(extract_sole_bash_fence_matching "$REPO_ROOT/.claude/agents/code-audit-frontend.md" '^FULL_BASE=')" || {
    echo "expected exactly one fence assigning FULL_BASE at column 0 in code-audit-frontend.md" >&2
    return 1
  }

  repo="$BATS_TEST_TMPDIR/no-pathspec"
  mkdir -p "$repo"
  git -C "$repo" init -q --initial-branch=main
  git_identity "$repo"
  echo init >"$repo/f"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init
  git -C "$repo" checkout -q -b feat
  mkdir -p "$repo/app"
  echo 'export const a = 1' >"$repo/app/a.ts"
  echo '# doc' >"$repo/note.md"
  echo 'echo hi' >"$repo/script.sh"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "one ts file and two non-ts files"

  out="$(AUDIT_ROOT="$repo" bash -c "${fence}"'; printf "%s\n" "$full_changed"')"
  local p
  for p in app/a.ts note.md script.sh; do
    grep -qxF "$p" <<<"$out" || {
      printf 'eligibility set missing %s (this is the "*.ts/*.tsx" pathspec a "helpful" future edit would silently add): %s\n' "$p" "$out" >&2
      return 1
    }
  done
}

@test "7b. an unresolvable base yields changed=unknown, never 0" {
  local full_base_fence changed_fence repo result

  full_base_fence="$(extract_sole_bash_fence_matching "$REPO_ROOT/.claude/agents/code-audit-frontend.md" '^FULL_BASE=')" || {
    echo "expected exactly one fence assigning FULL_BASE at column 0 in code-audit-frontend.md" >&2
    return 1
  }
  changed_fence="$(extract_sole_bash_fence_matching "$REPO_ROOT/.claude/agents/code-audit-frontend.md" '^[[:space:]]*debt_origin_changed=')" || {
    echo "expected exactly one fence assigning debt_origin_changed in code-audit-frontend.md" >&2
    return 1
  }

  # A repo with no origin remote and a branch other than main: the
  # default-branch probe finds no refs/remotes/origin/HEAD, falls back to
  # the literal "main", and neither origin/main nor main exists, so both
  # merge-base arms fail and FULL_BASE comes back empty. Reachable on a real
  # adopter clone (git init + git remote add creates no origin/HEAD symref),
  # not a contrivance.
  repo="$BATS_TEST_TMPDIR/no-base"
  mkdir -p "$repo"
  git -C "$repo" init -q --initial-branch=master
  git_identity "$repo"
  echo init >"$repo/f"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init

  result="$(AUDIT_ROOT="$repo" bash -c "${full_base_fence}
${changed_fence}
printf '%s\n' \"\$debt_origin_changed\"")"

  [ "$result" = "unknown" ] || {
    printf 'debt_origin_changed was %s on an unresolvable base, want unknown\n' "$result" >&2
    return 1
  }
  # Explicit: the never-0 promise is a distinct assertion, not implied by the
  # equality check above.
  [ "$result" != "0" ] || {
    echo "debt_origin_changed resolved to 0 on an unresolvable base; 0 asserts the PR did not touch the file, which an unresolvable base can never assert" >&2
    return 1
  }
}

@test "7c. the eligibility diff is three-dot, never two-dot" {
  local fence
  fence="$(extract_sole_bash_fence_matching "$REPO_ROOT/.claude/agents/code-audit-frontend.md" '^FULL_BASE=')" || {
    echo "expected exactly one fence assigning FULL_BASE at column 0 in code-audit-frontend.md" >&2
    return 1
  }
  grep -qF -- '"${FULL_BASE}...HEAD"' <<<"$fence" || {
    echo "the eligibility fence no longer diffs \${FULL_BASE}...HEAD (three-dot); a two-dot form compares the base to the working tree instead" >&2
    return 1
  }
}

# Tests 7a through 7c extract the fence from `.claude/agents/code-audit-frontend.md`,
# so they guard the LOCAL route only. The continuous-integration route asks the
# same question of a value the event payload already carries, which is a second
# implementation of the same two properties. Without this test, adding a
# pathspec or switching three-dot to two-dot in the workflow would make a
# continuous-integration filing report `changed=0` for a finding on a
# non-TypeScript file the pull request did touch, while the identical finding
# filed locally reports `1`, and the whole suite would stay green.
@test "7d. the continuous-integration eligibility set carries no pathspec, resolves the fork point, and empties on an unresolvable base" {
  local wf body repo base moved_tip out actual expected prompt_flat

  wf="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$wf" ] || {
    echo "workflow not found: $wf" >&2
    return 1
  }

  # The step's own `run:` body, `- name:` through the line before the next one.
  body="$(awk '
    !grab && $0 == "      - name: Resolve debt provenance" { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$wf")"
  [ -n "$body" ] || {
    echo "could not extract the 'Resolve debt provenance' step body; the step was renamed or removed" >&2
    return 1
  }

  # EXECUTE the extracted body rather than reading it. A textual scan only ever
  # sees one physical line, and this command is already spread over four
  # backslash continuations, so a pathspec appended on a continuation line
  # reads as clean while genuinely filtering the set. Running it is immune to
  # that and to any other spelling, and it matches how test 7a checks the local
  # route, so the two routes are held to one standard instead of the CI one
  # being textual and weaker.
  repo="$BATS_TEST_TMPDIR/ci-eligibility"
  mkdir -p "$repo"
  git -C "$repo" init -q --initial-branch=main
  git_identity "$repo"
  echo init >"$repo/f"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init
  base="$(git -C "$repo" rev-parse HEAD)"

  # A later commit on main, and the value handed to the step as PR_BASE_SHA.
  # It must be this MOVED TIP rather than the fork point: the event payload
  # carries the base branch's tip at pull-request time, and a base that never
  # moved makes two-dot and three-dot agree, so a fixture pinned at the fork
  # point cannot tell them apart and would green a two-dot regression.
  #
  # It MODIFIES a file that already exists at the fork point rather than adding
  # a new one. A two-dot diff reports main's post-fork add as a deletion, so a
  # `--diff-filter` dropping D would erase the only two-dot discriminator here
  # while the set stayed genuinely two-dot; a modification surfaces as M under
  # every filter that admits a real change.
  echo moved >"$repo/f"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "main moves on"
  moved_tip="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" checkout -q -b feat "$base"
  mkdir -p "$repo/app"
  echo 'export const a = 1' >"$repo/app/a.ts"
  echo '# doc' >"$repo/note.md"
  echo 'echo hi' >"$repo/script.sh"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "one ts file and two non-ts files"

  ( cd "$repo" && PR_BASE_SHA="$moved_tip" PR_BRANCH=feat bash -c "$body" ) >/dev/null 2>&1 || true

  out="$repo/.gaia/local/audit/provenance/pr-changed-files.txt"
  [ -f "$out" ] || {
    echo "the provenance step produced no pr-changed-files.txt" >&2
    return 1
  }

  # Exact set equality against a literal, rather than a pair of contains and
  # not-contains needles: it catches both directions at once and catches
  # spellings no named needle anticipates. An entry that should not be there
  # means the diff is two-dot; a missing entry means something is filtering the
  # set. Both sides pass through the same `sort` so collation cannot decide it.
  actual="$(sort <"$out")"
  expected="$(printf '%s\n' app/a.ts note.md script.sh | sort)"
  [ "$actual" = "$expected" ] || {
    printf 'CI eligibility set is [%s], want exactly [app/a.ts note.md script.sh]. An extra entry means the diff is two-dot against a base tip that has moved rather than three-dot against the fork point. A missing entry means a pathspec or a filter is narrowing the set, so a finding on that file would record changed=0 while the same finding filed locally records 1.\n' "$(tr '\n' ' ' <<<"$actual")" >&2
    return 1
  }

  # Second arm: the same promise test 7b pins for the local route, an
  # unresolvable base yields unknown and never 0, asked of the
  # continuous-integration route's own implementation of it. The event payload
  # always carries a base sha, but the runner's object store need not hold it
  # (a shallow fetch is the ordinary way it does not), so the diff fails and
  # the step's `|| :` leaves no set. What must not happen is a PARTIAL set: a
  # finding on a file missing from it would record 0, which asserts the pull
  # request did not touch that file, and an unresolvable base can assert
  # nothing. Start from the blank slate a fresh runner has, so a stale file
  # from the arm above cannot be mistaken for output of this one.
  rm -rf "$repo/.gaia/local/audit/provenance"
  ( cd "$repo" && PR_BASE_SHA=0000000000000000000000000000000000000000 PR_BRANCH=feat bash -c "$body" ) >/dev/null 2>&1 || true

  [ ! -s "$out" ] || {
    printf 'the provenance step produced a non-empty eligibility set from an unresolvable base: [%s]. Anything absent from that set records changed=0, which asserts the pull request did not touch the file.\n' "$(tr '\n' ' ' <"$out")" >&2
    return 1
  }

  # And the consumer still reads that empty set as unknown. The arm above
  # proves the step emits no set; this proves the prompt maps no-set to
  # unknown rather than to 0. Matched against the whitespace-folded file
  # because the mapping sentence wraps across lines, and a needle that only
  # ever sees one physical line is the weakness round 4 already found here.
  prompt_flat="$(tr '\n' ' ' <"$wf" | tr -s ' ')"
  grep -qF -- '`origin.changed-unknown.txt` when `pr-changed-files.txt` is missing or empty' <<<"$prompt_flat" || {
    echo "the workflow prompt no longer maps a missing or empty pr-changed-files.txt to origin.changed-unknown.txt, so an unresolvable base would file changed=0" >&2
    return 1
  }

  # And that the membership test stays a whole-line one. The local route
  # matches with `grep -qxF`; read as a substring instead, a finding on an
  # untouched `app/a.ts` would record changed=1 whenever the pull request
  # touched `app/a.tsx`, asserting it touched a file it did not.
  grep -qF -- 'as its own complete line' <<<"$prompt_flat" || {
    echo "the workflow prompt no longer requires the cited path to appear as its own complete line, so a substring match would file changed=1 for a file the pull request never touched" >&2
    return 1
  }
}

# ========== 8. the rollout command is byte-identical in both homes ==========

@test "8. the rollout command is byte-identical between SKILL.md and CHANGELOG.md" {
  local skill_block changelog_block skill_norm changelog_norm

  skill_block="$(extract_fenced_bash_after_heading "$REPO_ROOT/.claude/skills/file-tech-debt/SKILL.md" "## Rollout: mark the pre-provenance cohort")" || {
    echo "expected exactly one heading match and one fenced block under '## Rollout: mark the pre-provenance cohort'" >&2
    return 1
  }
  # CHANGELOG.md carries exactly one fenced bash block total; anchoring on
  # its content (the debt:pre-provenance label it applies) rather than a
  # heading, since CHANGELOG.md's release notes have no headings to anchor
  # on the way SKILL.md's sections do.
  changelog_block="$(extract_sole_bash_fence_matching "$REPO_ROOT/CHANGELOG.md" 'debt:pre-provenance')" || {
    echo "expected exactly one fenced bash block in CHANGELOG.md naming debt:pre-provenance" >&2
    return 1
  }

  skill_norm="$(strip_common_indent <<<"$skill_block")"
  changelog_norm="$(strip_common_indent <<<"$changelog_block")"

  [ "$skill_norm" = "$changelog_norm" ] || {
    printf 'the rollout command differs between homes after stripping common indentation.\nSKILL.md:\n%s\nCHANGELOG.md:\n%s\n' "$skill_norm" "$changelog_norm" >&2
    return 1
  }

  # What makes a re-run both safe and correct: the body test (so a second
  # run days later never re-stamps issues filed after provenance landed) and
  # the raised limit (so the sweep does not stop silently at a default page
  # size).
  grep -qF -- 'test("<!-- gaia-debt-origin:")' <<<"$skill_norm" || {
    echo "the rollout command lost its body test; a re-run would stamp issues filed after provenance landed" >&2
    return 1
  }
  grep -qF -- '--limit 1000' <<<"$skill_norm" || {
    echo "the rollout command lost its raised --limit; the sweep would stop silently at a default page size" >&2
    return 1
  }
}

# ========== 9. a disposition completes when the helper is absent or failing ==========
#
# Exercises the frozen bare C5 call form itself (extracted from SKILL.md,
# never retyped) in three degraded states. Proves the call form cannot break
# its caller; does NOT prove that any agent following the prose actually
# continues to file, that half is instruction-following and is review.

extract_bare_call_form() {
  local file="$1"
  awk '
    /^```bash$/ { infence = 1; buf = ""; has = 0; next }
    /^```$/     { if (infence) { if (has) { printf "%s", buf; found++ } ; infence = 0 } ; next }
    infence     { buf = buf $0 "\n"; if ($0 ~ /debt-origin-lib\.sh/ && $0 !~ /AUDIT_ROOT/) has = 1 }
    END         { if (found != 1) exit 1 }
  ' "$file"
}

run_c5_against() {
  local helper_path="$1" line call_form out
  line="$(extract_bare_call_form "$REPO_ROOT/.claude/skills/file-tech-debt/SKILL.md")" || return 2
  call_form="${line//<0|1|unknown>/1}"
  call_form="${call_form//.gaia\/scripts\/debt-origin-lib.sh/\$HELPER_PATH}"
  out="$(bash -c "set -e; HELPER_PATH='${helper_path}'; ${call_form}; printf 'rc=0 origin=[%s]\n' \"\$origin\"; echo CONTINUED" 2>&1)"
  printf '%s' "$out"
}

@test "9a. fail-open: the helper file is absent" {
  local out
  out="$(run_c5_against "$BATS_TEST_TMPDIR/does-not-exist.sh")" || {
    echo "extraction of the bare C5 call form failed" >&2
    return 1
  }
  grep -qF -- "rc=0 origin=[]" <<<"$out" || {
    printf "expected rc=0 and an empty \$origin with the helper absent, got: %s\n" "$out" >&2
    return 1
  }
  grep -qF -- "CONTINUED" <<<"$out" || {
    echo "the shell aborted instead of continuing past the absent-helper call" >&2
    return 1
  }
}

@test "9b. fail-open: the helper file is present but non-executable" {
  local helper out
  helper="$BATS_TEST_TMPDIR/noexec.sh"
  # No execute bit: proves the documented `bash <path>` form (not a direct
  # exec of <path>) is what makes this call form robust to a permission
  # problem in the first place. Prints nothing to stdout, so $origin reads
  # empty regardless of the exit code the stub returns.
  printf '#!/usr/bin/env bash\nexit 9\n' >"$helper"
  chmod -x "$helper"
  out="$(run_c5_against "$helper")" || {
    echo "extraction of the bare C5 call form failed" >&2
    return 1
  }
  grep -qF -- "rc=0 origin=[]" <<<"$out" || {
    printf "expected rc=0 and an empty \$origin with a non-executable helper, got: %s\n" "$out" >&2
    return 1
  }
  grep -qF -- "CONTINUED" <<<"$out" || {
    echo "the shell aborted instead of continuing past the non-executable-helper call" >&2
    return 1
  }
}

@test "9c. fail-open: the helper exits non-zero" {
  local helper out
  helper="$BATS_TEST_TMPDIR/exit3.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$helper"
  chmod +x "$helper"
  out="$(run_c5_against "$helper")" || {
    echo "extraction of the bare C5 call form failed" >&2
    return 1
  }
  grep -qF -- "rc=0 origin=[]" <<<"$out" || {
    printf "expected rc=0 and an empty \$origin with an exit-3 helper, got: %s\n" "$out" >&2
    return 1
  }
  grep -qF -- "CONTINUED" <<<"$out" || {
    echo "the shell aborted instead of continuing past the exit-3 helper call" >&2
    return 1
  }
}
