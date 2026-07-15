#!/usr/bin/env bats
# Structural, regression, and invariant tests for the shared ownership
# classifier (UAT-015), covering the parts owned by the ownership-classifier
# phase: exactly-one-classifier (part 1), every-consumer-sources-it minus the
# carry-forward predicate half (part 2), the four in-scope sets staying
# separately named (part 3), the golden behavior table (part 4), and
# absent-module -> DENY (part 5). Plus two further invariants: SEC-007 (every
# machinery path is roster-claimed) and the scrub-marker survival check.
#
# Assertion style (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so assertions below use `grep -q` /
# `[ ]` (real exit codes) or an explicit `return 1`, never a bare `[[ ]]`
# unless it is the test's last command.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCOPE_LIB="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  MACHINERY_LIB="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  RESOLVER="$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh"
  SPAWN="$REPO_ROOT/.gaia/scripts/resolve-audit-spawn.sh"
  HOOK="$REPO_ROOT/.claude/hooks/pr-merge-audit-check.sh"
  CF_LIB="$REPO_ROOT/.claude/hooks/lib/audit-carry-forward.sh"

  ALLOWLIST_LITERAL='wiki/*|.claude/*|.specify/*|.gaia/*|docs/*'
}

# Extract a named function's body (from its `name() {` line through the next
# column-0 `}`) so a structural assertion can inspect one function in
# isolation without matching a sibling's text.
extract_function() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\) \\{" { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Part 1: exactly one classifier. The merge gate's out-of-scope allowlist
# case-arm literal lives in exactly one tracked file.
# ---------------------------------------------------------------------------

@test "exactly one classifier: the out-of-scope allowlist literal lives in one tracked file" {
  matches="$(git -C "$REPO_ROOT" grep -lF -- "$ALLOWLIST_LITERAL" -- '*.sh')"
  count="$(printf '%s\n' "$matches" | grep -c .)"
  [ "$count" -eq 1 ]
  grep -qxF ".claude/hooks/lib/audit-scope.sh" <<<"$matches" || return 1
}

# ---------------------------------------------------------------------------
# Part 2 (minus the carry-forward-predicate half, added in a later phase):
# every consumer sources the module and calls audit_scope_init once per run,
# never once per path.
# ---------------------------------------------------------------------------

@test "surfaces exist: the classifier, the machinery list, and all three consumers" {
  [ -f "$SCOPE_LIB" ]
  [ -f "$MACHINERY_LIB" ]
  [ -f "$RESOLVER" ]
  [ -f "$SPAWN" ]
  [ -f "$HOOK" ]
}

@test "resolve-audit-members.sh sources audit-scope.sh and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$RESOLVER" || return 1
  count="$(grep -c "audit_scope_init " "$RESOLVER")"
  [ "$count" -eq 1 ]
}

@test "resolve-audit-spawn.sh sources audit-scope.sh" {
  grep -qF -- "audit-scope.sh" "$SPAWN" || return 1
}

@test "pr-merge-audit-check.sh sources audit-scope.sh and audit-machinery.sh, and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$HOOK" || return 1
  grep -qF -- "audit-machinery.sh" "$HOOK" || return 1
  count="$(grep -c "audit_scope_init " "$HOOK")"
  [ "$count" -eq 1 ]
}

@test "no consumer calls the classifier once per path (no per-path source or init inside a changed-path loop)" {
  # A per-path fork would show the source/init call INSIDE the "while IFS= read"
  # dispatch loop bodies; those loops call only the batch predicate
  # (audit_owners_for_paths) or the single-path predicates directly, never
  # re-source or re-init. Grep each consumer's post-init body for a second
  # audit_scope_init call is already covered above (count -eq 1); this test
  # additionally proves the dispatch loop itself never calls it.
  for f in "$RESOLVER" "$SPAWN" "$HOOK"; do
    dispatch_loop="$(awk '/while IFS= read -r path; do/,/^done/' "$f")"
    [ -z "$dispatch_loop" ] && continue
    grep -qF "audit_scope_init" <<<"$dispatch_loop" && return 1
  done
  true
}

# Part 2, carry-forward-predicate half (the fourth consumer). The predicate
# sources audit-scope.sh and calls audit_scope_init once per run, never once
# per path.

@test "the carry-forward predicate sources audit-scope.sh" {
  [ -f "$CF_LIB" ]
  grep -qF -- "audit-scope.sh" "$CF_LIB" || return 1
}

