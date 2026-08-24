#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-verb-arming-adoption.sh: the
# eleven hooks stay a single-source-of-truth over the arming decision only
# because nothing lets that fact drift silently. This suite is what actually
# fails a build when a twelfth hook spells its own pattern pair, when a hook
# arms through a grep re-implementation instead of the shared function, when
# the registered-hook roster drifts from the enumerated eleven, or when a
# deny-capable hook's library-absent fail direction moves without a written
# exemption.
#
# Every test drives the check through its <repo_root> parameter against a
# fixture tree, matching check-base-provenance-adoption.bats's reasoning: a
# predicate that only ever runs against the healthy real tree has every
# branch it takes be the passing one, so a broken predicate still reports
# green.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-verb-arming-adoption.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-verb-arming-adoption.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-verb-arming-adoption.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# write_baseline <dir>: a healthy tree -- the library's two definitions, all
# eleven hooks adopting gaia_verb_armed and registered in settings.json to
# match, the three merge gates denying on a missing library, and
# distribution-preflight-check.sh taking the written fail-open exemption
# while staying deny-capable. Every "must fail" fixture starts here and
# mutates one thing.
write_baseline() {
  local dir="$1" h
  mkdir -p "$dir/.claude/hooks/lib"

  cat >"$dir/.claude/hooks/lib/verb-arming.sh" <<'EOF'
#!/usr/bin/env bash
gaia_verb_armed() {
  local frag="$1" words="$2" text="$3"
  local start_re sep_re
  start_re='^[[:space:]]*'"$frag"
  sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*'"$frag"
  if [[ "$text" =~ $start_re ]]; then
    return 0
  fi
  return 1
}
EOF

  cat >"$dir/.claude/hooks/lib/verb-arming-walk.sh" <<'EOF'
#!/usr/bin/env bash
gaia_verb_arm_view() {
  GAIA_VERB_ARM_VIEW="$1"
}
EOF

  for h in pr-merge-audit-check worthiness-presence-check audit-disposition-check; do
    cat >"$dir/.claude/hooks/$h.sh" <<EOF
#!/usr/bin/env bash
. "\$(dirname "\${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
if ! type gaia_verb_armed >/dev/null 2>&1; then
  jq -n --arg r "$h gate: cannot load the shared verb-arming decision (must exist, be readable, and define gaia_verb_armed)." '{}'
  exit 0
fi
if gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)' 'gh pr merge' "\$cmd"; then
  :
fi
EOF
  done

  cat >"$dir/.claude/hooks/distribution-preflight-check.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0
if gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' 'gh pr create' "$cmd_joined"; then
  :
fi
deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}
EOF

  for h in post-findings-block-on-merge token-tally-git-op token-tally-review \
           token-rollup-merge issue-claim-release debt-sentinel-touch capture-gh-artifact; do
    cat >"$dir/.claude/hooks/$h.sh" <<EOF
#!/usr/bin/env bash
. "\$(dirname "\${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0
if gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)' 'gh pr merge' "\$cmd"; then
  :
fi
EOF
  done

  cat >"$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": ".claude/hooks/pr-merge-audit-check.sh"},
        {"type": "command", "command": ".claude/hooks/worthiness-presence-check.sh"},
        {"type": "command", "command": ".claude/hooks/audit-disposition-check.sh"},
        {"type": "command", "command": ".claude/hooks/distribution-preflight-check.sh"}
      ]}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": ".claude/hooks/post-findings-block-on-merge.sh"},
        {"type": "command", "command": ".claude/hooks/token-tally-git-op.sh"},
        {"type": "command", "command": ".claude/hooks/token-rollup-merge.sh"},
        {"type": "command", "command": ".claude/hooks/issue-claim-release.sh"},
        {"type": "command", "command": ".claude/hooks/debt-sentinel-touch.sh"},
        {"type": "command", "command": ".claude/hooks/capture-gh-artifact.sh"}
      ]}
    ],
    "Stop": [
      {"hooks": [
        {"type": "command", "command": ".claude/hooks/token-tally-review.sh"}
      ]}
    ]
  }
}
EOF
  printf 'fixture\n' >"$dir/README.md"
}

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR seeded
# with write_baseline and committed. Files it sees only via `git grep` /
# `git ls-files` require this: a plain directory of files is invisible to
# both, so a fixture skipping this step greens every "must fail" case by
# finding no matches at all.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  write_baseline "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

commit_all() {
  local dir="$1"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m update
}

@test "structural: sourcing the script defines gaia_check_verb_arming_adoption with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_verb_arming_adoption >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "fixture: healthy baseline passes" {
  local repo
  repo="$(make_fixture_repo healthy)"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "real repo: exits 0 with all six assertions satisfied (case 5)" {
  run gaia_check_verb_arming_adoption "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "gaia_verb_armed definitions found: 1" <<<"$output" || return 1
  grep -qF "gaia_verb_arm_view definitions found: 1" <<<"$output" || return 1
  grep -qF ".claude/hooks/pr-merge-audit-check.sh: adopted" <<<"$output" || return 1
  grep -qF "roster: registered adopters match the enumerated eleven" <<<"$output" || return 1
}

