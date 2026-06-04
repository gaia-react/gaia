#!/usr/bin/env bash
# Smoke: structural check for the wiki-promote artifacts.
#
# Verifies the manifest + command files + revised-contracts amendment are
# present and parse cleanly.
#
# Does NOT exercise the live hook fire; that requires a real
# spec-kit invocation against a synthetic SPEC, branch, and PR, which is out
# of scope for the smoke layer. See README.md for the full scope statement.
set -euo pipefail

# Resolve repo root from the script's own location so the harness works
# regardless of caller cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MANIFEST=".specify/extensions/gaia/extension.yml"
WIKI_PROMOTE_CMD=".specify/extensions/gaia/commands/wiki-promote.md"
SPEC_CLOSE_CMD=".specify/extensions/gaia/commands/spec-close.md"
REVISED_CONTRACTS=".gaia/local/specs/SPEC-001-revised-contracts.md"

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

# 1. Manifest exists and contains both new rows.
if [ ! -f "$MANIFEST" ]; then
    fail "manifest missing at $MANIFEST"
else
    pass "manifest present"

    if grep -q 'name: "speckit.gaia.wiki-promote"' "$MANIFEST"; then
        pass "manifest declares speckit.gaia.wiki-promote in provides.commands[]"
    else
        fail "manifest missing speckit.gaia.wiki-promote in provides.commands[]"
    fi

    # The after_implement block has the wiki-promote command target.
    if awk '
        /^hooks:/ { in_hooks = 1; next }
        in_hooks && /^[a-zA-Z_-]+:/ { in_hooks = 0 }
        in_hooks && /^[[:space:]]+after_implement:/ { in_after = 1; next }
        in_after && /^[[:space:]]+[a-z_]+:/ {
            if ($1 == "command:" && $2 == "\"speckit.gaia.wiki-promote\"") found = 1
        }
        in_after && /^[[:space:]]{2}[a-zA-Z_-]+:/ && !/^[[:space:]]+(command|optional|description|condition):/ { in_after = 0 }
        END { exit !found }
    ' "$MANIFEST"; then
        pass "manifest registers speckit.gaia.wiki-promote under hooks.after_implement"
    else
        fail "manifest does not register speckit.gaia.wiki-promote under hooks.after_implement"
    fi

    # YAML parse if python3 is available; non-fatal otherwise.
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)
with open('$MANIFEST') as f:
    yaml.safe_load(f)
" 2>/dev/null; then
            pass "manifest parses as YAML (python3 + PyYAML)"
        else
            rc=$?
            if [ $rc -eq 2 ]; then
                pass "manifest YAML parse skipped (PyYAML not installed)"
            else
                fail "manifest does not parse as YAML"
            fi
        fi
    else
        pass "manifest YAML parse skipped (python3 not on PATH)"
    fi
fi

# 2. wiki-promote.md exists and has the seven Step sections.
if [ ! -f "$WIKI_PROMOTE_CMD" ]; then
    fail "wiki-promote command missing at $WIKI_PROMOTE_CMD"
else
    pass "wiki-promote command present"

    missing_steps=()
    for n in 1 2 3 4 5 6 7; do
        if ! grep -qE "^## Step ${n}( |\$|—)" "$WIKI_PROMOTE_CMD"; then
            missing_steps+=("Step ${n}")
        fi
    done
    if [ ${#missing_steps[@]} -eq 0 ]; then
        pass "wiki-promote command has all seven Step sections"
    else
        fail "wiki-promote command missing sections: ${missing_steps[*]}"
    fi
fi

# 3. spec-close.md exists.
if [ -f "$SPEC_CLOSE_CMD" ]; then
    pass "spec-close command present"
else
    fail "spec-close command missing at $SPEC_CLOSE_CMD"
fi

# 4. revised-contracts contains the wiki_promote_targets sub-section.
if [ ! -f "$REVISED_CONTRACTS" ]; then
    fail "revised-contracts missing at $REVISED_CONTRACTS"
else
    pass "revised-contracts present"

    if grep -q "wiki_promote_targets" "$REVISED_CONTRACTS"; then
        pass "revised-contracts mentions wiki_promote_targets"
    else
        fail "revised-contracts does not mention wiki_promote_targets"
    fi
fi

# 5. Optional: schema-validate via `specify extension list` if available.
if command -v specify >/dev/null 2>&1; then
    if specify extension list >/dev/null 2>&1; then
        pass "specify extension list succeeded (schema validates)"
    else
        fail "specify extension list failed"
    fi
else
    pass "specify CLI not on PATH; schema validation skipped (framework-neutral)"
fi

# Summary.
echo
if [ "$failures" -eq 0 ]; then
    printf 'wiki-promote smoke: PASS (%d/%d checks)\n' "$checks" "$checks"
    exit 0
else
    printf 'wiki-promote smoke: FAIL (%d/%d checks failed)\n' "$failures" "$checks" >&2
    exit 1
fi
