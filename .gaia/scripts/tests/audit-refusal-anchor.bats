#!/usr/bin/env bats
#
# End to end: the REAL findings writer, clearance writer, scope resolver, and
# base resolver agree on one contract. A member that refused a round re-audits
# only the fixer's delta since that refusal, and only when the writer left the
# per-member provenance and review-coverage proof the resolver demands, at the
# key both derive. Each half has its own suite against hand-built fixtures; this
# suite exists because those can stay green while the halves disagree on a key
# or a field and the feature goes inert.
#
# Every test drives a member round the way the member protocol does, through
# the shipped scripts at their real repo-relative paths inside a sandbox repo:
# audit-resolve-scope.sh (scope and capture), audit-write-findings.sh (sidecar),
# audit-write-clearance.sh (record and ledger), then resolve-audit-base.sh
# --member on the next commit.
#
# Run under bash 5 (.claude/rules/bats-assertions.md): `source
# .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/audit-refusal-anchor.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

MEMBER="code-audit-maintainer-shell"
SIBLING="code-audit-maintainer-node"
MEMBER_FILE=".claude/hooks/guard.sh"
MEMBER_OTHER_FILE=".claude/hooks/older.sh"
SIBLING_FILE=".gaia/cli/src/probe.ts"

setup() {
  # The jq guard runs before the unset below: unsetting GITHUB_ACTIONS first
  # would turn a jq-less CI runner into a green skip.
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; the round-trip probes here would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  unset GITHUB_ACTIONS CI GITHUB_BASE_REF GH_TOKEN
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIRECTORY" rev-parse --show-toplevel)"
  . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
  # A `gh` that answers nothing, so no probe reaches the developer's real `gh`.
  mkdir -p "$BATS_TEST_TMPDIR/no-gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/no-gh/gh"
  chmod +x "$BATS_TEST_TMPDIR/no-gh/gh"
  PATH="$BATS_TEST_TMPDIR/no-gh:$PATH"
  build_sandbox
}

# build_sandbox: a committed repo carrying its own copy of every script a round
# runs, so the scope resolver's root confinement holds and the writer resolves
# the sandbox's own resolver.
build_sandbox() {
  local directory="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$directory/.gaia/scripts" "$directory/.github/audit" "$directory/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-write-findings.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-write-clearance.sh" \
    "$directory/.gaia/scripts/"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$directory/.github/audit/"
  cp "$REPO_ROOT/.claude/hooks/lib/"*.sh "$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md" \
    "$directory/.claude/hooks/lib/"
  chmod +x "$directory/.gaia/scripts/"*.sh "$directory/.github/audit/resolve-audit-base.sh"
  printf '2.0.0\n' > "$directory/.gaia/VERSION"
  seed_audit_roster "$directory"
  printf '#!/usr/bin/env bash\necho base\n' > "$directory/$MEMBER_FILE"
  printf '#!/usr/bin/env bash\necho older\n' > "$directory/$MEMBER_OTHER_FILE"
  mkdir -p "$directory/.gaia/cli/src"
  printf 'export const probe = 1;\n' > "$directory/$SIBLING_FILE"
  git -C "$directory" init -q --initial-branch=main
  git -C "$directory" config user.email t@example.com
  git -C "$directory" config user.name T
  git -C "$directory" config commit.gpgsign false
  printf '.gaia/local/\n' >> "$directory/.git/info/exclude"
  git -C "$directory" add -A
  git -C "$directory" commit -q -m base
  git -C "$directory" checkout -q -b fix/refusal-anchor
  ROOT="$(cd "$directory" && pwd -P)"
  AUDIT_DIRECTORY="$ROOT/.gaia/local/audit"
  AUDIT_KEY=""
}

# commit_touch <path>...: append a distinct line to each path and commit, so
# every call moves the content tree. Sets LAST_SHA.
commit_touch() {
  local path
  for path in "$@"; do
    mkdir -p "$(dirname "$ROOT/$path")"
    printf '# change %s\n' "$RANDOM$RANDOM" >> "$ROOT/$path"
  done
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m "touch $*"
  LAST_SHA="$(git -C "$ROOT" rev-parse HEAD)"
}

tree_of() {
  git -C "$ROOT" rev-parse "$1^{tree}"
}

# scope_value <KEY>: the value of the first KEY= line of the last scope run.
scope_value() {
  printf '%s\n' "$SCOPE_OUTPUT" | sed -n "s/^$1=//p" | head -1
}

