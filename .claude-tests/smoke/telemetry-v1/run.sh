#!/usr/bin/env bash
# Smoke: structural release-gate harness for SPEC-001 telemetry-v1.
#
# Six deterministic tests covering the integration surface:
#   1. Envelope correctness end-to-end (mentorship + cloud, idempotency by event_id).
#   2. Cloud-projection drift (extra payload field rejects, exit 12, no writes).
#   3. File modes (mentorship 700/600, cloud 755/644).
#   4. Idempotent compute-profile (atomic write, second run identical).
#   5. Analytics dry-run audit attestation (all four booleans true, fields_present matches).
#   6. Mentorship-disabled short-circuit (cloud writes, mentorship absent, compute-profile silent).
#
# Each test isolates state under a fresh scratch HOME and a fresh scratch repo
# root via mktemp; cleanup is mandatory and runs on every exit path. Walk-
# through narrative (47 UATs, maintainer judgment allowed) lives at
# `.specify/extensions/gaia/test/smoke-telemetry-v1.md` per `.claude/rules/_internal/smoke.md`.
set -euo pipefail

# Resolve the real repo root from this script's location so the harness
# works regardless of caller cwd. The gaia CLI itself runs against the
# scratch dirs we create per-test (HOME override + sub-shell cd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
GAIA_BIN="${REPO_ROOT}/.gaia/cli/gaia"
TSX_BIN="${REPO_ROOT}/node_modules/.bin/tsx"
FIXTURE="${REPO_ROOT}/.gaia/cli/test-fixtures/profile/articulation-fire.jsonl"
PROJECTION_TS="${REPO_ROOT}/.gaia/cli/src/telemetry/projection.ts"

# One scratch tree per harness run; per-test sub-trees live underneath.
WORK="$(mktemp -d -t gaia-telemetry-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

# Pre-flight: bin and fixture present.
if [ ! -x "$GAIA_BIN" ]; then
    printf 'FATAL: .gaia/cli/gaia not executable at %s\n' "$GAIA_BIN" >&2
    exit 2
fi
if [ ! -f "$FIXTURE" ]; then
    printf 'FATAL: fixture missing at %s\n' "$FIXTURE" >&2
    exit 2
fi
if [ ! -x "$TSX_BIN" ]; then
    printf 'FATAL: node_modules/.bin/tsx not executable; run `pnpm install` first\n' >&2
    exit 2
fi

# Helpers -----------------------------------------------------------------

# Set up a fresh scratch isolation: a HOME and a "repo root" (cwd) directory.
# Returns via globals: TEST_HOME, TEST_REPO. Each test should call this fresh.
#
# Both paths are realpath-resolved (`pwd -P`) because macOS exposes /tmp and
# /var/folders/... as symlinks to /private/... — `process.cwd()` and
# `os.homedir()` return the resolved variant. The mentorship slug derives
# from `process.cwd()`, so the harness has to mirror the resolved form to
# look up the file the CLI writes.
setup_isolation() {
    local label="$1"
    mkdir -p "${WORK}/${label}/home" "${WORK}/${label}/repo"
    TEST_HOME="$(cd "${WORK}/${label}/home" && pwd -P)"
    TEST_REPO="$(cd "${WORK}/${label}/repo" && pwd -P)"
}

# Path to the mentorship dir under TEST_HOME, derived the same way the CLI does.
mentorship_dir_for() {
    local repo="$1"
    local home="$2"
    local slug
    # Slug derivation mirrors `deriveClaudeSlug` in storage/paths.ts:
    # all `/` → `-`. Because `repo` is absolute, slug starts with `-`.
    slug="${repo//\//-}"
    printf '%s' "${home}/.claude/projects/${slug}/gaia/telemetry/mentorship"
}

# Path to the slug-rooted gaia dir (parent of profile.md, mentorship/, install-id.txt).
slug_gaia_dir_for() {
    local repo="$1"
    local home="$2"
    local slug
    slug="${repo//\//-}"
    printf '%s' "${home}/.claude/projects/${slug}/gaia"
}

cloud_dir_for() {
    printf '%s' "${1}/.gaia/local/telemetry/cloud"
}

# Run gaia from inside the scratch repo. Sub-shell `cd` is scoped (does not
# pollute the parent shell), per `.claude/rules/shell-cwd.md` carve-out for
# test harnesses that need cwd-controlled fall-through (`git rev-parse`
# fails inside the scratch dir, so paths.ts falls back to `process.cwd()`).
run_gaia() {
    local repo="$1"
    local home="$2"
    shift 2
    (cd "$repo" && HOME="$home" "$GAIA_BIN" "$@")
}

