#!/usr/bin/env bats
# Pins for `.claude/agents/audit-loop-unit.md`, the off-thread audit
# orchestrator the PR Merge Workflow main thread dispatches, and for the
# roster glob that routes a change to that file to a reviewing member.
#
# Prose-to-prose checks: each literal below is something the unit acts on (a
# page anchor it follows, a deny prefix it classifies, a stop it writes, a
# thing it must never do). Every presence check has a red twin: a scratch copy
# with the literal removed must fail the same predicate, so the predicate is
# proven able to fail.
#
# GAIA_AUDIT_LOOP_UNIT_AGENT overrides the agent path so a scratch copy can be
# driven through the same cases; it defaults to the real file.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT="${GAIA_AUDIT_LOOP_UNIT_AGENT:-$ROOT/.claude/agents/audit-loop-unit.md}"
}

# has_literal <file> <literal>: rc 0 when the fixed string is present.
has_literal() {
  grep -qF -- "$2" "$1"
}

# scratch_without <literal>: writes a copy of the agent with every line
# carrying the literal removed and prints its path.
scratch_without() {
  local out="$BATS_TEST_TMPDIR/agent-without.md"
  grep -vF -- "$1" "$AGENT" >"$out"
  printf '%s\n' "$out"
}

# assert_pinned <literal>: present in the real file, absent in the scratch
# copy that drops it (the red twin).
assert_pinned() {
  has_literal "$AGENT" "$1" || { echo "missing: $1" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1")"
  has_literal "$copy" "$1" && { echo "red twin did not fail: $1" >&2; return 1; }
  true
}

@test "agent frontmatter: name equals the filename stem and model is opus" {
  [ "$(sed -n '1p' "$AGENT")" = '---' ]
  local close
  close="$(awk 'NR>1 && /^---$/ {print NR; exit}' "$AGENT")"
  [ -n "$close" ]
  sed -n "2,$((close - 1))p" "$AGENT" >"$BATS_TEST_TMPDIR/fm.txt"
  grep -qx 'name: audit-loop-unit' "$BATS_TEST_TMPDIR/fm.txt"
  grep -qx 'model: opus' "$BATS_TEST_TMPDIR/fm.txt"
  grep -q '^description: ' "$BATS_TEST_TMPDIR/fm.txt"
  # No tools line, matching the other agent definitions.
  grep -q '^tools:' "$BATS_TEST_TMPDIR/fm.txt" && return 1
  [ "$(basename "$AGENT" .md)" = "audit-loop-unit" ]
  # The body after the frontmatter is non-empty.
  [ "$(sed -n "$((close + 1)),\$p" "$AGENT" | grep -c '[^[:space:]]')" -gt 0 ]
}

@test "frontmatter red twin: a wrong name or model fails the same checks" {
  sed 's/^name: audit-loop-unit$/name: other/' "$AGENT" >"$BATS_TEST_TMPDIR/bad-name.md"
  grep -qx 'name: audit-loop-unit' "$BATS_TEST_TMPDIR/bad-name.md" && return 1
  sed 's/^model: opus$/model: sonnet/' "$AGENT" >"$BATS_TEST_TMPDIR/bad-model.md"
  grep -qx 'model: opus' "$BATS_TEST_TMPDIR/bad-model.md" && return 1
  true
}

@test "agent names every page anchor it follows" {
  assert_pinned '#### The audit loop unit'
  assert_pinned '#### The fix round: fixer, verifier, gate'
  assert_pinned '#### When rounds stop: pre-commit a disposition for every branch'
  assert_pinned '#### Cross-remit findings'
}

@test "agent names all seven stop_reason values" {
  local reason
  for reason in clean window-end checkpoint-deny dispositions-check-failed \
    needs-human nesting-unavailable failure; do
    assert_pinned "\`$reason\`"
  done
}

@test "agent maps each deny prefix to its stop_reason" {
  assert_pinned '| `BLOCKED: audit checkpoint` | `checkpoint-deny` |'
  assert_pinned '| `BLOCKED: audit window` | `window-end` |'
  assert_pinned '| `BLOCKED: audit dispositions` | `dispositions-check-failed`'
  assert_pinned '| any other `BLOCKED:` | `failure` |'
}

@test "agent classifies the marker as a substring after the harness prefix" {
  assert_pinned 'PreToolUse:Agent hook error: BLOCKED: audit'
  assert_pinned 'A `BLOCKED:` deny is never `nesting-unavailable`.'
}

@test "agent names the window check, the ENFORCEMENT_PATHS rule and the stop" {
  assert_pinned 'unit-window'
  assert_pinned 'enforcement_paths_allowed'
  assert_pinned 'needs-human'
}

@test "agent carries the How your run ends paragraph verbatim" {
  local plan="$ROOT/.claude/skills/gaia/references/plan.md"
  local para
  para="$(grep -F -m1 'How your run ends:' "$plan" | sed 's/^[[:space:]>]*//')"
  [ -n "$para" ]
  has_literal "$AGENT" "$para"
  assert_pinned 'How your run ends:'
}

@test "agent hard-codes no id reference, em dash, or round count" {
  grep -qE 'SPEC-[0-9]|UAT-[0-9]' "$AGENT" && return 1
  grep -qF -- "$(printf '\xe2\x80\x94')" "$AGENT" && return 1
  grep -qF -- '3 rounds' "$AGENT" && return 1
  # Red twins: each forbidden literal is detected when present.
  printf 'x SPEC-093 y\n' >"$BATS_TEST_TMPDIR/id.md"
  grep -qE 'SPEC-[0-9]|UAT-[0-9]' "$BATS_TEST_TMPDIR/id.md"
  printf 'x \xe2\x80\x94 y\n' >"$BATS_TEST_TMPDIR/dash.md"
  grep -qF -- "$(printf '\xe2\x80\x94')" "$BATS_TEST_TMPDIR/dash.md"
  printf 'run 3 rounds\n' >"$BATS_TEST_TMPDIR/k.md"
  grep -qF -- '3 rounds' "$BATS_TEST_TMPDIR/k.md"
}

@test "agent forbids merging, posting a status, CHANGELOG edits and vetoes.json" {
  assert_pinned 'Never run `gh pr merge`'
  assert_pinned 'Never run `post-audit-status.sh`'
  assert_pinned 'Never edit `CHANGELOG.md`.'
  assert_pinned 'never write `vetoes.json`'
  # Each prohibition sits under the Never heading, not elsewhere.
  local never
  never="$(awk '/^## Never$/ {f=1; next} /^## / {f=0} f' "$AGENT")"
  [ -n "$never" ]
  local needle
  for needle in 'gh pr merge' 'post-audit-status.sh' 'CHANGELOG.md' 'vetoes.json'; do
    grep -qF -- "$needle" <<<"$never" || { echo "not under Never: $needle" >&2; return 1; }
  done
}

@test "roster: a change to the agent file routes to the shell member only" {
  local sb="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$sb/.gaia" "$sb/.claude/agents"
  git -C "$sb" init -q -b main
  cp "$ROOT/.gaia/audit-ci.yml" "$sb/.gaia/audit-ci.yml"
  printf 'x\n' >"$sb/README.md"
  git -C "$sb" add -A
  git -C "$sb" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$sb" checkout -q -b feat
  printf 'y\n' >"$sb/.claude/agents/audit-loop-unit.md"
  git -C "$sb" add -A
  git -C "$sb" -c user.email=t@t -c user.name=t commit -qm change

  run bash "$ROOT/.gaia/scripts/resolve-audit-members.sh" --root "$sb" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]
  grep -qF 'audit-loop-unit' <<<"$output" && return 1

  # Red twin: with the glob removed from the sandbox roster, nobody owns it.
  grep -vF '".claude/agents/audit-loop-unit.md"' "$sb/.gaia/audit-ci.yml" >"$sb/roster.new"
  mv "$sb/roster.new" "$sb/.gaia/audit-ci.yml"
  run bash "$ROOT/.gaia/scripts/resolve-audit-members.sh" --root "$sb" --base main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "roster: the shell member's remit region names the agent file" {
  grep -qF -- '- `.claude/agents/audit-loop-unit.md`' "$ROOT/.claude/agents/code-audit-maintainer-shell.md"
}

@test "roster verifier passes on the real roster" {
  run bash "$ROOT/.gaia/scripts/verify-audit-roster.sh"
  [ "$status" -eq 0 ]
}