# scope_resolve <member>: run the scope resolver the way a member does and keep
# its output. Sets SCOPE_OUTPUT and AUDIT_KEY.
scope_resolve() {
  SCOPE_OUTPUT="$("$ROOT/.gaia/scripts/audit-resolve-scope.sh" --member "$1" --root "$ROOT" --skip-full-base 2>/dev/null)" || return 1
  AUDIT_KEY="$(scope_value AUDIT_KEY)"
  [ -n "$AUDIT_KEY" ]
}

ledger_path() {
  printf '%s/%s.rerun.json' "$AUDIT_DIRECTORY" "$AUDIT_KEY"
}

member_digest() {
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$ROOT/.claude/hooks/lib/audit-digest.sh" "$ROOT" "$1"
}

# finding_object <line> <title>: one valid finding in the member's own file.
finding_object() {
  jq -nc --argjson line "$1" --arg title "$2" --arg path "$MEMBER_FILE" \
    '{finding_class:"holistic/swallowed-error",severity:"error",path:$path,line:$line,title:$title,
      failure_mode:"the failure the finding names",verified_by:"ran it and saw the failure",
      suggested_fix:"the repair"}'
}

# open_entry_ids <member>: the entry_id of each of the member's open ledger entries.
open_entry_ids() {
  jq -r --arg member "$1" '.remaining[] | select(.member == $member) | .entry_id' "$(ledger_path)"
}

