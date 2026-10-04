#!/usr/bin/env bats
# Static and executable checks over `.claude/commands/setup-gaia.md`, the
# onboarding command an agent reads and runs phase by phase.
#
# The command carries no CI-wiring or per-developer audit-mode phase. What it
# keeps, and what this suite pins:
#
#   - No CI phase heading, no removed CLI verb, no CI token or tool-mode
#     question.
#   - `--reconfigure` is parsed, and `RECONFIGURE` is consulted only by the
#     decisions it re-opens (Phase 2 sandbox, Phase 3.5 isolation policy,
#     Phase 3.6 Dependabot, Phase 4.6 statusline left side) and the Phase 6
#     ping classification.
#   - Every team-setting read and commit targets `.gaia/project.json`, and so
#     does the isolation policy read in the shared isolation reference.
#   - Every `Phase N` cross-reference names a phase heading that exists.
#   - The `GAIA-Audit` registration fence, extracted from the page and run
#     against a stubbed `gh`, adds `GAIA-Audit`, keeps every sibling context,
#     drops the stale `code-review-audit` context, and sends no PUT when
#     nothing is owed.
#
# Each check is a function over a file path, so every test that proves the
# real page passes has a twin that runs the same function over a scratch copy
# with the forbidden content put back and asserts it fails.
#
# Tokens the removed-automation guard forbids anywhere in the tree are built
# at runtime (printf or concatenation) so this file never carries one.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  ISOLATION_REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/isolation.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -f "$ISOLATION_REFERENCE" ] || {
    echo "the isolation reference is absent: ${ISOLATION_REFERENCE}" >&2
    return 1
  }
}

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# ---------------------------------------------------------------------------
# No CI phases
# ---------------------------------------------------------------------------

# forbidden_literals: one forbidden fixed string per line.
forbidden_literals() {
  printf '%s\n' \
    '## Phase 4:' \
    '## Phase 5:' \
    'audit-mode-decision' \
    'setup-ci status' \
    'check-drift' \
    'check-audit-drift' \
    'dismiss-personal' \
    'opt-out-team' \
    'verify-run' \
    'setup-ci finalize' \
    'write-tool-mode' \
    'CLAUDE_CODE_OAUTH_TOKEN' \
    'ANTHROPIC_API_KEY' \
    'default_mode'
  printf 'automation%sjson\n' .
  printf 'claude-code%saction\n' -
  printf 'docs.gaiareact.com/maintenance/gaia%sci\n' -
}

# check_no_ci_phases <file>: fails, naming the hit, when the file carries any
# forbidden literal or a CI enable, token-type, or tool-mode question.
check_no_ci_phases() {
  local file="$1" literal count=0
  while IFS= read -r literal; do
    count=$((count + 1))
    if grep -qF -- "$literal" "$file"; then
      echo "forbidden literal present: ${literal}" >&2
      return 1
    fi
  done < <(forbidden_literals)
  # A short read of the literal list would turn the loop into a partial check.
  [ "$count" -eq 17 ] || {
    echo "expected 17 forbidden literals, read ${count}" >&2
    return 1
  }
  if grep -qiE 'enable gaia ci|which bot token|token type|tool mode|tools running on cron' "$file"; then
    echo "a CI enable, token-type, or tool-mode question is present" >&2
    return 1
  fi
}

@test "setup-gaia carries no CI phase, removed verb, token, or tool-mode question" {
  check_no_ci_phases "$PAGE"
}

@test "the no-CI check fails on every forbidden literal put back" {
  local literal count=0 copy
  while IFS= read -r literal; do
    count=$((count + 1))
    copy="$(scratch_copy "$PAGE" "no-ci-${count}.md")"
    printf '\n%s\n' "$literal" >>"$copy"
    run check_no_ci_phases "$copy"
    [ "$status" -ne 0 ] || {
      echo "the check passed with ${literal} present" >&2
      return 1
    }
  done < <(forbidden_literals)
  [ "$count" -eq 17 ]
}

