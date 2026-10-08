#!/usr/bin/env bats
# Conformance suite for .claude/hooks/lib/gaia-packages.sh, the bash reader of
# the package registry (.gaia/packages.json) and per-package descriptors
# (<path>/gaia.package.json), SPEC-092 contract C1 to C4.
#
# One of three implementations of one contract. The Node twin
# (.gaia/scripts/lib/gaia-packages.mjs) and the TypeScript twin
# (.gaia/cli/src/util/packages.ts) are driven over the SAME corpus by
# .gaia/cli/src/util/gaia-packages-mjs.test.ts and packages.test.ts, so a corpus
# edit that one implementation disagrees with fails there. This file is the bash
# half. It lives in a seam directory so the bats sharder runs it (S13).
#
# Corpus layout, .gaia/tests/fixtures/gaia-packages/<case>/: an optional
# packages.json (installed as .gaia/packages.json), optional descriptor files at
# their package paths, and expected.json. Assertion style:
# .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LIBRARY="$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh"
  CORPUS="$REPO_ROOT/.gaia/tests/fixtures/gaia-packages"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  [ -f "$LIBRARY" ] || skip "gaia-packages.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

# materialize <corpus-case-dir> <repo-root>: copy the case into a fresh repo
# root, installing packages.json as .gaia/packages.json and dropping the oracle.
materialize() {
  mkdir -p "$2/.gaia"
  cp -R "$1/." "$2/"
  rm -f "$2/expected.json"
  if [ -f "$2/packages.json" ]; then
    mv "$2/packages.json" "$2/.gaia/packages.json"
  fi
}

# check_case <expected.json> <repo-root>: print one line per disagreement with
# the oracle and return 1 when there is any. Runs the library in this shell.
check_case() {
  local expected="$1" root="$2" status=0 want_load want_error got failures=0
  local key candidate want_dir ere line field_a field_b
  local sep=$'\037'

  # A previous case's state must not survive: the library resets on every load.
  gaia_packages_load "$root" || status=$?
  want_load=$(jq -r '.load' "$expected")
  if [ "$status" != "$want_load" ]; then
    echo "load: want $want_load, got $status ($GAIA_PACKAGES_ERROR)"
    return 1
  fi
  if [ "$want_load" != 0 ]; then
    want_error=$(jq -r '.error' "$expected")
    if [ "$GAIA_PACKAGES_ERROR" != "$want_error" ]; then
      echo "error text: want [$want_error], got [$GAIA_PACKAGES_ERROR]"
      failures=1
    fi
    # A failed load must answer as if nothing were loaded.
    if [ -n "$(gaia_packages_list)" ] || [ -n "$(gaia_package_globs_ere tddUnitTests)" ]; then
      echo "failed load left state behind"
      failures=1
    fi
    [ "$failures" = 0 ]
    return
  fi

  got=$(gaia_packages_source)
  if [ "$got" != "$(jq -r '.source' "$expected")" ]; then
    echo "source: got $got"
    failures=1
  fi
  got=$(gaia_packages_list)
  if [ "$got" != "$(jq -r '.list | map(join("\t")) | .[]' "$expected")" ]; then
    echo "list: got [$got]"
    failures=1
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ere=$(gaia_package_globs_ere "$key")
    if [ "$(jq -r --arg k "$key" '.globs[$k].empty // false' "$expected")" = true ]; then
      if [ -n "$ere" ]; then
        echo "$key: want empty ERE, got [$ere]"
        failures=1
      fi
      continue
    fi
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [[ $candidate =~ $ere ]] || {
        echo "$key: want match for [$candidate] under [$ere]"
        failures=1
      }
    done < <(jq -r --arg k "$key" '.globs[$k].match[]?' "$expected")
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if [[ $candidate =~ $ere ]]; then
        echo "$key: want NO match for [$candidate] under [$ere]"
        failures=1
      fi
    done < <(jq -r --arg k "$key" '.globs[$k].noMatch[]?' "$expected")
  done < <(jq -r '.globs // {} | keys[]' "$expected")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    field_a="${line%%"$sep"*}"
    field_b="${line#*"$sep"}"
    got=$(gaia_package_for_path "$field_a")
    if [ "$got" != "$field_b" ]; then
      echo "for_path [$field_a]: want [$field_b], got [$got]"
      failures=1
    fi
  done < <(jq -r '.forPath // {} | to_entries[] | .key + "\u001f" + .value' "$expected")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    field_a="${line%%"$sep"*}"
    want_dir="${line#*"$sep"}"
    if got=$(gaia_package_dir "$field_a"); then
      [ "$got" = "$want_dir" ] || {
        echo "dir [$field_a]: want [$want_dir], got [$got]"
        failures=1
      }
    else
      [ "$want_dir" = "-null-" ] || {
        echo "dir [$field_a]: want [$want_dir], got unknown"
        failures=1
      }
    fi
  done < <(jq -r '.dir // {} | to_entries[] | .key + "\u001f" + (.value // "-null-")' "$expected")

  [ "$failures" = 0 ]
}

