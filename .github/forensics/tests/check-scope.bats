#!/usr/bin/env bats
# Tests for .github/forensics/check-scope.sh
#
# Covers every allowlist hit, every denylist hit, the default-deny case,
# the allowlist-subtraction edge case, and multi-path partitioning.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-scope.sh"
  [ -x "$SCRIPT" ] || skip "check-scope.sh not executable"
}

# --- exit-code contract ----------------------------------------------------

@test "exit code is always 0 (consumer reads ok from JSON)" {
  run "$SCRIPT" app/foo.ts
  [ "$status" -eq 0 ]
  run "$SCRIPT" .gaia/cli/foo.sh
  [ "$status" -eq 0 ]
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- allowlist hits --------------------------------------------------------

@test "allowlist: .gaia/cli/" {
  run "$SCRIPT" .gaia/cli/foo.sh
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo.sh"],"denied":[]}' ]
}

@test "allowlist: .claude/hooks/" {
  run "$SCRIPT" .claude/hooks/post-commit.sh
  [ "$output" = '{"ok":true,"allowed":[".claude/hooks/post-commit.sh"],"denied":[]}' ]
}

@test "allowlist: .claude/skills/" {
  run "$SCRIPT" .claude/skills/foo/SKILL.md
  [ "$output" = '{"ok":true,"allowed":[".claude/skills/foo/SKILL.md"],"denied":[]}' ]
}

@test "allowlist: .claude/commands/" {
  run "$SCRIPT" .claude/commands/gaia.md
  [ "$output" = '{"ok":true,"allowed":[".claude/commands/gaia.md"],"denied":[]}' ]
}

@test "allowlist: .claude/agents/" {
  run "$SCRIPT" .claude/agents/code-review-audit.md
  [ "$output" = '{"ok":true,"allowed":[".claude/agents/code-review-audit.md"],"denied":[]}' ]
}

@test "allowlist: .gaia/statusline/" {
  run "$SCRIPT" .gaia/statusline/render.sh
  [ "$output" = '{"ok":true,"allowed":[".gaia/statusline/render.sh"],"denied":[]}' ]
}

@test "allowlist: .specify/extensions/gaia/ (non-templates path)" {
  run "$SCRIPT" .specify/extensions/gaia/scripts/foo.sh
  [ "$output" = '{"ok":true,"allowed":[".specify/extensions/gaia/scripts/foo.sh"],"denied":[]}' ]
}

@test "allowlist: .gaia/manifest.json (exact file)" {
  run "$SCRIPT" .gaia/manifest.json
  [ "$output" = '{"ok":true,"allowed":[".gaia/manifest.json"],"denied":[]}' ]
}

# --- denylist hits ---------------------------------------------------------

@test "denylist: app/" {
  run "$SCRIPT" app/foo.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"app/foo.ts","reason":"denylist"}]}' ]
}

@test "denylist: wiki/" {
  run "$SCRIPT" wiki/index.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"wiki/index.md","reason":"denylist"}]}' ]
}

@test "denylist: studio/" {
  run "$SCRIPT" studio/branding/IDENTITY.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"studio/branding/IDENTITY.md","reason":"denylist"}]}' ]
}

@test "denylist: website/" {
  run "$SCRIPT" website/src/sections/Hero.tsx
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"website/src/sections/Hero.tsx","reason":"denylist"}]}' ]
}

@test "denylist: .specify/specs/" {
  run "$SCRIPT" .specify/specs/SPEC-002.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".specify/specs/SPEC-002.md","reason":"denylist"}]}' ]
}

@test "denylist: .specify/memory/" {
  run "$SCRIPT" .specify/memory/foo.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".specify/memory/foo.md","reason":"denylist"}]}' ]
}

@test "denylist: .gaia/local/specs/" {
  run "$SCRIPT" .gaia/local/specs/SPEC-002.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/local/specs/SPEC-002.md","reason":"denylist"}]}' ]
}

@test "denylist: .github/workflows/" {
  run "$SCRIPT" .github/workflows/forensics-triage.yml
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".github/workflows/forensics-triage.yml","reason":"denylist"}]}' ]
}

# --- allowlist subtraction (UAT-007 edge case) -----------------------------

@test "subtraction: .specify/extensions/gaia/templates/ overrides parent allowlist" {
  run "$SCRIPT" .specify/extensions/gaia/templates/foo.md
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".specify/extensions/gaia/templates/foo.md","reason":"denylist"}]}' ]
}

# --- default-deny (UAT-014) ------------------------------------------------

