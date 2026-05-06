#!/usr/bin/env bash
# Smoke: structural check for the SPEC-003 before_implement UAT-write hook.
#
# Drives the renderer (.specify/extensions/gaia/lib/uat-write.sh) against a
# sandbox SPEC fixture (.gaia/local/specs/SPEC-099.md, copied from
# fixture/SPEC-099.md) and asserts the renderer's structural contracts:
# write/rewrite/delete branches, idempotency, fixme heuristic, cache mirror,
# and manifest declarations. Maps to UAT-001..UAT-008 of SPEC-003.
#
# Does NOT exercise the live /speckit-implement hook fire — that requires a
# real spec-kit invocation and is out of scope for the smoke layer (same
# caveat as wiki-promote/run.sh). UAT-005's manifest rows are checked
# structurally; the EXECUTE_COMMAND directive emission is hand-verified.
# UAT-006's four-step SPEC resolution is checked by grepping the slash-
# command body for the algorithm; the live UI-driven steps (AskUserQuestion,
# explicit $ARGUMENTS) are out of harness scope.
set -euo pipefail

# Resolve repo root from the script's own location so the harness works
# regardless of caller cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RENDERER=".specify/extensions/gaia/lib/uat-write.sh"
MANIFEST=".specify/extensions/gaia/extension.yml"
COMMAND_BODY=".specify/extensions/gaia/commands/uat-write.md"
FIXTURE_SPEC="$SCRIPT_DIR/fixture/SPEC-099.md"
SPEC_PATH=".gaia/local/specs/SPEC-099.md"
SPEC_DIR=".playwright/e2e/spec-099"
CACHE_FILE=".gaia/local/cache/uat-write/SPEC-099.json"

failures=0
checks=0