@test "the carry-forward predicate calls audit_scope_init exactly once (never once per path)" {
  [ -f "$CF_LIB" ]
  # Exactly one INVOCATION (matched by its quoted argument, so the defensive
  # `command -v audit_scope_init` existence guard is not counted), in the
  # scope-init guard, so a member set never re-parses the roster once per delta
  # path. One call total cannot be per-path.
  count="$(grep -c 'audit_scope_init "' "$CF_LIB")"
  [ "$count" -eq 1 ]
  # No `while ... read` dispatch loop in the predicate contains the init call.
  loop="$(awk '/while IFS=.*read/,/done/' "$CF_LIB")"
  if [ -n "$loop" ]; then
    grep -qF "audit_scope_init" <<<"$loop" && return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Part 3: the four in-scope sets stay separately named. Each of
# audit_in_auditable_base, audit_out_of_scope_allowlisted, and
# audit_self_mod_classify is a distinct symbol, and none is defined in terms
# of another. CI's has_source stays a workflow-local grep pair, never
# replaced by a call into the module.
# ---------------------------------------------------------------------------

@test "the three path-classification functions are distinct symbols" {
  grep -qF "audit_in_auditable_base() {" "$SCOPE_LIB" || return 1
  grep -qF "audit_out_of_scope_allowlisted() {" "$SCOPE_LIB" || return 1
  grep -qF "audit_self_mod_classify() {" "$SCOPE_LIB" || return 1
}

@test "audit_in_auditable_base is not defined in terms of the other two" {
  body="$(extract_function "$SCOPE_LIB" audit_in_auditable_base)"
  grep -qF "audit_out_of_scope_allowlisted" <<<"$body" && return 1
  grep -qF "audit_self_mod_classify" <<<"$body" && return 1
  true
}

@test "audit_out_of_scope_allowlisted is not defined in terms of the other two" {
  body="$(extract_function "$SCOPE_LIB" audit_out_of_scope_allowlisted)"
  grep -qF "audit_in_auditable_base" <<<"$body" && return 1
  grep -qF "audit_self_mod_classify" <<<"$body" && return 1
  true
}

@test "audit_self_mod_classify is not defined in terms of the other two, and stays a three-way classification" {
  body="$(extract_function "$SCOPE_LIB" audit_self_mod_classify)"
  grep -qF "audit_in_auditable_base" <<<"$body" && return 1
  grep -qF "audit_out_of_scope_allowlisted" <<<"$body" && return 1
  grep -qF "out-of-scope" <<<"$body" || return 1
  grep -qF "audit-workflow" <<<"$body" || return 1
  grep -qF "in-scope" <<<"$body" || return 1
}

@test "CI's has_source gate is not replaced by a call into the classifier module" {
  wf="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$wf" ]
  grep -qF "has_source" "$wf" || return 1
  grep -qF "audit-scope.sh" "$wf" && return 1
  grep -qF "audit_out_of_scope_allowlisted" "$wf" && return 1
  true
}

# ---------------------------------------------------------------------------
# Part 4: the gate's decision is unchanged across a golden table of path
# sets. Each case drives the real merge-gate hook end to end (a sandbox on a
# `feature` branch off `main`, mirroring the sibling pr-merge-audit-check.bats
# fixture) and asserts allow/deny.
# ---------------------------------------------------------------------------

golden_setup() {
  GREPO=$(mktemp -d -t audit-scope-golden-XXXXXX)
  git -C "$GREPO" init --quiet --initial-branch=main
  git -C "$GREPO" config user.email "test@example.com"
  git -C "$GREPO" config user.name "Test"
  git -C "$GREPO" config commit.gpgsign false

  mkdir -p "$GREPO/.gaia"
  printf '1.4.0\n' > "$GREPO/.gaia/VERSION"
  echo "# readme" > "$GREPO/README.md"
  git -C "$GREPO" add .gaia/VERSION README.md
  git -C "$GREPO" commit --quiet -m "init"
  git -C "$GREPO" checkout --quiet -b feature

  # The real hook (run by absolute path via $HOOK, never copied) delegates
  # dispatch to .gaia/scripts/resolve-audit-members.sh CWD-relatively, so the
  # golden table needs a real copy here too, mirroring the sibling
  # pr-merge-audit-check.bats fixture. That copy resolves its own libs
  # relative to ITSELF ($GREPO/.claude/hooks/lib/), so the sandbox needs its
  # own copy of the shared ownership classifier alongside it.
  mkdir -p "$GREPO/.gaia/scripts" "$GREPO/.claude/hooks/lib"
  cp "$RESOLVER" "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  cp "$SCOPE_LIB" "$GREPO/.claude/hooks/lib/audit-scope.sh"
  cp "$MACHINERY_LIB" "$GREPO/.claude/hooks/lib/audit-machinery.sh"
}

golden_teardown() {
  [ -n "${GREPO:-}" ] && rm -rf "$GREPO"
  true
}

golden_commit() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$GREPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$GREPO/$path"
    git -C "$GREPO" add "$path"
  done
  git -C "$GREPO" commit --quiet -m "change"
}

golden_run_hook() {
  local json
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 1 --squash"}}')
  run bash -c "cd '$GREPO' && printf '%s' '$json' | bash '$HOOK'"
}

