#!/usr/bin/env bash
# Drives the spec-lifecycle script sequence the spec authoring flow runs (reconcile, the three
# archive sweeps, allocator, session lock, title normalize, ledger update, lint) against a scratch
# repo and writes one TSV line per command plus the observable effects.
#
# Usage: run.sh --lib-dir <repo-relative spec-lib dir> --out <file>
#
# Exit codes alone cannot prove a relocated script still loads its siblings: those loads are
# written fail-open and spec-reconcile.sh exits 0 even when its branch-name library failed to
# load. The effect lines (ledger statuses, lint JSON) are what catch that.
set -euo pipefail

library_directory=""
output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lib-dir) library_directory="${2:-}"; shift 2 ;;
    --out) output_file="${2:-}"; shift 2 ;;
    *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$library_directory" ] || [ -z "$output_file" ]; then
  echo "usage: run.sh --lib-dir <repo-relative spec-lib dir> --out <file>" >&2
  exit 2
fi

fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_repo="$(git -C "$fixture_root" rev-parse --show-toplevel)"
fixture_directory="${fixture_root}/fixture"

setup_failed() {
  echo "run.sh: setup failed at step '$1'" >&2
  exit 1
}

# Run the helper, never source it: sourcing would apply its errexit, its cd, and its flag parser
# to this runner.
scratch_repo="$(bash "${real_repo}/.gaia/tests/lib/helpers/tmp-spec-repo.sh")" || setup_failed "build scratch repo"
stub_directory="$(mktemp -d)"
trap 'rm -rf "$scratch_repo" "$stub_directory"' EXIT

# The helper copies only the scripts its own suites need; copy every other script of the library
# (never a symlink, so ${BASH_SOURCE[0]}-relative loads resolve inside the scratch repo).
mkdir -p "${scratch_repo}/${library_directory}"
for library_script in "${real_repo}/${library_directory}"/*.sh; do
  if [ ! -e "${scratch_repo}/${library_directory}/$(basename "$library_script")" ]; then
    cp "$library_script" "${scratch_repo}/${library_directory}/" || setup_failed "copy library script"
  fi
done

merged_branch="$(bash "${real_repo}/.gaia/scripts/branch-name-lib.sh" name plan spec-001 --type refactor --slug "pin saved articles")" \
  || setup_failed "mint merged branch name"

# Seed the committed fixture: the ledger, the saved SPEC, and the branch merged into main.
cp "${fixture_directory}/ledger.json" "${scratch_repo}/.gaia/local/specs/ledger.json"
mkdir -p "${scratch_repo}/.gaia/local/specs/SPEC-002"
cp "${fixture_directory}/SPEC.md" "${scratch_repo}/.gaia/local/specs/SPEC-002/SPEC.md"
git -C "$scratch_repo" add -A
git -C "$scratch_repo" commit --quiet -m "seed fixture" || setup_failed "record fixture"
git -C "$scratch_repo" checkout --quiet -b "$merged_branch"
printf 'pinned\n' > "${scratch_repo}/pinned.txt"
git -C "$scratch_repo" add pinned.txt
git -C "$scratch_repo" commit --quiet -m "implement" || setup_failed "record merged branch"
git -C "$scratch_repo" checkout --quiet main
git -C "$scratch_repo" merge --quiet --no-ff -m "merge" "$merged_branch" || setup_failed "merge branch"

cat > "${stub_directory}/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' '[{"number":42,"headRefName":"${merged_branch}","mergedAt":"2026-05-01T00:00:00Z"}]'
STUB
chmod +x "${stub_directory}/gh"

export PATH="${stub_directory}:${PATH}"
export GAIA_SPEC_FORCE_OFFLINE=1
# The lock records the session-lifetime host process; point the host match at this runner so the
# result does not depend on whether a real CLI process sits above it.
export GAIA_SPEC_LOCK_HOST_PATTERN='run\.sh --lib-dir'

lib="${scratch_repo}/${library_directory}"
: > "$output_file"
standard_output=""

# step <label> <stdin-file|-> <command...>: record the exit status and whether a load failed with
# "No such file or directory"; leaves the command's stdout in $standard_output.
step() {
  local label="$1" input="$2" status error_file missing=no
  shift 2
  error_file="$(mktemp)"
  if [ "$input" = "-" ]; then
    input=/dev/null
  fi
  standard_output="$("$@" 2>"$error_file" < "$input")" && status=0 || status=$?
  if grep -q 'No such file or directory' "$error_file"; then
    missing=yes
  fi
  rm -f "$error_file"
  printf '%s\t%s\t%s\n' "$label" "$status" "$missing" >> "$output_file"
}

effect() {
  printf 'effect\t%s\t%s\n' "$1" "$2" >> "$output_file"
}

ledger_status() {
  jq -r --arg id "$1" '.specs[] | select(.id == $id) | .status' "${scratch_repo}/.gaia/local/specs/ledger.json"
}

cd "$scratch_repo"

step reconcile - bash "${lib}/spec-reconcile.sh" "$scratch_repo"
step archive-merged - bash "${lib}/spec-archive-merged.sh" "$scratch_repo"
step archive-abandoned - bash "${lib}/spec-archive-abandoned.sh" "$scratch_repo"
step abandon-empty - bash "${lib}/spec-abandon-empty.sh" "$scratch_repo"
step allocator-in-progress - bash "${lib}/spec-allocator.sh" in_progress "$scratch_repo"
effect in-progress "$standard_output"
step allocator-next - bash "${lib}/spec-allocator.sh" next "$scratch_repo" "Pin saved articles"
allocated_id="$standard_output"
effect allocated "$allocated_id"
step lock-acquire - bash "${lib}/spec-session-lock.sh" acquire "$scratch_repo" "$allocated_id"
step lock-status - bash "${lib}/spec-session-lock.sh" status "$scratch_repo" "$allocated_id"
effect lock-status "$standard_output"
step lock-release - bash "${lib}/spec-session-lock.sh" release "$scratch_repo" "$allocated_id"

intent_file="$(mktemp)"
printf 'A signed-in reader can pin a saved article so it stays at the top of their reading list across devices.' > "$intent_file"
step title-normalize "$intent_file" bash "${lib}/title-normalize.sh"
rm -f "$intent_file"
intent="$standard_output"
effect intent "$intent"
patch="$(jq -nc --arg intent "$intent" '{status: "ready"} + (if $intent == "" then {} else {intent: $intent} end)')"
step ledger-update - bash "${lib}/ledger-update.sh" "$scratch_repo" SPEC-002 "$patch"
step lint - bash "${lib}/lint.sh" "${scratch_repo}/.gaia/local/specs/SPEC-002/SPEC.md"
lint_json="$(printf '%s' "$standard_output" | tr -d '\n')"

effect reconcile-row "$(ledger_status SPEC-001)"
effect saved-row "$(ledger_status SPEC-002)"
effect ghost-row "$(ledger_status SPEC-004)"
effect lint "$lint_json"
