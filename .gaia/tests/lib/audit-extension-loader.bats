#!/usr/bin/env bats
#
# The `## Extension Loading` section of .claude/agents/code-audit-frontend.md.
# A member must resolve the project root from the literal `<root>` it already
# resolved: a package launch's Claude project directory is the package
# directory, not the repository root, and the agent file forbids a command
# substitution for a root. The text is the contract, so the suite reads it.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT_FILE="$REPO_ROOT_REAL/.claude/agents/code-audit-frontend.md"
  SECTION="$(awk '
    /^## Extension Loading$/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$AGENT_FILE")"
}

@test "the Extension Loading section is found and non-empty" {
  [ -n "$SECTION" ]
  [ "$(printf '%s\n' "$SECTION" | wc -l | tr -d ' ')" -gt 5 ]
}

@test "the loader reads the package registry" {
  grep -qF -- '<root>/.gaia/packages.json' <<<"$SECTION"
}

@test "the loader globs the root extensions and each package's extensions over the literal <root>" {
  grep -qF -- '<root>/.claude/agents/code-audit-frontend/*.md' <<<"$SECTION" || return 1
  grep -qF -- '<root>/<path>/.claude/agents/code-audit-frontend/*.md' <<<"$SECTION"
}

@test "a missing or empty frontend extension directory is an error finding, not a silent skip" {
  grep -qF -- 'error finding' <<<"$SECTION" || return 1
  grep -qF -- 'missing or empty' <<<"$SECTION" || return 1
  grep -qF -- 'proceed without extensions' <<<"$SECTION" && return 1
  true
}

@test "the section uses no command substitution and no CLAUDE_PROJECT_DIR" {
  grep -qF -- '$(' <<<"$SECTION" && return 1
  grep -qF -- 'CLAUDE_PROJECT_DIR' <<<"$SECTION" && return 1
  true
}

# contract_violations <section text>: prints one line per contract check the
# text fails, the same checks the tests above apply to the live section.
contract_violations() {
  local text="$1"
  grep -qF -- '<root>/.gaia/packages.json' <<<"$text" || echo "no registry read"
  grep -qF -- '<root>/<path>/.claude/agents/code-audit-frontend/*.md' <<<"$text" || echo "no per-package glob"
  grep -qF -- 'error finding' <<<"$text" || echo "no missing-directory error"
  if grep -qF -- 'CLAUDE_PROJECT_DIR' <<<"$text"; then echo "uses CLAUDE_PROJECT_DIR"; fi
  if grep -qF -- '$(' <<<"$text"; then echo "uses a command substitution"; fi
  return 0
}

# The negative control: the loader as it read before package resolution, held
# as a literal so it cannot go unreachable, fails the contract checks; the live
# section passes them. Without this the checks could be satisfied by any text.
@test "the previous loader text fails the contract checks and the live section passes" {
  previous="$(cat <<'OLD'
Before starting the review, resolve the project root and load library-specific extensions:

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

1. Glob `$PROJECT_ROOT/.claude/agents/code-audit-frontend/*.md`
2. Read each matched file; skip any named exactly `README.md`

If the directory is missing or empty, proceed without extensions.
OLD
)"
  old_violations="$(contract_violations "$previous")"
  [ "$(printf '%s\n' "$old_violations" | wc -l | tr -d ' ')" -eq 5 ] || return 1
  [ -z "$(contract_violations "$SECTION")" ]
}
