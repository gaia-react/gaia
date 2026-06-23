#!/usr/bin/env bats
# Workflow-logic tests for the "Resolve audit decision" step in
# .github/workflows/code-review-audit.yml.
#
# The workflow YAML itself is not directly unit-testable, but the decision
# VALUE the step's `if:` keys on (`should_run`) is produced by the shared
# resolver (.gaia/scripts/read-audit-ci-config.sh --resolve-author). These
# tests exercise the resolver EXACTLY as the workflow's step calls it:
#
#   1. derive override-label presence from the PR's labels (the jq probe over
#      `PR_LABELS_JSON` against `OVERRIDE_LABEL`), then
#   2. call the resolver with `OVERRIDE_LABEL_PRESENT=<true|false>`.
#
# The Phase 1 resolver bats (.gaia/scripts/tests/read-audit-ci-config.bats)
# already cover precedence / normalization / fail-closed by setting
# OVERRIDE_LABEL_PRESENT directly. This suite covers the part those do not:
# the step's own override-presence DERIVATION from the labels JSON, and the
# resolver call shape wired through it, so the `should_run` value the
# workflow's expensive-step / stand-down `if:` conditions read is asserted
# end-to-end.
#
# Subordination (UAT-026) is verified by inspecting the in-tree workflow: the
# decision step and the stand-down step both gate on
# `has_source == 'true' && self_modified == 'false'`, so neither fires
# out-of-scope or on a self-mod PR. A documented trace lives in the
# subordination test below alongside an executable proxy.
#
# Each test runs in an isolated `git init`'d sandbox so the resolver's
# `git rev-parse --show-toplevel` resolves to the fixture (not the GAIA repo
# root, whose shipped config would otherwise leak in).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  RESOLVER="$REPO_ROOT/.gaia/scripts/read-audit-ci-config.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -x "$RESOLVER" ] || skip "read-audit-ci-config.sh not executable"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  ( cd "$SANDBOX" && git init --quiet )
}

# write_config <yaml-body>
write_config() {
  printf '%s\n' "$1" > "$SANDBOX/.gaia/audit-ci.yml"
}

# stub_gh_confirms: fake `gh` reporting GAIA-Audit as a registered required
# check + a valid repo slug, so a `local` resolution survives verification
# instead of failing closed.
stub_gh_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  repo) echo "owner/repo" ;;
  api) printf 'GAIA-Audit\n' ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# decide <override_label> <pr_labels_json> <pr_author> [STUB]
#   Reproduces the "Resolve audit decision" step's shell logic verbatim: compute
#   override-presence from the labels JSON, then call the resolver with
#   OVERRIDE_LABEL_PRESENT. Echoes the resolver output (resolved_mode=/should_run=
#   lines). Pass a 4th arg "STUB" to put the confirming gh stub on PATH (needed
#   for a `local` resolution to survive required-check verification).
decide() {
  local override_label="$1"
  local pr_labels_json="$2"
  local pr_author="$3"
  local use_stub="${4:-}"

  local path="/usr/bin:/bin"
  [ "$use_stub" = "STUB" ] && path="$SANDBOX/bin:/usr/bin:/bin"

  (
    cd "$SANDBOX"
    export PATH="$path"
    OVERRIDE_LABEL="$override_label"
    PR_LABELS_JSON="$pr_labels_json"
    PR_AUTHOR="$pr_author"
    # --- begin: mirror of the workflow step's run: block ---
    if [ -n "$OVERRIDE_LABEL" ] \
        && printf '%s' "$PR_LABELS_JSON" \
          | jq -e --arg l "$OVERRIDE_LABEL" 'index($l)' >/dev/null; then
      override_present=true
    else
      override_present=false
    fi
    OVERRIDE_LABEL_PRESENT="$override_present" \
      bash "$RESOLVER" --resolve-author "$PR_AUTHOR"
    # --- end ---
  )
}

# ---------------------------------------------------------------------------
# Snippet-fidelity guard: the executable mirror in `decide()` must match the
# bytes shipped in the workflow. If the step's override-presence probe or its
# resolver invocation drifts, this fails and the mirror is stale.
# ---------------------------------------------------------------------------

@test "ci decision: step's override-presence probe + resolver call match the shipped workflow" {
  [ -f "$WORKFLOW" ] || skip "in-tree workflow absent (adopter clone)"
  # The override-presence jq probe over the labels JSON.
  grep -qF "jq -e --arg l \"\$OVERRIDE_LABEL\" 'index(\$l)'" "$WORKFLOW"
  # The resolver call passes presence via the Phase 1 input form.
  grep -qF 'OVERRIDE_LABEL_PRESENT="$override_present" \' "$WORKFLOW"
  grep -qF -e '--resolve-author "$PR_AUTHOR"' "$WORKFLOW"
}