@test "the no-CI check fails on a CI enable question put back" {
  local copy
  copy="$(scratch_copy "$PAGE" "no-ci-question.md")"
  printf '\n> Enable GAIA CI now?\n' >>"$copy"
  run check_no_ci_phases "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# --reconfigure stays, scoped to its decisions and the ping
# ---------------------------------------------------------------------------

# check_reconfigure_scope <file>: the argument parse names --reconfigure and
# caches RECONFIGURE, and every other RECONFIGURE line sits under Phase 2,
# 3.5, 3.6, 3.7, 4.6, or 6.
check_reconfigure_scope() {
  local file="$1" parse_section stray
  parse_section="$(awk '/^## /{inside = ($0 == "## Argument parse")} inside' "$file")"
  grep -qF -- '--reconfigure' <<<"$parse_section" || {
    echo "the argument parse no longer names --reconfigure" >&2
    return 1
  }
  grep -qF -- 'RECONFIGURE' <<<"$parse_section" || {
    echo "the argument parse no longer caches RECONFIGURE" >&2
    return 1
  }
  stray="$(awk '
    /^## / { heading = $0 }
    /RECONFIGURE/ {
      if (heading == "## Argument parse") next
      if (heading ~ /^## Phase (2|3\.5|3\.6|3\.7|4\.6|6):/) next
      print NR ": " heading
    }
  ' "$file")"
  [ -z "$stray" ] || {
    echo "RECONFIGURE outside its phases: ${stray}" >&2
    return 1
  }
}

@test "--reconfigure is parsed and RECONFIGURE is read only in Phases 2, 3.5, 3.6, 3.7, 4.6, and 6" {
  check_reconfigure_scope "$PAGE"
}

@test "the reconfigure check fails on RECONFIGURE under another phase" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-stray.md")"
  awk '{ print } /^## Phase 4\.5:/ { print ""; print "When `RECONFIGURE` is set, rotate the token." }' \
    "$PAGE" >"$copy"
  run check_reconfigure_scope "$copy"
  [ "$status" -ne 0 ]
}

@test "the reconfigure check fails when the argument parse drops the flag" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-unparsed.md")"
  awk '/^## /{inside = ($0 == "## Argument parse")} inside && /RECONFIGURE/ { next } { print }' \
    "$PAGE" >"$copy"
  run check_reconfigure_scope "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Team settings live in .gaia/project.json
# ---------------------------------------------------------------------------

# check_project_json <file>: every jq read of a .gaia/*.json file targets
# .gaia/project.json, the expected three keys are read from it, and the two
# team-setting commits stage it. A read of .gaia/local/settings.json is not a
# team setting: it is the per-machine opt-ins file (the statusline left-side
# choice), so it is left out of the read set.
check_project_json() {
  local file="$1" reads stray key staged
  reads="$(grep -E "jq -r '[^']*' \.gaia/[^ ]*\.json" "$file" | grep -vF "' .gaia/local/settings.json" || true)"
  [ -n "$reads" ] || {
    echo "no jq read of a .gaia/*.json file found" >&2
    return 1
  }
  stray="$(grep -vF '.gaia/project.json' <<<"$reads" || true)"
  [ -z "$stray" ] || {
    echo "a key read targets another file: ${stray}" >&2
    return 1
  }
  for key in sandbox_recommended isolation_policy dependabot_security_updates; do
    grep -qF -- "$key" <<<"$reads" || {
      echo "no .gaia/project.json read for ${key}" >&2
      return 1
    }
  done
  staged="$(grep -cE '^git add \.gaia/project\.json' "$file" || true)"
  [ "$staged" -eq 2 ] || {
    echo "expected 2 commits staging .gaia/project.json, found ${staged}" >&2
    return 1
  }
}

@test "every team-setting read and commit targets .gaia/project.json" {
  check_project_json "$PAGE"
}

@test "the project.json check fails on a read of another config file" {
  local copy
  copy="$(scratch_copy "$PAGE" "project-json-read.md")"
  sed "s#has(\"isolation_policy\")' \.gaia/project\.json#has(\"isolation_policy\")' .gaia/other.json#" \
    "$PAGE" >"$copy"
  grep -qF '.gaia/other.json' "$copy"
  run check_project_json "$copy"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when a commit stages another file" {
  local copy
  copy="$(scratch_copy "$PAGE" "project-json-commit.md")"
  awk '/^git add \.gaia\/project\.json/ && !done { sub(/project\.json/, "other.json"); done = 1 } { print }' \
    "$PAGE" >"$copy"
  run check_project_json "$copy"
  [ "$status" -ne 0 ]
}

# check_isolation_reference <file>: the policy read targets
# .gaia/project.json with its load-bearing fallback tail, and the file names
# no automation config anywhere.
check_isolation_reference() {
  local file="$1"
  grep -qF -- "jq -r '.isolation_policy // \"prefer-branch\"' .gaia/project.json 2>/dev/null || echo prefer-branch" "$file" || {
    echo "the policy read does not target .gaia/project.json with its fallback tail" >&2
    return 1
  }
  if grep -n 'automation' "$file"; then
    echo "the isolation reference still mentions automation" >&2
    return 1
  fi
}

@test "the isolation reference reads its policy from .gaia/project.json" {
  check_isolation_reference "$ISOLATION_REFERENCE"
}