@test "fixture: a twelfth hook with a private start_re/sep_re pair fails and names file and line (case 1)" {
  local repo
  repo="$(make_fixture_repo twelfth-hook)"
  cat >"$repo/.claude/hooks/rogue-verb-check.sh" <<'EOF'
#!/usr/bin/env bash
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge'
sep_re=$'(\\&\\&|;)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge'
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/rogue-verb-check.sh:2:" <<<"$output" || return 1
}

@test "fixture: a hook arming through the grep-based idiom fails and names it (case 2)" {
  local repo
  repo="$(make_fixture_repo grep-idiom)"
  cat >"$repo/.claude/hooks/rogue-grep-check.sh" <<'EOF'
#!/usr/bin/env bash
if printf '%s' "$cmd" | grep -qE '(&&|;|\|\|)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge'; then
  echo armed
fi
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/rogue-grep-check.sh:2:" <<<"$output" || return 1
}

@test "fixture: a registered hook that adopts without being enumerated fails and names it (case 3, direction A)" {
  local repo
  repo="$(make_fixture_repo drift-extra)"
  cat >"$repo/.claude/hooks/twelfth-registered.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0
gaia_verb_armed 'gh[[:space:]]+issue[[:space:]]+close' 'gh issue close' "$cmd" || true
EOF
  python3 - "$repo/.claude/settings.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"]["PostToolUse"][0]["hooks"].append(
    {"type": "command", "command": ".claude/hooks/twelfth-registered.sh"}
)
json.dump(data, open(path, "w"), indent=2)
PYEOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/twelfth-registered.sh" <<<"$output" || return 1
  grep -qF "not enumerated" <<<"$output" || return 1
}

@test "fixture: an enumerated hook that stops adopting fails and names it (case 3, direction B)" {
  local repo
  repo="$(make_fixture_repo drift-missing)"
  printf '#!/usr/bin/env bash\necho no longer adopted\n' >"$repo/.claude/hooks/capture-gh-artifact.sh"
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/capture-gh-artifact.sh: NOT adopted" <<<"$output" || return 1
  grep -qF "no longer referenced by a registered hook" <<<"$output" || return 1
}

@test "fixture: two definitions of gaia_verb_armed fails (case 4)" {
  local repo
  repo="$(make_fixture_repo two-defs)"
  cat >"$repo/.claude/hooks/lib/second-verb-arming.sh" <<'EOF'
#!/usr/bin/env bash
gaia_verb_armed() {
  return 1
}
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "gaia_verb_armed definitions found: 2" <<<"$output" || return 1
  grep -qF "lib/verb-arming.sh" <<<"$output" || return 1
  grep -qF "lib/second-verb-arming.sh" <<<"$output" || return 1
}

@test "fixture: two definitions of gaia_verb_arm_view fails" {
  local repo
  repo="$(make_fixture_repo two-view-defs)"
  cat >"$repo/.claude/hooks/lib/second-walk.sh" <<'EOF'
#!/usr/bin/env bash
gaia_verb_arm_view() {
  GAIA_VERB_ARM_VIEW="$1"
}
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "gaia_verb_arm_view definitions found: 2" <<<"$output" || return 1
}

@test "fixture: a comment mention is not a second definition" {
  local repo
  repo="$(make_fixture_repo comment-mention)"
  printf '#!/usr/bin/env bash\n# gaia_verb_armed() is the shared arming decision\n' >"$repo/.claude/hooks/lib/note.sh"
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 0 ]
}

@test "fixture: a missing enumerated hook file fails and names it" {
  local repo
  repo="$(make_fixture_repo missing-hook)"
  rm "$repo/.claude/hooks/token-rollup-merge.sh"
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF ".claude/hooks/token-rollup-merge.sh: MISSING" <<<"$output" || return 1
}

@test "fixture: a non-exempt deny-capable hook that stops denying on a missing library fails" {
  local repo
  repo="$(make_fixture_repo faildir-nonexempt)"
  cat >"$repo/.claude/hooks/worthiness-presence-check.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0
if gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' 'gh pr merge' "$cmd"; then
  :
fi
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "worthiness-presence-check.sh: does not deny on a missing verb-arming library, and carries no written exemption" <<<"$output" || return 1
}

@test "fixture: the exempt hook losing deny-capability makes the exemption stale and fails" {
  local repo
  repo="$(make_fixture_repo faildir-stale-exemption)"
  cat >"$repo/.claude/hooks/distribution-preflight-check.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0
if gaia_verb_armed 'gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' 'gh pr create' "$cmd_joined"; then
  :
fi
EOF
  commit_all "$repo"
  run gaia_check_verb_arming_adoption "$repo"
  [ "$status" -eq 1 ]
  grep -qF "no longer deny-capable; the fail-open exemption is stale" <<<"$output" || return 1
}

@test "usage: no repo_root and not a git repository exits 2" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"
  run bash -c 'cd "$1" && bash "$2"' _ "$dir" "$CHECK"
  [ "$status" -eq 2 ]
}