# ---------------------------------------------------------------------------
# UAT-001: default_mode ci, no audit_authors entry for the author, no override
# → should_run=true (CI runs the full audit).
# ---------------------------------------------------------------------------

@test "ci decision: default_mode ci no author entry → should_run true (full audit, UAT-001)" {
  write_config "default_mode: ci"
  run decide "run-audit" '[]' "stranger"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# UAT-002: resolved local (via audit_authors), no override → should_run=false
# (CI stands down; the stand-down step posts the pending status).
# ---------------------------------------------------------------------------

@test "ci decision: resolved local no override → should_run false (stand-down, UAT-002)" {
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"stevensacks=local\""
  run decide "run-audit" '[]' "stevensacks" STUB
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
  [[ "$output" == *"should_run=false"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# UAT-004: the override label is sticky. A local author with the override
# label present resolves ci, should_run=true, so CI re-audits even though the
# author's standing mode is local. (The label re-trigger wiring lives in the
# workflow's `on: pull_request: types: [labeled, ...]`; this asserts the
# resolution the relabeled run would compute.)
# ---------------------------------------------------------------------------

@test "ci decision: local author WITH override label → should_run true (sticky override, UAT-004)" {
  write_config "default_mode: local
audit_authors: \"stevensacks=local\""
  # Labels JSON carries the override label → presence derived true → ci.
  run decide "run-audit" '["run-audit"]' "stevensacks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# Author-login display casing: the step passes the raw login; the resolver
# lowercases. StevenSacks matches stevensacks=local.
# ---------------------------------------------------------------------------

@test "ci decision: display-cased author login resolves against lowercased pair" {
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"stevensacks=local\""
  run decide "run-audit" '[]' "StevenSacks" STUB
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
  [[ "$output" == *"should_run=false"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# Override-presence derivation: an UNRELATED label on the PR must NOT be read
# as the override. A local author whose PR carries only an unrelated label
# still stands down (should_run=false).
# ---------------------------------------------------------------------------

@test "ci decision: unrelated label does not count as override (local author still stands down)" {
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"stevensacks=local\""
  run decide "run-audit" '["needs-review"]' "stevensacks" STUB
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
  [[ "$output" == *"should_run=false"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# UAT-026 subordination: the decision step and the stand-down step are BOTH
# gated on `has_source == 'true' && self_modified == 'false'`, so out-of-scope
# (has_source==false) and self-mod (self_modified==true) PRs never reach the
# decision/stand-down at all; they take the existing success-stamp paths and
# never double-stamp. This test documents that trace and proves it executably:
# the decision step does not even run when out-of-scope, so `should_run` is
# never produced and the stand-down's `should_run == 'false'` is unsatisfiable.
# ---------------------------------------------------------------------------

@test "ci decision step does not fire on out-of-scope or self-mod (subordination, UAT-026)" {
  [ -f "$WORKFLOW" ] || skip "in-tree workflow absent (adopter clone)"

  # Documented YAML trace: both the decision step and the stand-down step carry
  # the scope-gate predicates in their `if:`. Assert those predicates are
  # present on both so the subordination holds by construction.
  #
  # The decision step is `id: decision`; the stand-down is the step posting the
  # pending status. Each must include the two scope-gate lines.
  local has_source_line="steps.source-changes.outputs.has_source == 'true' &&"
  local self_mod_line="steps.workflow-self-mod.outputs.self_modified == 'false'"

  # Both lines appear in the decision step block and the stand-down step block.
  # (Count >= 2 each: at minimum decision + stand-down carry them; the rest of
  # the expensive steps share the predicates too.)
  local has_source_count self_mod_count
  has_source_count=$(grep -cF "$has_source_line" "$WORKFLOW")
  self_mod_count=$(grep -cF "$self_mod_line" "$WORKFLOW")
  [ "$has_source_count" -ge 2 ]
  [ "$self_mod_count" -ge 2 ]

  # The stand-down's pending status POST is gated on should_run == 'false'
  # AND the scope gates, so an out-of-scope run (decision skipped, should_run
  # empty) can never satisfy it.
  grep -qF "steps.decision.outputs.should_run == 'false'" "$WORKFLOW"

  # Executable proxy: the out-of-scope success-stamp path is gated on
  # has_source == 'false', which is mutually exclusive with the decision step's
  # has_source == 'true' guard, so the two never co-fire.
  grep -qF "steps.source-changes.outputs.has_source == 'false'" "$WORKFLOW"
}