pass() {
    checks=$((checks + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

# --- Pre-flight ---------------------------------------------------------------

# Snapshot SPEC-099.md if it already exists so we can restore it on EXIT.
PREEXISTING_SPEC=""
if [ -f "$SPEC_PATH" ]; then
    PREEXISTING_SPEC="$(mktemp)"
    cp "$SPEC_PATH" "$PREEXISTING_SPEC"
fi

# Snapshot existing artifacts under the playwright dir / cache so cleanup
# only removes what this harness created.
PREEXISTING_SPEC_DIR=0
[ -d "$SPEC_DIR" ] && PREEXISTING_SPEC_DIR=1
PREEXISTING_CACHE=0
[ -f "$CACHE_FILE" ] && PREEXISTING_CACHE=1

cleanup() {
    # Only remove what we created. Restore SPEC-099.md if it pre-existed.
    if [ "$PREEXISTING_SPEC_DIR" -eq 0 ]; then
        rm -rf "$SPEC_DIR"
    fi
    if [ "$PREEXISTING_CACHE" -eq 0 ]; then
        rm -f "$CACHE_FILE"
    fi
    if [ -n "$PREEXISTING_SPEC" ]; then
        cp "$PREEXISTING_SPEC" "$SPEC_PATH"
        rm -f "$PREEXISTING_SPEC"
    else
        rm -f "$SPEC_PATH"
    fi
}
trap cleanup EXIT

# Drop fixture SPEC into place.
mkdir -p "$(dirname "$SPEC_PATH")"
cp "$FIXTURE_SPEC" "$SPEC_PATH"

if [ ! -x "$RENDERER" ]; then
    fail "renderer missing or not executable at $RENDERER"
    printf '\nuat-write smoke: FAIL (%d/%d checks failed)\n' "$failures" "$checks" >&2
    exit 1
fi
pass "renderer present and executable at $RENDERER"

# Working dir for stdout captures.
TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"; cleanup' EXIT

# --- UAT-001 — N UATs render to N stable spec files ---------------------------

run1_stdout="$TMPDIR_RUN/run1.stdout"
if bash "$RENDERER" "$SPEC_PATH" > "$run1_stdout" 2>/dev/null; then
    pass "UAT-001 renderer first run exits 0"
else
    fail "UAT-001 renderer first run failed (non-zero exit)"
fi

# Three files exist with expected names.
expected_files=(uat-001.spec.ts uat-002.spec.ts uat-003.spec.ts)
all_present=1
for f in "${expected_files[@]}"; do
    if [ ! -f "$SPEC_DIR/$f" ]; then
        all_present=0
        fail "UAT-001 expected spec file missing: $SPEC_DIR/$f"
    fi
done
if [ "$all_present" -eq 1 ]; then
    pass "UAT-001 three spec files exist under $SPEC_DIR/"
fi

# Each file imports playwright + carries the UAT-NNN — SPEC-099 test name.
for f in "${expected_files[@]}"; do
    path="$SPEC_DIR/$f"
    [ -f "$path" ] || continue
    if grep -qF "import {expect, test} from '@playwright/test';" "$path"; then
        pass "$(basename "$f") has playwright import line"
    else
        fail "$(basename "$f") missing playwright import line"
    fi
    uat_id=$(echo "$f" | sed -E 's/uat-([0-9]+)\.spec\.ts/UAT-\1/' | tr '[:lower:]' '[:upper:]')
    if grep -qE "test(\\.fixme)?\\('${uat_id} — SPEC-099'" "$path"; then
        pass "$(basename "$f") carries stable test name '${uat_id} — SPEC-099'"
    else
        fail "$(basename "$f") missing stable test name '${uat_id} — SPEC-099'"
    fi
done

# Stdout JSON: summary.written == 3 and each detail entry has a sha256 hash.
if grep -qE '"summary":\{"written":3,"rewritten":0,"deleted":0,"fixme":0,"unchanged":0\}' "$run1_stdout"; then
    pass "UAT-001 stdout summary.written == 3 (all branches written)"
else
    fail "UAT-001 stdout missing expected summary {written:3, ...} block"
fi
hash_count=$(grep -oE '"hash":"sha256:[0-9a-f]+"' "$run1_stdout" | wc -l | tr -d ' ')
if [ "$hash_count" -eq 3 ]; then
    pass "UAT-001 stdout includes sha256 hash for each of the 3 detail entries"
else
    fail "UAT-001 stdout sha256-hash detail count is $hash_count (expected 3)"
fi

# --- UAT-002 — Red-state baseline fails as assertions, not parse errors -------

if command -v pnpm >/dev/null 2>&1; then
    pw_out="$TMPDIR_RUN/pw.out"
    set +e
    pnpm pw "$SPEC_DIR/" > "$pw_out" 2>&1
    pw_exit=$?
    set -e
    if [ "$pw_exit" -ne 0 ]; then
        pass "UAT-002 pnpm pw exits non-zero on unimplemented SPEC"
    else
        fail "UAT-002 pnpm pw exited 0 on unimplemented SPEC (red-state expected)"
    fi
    if grep -qE 'SyntaxError|Cannot find module|Test file is empty' "$pw_out"; then
        fail "UAT-002 pnpm pw output contains parse/import error (renderer bug)"
    else
        pass "UAT-002 pnpm pw output has no parse-error / missing-import signature"
    fi
else
    pass "UAT-002 SKIPPED: pnpm not on PATH (red-state baseline check requires Playwright runner)"
fi

# --- UAT-003a — Idempotency on re-run -----------------------------------------

run2_stdout="$TMPDIR_RUN/run2.stdout"
if bash "$RENDERER" "$SPEC_PATH" > "$run2_stdout" 2>/dev/null; then
    pass "UAT-003a renderer second run exits 0"
else
    fail "UAT-003a renderer second run failed (non-zero exit)"
fi
if grep -qE '"summary":\{"written":0,"rewritten":0,"deleted":0,"fixme":0,"unchanged":3\}' "$run2_stdout"; then
    pass "UAT-003a re-run on unchanged SPEC reports unchanged:3, written:0, rewritten:0"
else
    fail "UAT-003a re-run summary block is not the all-unchanged shape"
fi
# Hashes should be byte-identical between run1 and run2 detail entries.
hashes_run1=$(grep -oE '"hash":"sha256:[0-9a-f]+"' "$run1_stdout" | sort)
hashes_run2=$(grep -oE '"hash":"sha256:[0-9a-f]+"' "$run2_stdout" | sort)
if [ "$hashes_run1" = "$hashes_run2" ]; then
    pass "UAT-003a per-UAT sha256 hashes are byte-identical across re-run"
else
    fail "UAT-003a sha256 hashes diverged between run1 and run2 (idempotency broken)"
fi

# --- UAT-003b — Modify one UAT, re-run, only that file rewrites ---------------

# Snapshot all three rendered files for byte-compare after the targeted rewrite.
mkdir -p "$TMPDIR_RUN/snap1"
for f in "${expected_files[@]}"; do
    cp "$SPEC_DIR/$f" "$TMPDIR_RUN/snap1/$f"
done

# Mutate UAT-002's then-clause in the SPEC fixture in place.
# Replace the existing UAT-002 then-line with a new (still concrete) value.
python3 - <<'PYEOF' "$SPEC_PATH"
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    txt = f.read()
old = 'then: The page navigates to "/" and the "Sign in" button is visible again.'
new = 'then: The page navigates to "/login" and the "Sign in" button is visible again.'
if old not in txt:
    sys.exit("UAT-003b mutation: old then-line not found in SPEC fixture")
txt = txt.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
PYEOF

run3_stdout="$TMPDIR_RUN/run3.stdout"
if bash "$RENDERER" "$SPEC_PATH" > "$run3_stdout" 2>/dev/null; then
    pass "UAT-003b renderer post-mutation run exits 0"
else
    fail "UAT-003b renderer post-mutation run failed (non-zero exit)"
fi
if grep -qE '"summary":\{"written":0,"rewritten":1,"deleted":0,"fixme":0,"unchanged":2\}' "$run3_stdout"; then
    pass "UAT-003b summary is rewritten:1, unchanged:2 (selective rewrite)"
else
    fail "UAT-003b summary is not the selective-rewrite shape"
fi
# Confirm only uat-002.spec.ts changed on disk.
if ! cmp -s "$TMPDIR_RUN/snap1/uat-001.spec.ts" "$SPEC_DIR/uat-001.spec.ts"; then
    fail "UAT-003b uat-001.spec.ts changed (should be byte-identical to run1)"
else
    pass "UAT-003b uat-001.spec.ts unchanged byte-for-byte"
fi
if ! cmp -s "$TMPDIR_RUN/snap1/uat-003.spec.ts" "$SPEC_DIR/uat-003.spec.ts"; then
    fail "UAT-003b uat-003.spec.ts changed (should be byte-identical to run1)"
else
    pass "UAT-003b uat-003.spec.ts unchanged byte-for-byte"
fi
if cmp -s "$TMPDIR_RUN/snap1/uat-002.spec.ts" "$SPEC_DIR/uat-002.spec.ts"; then
    fail "UAT-003b uat-002.spec.ts unchanged (should have been rewritten)"
else
    pass "UAT-003b uat-002.spec.ts content was rewritten"
fi
# The new then-clause should appear in the rewritten file.
if grep -qF '/login' "$SPEC_DIR/uat-002.spec.ts"; then
    pass "UAT-003b rewritten uat-002.spec.ts carries the new then-clause"
else
    fail "UAT-003b rewritten uat-002.spec.ts does not contain mutated then-clause"
fi

# --- UAT-004 — Deleted UAT triggers hard-delete -------------------------------

# Strip the entire UAT-003 block (uat_id line + its given/when/then) from the SPEC.
python3 - <<'PYEOF' "$SPEC_PATH"
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    txt = f.read()
# Match `  - uat_id: UAT-003` plus its three indented attribute lines.
pattern = re.compile(
    r"  - uat_id: UAT-003\n(?:    [a-z_]+:[^\n]*\n){3}"
)
if not pattern.search(txt):
    sys.exit("UAT-004 mutation: UAT-003 block not found in SPEC fixture")
txt = pattern.sub("", txt, count=1)
with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
PYEOF

run4_stdout="$TMPDIR_RUN/run4.stdout"
if bash "$RENDERER" "$SPEC_PATH" > "$run4_stdout" 2>/dev/null; then
    pass "UAT-004 renderer post-deletion run exits 0"
else
    fail "UAT-004 renderer post-deletion run failed (non-zero exit)"
fi
if grep -qE '"deleted":1' "$run4_stdout"; then
    pass "UAT-004 summary.deleted == 1"
else
    fail "UAT-004 summary.deleted != 1"
fi
if [ ! -f "$SPEC_DIR/uat-003.spec.ts" ]; then
    pass "UAT-004 uat-003.spec.ts hard-deleted from $SPEC_DIR/"
else
    fail "UAT-004 uat-003.spec.ts still present (hard-delete violation)"
fi
if [ ! -d "$SPEC_DIR/_archived" ]; then
    pass "UAT-004 no _archived/ directory created (hard-delete contract honored)"
else
    fail "UAT-004 _archived/ directory created (resolution #3 violated)"
fi

# --- UAT-005 — Manifest declarations ------------------------------------------
# (Live /speckit-implement EXECUTE_COMMAND directive emission is out of scope.)

if [ ! -f "$MANIFEST" ]; then
    fail "UAT-005 manifest missing at $MANIFEST"
else
    if grep -q 'name: "speckit.gaia.uat-write"' "$MANIFEST"; then
        pass "UAT-005 manifest declares speckit.gaia.uat-write in provides.commands[]"
    else
        fail "UAT-005 manifest missing speckit.gaia.uat-write in provides.commands[]"
    fi

    # before_implement.command == "speckit.gaia.uat-write".
    if awk '
        /^hooks:/ { in_hooks = 1; next }
        in_hooks && /^[a-zA-Z_-]+:/ && !/^[[:space:]]/ { in_hooks = 0 }
        in_hooks && /^[[:space:]]+before_implement:/ { in_block = 1; next }
        in_block && /^[[:space:]]+command:[[:space:]]+"speckit\.gaia\.uat-write"/ { found = 1 }
        in_block && /^[[:space:]]{2}[a-zA-Z_-]+:/ && !/^[[:space:]]+(command|optional|description|condition):/ { in_block = 0 }
        END { exit !found }
    ' "$MANIFEST"; then
        pass "UAT-005 manifest registers speckit.gaia.uat-write under hooks.before_implement"
    else
        fail "UAT-005 manifest does not register speckit.gaia.uat-write under hooks.before_implement"
    fi

    # before_implement.optional == false.
    if awk '
        /^hooks:/ { in_hooks = 1; next }
        in_hooks && /^[a-zA-Z_-]+:/ && !/^[[:space:]]/ { in_hooks = 0 }
        in_hooks && /^[[:space:]]+before_implement:/ { in_block = 1; next }
        in_block && /^[[:space:]]+optional:[[:space:]]+false/ { found = 1 }
        in_block && /^[[:space:]]{2}[a-zA-Z_-]+:/ && !/^[[:space:]]+(command|optional|description|condition):/ { in_block = 0 }
        END { exit !found }
    ' "$MANIFEST"; then
        pass "UAT-005 manifest declares hooks.before_implement.optional == false"
    else
        fail "UAT-005 manifest does not declare hooks.before_implement.optional == false"
    fi
fi

# --- UAT-006 — SPEC resolution algorithm (4 steps) ----------------------------
# (Live slash-command invocation steps are UI-driven and out of harness scope.
#  Static check: the slash-command body documents the four-step algorithm.)

if [ ! -f "$COMMAND_BODY" ]; then
    fail "UAT-006 slash-command body missing at $COMMAND_BODY"
else
    pass "UAT-006 slash-command body present at $COMMAND_BODY"
    missing_steps=()
    if ! grep -qE '^1\. .*\$ARGUMENTS' "$COMMAND_BODY"; then
        missing_steps+=("step 1 (\$ARGUMENTS)")
    fi
    if ! grep -qE '^2\. .*most-recent.*in-progress.*30 minutes' "$COMMAND_BODY"; then
        missing_steps+=("step 2 (most-recent in-progress / 30-minute window)")
    fi
    if ! grep -qE '^3\. .*single.*in-progress' "$COMMAND_BODY"; then
        missing_steps+=("step 3 (single in-progress fallback)")
    fi
    if ! grep -qE '^4\. .*AskUserQuestion' "$COMMAND_BODY"; then
        missing_steps+=("step 4 (AskUserQuestion)")
    fi
    if [ ${#missing_steps[@]} -eq 0 ]; then
        pass "UAT-006 slash-command body documents all four resolution steps"
    else
        fail "UAT-006 slash-command body missing: ${missing_steps[*]}"
    fi
fi

# --- UAT-007 — Too-abstract UAT renders as test.fixme() with blocker ----------

# Restore the SPEC fixture (UAT-004's deletion is destructive), then mutate
# UAT-001's then-clause to an abstract form.
cp "$FIXTURE_SPEC" "$SPEC_PATH"

python3 - <<'PYEOF' "$SPEC_PATH"
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    txt = f.read()
old = 'then: The page navigates to "/sign-in" and a heading reading "Sign in" is visible.'
new = 'then: The system feels right and the user is delighted.'
if old not in txt:
    sys.exit("UAT-007 mutation: UAT-001 original then-line not found")
txt = txt.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
PYEOF

run5_stdout="$TMPDIR_RUN/run5.stdout"
if bash "$RENDERER" "$SPEC_PATH" > "$run5_stdout" 2>/dev/null; then
    pass "UAT-007 renderer post-abstraction run exits 0"
else
    fail "UAT-007 renderer post-abstraction run failed (non-zero exit)"
fi
if grep -qE '"fixme":1' "$run5_stdout"; then
    pass "UAT-007 summary.fixme == 1"
else
    fail "UAT-007 summary.fixme != 1"
fi
if [ -f "$SPEC_DIR/uat-001.spec.ts" ]; then
    if grep -qF 'test.fixme(' "$SPEC_DIR/uat-001.spec.ts"; then
        pass "UAT-007 uat-001.spec.ts uses test.fixme() for the abstract UAT"
    else
        fail "UAT-007 uat-001.spec.ts does not use test.fixme()"
    fi
    if grep -qiE 'abstraction blocker' "$SPEC_DIR/uat-001.spec.ts"; then
        pass "UAT-007 uat-001.spec.ts carries an abstraction-blocker comment"
    else
        fail "UAT-007 uat-001.spec.ts missing abstraction-blocker comment"
    fi
else
    fail "UAT-007 uat-001.spec.ts missing after abstraction mutation (must not be silently dropped)"
fi

# --- UAT-008 — Cache file mirrors stdout JSON ---------------------------------

if [ -f "$CACHE_FILE" ]; then
    pass "UAT-008 cache file present at $CACHE_FILE"
    # Cache contents must match the most recent renderer stdout (modulo
    # trailing newline). Compare the trimmed forms.
    cache_trim="$TMPDIR_RUN/cache.trim"
    stdout_trim="$TMPDIR_RUN/stdout.trim"
    awk 'NF { print }' "$CACHE_FILE" > "$cache_trim"
    awk 'NF { print }' "$run5_stdout" > "$stdout_trim"
    if cmp -s "$cache_trim" "$stdout_trim"; then
        pass "UAT-008 cache file contents match renderer stdout (modulo trailing newline)"
    else
        fail "UAT-008 cache file contents diverge from renderer stdout"
    fi
else
    fail "UAT-008 cache file missing at $CACHE_FILE"
fi

# --- Summary ------------------------------------------------------------------

echo
if [ "$failures" -eq 0 ]; then
    printf 'uat-write smoke: PASS (%d/%d checks)\n' "$checks" "$checks"
    exit 0
else
    printf 'uat-write smoke: FAIL (%d/%d checks failed)\n' "$failures" "$checks" >&2
    exit 1
fi