@test "default-deny: package.json" {
  run "$SCRIPT" package.json
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"package.json","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: eslint.config.ts" {
  run "$SCRIPT" eslint.config.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: .github/CODEOWNERS (unenumerated .github/ subpath)" {
  run "$SCRIPT" .github/CODEOWNERS
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".github/CODEOWNERS","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: sibling of an allowlist prefix does not match" {
  # `.gaia/cliques/` is NOT `.gaia/cli/`; trailing-slash discipline prevents
  # bleed.
  run "$SCRIPT" .gaia/cliques/foo.sh
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cliques/foo.sh","reason":"default-deny-unenumerated"}]}' ]
}

@test "default-deny: bare directory name without trailing path" {
  # Defensive: git diff names files, never bare directories. A bare
  # ".gaia/cli" does not match the ".gaia/cli/" prefix.
  run "$SCRIPT" .gaia/cli
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":".gaia/cli","reason":"default-deny-unenumerated"}]}' ]
}

# --- multi-path partitioning -----------------------------------------------

@test "multi: all-allow → ok:true" {
  run "$SCRIPT" .gaia/cli/foo.sh .claude/hooks/bar.sh .gaia/manifest.json
  [ "$output" = '{"ok":true,"allowed":[".gaia/cli/foo.sh",".claude/hooks/bar.sh",".gaia/manifest.json"],"denied":[]}' ]
}

@test "multi: any-deny flips ok:false; allowed/denied partition the input" {
  run "$SCRIPT" .gaia/cli/foo.sh app/bar.ts package.json
  [ "$output" = '{"ok":false,"allowed":[".gaia/cli/foo.sh"],"denied":[{"path":"app/bar.ts","reason":"denylist"},{"path":"package.json","reason":"default-deny-unenumerated"}]}' ]
}

@test "multi: deny reasons are recorded per-path (mixed denylist + default-deny)" {
  run "$SCRIPT" wiki/foo.md eslint.config.ts
  [ "$output" = '{"ok":false,"allowed":[],"denied":[{"path":"wiki/foo.md","reason":"denylist"},{"path":"eslint.config.ts","reason":"default-deny-unenumerated"}]}' ]
}

# --- zero-input contract ---------------------------------------------------

@test "no args: ok:true with empty arrays" {
  run "$SCRIPT"
  [ "$output" = '{"ok":true,"allowed":[],"denied":[]}' ]
}

# --- control-byte rejection (UAT-009) --------------------------------------
#
# JSON forbids unescaped U+0000..U+001F inside string literals. The script
# rejects any path containing a control byte with a structured error
# envelope rather than emitting malformed JSON. Filesystems forbid these
# in path names in practice; the rejection path defends against synthetic
# inputs (misbehaving callers, future test harnesses) and surfaces them
# as an explicit upstream signal.

@test "control-byte: tab (0x09) → reject with reason naming hex+position" {
  path=$(printf 'app/foo\tbar.ts')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"control-byte:0x09-at-position-7"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: newline (0x0a) → reject with reason naming hex+position" {
  path=$(printf 'wiki/index\nmd')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"ok":false'*'"reason":"control-byte:0x0a-at-position-10"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: carriage-return (0x0d) → reject" {
  path=$(printf 'a\rb')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"reason":"control-byte:0x0d-at-position-1"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: U+0001 (SOH, 0x01) → reject" {
  path=$(printf 'foo\001bar')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  case $output in
    *'"reason":"control-byte:0x01-at-position-3"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: rejection envelope shape — ok:false, allowed:[], single denied entry" {
  path=$(printf 'x\ty')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  # Whole envelope: allowed must be empty and denied must hold exactly the one entry.
  case $output in
    '{"ok":false,"allowed":[],"denied":[{"path":"x?y","reason":"control-byte:0x09-at-position-1"}]}') ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: short-circuits before classifying remaining paths" {
  # First arg has a control byte; remaining args (allow + deny) must NOT
  # appear in the output — the rejection envelope replaces the normal
  # classification result.
  bad=$(printf 'bad\tpath')
  run "$SCRIPT" "$bad" .gaia/cli/foo.sh app/bar.ts
  [ "$status" -eq 0 ]
  case $output in
    *'.gaia/cli/foo.sh'*) printf 'allowlisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'app/bar.ts'*) printf 'denylisted path leaked: %s\n' "$output" >&2; return 1 ;;
    *'"reason":"control-byte:0x09-at-position-3"'*) ;;
    *) printf 'unexpected output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "control-byte: rejection JSON parses with jq" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not available"
  fi
  path=$(printf 'a\tb')
  run "$SCRIPT" "$path"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq . >/dev/null
}