@test "golden table: pure wiki-only diff allows" {
  golden_setup
  golden_commit "wiki/x.md" "doc"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

@test "golden table: pure app/ diff denies (marker mandatory)" {
  golden_setup
  golden_commit "app/x.ts" "export const x = 1;"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: mixed app/ + wiki/ diff denies" {
  golden_setup
  golden_commit "app/x.ts" "export const x = 1;" "wiki/x.md" "doc"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: .gaia/**/*.sh-only diff denies (allowlisted AND owned; legacy branch never reached)" {
  golden_setup
  golden_commit ".gaia/scripts/probe.sh" "#!/bin/bash"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: ownerless-but-in-scope root Dockerfile denies" {
  golden_setup
  golden_commit "Dockerfile" "FROM scratch"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: self-mod-only with a template-matching workflow blob allows" {
  golden_setup
  golden_commit \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

@test "golden table: self-mod plus one extra in-scope path denies" {
  golden_setup
  golden_commit \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit" \
    "app/evil.ts" "export const evil = 1;"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: self-mod with an edited (non-template-matching) workflow denies" {
  golden_setup
  golden_commit \
    ".github/workflows/code-review-audit.yml" "name: Code Review Audit (customized)" \
    ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" "name: Code Review Audit"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Part 5: absent module -> DENY. A COPY of the hook in a sandbox
# `.claude/hooks/` with no `lib/` at all must deny, never allow. Never `mv`
# the real module aside: a bats run must not mutate the working tree, and a
# copied hook exercises the same BASH_SOURCE-relative miss.
# ---------------------------------------------------------------------------

@test "absent classifier module: a copied hook with no lib/ directory denies, never allows" {
  SANDBOX=$(mktemp -d -t audit-scope-absent-XXXXXX)
  mkdir -p "$SANDBOX/.claude/hooks"
  cp "$HOOK" "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"
  chmod +x "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"

  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 1 --squash"}}')
  run bash -c "cd '$SANDBOX' && printf '%s' '$json' | bash '$SANDBOX/.claude/hooks/pr-merge-audit-check.sh'"
  rm -rf "$SANDBOX"

  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# SEC-007: every machinery path is roster-claimed. Run against the real
# .gaia/audit-ci.yml (the maintainer roster); bats suites are release-
# excluded, so this only ever runs where the maintainer members exist.
# ---------------------------------------------------------------------------

@test "SEC-007: audit_owner_for_path returns a non-empty member for every machinery path" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIB"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIB"
  audit_scope_init "$REPO_ROOT"

  fail=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *"/**")
        prefix="${entry%\*\*}"
        rep="${prefix}__representative__.sh"
        owner="$(audit_owner_for_path "$rep")"
        if [ -z "$owner" ]; then
          echo "representative path unowned: $rep" >&2
          fail=1
        fi
        while IFS= read -r tracked; do
          [ -n "$tracked" ] || continue
          owner="$(audit_owner_for_path "$tracked")"
          if [ -z "$owner" ]; then
            echo "tracked file unowned: $tracked (entry $entry)" >&2
            fail=1
          fi
        done < <(git -C "$REPO_ROOT" ls-files "$prefix")
        ;;
      *)
        owner="$(audit_owner_for_path "$entry")"
        if [ -z "$owner" ]; then
          echo "machinery path unowned: $entry" >&2
          fail=1
        fi
        ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF

  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The scrub markers survive. Balanced start/end markers, and a marker-
# stripped copy of the module (simulating the release scrub) yields a
# roster naming exactly one member, code-audit-frontend.
# ---------------------------------------------------------------------------

@test "scrub markers are balanced in audit-scope.sh" {
  starts="$(grep -c "# gaia:maintainer-only:start" "$SCOPE_LIB")"
  ends="$(grep -c "# gaia:maintainer-only:end" "$SCOPE_LIB")"
  [ "$starts" -eq "$ends" ]
  [ "$starts" -ge 1 ]
  start_line="$(grep -n "# gaia:maintainer-only:start" "$SCOPE_LIB" | head -1 | cut -d: -f1)"
  end_line="$(grep -n "# gaia:maintainer-only:end" "$SCOPE_LIB" | head -1 | cut -d: -f1)"
  [ "$start_line" -lt "$end_line" ]
}

@test "a marker-stripped copy of audit-scope.sh yields a single-member (frontend-only) roster" {
  SCRUBBED=$(mktemp -t audit-scope-scrubbed-XXXXXX)
  awk '
    /gaia:maintainer-only:start/ { skip = 1; next }
    /gaia:maintainer-only:end/   { skip = 0; next }
    !skip { print }
  ' "$SCOPE_LIB" > "$SCRUBBED"

  EMPTY_ROOT=$(mktemp -d -t audit-scope-noroster-XXXXXX)

  run bash -c '
    . "$1"
    audit_scope_init "$2"
    audit_owner_for_path "app/x.ts"
    audit_owner_for_path ".gaia/scripts/y.sh"
  ' _ "$SCRUBBED" "$EMPTY_ROOT"

  rm -f "$SCRUBBED"
  rm -rf "$EMPTY_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}