# reported_open_entries <member>: the member's open ledger entries as findings
# that echo their entry_id, which is how a member re-reports a still-open one.
reported_open_entries() {
  jq -c --arg member "$1" '[.remaining[] | select(.member == $member)
    | {finding_class, path, line, title, failure_mode, verified_by, suggested_fix, entry_id,
       severity: ({"critical":"error","important":"warning","suggestion":"suggestion"}[.severity] // "warning")}]' \
    "$(ledger_path)"
}

# resolutions_for_open_entries <member> <rationale>: a resolution record per open entry.
resolutions_for_open_entries() {
  jq -c --arg member "$1" --arg rationale "$2" \
    '[.remaining[] | select(.member == $member) | {entry_id, rationale: $rationale}]' "$(ledger_path)"
}

# member_round <member> <findings-json> <resolutions-json|""> <provenance>:
# one round exactly as the member protocol runs it. Sets ROUND_STATUS (the
# clearance writer's exit status) and ROUND_OUTPUT (its combined output). Set
# OMIT_BASE=1 to leave --base off the clearance write, which leaves the ledger
# write unarmed, as a best-effort ledger write that did not land would.
member_round() {
  local member="$1" findings="$2" resolutions="$3" provenance="$4"
  local findings_file="$BATS_TEST_TMPDIR/round-findings.json"
  local resolutions_file="$BATS_TEST_TMPDIR/round-resolutions.json"
  scope_resolve "$member" || { echo "scope resolution failed for $member" >&2; return 1; }
  local key_base review_base base_reason anchor_tree
  key_base="$(scope_value KEY_BASE)"
  review_base="$(scope_value BASE_SHA)"
  base_reason="$(scope_value BASE_REASON)"
  anchor_tree="$(scope_value ANCHOR_TREE)"
  printf '%s\n' "$findings" > "$findings_file"
  local findings_arguments=(--root "$ROOT" --member "$member" --base "$key_base"
    --review-base "$review_base" --base-reason "$base_reason" --anchor-tree "$anchor_tree"
    --findings "$findings_file")
  if [ -n "$resolutions" ]; then
    printf '%s\n' "$resolutions" > "$resolutions_file"
    findings_arguments+=(--resolutions "$resolutions_file")
  fi
  bash "$ROOT/.gaia/scripts/audit-write-findings.sh" "${findings_arguments[@]}" >/dev/null \
    || { echo "findings writer failed for $member" >&2; return 1; }
  local clearance_arguments=(--root "$ROOT" --member "$member" --provenance "$provenance")
  [ "${OMIT_BASE:-0}" = "1" ] || clearance_arguments+=(--base "$key_base")
  if [ "$provenance" = "earned" ]; then
    clearance_arguments+=(--scope-digest "$(bash "$ROOT/.gaia/scripts/audit-scope-digest.sh" --read \
      --root "$ROOT" --member "$member" --base "$key_base")")
  fi
  ROUND_STATUS=0
  ROUND_OUTPUT="$(bash "$ROOT/.gaia/scripts/audit-write-clearance.sh" "${clearance_arguments[@]}" 2>&1)" \
    || ROUND_STATUS=$?
  return 0
}

# resolve_member <member>: the base resolver's --member output at HEAD.
# Sets RESOLVED_BASE, RESOLVED_REASON, RESOLVED_SHARED, RESOLVED_TREE.
resolve_member() {
  local output
  output="$( (cd "$ROOT" && bash .github/audit/resolve-audit-base.sh --member "$1") 2>/dev/null)"
  RESOLVED_BASE="$(printf '%s\n' "$output" | sed -n 1p)"
  RESOLVED_REASON="$(printf '%s\n' "$output" | sed -n 2p)"
  RESOLVED_SHARED="$(printf '%s\n' "$output" | sed -n 3p)"
  RESOLVED_TREE="$(printf '%s\n' "$output" | sed -n 4p)"
}

# refuse_with_two_findings <member>: the opening refusal most tests start from.
refuse_with_two_findings() {
  member_round "$1" "[$(finding_object 10 'first defect'),$(finding_object 20 'second defect')]" "" refused
  [ "$ROUND_STATUS" -eq 0 ]
}

@test "a refused member re-audits only the fixer's delta since its own refusal" {
  commit_touch "$MEMBER_FILE" "$MEMBER_OTHER_FILE"
  local refused_sha="$LAST_SHA"
  refuse_with_two_findings "$MEMBER"
  commit_touch "$MEMBER_FILE"

  resolve_member "$MEMBER"
  [ "$RESOLVED_BASE" = "$refused_sha" ]
  [ "$RESOLVED_REASON" = "member-refusal" ]
  [ "$RESOLVED_TREE" = "$(tree_of "$refused_sha")" ]

  scope_resolve "$MEMBER"
  [ "$(scope_value BASE_REASON)" = "member-refusal" ]
  local changed
  changed="$(printf '%s\n' "$SCOPE_OUTPUT" | sed -n 's/^CHANGED=//p')"
  [ "$changed" = "$MEMBER_FILE" ]
}

@test "a re-report that drops a still-open finding is refused, and re-reporting it by entry_id is accepted" {
  commit_touch "$MEMBER_FILE"
  member_round "$MEMBER" "[$(finding_object 10 'first defect')]" "" refused
  [ "$ROUND_STATUS" -eq 0 ]
  local first_entry_id
  first_entry_id="$(open_entry_ids "$MEMBER" | head -1)"
  [ -n "$first_entry_id" ]
  commit_touch "$MEMBER_FILE"
  local digest_at_fixer ledger_before
  digest_at_fixer="$(member_digest "$MEMBER")"
  ledger_before="$(cat "$(ledger_path)")"

  member_round "$MEMBER" "[$(finding_object 30 'second defect')]" "" refused
  [ "$ROUND_STATUS" -eq 3 ]
  [ -e "$AUDIT_DIRECTORY/${digest_at_fixer}.${MEMBER}.refused" ] && return 1
  [ "$(cat "$(ledger_path)")" = "$ledger_before" ]

  local reported
  reported="$(reported_open_entries "$MEMBER" | jq -c --argjson extra "$(finding_object 30 'second defect')" '. + [$extra]')"
  member_round "$MEMBER" "$reported" "" refused
  [ "$ROUND_STATUS" -eq 0 ]
  [ "$(open_entry_ids "$MEMBER" | wc -l | tr -d ' ')" = "2" ]
  open_entry_ids "$MEMBER" | grep -qxF "$first_entry_id"
  local second_sha
  second_sha="$(git -C "$ROOT" rev-parse HEAD)"

  commit_touch "$MEMBER_FILE"
  resolve_member "$MEMBER"
  [ "$RESOLVED_BASE" = "$second_sha" ]
  [ "$RESOLVED_REASON" = "member-refusal" ]
}

@test "resolving every open finding with a rationale earns, and the earned record then anchors the member" {
  commit_touch "$MEMBER_FILE"
  refuse_with_two_findings "$MEMBER"
  commit_touch "$MEMBER_FILE"
  local fixed_sha="$LAST_SHA"

  member_round "$MEMBER" "[]" "$(resolutions_for_open_entries "$MEMBER" 'fixed at the head commit')" earned
  [ "$ROUND_STATUS" -eq 0 ]
  local record
  record="$(ls "$AUDIT_DIRECTORY/"*".${MEMBER}.ok")"
  [ -f "$record" ]
  [ "$(jq '[.remaining[] | select(.member == "'"$MEMBER"'")] | length' "$(ledger_path)" 2>/dev/null || echo 0)" = "0" ]

  commit_touch "$MEMBER_FILE"
  resolve_member "$MEMBER"
  [ "$RESOLVED_BASE" = "$fixed_sha" ]
  [ "$RESOLVED_REASON" = "member-clearance" ]
  [ "$RESOLVED_TREE" = "$(jq -r .tree "$record")" ]
}

@test "a refusal whose ledger write did not land never anchors a member, even while a sibling updates the ledger" {
  commit_touch "$MEMBER_FILE"
  refuse_with_two_findings "$MEMBER"
  commit_touch "$MEMBER_FILE" "$SIBLING_FILE"
  local second_refused_sha="$LAST_SHA"

  local reported
  reported="$(reported_open_entries "$MEMBER")"
  OMIT_BASE=1 member_round "$MEMBER" "$reported" "" refused
  [ "$ROUND_STATUS" -eq 0 ]

  local member_state_before
  member_state_before="$(jq -S -c --arg member "$MEMBER" \
    '{remaining: [.remaining[] | select(.member == $member)], provenance: .member_provenance[$member]}' "$(ledger_path)")"

  member_round "$SIBLING" "[$(finding_object 5 'sibling defect' | jq -c '.path = ".gaia/cli/src/probe.ts"')]" "" refused
  [ "$ROUND_STATUS" -eq 0 ]
  [ "$(jq -S -c --arg member "$MEMBER" \
    '{remaining: [.remaining[] | select(.member == $member)], provenance: .member_provenance[$member]}' "$(ledger_path)")" = "$member_state_before" ]

  commit_touch "$MEMBER_FILE"
  resolve_member "$MEMBER"
  [ "$RESOLVED_REASON" = "no-anchor" ]
  [ "$RESOLVED_BASE" != "$second_refused_sha" ]
}

@test "a refusal written over content its scope capture did not cover carries no coverage proof and never anchors" {
  commit_touch "$MEMBER_FILE"
  scope_resolve "$MEMBER"
  commit_touch "$MEMBER_FILE"
  local refused_sha="$LAST_SHA"

  member_round "$MEMBER" "[$(finding_object 10 'first defect')]" "" refused
  [ "$ROUND_STATUS" -eq 0 ]
  local refusal
  refusal="$(ls "$AUDIT_DIRECTORY/"*".${MEMBER}.refused")"
  [ "$(jq 'has("review_coverage")' "$refusal")" = "false" ]

  commit_touch "$MEMBER_FILE"
  resolve_member "$MEMBER"
  [ "$RESOLVED_REASON" != "member-refusal" ]
  [ "$RESOLVED_BASE" != "$refused_sha" ]
}

@test "an earned write after a member-refusal round refuses when the ledger is gone, and the printed recovery clears it" {
  commit_touch "$MEMBER_FILE"
  refuse_with_two_findings "$MEMBER"
  commit_touch "$MEMBER_FILE"

  scope_resolve "$MEMBER"
  [ "$(scope_value BASE_REASON)" = "member-refusal" ]
  local key_base
  key_base="$(scope_value KEY_BASE)"
  rm -f "$(ledger_path)"

  member_round "$MEMBER" "[]" "" earned
  [ "$ROUND_STATUS" -eq 3 ]
  ls "$AUDIT_DIRECTORY/"*".${MEMBER}.ok" >/dev/null 2>&1 && return 1
  case "$ROUND_OUTPUT" in
    *"--release"*) ;;
    *) echo "refusal did not name the release recovery: $ROUND_OUTPUT" >&2; return 1 ;;
  esac

  bash "$ROOT/.gaia/scripts/audit-scope-digest.sh" --release --root "$ROOT" --member "$MEMBER" --base "$key_base"
  scope_resolve "$MEMBER"
  [ "$(scope_value BASE_REASON)" != "member-refusal" ]

  member_round "$MEMBER" "[]" "" earned
  [ "$ROUND_STATUS" -eq 0 ]
  ls "$AUDIT_DIRECTORY/"*".${MEMBER}.ok" >/dev/null
}

@test "the writer's ledger sits at the key the scope resolver prints, and the resolver derives the same key and base" {
  commit_touch "$MEMBER_FILE"
  refuse_with_two_findings "$MEMBER"
  commit_touch "$MEMBER_FILE"
  scope_resolve "$MEMBER"
  local shared_base merge_base resolver_key
  resolve_member "$MEMBER"
  shared_base="$RESOLVED_SHARED"
  merge_base="$(git -C "$ROOT" merge-base "$shared_base" HEAD)"
  resolver_key="$(bash -c '. "$1"; gaia_audit_key "$2" "$3"' _ "$ROOT/.gaia/scripts/audit-key-lib.sh" "$merge_base" "$ROOT")"

  [ -f "$AUDIT_DIRECTORY/${AUDIT_KEY}.rerun.json" ]
  [ "$resolver_key" = "$AUDIT_KEY" ]
  [ "$(ledger_path)" = "$AUDIT_DIRECTORY/${resolver_key}.rerun.json" ]
  [ "$(jq -r .base_sha "$(ledger_path)")" = "$merge_base" ]
  [ "$(jq -r .branch "$(ledger_path)")" = "$(git -C "$ROOT" branch --show-current)" ]
}