@test "the isolation check fails on the old config path put back" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-old.md")"
  sed "s#\.gaia/project\.json#.gaia/$(printf 'automation%sjson' .)#" "$ISOLATION_REFERENCE" >"$copy"
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Cross-references resolve
# ---------------------------------------------------------------------------

# check_phase_references <file>: every "Phase N" or "Phase N.N" mention names
# a "## Phase N:" heading that exists.
check_phase_references() {
  local file="$1" referenced phase missing="" count=0
  referenced="$(grep -oE 'Phase [0-9]+(\.[0-9]+)?' "$file" | sort -u)"
  [ -n "$referenced" ] || {
    echo "no phase reference found" >&2
    return 1
  }
  while IFS= read -r phase; do
    count=$((count + 1))
    grep -qE "^## ${phase//./\\.}:" "$file" || missing="${missing} ${phase}"
  done <<<"$referenced"
  [ -z "$missing" ] || {
    echo "phase references with no heading:${missing}" >&2
    return 1
  }
  [ "$count" -ge 7 ]
}

@test "every Phase cross-reference names an existing phase heading" {
  check_phase_references "$PAGE"
}

@test "the cross-reference check fails on a reference to a removed phase" {
  local copy
  copy="$(scratch_copy "$PAGE" "phase-reference.md")"
  printf '\nFall through to Phase 5.\n' >>"$copy"
  run check_phase_references "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The GAIA-Audit registration fence, executed against a stubbed gh
# ---------------------------------------------------------------------------

REGISTRATION_ANCHOR='required_checks_endpoint='

# registration_fence <file>: print the body of the one bash fence containing
# the registration anchor.
registration_fence() {
  awk -v anchor="$REGISTRATION_ANCHOR" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$1"
}

# run_fence <fence-file> <contexts-json>: run the fence with a gh stub on PATH
# that logs every call to ${BATS_TEST_TMPDIR}/gh.log and answers the GET with
# the given contexts array.
run_fence() {
  local fence="$1" contexts="$2" stub_directory="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "$stub_directory"
  cat >"${stub_directory}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case " $* " in
  *" -X PUT "*) cat >"$GH_BODY"; exit 0 ;;
esac
printf '%s\n' "$GH_CONTEXTS_FIXTURE"
STUB
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  : >"${BATS_TEST_TMPDIR}/gh.body"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" GH_BODY="${BATS_TEST_TMPDIR}/gh.body" GH_CONTEXTS_FIXTURE="$contexts" \
    PATH="${stub_directory}:${PATH}" bash "$fence"
}

# put_line: the one logged PUT call, empty when none was sent. put_body is the
# JSON the call piped to `--input -`.
put_line() {
  grep -E -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log" || true
}

# assert_stale_context_dropped <fence-file>: fixture 1. The GET reports the
# stale context beside a sibling; the PUT carries GAIA-Audit and the sibling
# and not the stale context.
assert_stale_context_dropped() {
  local stale="code-review-audit" put
  run_fence "$1" "[\"${stale}\", \"Vitest\"]" || return 1
  put="$(put_line)"
  [ "$(grep -cE -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log")" -eq 1 ] || {
    echo "expected exactly one PUT" >&2
    return 1
  }
  grep -qF -- '/protection/required_status_checks/contexts --input -' <<<"$put" || {
    echo "the PUT does not target the /contexts endpoint: ${put}" >&2
    return 1
  }
  jq -e 'any(.contexts[]; . == "GAIA-Audit") and any(.contexts[]; . == "Vitest")' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null || return 1
  if jq -e --arg stale "$stale" 'any(.contexts[]; . == $stale)' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null; then
    echo "the PUT body still carries the stale context: $(cat "${BATS_TEST_TMPDIR}/gh.body")" >&2
    return 1
  fi
}

extract_registration_fence() {
  registration_fence "$PAGE" >"${BATS_TEST_TMPDIR}/fence.sh"
  [ -s "${BATS_TEST_TMPDIR}/fence.sh" ]
}

@test "registration fixture 1: a stale code-review-audit context is dropped, siblings kept, GAIA-Audit added" {
  extract_registration_fence
  assert_stale_context_dropped "${BATS_TEST_TMPDIR}/fence.sh"
}