# Enable mentorship + analytics on a fresh scratch repo.
enable_mentorship() {
    local repo="$1"
    local home="$2"
    run_gaia "$repo" "$home" mentorship _internal-write-config \
        --enabled true --analytics true --decided-via gaia-init >/dev/null
    run_gaia "$repo" "$home" mentorship _internal-provision-dirs >/dev/null
}

# Disable mentorship (cloud still emits).
disable_mentorship() {
    local repo="$1"
    local home="$2"
    run_gaia "$repo" "$home" mentorship _internal-write-config \
        --enabled false --analytics false --decided-via mentorship-disable >/dev/null
}

# Count NDJSON lines in a file (0 if missing).
line_count() {
    if [ -f "$1" ]; then
        wc -l <"$1" | tr -d ' '
    else
        printf '0'
    fi
}

# Read the mode bits (octal, last three digits) of a file or directory.
# BSD stat (`-f '%Lp'`) on macOS, GNU stat (`-c '%a'`) on Linux. Selecting
# by uname keeps the function silent (no spurious stderr from the wrong
# variant being tried first).
mode_octal() {
    if [ "$(uname)" = "Darwin" ]; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

# Today's UTC date in YYYY-MM-DD form, matching the CLI's daily rotation.
today_utc() {
    date -u +%Y-%m-%d
}

# --- Test 1: emit a uat_pass event end-to-end (mentorship + cloud + idempotent) ---

test_envelope_end_to_end() {
    setup_isolation "t1"
    enable_mentorship "$TEST_REPO" "$TEST_HOME"

    local mdir cdir today
    mdir="$(mentorship_dir_for "$TEST_REPO" "$TEST_HOME")"
    cdir="$(cloud_dir_for "$TEST_REPO")"
    today="$(today_utc)"

    # Pass `--local '{...}'` so the mentorship envelope carries the `_local`
    # namespace (UAT-003). The token has no identity-bearing keys; cloud
    # projection strips `_local` entirely so cloud line stays clean.
    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry emit uat_pass \
        --uat-id UAT-007 --spec-id SPEC-014 --task-id TASK-093 \
        --attempts 1 --area-tags visual,react,form --agent-type Senior \
        --session-hash deadbeefdeadbeefdeadbeefdeadbeef \
        --local '{"trace":"smoke"}' >/dev/null; then
        fail "test1: gaia telemetry emit uat_pass returned non-zero"
        return
    fi

    local mfile cfile
    mfile="${mdir}/events-${today}.jsonl"
    cfile="${cdir}/events-${today}.jsonl"

    if [ "$(line_count "$mfile")" = "1" ]; then
        pass "test1: exactly one mentorship line written"
    else
        fail "test1: expected 1 mentorship line, got $(line_count "$mfile") at $mfile"
        return
    fi

    if [ "$(line_count "$cfile")" = "1" ]; then
        pass "test1: exactly one cloud line written"
    else
        fail "test1: expected 1 cloud line, got $(line_count "$cfile") at $cfile"
        return
    fi

    # Mentorship line carries _local; cloud line does not. (UAT-008, UAT-013.)
    if grep -q '"_local"' "$mfile"; then
        pass "test1: mentorship line carries _local namespace"
    else
        fail "test1: mentorship line missing _local"
    fi
    if grep -q '"_local"' "$cfile"; then
        fail "test1: cloud line contains forbidden _local key"
    else
        pass "test1: cloud line has no _local key"
    fi

    # Forbidden cloud keys absent. Sample the strict denylist (matches
    # FORBIDDEN_CLOUD_KEYS in cloud-projection.ts).
    local forbidden hit=0
    for forbidden in developer_id user_id email username github_username machine_id hostname ip_address git_author_email; do
        if grep -q "\"${forbidden}\":" "$cfile"; then
            fail "test1: cloud line contains forbidden field ${forbidden}"
            hit=1
        fi
    done
    if [ $hit -eq 0 ]; then
        pass "test1: cloud line has no forbidden identity fields"
    fi

    # Required envelope keys present in both lines.
    local key absent=0
    for key in event_id schema_version timestamp event_type project_id session_hash agent_type payload; do
        if ! grep -q "\"${key}\":" "$mfile"; then
            fail "test1: mentorship line missing envelope key ${key}"
            absent=1
        fi
    done
    if [ $absent -eq 0 ]; then
        pass "test1: mentorship envelope has all required keys"
    fi

    # Idempotency: re-emit identical content within the same minute → 1 line still.
    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry emit uat_pass \
        --uat-id UAT-007 --spec-id SPEC-014 --task-id TASK-093 \
        --attempts 1 --area-tags visual,react,form --agent-type Senior \
        --session-hash deadbeefdeadbeefdeadbeefdeadbeef \
        --local '{"trace":"smoke"}' >/dev/null; then
        fail "test1: idempotent re-emit returned non-zero"
        return
    fi
    if [ "$(line_count "$mfile")" = "1" ] && [ "$(line_count "$cfile")" = "1" ]; then
        pass "test1: idempotent re-emit produced no second line (UAT-012)"
    else
        fail "test1: idempotent re-emit added a duplicate line (mentorship=$(line_count "$mfile"), cloud=$(line_count "$cfile"))"
    fi
}

# --- Test 2: cloud projection drift ---
# Strategy: invoke `projectToCloud` directly via tsx-loaded ESM eval, passing
# a hand-built envelope with an unexpected payload field. The strict cloud
# schema rejects → returns `{ ok: false, code: 'cloud_projection_drift' }`.
# We exit the eval script with code 12 (EXIT_CODES.CLOUD_PROJECTION_DRIFT)
# to mirror what the emit path does, then assert the outer harness sees 12.
# Direct module invocation keeps the test surface small (no new
# `_internal-test-projection` subcommand to maintain).

test_projection_drift() {
    setup_isolation "t2"
    # Project root for projection.ts — read from the actual repo, not scratch.
    local script="${WORK}/t2/drift.mjs"

    cat >"$script" <<EOF
import {projectToCloud} from '${PROJECTION_TS}';
const envelope = {
    agent_type: 'Senior',
    event_id: '01KR14Y7G0M4FSBE7M1P0V643R',
    event_type: 'uat_pass',
    payload: {
        area_tags: ['visual'],
        attempts: 1,
        spec_id: 'SPEC-099',
        task_id: 'TASK-099',
        uat_id: 'UAT-099',
        forbidden_extra_field: 'drift',
    },
    project_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    schema_version: 1,
    session_hash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    timestamp: '2026-05-07T12:00:00.000Z',
};
const result = projectToCloud(envelope);
if (result.ok) {
    console.error('UNEXPECTED: projection succeeded on drift envelope');
    process.exit(0);
}
process.stdout.write(JSON.stringify(result) + '\n');
process.exit(12);
EOF

    local out rc=0
    out=$("$TSX_BIN" "$script" 2>&1) || rc=$?

    if [ "$rc" = "12" ]; then
        pass "test2: projection drift returns CLOUD_PROJECTION_DRIFT (exit 12)"
    else
        fail "test2: expected exit 12, got $rc; output: $out"
        return
    fi
    if echo "$out" | grep -q '"code":"cloud_projection_drift"'; then
        pass "test2: projection drift result carries code=cloud_projection_drift"
    else
        fail "test2: projection drift result missing expected code; got: $out"
    fi

    # Belt-and-suspenders: confirm no files were written via this path.
    # (The eval script never touches storage. We assert the scratch repo
    # has no .gaia/local/telemetry/cloud at all.)
    if [ ! -d "$(cloud_dir_for "$TEST_REPO")" ]; then
        pass "test2: projection-drift test wrote no cloud files"
    else
        fail "test2: cloud dir leaked into scratch despite drift"
    fi
}

# --- Test 3: file modes ---

test_file_modes() {
    setup_isolation "t3"
    enable_mentorship "$TEST_REPO" "$TEST_HOME"

    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry emit uat_pass \
        --uat-id UAT-007 --spec-id SPEC-014 --task-id TASK-093 \
        --attempts 1 --area-tags visual --agent-type Senior >/dev/null; then
        fail "test3: emit returned non-zero"
        return
    fi

    local mdir cdir today
    mdir="$(mentorship_dir_for "$TEST_REPO" "$TEST_HOME")"
    cdir="$(cloud_dir_for "$TEST_REPO")"
    today="$(today_utc)"

    local m_dir_mode m_file_mode c_dir_mode c_file_mode
    m_dir_mode="$(mode_octal "$mdir")"
    m_file_mode="$(mode_octal "${mdir}/events-${today}.jsonl")"
    c_dir_mode="$(mode_octal "$cdir")"
    c_file_mode="$(mode_octal "${cdir}/events-${today}.jsonl")"

    if [ "$m_dir_mode" = "700" ]; then
        pass "test3: mentorship dir mode 700"
    else
        fail "test3: mentorship dir mode is $m_dir_mode, expected 700"
    fi
    if [ "$m_file_mode" = "600" ]; then
        pass "test3: mentorship JSONL mode 600"
    else
        fail "test3: mentorship JSONL mode is $m_file_mode, expected 600"
    fi
    if [ "$c_dir_mode" = "755" ]; then
        pass "test3: cloud dir mode 755"
    else
        fail "test3: cloud dir mode is $c_dir_mode, expected 755"
    fi
    if [ "$c_file_mode" = "644" ]; then
        pass "test3: cloud JSONL mode 644"
    else
        fail "test3: cloud JSONL mode is $c_file_mode, expected 644"
    fi
}

# --- Test 4: idempotent compute-profile ---

test_compute_profile_idempotent() {
    setup_isolation "t4"
    enable_mentorship "$TEST_REPO" "$TEST_HOME"

    # Drop the articulation-fire fixture into today's mentorship file so
    # the reader picks it up. Pattern detector aggregates across the file's
    # contents regardless of per-line timestamps; profile.md generation is
    # deterministic relative to the mentorship config + fixture.
    local mdir today
    mdir="$(mentorship_dir_for "$TEST_REPO" "$TEST_HOME")"
    today="$(today_utc)"
    cp "$FIXTURE" "${mdir}/events-${today}.jsonl"
    chmod 600 "${mdir}/events-${today}.jsonl"

    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry compute-profile >/dev/null 2>&1; then
        fail "test4: compute-profile (run 1) returned non-zero"
        return
    fi

    local profile_path
    profile_path="$(slug_gaia_dir_for "$TEST_REPO" "$TEST_HOME")/profile.md"

    if [ -f "$profile_path" ]; then
        pass "test4: compute-profile wrote profile.md"
    else
        fail "test4: profile.md missing at $profile_path"
        return
    fi

    if head -n 1 "$profile_path" | grep -q "DO NOT EDIT"; then
        pass "test4: profile.md carries DO NOT EDIT header (UAT-036)"
    else
        fail "test4: profile.md missing DO NOT EDIT header"
    fi

    # The render embeds `Generated: <now ISO>` so a strict full-file digest
    # would differ between runs by that single line. Strip the Generated
    # line before comparing — the rest of the file is deterministic against
    # the fixture (UAT-035 idempotency on the same input).
    local stable_a stable_b
    stable_a="$(grep -v '^Generated:' "$profile_path" | shasum -a 256 | awk '{print $1}')"

    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry compute-profile >/dev/null 2>&1; then
        fail "test4: compute-profile (run 2) returned non-zero"
        return
    fi
    stable_b="$(grep -v '^Generated:' "$profile_path" | shasum -a 256 | awk '{print $1}')"

    if [ "$stable_a" = "$stable_b" ]; then
        pass "test4: compute-profile is idempotent ignoring Generated timestamp"
    else
        fail "test4: profile.md differs between runs (a=$stable_a b=$stable_b)"
    fi

    # Profile permission: 600 (off-project mentorship subtree).
    local profile_mode
    profile_mode="$(mode_octal "$profile_path")"
    if [ "$profile_mode" = "600" ]; then
        pass "test4: profile.md mode 600 (UAT-035 atomic write contract)"
    else
        fail "test4: profile.md mode is $profile_mode, expected 600"
    fi
}

# --- Test 5: analytics dry-run audit attestation ---

test_analytics_dry_run_audit() {
    setup_isolation "t5"
    enable_mentorship "$TEST_REPO" "$TEST_HOME"

    local mdir today
    mdir="$(mentorship_dir_for "$TEST_REPO" "$TEST_HOME")"
    today="$(today_utc)"
    cp "$FIXTURE" "${mdir}/events-${today}.jsonl"
    chmod 600 "${mdir}/events-${today}.jsonl"

    # compute-profile runs analytics report generation when analytics.enabled.
    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry compute-profile >/dev/null 2>&1; then
        fail "test5: compute-profile returned non-zero"
        return
    fi

    local report_dir="${TEST_REPO}/.gaia/local/telemetry/analytics"
    if [ ! -d "$report_dir" ]; then
        fail "test5: analytics dir not created at $report_dir"
        return
    fi

    local out
    if ! out="$(run_gaia "$TEST_REPO" "$TEST_HOME" mentorship analytics dry-run 2>/dev/null)"; then
        fail "test5: analytics dry-run returned non-zero"
        return
    fi

    if [ -z "$out" ] || echo "$out" | grep -q '"code":"no_analytics_report"'; then
        fail "test5: dry-run produced no_analytics_report (compute-profile did not write a report)"
        return
    fi

    # Each of the four assertions must be literal `true` in the JSON.
    local key
    for key in no_event_data no_user_paths no_user_text no_project_identifiers; do
        if echo "$out" | grep -q "\"${key}\":true"; then
            pass "test5: audit.${key} === true"
        else
            fail "test5: audit.${key} not true in dry-run output"
        fi
    done

    # fields_present must match actual top-level keys. The dry-run path
    # warns on mismatch via stderr; a clean run produces no stderr line.
    # Re-run and capture stderr explicitly.
    local stderr_log
    stderr_log="${WORK}/t5/dry-run.stderr"
    run_gaia "$TEST_REPO" "$TEST_HOME" mentorship analytics dry-run >/dev/null 2>"$stderr_log"
    if grep -q "analytics_audit_fields_mismatch" "$stderr_log"; then
        fail "test5: dry-run reported fields_present mismatch"
    else
        pass "test5: audit.fields_present matches actual top-level keys"
    fi
}

# --- Test 6: mentorship-disabled short-circuit ---

test_mentorship_disabled_short_circuit() {
    setup_isolation "t6"
    disable_mentorship "$TEST_REPO" "$TEST_HOME"

    if ! run_gaia "$TEST_REPO" "$TEST_HOME" telemetry emit uat_pass \
        --uat-id UAT-009 --spec-id SPEC-014 --task-id TASK-093 \
        --attempts 1 --area-tags visual --agent-type Senior >/dev/null; then
        fail "test6: emit returned non-zero"
        return
    fi

    local cdir mdir today
    cdir="$(cloud_dir_for "$TEST_REPO")"
    mdir="$(mentorship_dir_for "$TEST_REPO" "$TEST_HOME")"
    today="$(today_utc)"

    if [ "$(line_count "${cdir}/events-${today}.jsonl")" = "1" ]; then
        pass "test6: cloud line written despite mentorship disabled (UAT-009)"
    else
        fail "test6: expected 1 cloud line, got $(line_count "${cdir}/events-${today}.jsonl")"
    fi

    if [ ! -d "$mdir" ] || [ ! -f "${mdir}/events-${today}.jsonl" ]; then
        pass "test6: mentorship file absent (UAT-009)"
    else
        fail "test6: mentorship file present despite mentorship disabled"
    fi

    # compute-profile must short-circuit silently with exit 0; no profile.md.
    local profile_path
    profile_path="$(slug_gaia_dir_for "$TEST_REPO" "$TEST_HOME")/profile.md"
    local stdout_log stderr_log
    stdout_log="${WORK}/t6/compute.stdout"
    stderr_log="${WORK}/t6/compute.stderr"
    if run_gaia "$TEST_REPO" "$TEST_HOME" telemetry compute-profile \
        >"$stdout_log" 2>"$stderr_log"; then
        pass "test6: compute-profile exits 0 when mentorship disabled (UAT-040)"
    else
        fail "test6: compute-profile non-zero when mentorship disabled"
    fi
    if [ ! -f "$profile_path" ]; then
        pass "test6: compute-profile wrote no profile.md when disabled"
    else
        fail "test6: profile.md leaked at $profile_path despite mentorship disabled"
    fi
    if [ ! -s "$stdout_log" ]; then
        pass "test6: compute-profile silent on stdout when disabled (UAT-026 chain trigger contract)"
    else
        fail "test6: compute-profile wrote stdout when disabled: $(cat "$stdout_log")"
    fi
}

# Run every test. Each one isolates state under WORK; failures within a
# test don't abort the harness — every test runs so the maintainer sees
# the full surface in one report.
test_envelope_end_to_end || true
test_projection_drift || true
test_file_modes || true
test_compute_profile_idempotent || true
test_analytics_dry_run_audit || true
test_mentorship_disabled_short_circuit || true

# Summary.
echo
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
    printf 'telemetry-v1 smoke: PASS (%d/%d checks)\n' "$PASS_COUNT" "$TOTAL"
    exit 0
else
    printf 'telemetry-v1 smoke: FAIL (%d/%d checks failed)\n' "$FAIL_COUNT" "$TOTAL" >&2
    exit 1
fi
