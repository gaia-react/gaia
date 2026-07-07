#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/spec-reconcile.sh` (the spec arm; see
# plan-reconcile.bats for the plan arm). Uses helpers/tmp-spec-repo.sh, which
# already copies spec-reconcile.sh + ledger-update.sh + with-ledger-lock.sh
# into a real tmp git repo so ${BASH_SOURCE[0]}-relative sourcing resolves and
# `git -C <repo> rev-parse --git-dir` succeeds.
#
# The helper's seed flags cover draft/in-progress/merged rows but have no
# --seed-ready flag, so the "ready" row these tests need (the candidate
# status the guard's finalize transition now writes) is seeded by
# jq-patching the ledger directly after --seed-inprogress.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  RECONCILE=".specify/extensions/gaia/lib/spec-reconcile.sh"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
  if [ -n "${STUB_DIR:-}" ]; then
    rm -rf "$STUB_DIR"
  fi
  if [ -n "${NO_GH_PATH:-}" ]; then
    rm -rf "$NO_GH_PATH"
  fi
}

# Promotes the SPEC-006 row (seeded in-progress by the helper) to "ready",
# the finalize state these tests exercise.
_promote_to_ready() {
  local id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$id" \
    '(.specs[] | select(.id == $id) | .status) = "ready"' \
    "$REPO/.gaia/local/specs/ledger.json" > "$tmp"
  mv "$tmp" "$REPO/.gaia/local/specs/ledger.json"
}

_status_of() {
  jq -r --arg id "$1" '.specs[] | select(.id == $id) | .status' \
    "$REPO/.gaia/local/specs/ledger.json"
}

# Builds a `gh` stub on a temp PATH prefix that unconditionally echoes $1 to
# stdout (spec-reconcile.sh invokes gh in exactly one shape: `gh pr list
# --state merged --limit 200 --json number,headRefName,mergedAt`).
_stub_gh_echoing() {
  local body="$1"
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$body'
EOF
  chmod +x "$STUB_DIR/gh"
}

# Builds a `gh` stub that exits 0 with no stdout (the "gh returns empty" fail-
# open case, distinct from gh being altogether absent from PATH).
_stub_gh_empty() {
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUB_DIR/gh"
}

# A PATH with every tool spec-reconcile.sh (and its ledger-update.sh /
# with-ledger-lock.sh deps) actually invokes, symlinked in from the real
# PATH, but with no `gh` anywhere on it.
_no_gh_path() {
  NO_GH_PATH="$(mktemp -d)"
  local cmd real
  for cmd in bash jq git sed mktemp mv rm mkdir rmdir stat date sleep; do
    real="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "$NO_GH_PATH/$cmd"
  done
}

# --- 6: matching merged PR flips SPEC-006 to merged with merged_at from the PR ---
@test "6: gh returns a merged PR matching spec-006-*; SPEC-006 flips to merged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-006)"
  _promote_to_ready SPEC-006
  _stub_gh_echoing '[{"number":42,"headRefName":"spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]'

  run bash -c "PATH='$STUB_DIR:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  grep -qF "reconciled SPEC-006 -> merged (PR #42, 2026-05-01T00:00:00Z)" <<<"$output"
  [ "$(_status_of SPEC-006)" = "merged" ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-006") | .merged_at' "$REPO/.gaia/local/specs/ledger.json")" = "2026-05-01T00:00:00Z" ]
}

# --- 7: no matching merged PR; SPEC-006 stays ready, no-op ---
@test "7: no matching merged PR; SPEC-006 stays ready, no-op, exit 0" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-006)"
  _promote_to_ready SPEC-006
  # A merged PR exists, but its head branch does not match spec-006-*.
  _stub_gh_echoing '[{"number":7,"headRefName":"spec-999-other","mergedAt":"2026-05-01T00:00:00Z"}]'

  run bash -c "PATH='$STUB_DIR:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  [ "$(_status_of SPEC-006)" = "ready" ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-006") | has("merged_at")' "$REPO/.gaia/local/specs/ledger.json")" = "false" ]
}

# --- 8: fail-open; no gh on PATH, or gh present but returns empty ---
@test "8a: gh absent from PATH; exit 0, ledger unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-006)"
  _promote_to_ready SPEC-006
  before="$(cat "$REPO/.gaia/local/specs/ledger.json")"
  _no_gh_path

  run bash -c "PATH='$NO_GH_PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  after="$(cat "$REPO/.gaia/local/specs/ledger.json")"
  [ "$before" = "$after" ]
}

@test "8b: gh present but returns empty output; exit 0, ledger unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-006)"
  _promote_to_ready SPEC-006
  before="$(cat "$REPO/.gaia/local/specs/ledger.json")"
  _stub_gh_empty

  run bash -c "PATH='$STUB_DIR:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  after="$(cat "$REPO/.gaia/local/specs/ledger.json")"
  [ "$before" = "$after" ]
}

# --- 9: a retired 'specified' row is off-vocab, never a merge candidate ---
@test "9: a retired 'specified' row is not a merge candidate; logged unrecognized, left as-is" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-006)"
  tmp="$(mktemp)"
  jq '(.specs[] | select(.id == "SPEC-006") | .status) = "specified"' \
    "$REPO/.gaia/local/specs/ledger.json" > "$tmp"
  mv "$tmp" "$REPO/.gaia/local/specs/ledger.json"
  # A matching merged PR exists, but a "specified" row is off-vocabulary now
  # (the finalize state migrated to "ready"), so it is never reached as a
  # candidate; the off-vocab normalizer logs it as unrecognized instead.
  _stub_gh_echoing '[{"number":42,"headRefName":"spec-006-x","mergedAt":"2026-05-01T00:00:00Z"}]'

  run bash -c "PATH='$STUB_DIR:$PATH' bash '$REPO/$RECONCILE' '$REPO'"
  [ "$status" -eq 0 ]
  grep -qF "unrecognized status specified" <<<"$output"
  [ "$(_status_of SPEC-006)" = "specified" ]
}