@test "registration fixture 2: GAIA-Audit already required and nothing stale sends no PUT" {
  extract_registration_fence
  run_fence "${BATS_TEST_TMPDIR}/fence.sh" '["GAIA-Audit", "Vitest"]'
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "registration fixture 3: GAIA-Audit is added beside an existing sibling" {
  extract_registration_fence
  run_fence "${BATS_TEST_TMPDIR}/fence.sh" '["Vitest"]'
  local put
  put="$(put_line)"
  [ -n "$put" ]
  jq -e '.contexts == ["Vitest", "GAIA-Audit"]' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null
}

@test "registration: a failed GET sends no PUT" {
  extract_registration_fence
  local stub_directory="${BATS_TEST_TMPDIR}/failing-bin"
  mkdir -p "$stub_directory"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GH_LOG"\nexit 1\n' >"${stub_directory}/gh"
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" PATH="${stub_directory}:${PATH}" \
    bash "${BATS_TEST_TMPDIR}/fence.sh" 2>/dev/null
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "registration mutation: the fence without the drop filter fails fixture 1" {
  extract_registration_fence
  local mutated="${BATS_TEST_TMPDIR}/fence-no-drop.sh"
  sed 's/map(select(\. != "code-review-audit" and \. != "GAIA-Audit"))/map(select(. != "GAIA-Audit"))/' \
    "${BATS_TEST_TMPDIR}/fence.sh" >"$mutated"
  # The mutation must actually change the fence, or this test proves nothing.
  cmp -s "${BATS_TEST_TMPDIR}/fence.sh" "$mutated" && return 1
  run assert_stale_context_dropped "$mutated"
  [ "$status" -ne 0 ]
}

@test "registration mutation: a fence that PUTs to the bare endpoint fails fixture 1" {
  extract_registration_fence
  local mutated="${BATS_TEST_TMPDIR}/fence-bare-endpoint.sh"
  sed 's#"\$required_checks_endpoint/contexts"#"$required_checks_endpoint"#' \
    "${BATS_TEST_TMPDIR}/fence.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/fence.sh" "$mutated" && return 1
  run assert_stale_context_dropped "$mutated"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The default-branch protection fence, executed against a stubbed gh
# ---------------------------------------------------------------------------
# The full protection PUT replaces every setting on an existing rule, so the
# fence must send it only when the probe finds no rule (gaia-react/gaia#2412).

PROTECTION_ANCHOR='protection_endpoint='

extract_protection_fence() {
  awk -v anchor="$PROTECTION_ANCHOR" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$PAGE" >"${BATS_TEST_TMPDIR}/protection.sh"
  [ -s "${BATS_TEST_TMPDIR}/protection.sh" ]
}

# run_protection_fence <fence-file> <get-exit-status>: run the fence with a gh
# stub that logs every call and answers the protection GET with the given exit
# status (0: a rule exists, 1: none does).
run_protection_fence() {
  local stub_directory="${BATS_TEST_TMPDIR}/protection-bin"
  mkdir -p "$stub_directory"
  cat >"${stub_directory}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case " $* " in
  *" -X PUT "*) cat >"$GH_BODY"; exit 0 ;;
esac
exit "$GH_PROTECTION_GET_STATUS"
STUB
  chmod +x "${stub_directory}/gh"
  : >"${BATS_TEST_TMPDIR}/gh.log"
  : >"${BATS_TEST_TMPDIR}/gh.body"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log" GH_BODY="${BATS_TEST_TMPDIR}/gh.body" GH_PROTECTION_GET_STATUS="$2" \
    PATH="${stub_directory}:${PATH}" bash "$1" >/dev/null
}

@test "protection fixture: an existing rule is kept and no protection PUT is sent" {
  extract_protection_fence
  run_protection_fence "${BATS_TEST_TMPDIR}/protection.sh" 0
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/gh.log" | tr -d ' ')" -eq 1 ]
  [ -z "$(put_line)" ]
}

@test "protection fixture: with no rule, exactly one full protection PUT is sent" {
  extract_protection_fence
  run_protection_fence "${BATS_TEST_TMPDIR}/protection.sh" 1
  [ "$(grep -cE -- '(^| )-X PUT ' "${BATS_TEST_TMPDIR}/gh.log")" -eq 1 ]
  grep -qE -- '/branches/<default-branch>/protection --input -$' <<<"$(put_line)"
  jq -e '.enforce_admins == false and .required_status_checks.contexts == []' "${BATS_TEST_TMPDIR}/gh.body" >/dev/null
}

@test "protection mutation: an unconditional PUT fails the existing-rule fixture" {
  extract_protection_fence
  local mutated="${BATS_TEST_TMPDIR}/protection-unconditional.sh"
  sed 's#^if gh api "\$protection_endpoint" >/dev/null 2>&1; then#if false; then#' \
    "${BATS_TEST_TMPDIR}/protection.sh" >"$mutated"
  cmp -s "${BATS_TEST_TMPDIR}/protection.sh" "$mutated" && return 1
  run_protection_fence "$mutated" 0
  [ -n "$(put_line)" ]
}