@test "corpus: every case's expected answers hold for the bash reader" {
  . "$LIBRARY"
  local case_directory case_name checked=0 failed=0 report
  for case_directory in "$CORPUS"/*/; do
    case_name="$(basename "$case_directory")"
    [ -f "$case_directory/expected.json" ] || {
      echo "case $case_name has no expected.json"
      failed=$((failed + 1))
      continue
    }
    materialize "$case_directory" "$BATS_TEST_TMPDIR/$case_name"
    if report=$(check_case "$case_directory/expected.json" "$BATS_TEST_TMPDIR/$case_name"); then
      :
    else
      echo "FAIL $case_name:"
      echo "$report"
      failed=$((failed + 1))
    fi
    checked=$((checked + 1))
  done
  # The floor keeps an emptied or mis-pathed corpus from passing vacuously.
  [ "$checked" -ge 35 ] || {
    echo "only $checked corpus cases found"
    return 1
  }
  [ "$failed" = 0 ]
}

@test "corpus: the check itself fails on a wrong expectation (guard can fail)" {
  . "$LIBRARY"
  local root="$BATS_TEST_TMPDIR/mutant" expected="$BATS_TEST_TMPDIR/expected.json"
  materialize "$CORPUS/path-frontend" "$root"

  # Control: the untouched oracle passes, so the failures below are the mutants'.
  check_case "$CORPUS/path-frontend/expected.json" "$root"

  # A glob that must match, claimed not to.
  jq '.globs.tddUnitTests.noMatch += ["frontend/app/x.test.ts"]' \
    "$CORPUS/path-frontend/expected.json" >"$expected"
  run check_case "$expected" "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"want NO match"* ]]

  # A load status that is not the real one.
  jq '.load = 3 | .error = "x"' "$CORPUS/path-frontend/expected.json" >"$expected"
  run check_case "$expected" "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"load: want 3, got 0"* ]]

  # An owner that is not the real one.
  jq '.forPath["frontend/app/x.ts"] = "ios"' "$CORPUS/path-frontend/expected.json" >"$expected"
  run check_case "$expected" "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"for_path"* ]]
}

@test "malformed registry: load returns 2, names the file and the next step, never 0" {
  . "$LIBRARY"
  materialize "$CORPUS/registry-malformed-json" "$BATS_TEST_TMPDIR/r"
  local status=0
  gaia_packages_load "$BATS_TEST_TMPDIR/r" || status=$?
  [ "$status" -ne 0 ]
  [ "$status" -eq 2 ]
  [[ "$GAIA_PACKAGES_ERROR" =~ ^gaia-packages:\ .*\.gaia/packages\.json\ is\ malformed.*Next\ step:\  ]]
  # The answers are empty, not stale.
  [ -z "$(gaia_package_globs_ere selfHealRefuse)" ]
}

@test "missing descriptor: load returns 3 naming the descriptor path, never 0" {
  . "$LIBRARY"
  materialize "$CORPUS/descriptor-missing" "$BATS_TEST_TMPDIR/r"
  local status=0
  gaia_packages_load "$BATS_TEST_TMPDIR/r" || status=$?
  [ "$status" -ne 0 ]
  [ "$status" -eq 3 ]
  [[ "$GAIA_PACKAGES_ERROR" == *"frontend/gaia.package.json is missing"* ]]
  [[ "$GAIA_PACKAGES_ERROR" == *"Next step: "* ]]
}

@test "a failed load after a good one clears the earlier answers" {
  . "$LIBRARY"
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/good"
  materialize "$CORPUS/registry-malformed-json" "$BATS_TEST_TMPDIR/bad"
  gaia_packages_load "$BATS_TEST_TMPDIR/good"
  [ -n "$(gaia_package_globs_ere tddUnitTests)" ]
  local status=0
  gaia_packages_load "$BATS_TEST_TMPDIR/bad" || status=$?
  [ "$status" -eq 2 ]
  [ -z "$(gaia_package_globs_ere tddUnitTests)" ]
  [ -z "$(gaia_packages_list)" ]
  [ -z "$(gaia_packages_source)" ]
}

@test "jq unavailable: load returns 4 naming jq, never 0" {
  local shimmed_path
  shimmed_path="$(path_shim_without jq)"
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/r"
  PATH="$shimmed_path" run bash -c 'command -v jq && exit 99
    . "$1"; status=0; gaia_packages_load "$2" || status=$?
    printf "%s\n" "$status" "$GAIA_PACKAGES_ERROR"' _ "$LIBRARY" "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 4 ]
  [[ "${lines[1]}" == *jq* ]]
  [[ "${lines[1]}" == *"Next step: "* ]]
}

@test "jq unavailable: an absent registry does not fall back to the built-in default" {
  local shimmed_path
  shimmed_path="$(path_shim_without jq)"
  mkdir -p "$BATS_TEST_TMPDIR/empty-root"
  PATH="$shimmed_path" run bash -c '. "$1"; status=0; gaia_packages_load "$2" || status=$?
    printf "%s\n" "$status"; gaia_package_globs_ere tddUnitTests' _ "$LIBRARY" "$BATS_TEST_TMPDIR/empty-root"
  [ "${lines[0]}" = 4 ]
  [ -z "${lines[1]:-}" ]
}

@test "registry absent: source is builtin, frontend/app matches and root app does not" {
  . "$LIBRARY"
  mkdir -p "$BATS_TEST_TMPDIR/absent"
  gaia_packages_load "$BATS_TEST_TMPDIR/absent"
  [ "$(gaia_packages_source)" = builtin ]
  local ere
  ere="$(gaia_package_globs_ere tddUnitTests)"
  [[ "frontend/app/utils/x.test.ts" =~ $ere ]]
  [[ "app/utils/x.test.ts" =~ $ere ]] && return 1
  true
}

@test "literal registry at path . with a literal descriptor: root app matches, frontend/app does not" {
  . "$LIBRARY"
  materialize "$CORPUS/path-dot" "$BATS_TEST_TMPDIR/dot"
  gaia_packages_load "$BATS_TEST_TMPDIR/dot"
  [ "$(gaia_packages_source)" = registry ]
  local ere
  ere="$(gaia_package_globs_ere tddUnitTests)"
  [[ "app/utils/x.test.ts" =~ $ere ]]
  [[ "frontend/app/utils/x.test.ts" =~ $ere ]] && return 1
  true
}

@test "built-in descriptor equals the committed descriptor located through the committed registry" {
  . "$LIBRARY"
  local package_path committed
  package_path="$(jq -r '.[] | select(.name == "frontend") | .path' "$REPO_ROOT/.gaia/packages.json")"
  [ -n "$package_path" ]
  if [ "$package_path" = . ]; then
    committed="$REPO_ROOT/gaia.package.json"
  else
    committed="$REPO_ROOT/$package_path/gaia.package.json"
  fi
  [ -f "$committed" ]
  [ "$(jq -S . "$committed")" = "$(_gaia_packages_builtin_descriptor | jq -S .)" ]
}

@test "the committed descriptor loads clean through the committed registry" {
  . "$LIBRARY"
  local status=0
  gaia_packages_load "$REPO_ROOT" || status=$?
  [ "$status" -eq 0 ]
  [ "$(gaia_packages_source)" = registry ]
}

@test "the built-in registry is the frontend package at frontend" {
  . "$LIBRARY"
  [ "$(_gaia_packages_builtin_registry | jq -c .)" = '[{"name":"frontend","path":"frontend"}]' ]
}

@test "hostile registry path is malformed (2) and runs nothing" {
  . "$LIBRARY"
  local root="$BATS_TEST_TMPDIR/hostile" marker="$BATS_TEST_TMPDIR/pwned" status=0
  mkdir -p "$root/.gaia"
  jq -n --arg p "frontend\"; touch $marker" '[{name: "frontend", path: $p}]' >"$root/.gaia/packages.json"
  gaia_packages_load "$root" || status=$?
  [ "$status" -eq 2 ]
  [ ! -e "$marker" ]
}

@test "hostile descriptor glob is data: it compiles to an ERE and runs nothing" {
  . "$LIBRARY"
  local root="$BATS_TEST_TMPDIR/hostile-glob" marker="$BATS_TEST_TMPDIR/pwned-glob" status=0
  materialize "$CORPUS/path-frontend" "$root"
  jq --arg g "\$(touch $marker)" '.globs.doctorConfigs = [$g]' \
    "$root/frontend/gaia.package.json" >"$root/frontend/next.json"
  mv "$root/frontend/next.json" "$root/frontend/gaia.package.json"
  gaia_packages_load "$root" || status=$?
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "an unknown glob key returns 1" {
  . "$LIBRARY"
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/r"
  gaia_packages_load "$BATS_TEST_TMPDIR/r"
  local status=0
  gaia_package_globs_ere noSuchKey >/dev/null || status=$?
  [ "$status" -eq 1 ]
}

@test "the library is safe under set -euo pipefail with unset caller state" {
  materialize "$CORPUS/path-frontend" "$BATS_TEST_TMPDIR/r"
  run bash -c 'set -euo pipefail; . "$1"; status=0; gaia_packages_load "$2" || status=$?
    [ "$status" -eq 0 ]; gaia_package_for_path frontend/app/x.ts; gaia_package_dir nope || true' _ "$LIBRARY" "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  [ "$output" = frontend ]
}
