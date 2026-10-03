#!/usr/bin/env bats
# The 2.0.0 release fence (SPEC-092 contracts C9 and C10).
#
# v1.6.1's /update-gaia downloads with `--pattern "gaia-${tag}.tar.gz"`. The 2.x
# manifest is keyed on frontend/ paths, so a 1.6.1 merge against it would read
# every baseline app path as an upstream deletion. The fence is the asset name:
# 2.x publishes `gaia-bundle-${TAG}.tar.gz`, which that glob cannot match, so
# 1.6.1 stops at its fetch step before it writes anything.
#
#   A1-A4  the asset name in release.yml, the 2.x /update-gaia pattern, and the
#          glob semantics that make the fence hold. A2 and A3 drive the failing
#          state: the retired name is matched by v1.6.1's pattern, and a
#          pattern that drifts from the upload name is reported.
#   B1-B4  the 1.x baseline refusal in SKILL.md Step 3b.
#   C1-C5  .gaia/scripts/compose-release-body.sh, which puts the routing line
#          first in the release body.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep, `case` for glob matching.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
  SKILL="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md"
  MERGE_EXECUTION="$REPO_ROOT/.claude/skills/update-gaia/references/merge-execution.md"
  COMPOSE="$REPO_ROOT/.gaia/scripts/compose-release-body.sh"
  ROUTING_LINE='On GAIA 1.6.1? Choose Abort, then paste the prompt from https://gaiareact.com/migrate into a fresh session.'
}

# The first argument of the `gh release create` call in a workflow file: the
# tarball name the release uploads, as a template with ${TAG} left unexpanded.
uploaded_asset_name() {
  awk '
    /^[[:space:]]*gh release create / { armed = 1; next }
    armed { gsub(/^[[:space:]]+/, ""); sub(/[[:space:]]*\\$/, ""); gsub(/"/, ""); print; exit }
  ' "$1"
}

# The --pattern a /update-gaia Step 5 download passes, with ${tag} left unexpanded.
update_pattern() {
  sed -n 's/^.*--pattern "\(gaia[^"]*\)".*$/\1/p' "$1" | head -n 1
}

# 0 when the glob `$1` (what `gh release download --pattern` evaluates) matches
# the file name `$2`.
glob_matches() {
  # The pattern is a glob on purpose: that is what `gh release download
  # --pattern` evaluates.
  # shellcheck disable=SC2254
  case "$2" in
    $1) return 0 ;;
  esac
  return 1
}

# The fenced bash block that follows the heading line `$2` in file `$1`.
block_after_heading() {
  awk -v heading="$2" '
    index($0, heading) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

@test "A1: release.yml uploads gaia-bundle-<tag>.tar.gz and its sha256" {
  name="$(uploaded_asset_name "$RELEASE_YML")"
  [ "$name" = 'gaia-bundle-${TAG}.tar.gz' ]
  grep -qF -- 'gaia-bundle-${TAG}.tar.gz.sha256' "$RELEASE_YML"
  grep -qF -- 'shasum -a 256' "$RELEASE_YML"
  # The retired name must not survive as a tar or upload target.
  grep -qE -- '"gaia-\$\{TAG\}\.tar\.gz"' "$RELEASE_YML" && return 1
  true
}

@test "A2: v1.6.1's pattern cannot match the 2.x asset, and can match the retired name" {
  TAG=v2.0.0
  new_name="gaia-bundle-${TAG}.tar.gz"
  v1_pattern="gaia-${TAG}.tar.gz"
  glob_matches "$v1_pattern" "$new_name" && return 1
  # Control: the same matcher on the retired name matches, so a pass above is
  # the name's doing and not a matcher that never matches anything.
  glob_matches "$v1_pattern" "gaia-${TAG}.tar.gz"
}

@test "A3: a release.yml that still uploads the retired name is reported" {
  fixture="$BATS_TEST_TMPDIR/old-release.yml"
  sed 's/gaia-bundle-/gaia-/g' "$RELEASE_YML" > "$fixture"
  TAG=v2.0.0
  old_name="$(uploaded_asset_name "$fixture")"
  [ "$old_name" = 'gaia-${TAG}.tar.gz' ]
  expanded="gaia-${TAG}.tar.gz"
  # v1.6.1's pattern matches the retired upload: the failure the fence prevents.
  glob_matches "gaia-${TAG}.tar.gz" "$expanded"
  # And the real workflow's name is a different string.
  [ "$(uploaded_asset_name "$RELEASE_YML")" != "$old_name" ]
}

@test "A4: the /update-gaia Step 5 pattern equals the upload name, and drift is reported" {
  pattern="$(update_pattern "$MERGE_EXECUTION")"
  [ -n "$pattern" ]
  # Both templates name the tag differently (${tag} and ${TAG}); compare shapes.
  normalized_pattern="$(printf '%s' "$pattern" | sed 's/\${tag}/${TAG}/g')"
  [ "$normalized_pattern" = "$(uploaded_asset_name "$RELEASE_YML")" ]
  # Failing state: a pattern with the retired name reads as drift.
  drifted="$BATS_TEST_TMPDIR/merge-execution-drifted.md"
  sed 's/gaia-bundle-/gaia-/g' "$MERGE_EXECUTION" > "$drifted"
  drifted_pattern="$(update_pattern "$drifted" | sed 's/\${tag}/${TAG}/g')"
  [ "$drifted_pattern" != "$(uploaded_asset_name "$RELEASE_YML")" ]
}

@test "A5: the extracted tarball is read with --strip-components, so the staging directory name never shows" {
  grep -qF -- '--strip-components=1' "$MERGE_EXECUTION"
  grep -qF -- 'tar -czf "gaia-bundle-${TAG}.tar.gz" -C /tmp "gaia-${TAG}"' "$RELEASE_YML"
}

@test "B1: a 1.6.1 baseline is refused with the migrate pointer" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  [ -n "$block" ]
  run env BASELINE=1.6.1 bash -c "$block"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'https://gaiareact.com/migrate'
  printf '%s' "$output" | grep -qF 'REFUSED'
}

@test "B2: a 2.0.0 baseline proceeds silently" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  run env BASELINE=2.0.0 bash -c "$block"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "B3: a malformed baseline is refused, never read as proceed" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  for bad in '' 'v2.0.0' 'abc' '1x.0.0'; do
    run env BASELINE="$bad" bash -c "$block"
    [ "$status" -eq 1 ]
  done
}

@test "B4: the refusal block creates no branch and precedes the Step 4 branch creation" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  printf '%s' "$block" | grep -qF 'checkout -b' && return 1
  refusal_line="$(grep -n '^## Step 3b' "$SKILL" | head -n 1 | cut -d: -f1)"
  branch_line="$(grep -n 'git checkout -b' "$SKILL" | head -n 1 | cut -d: -f1)"
  [ -n "$refusal_line" ]
  [ -n "$branch_line" ]
  [ "$refusal_line" -lt "$branch_line" ]
}

@test "C1: the composed body starts with the routing line and carries the sha256" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.0.0] - 2026-10-03\n\n### Breaking\n\n%s\n\n- the entry\n' "$ROUTING_LINE" > "$notes"
  printf 'deadbeef  gaia-bundle-v2.0.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.0.0 "$notes" "$sha" "$out"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$out")" = "$ROUTING_LINE" ]
  grep -qF 'deadbeef  gaia-bundle-v2.0.0.tar.gz' "$out"
  grep -qF 'FETCH_FAILED' "$out"
  # The routing line appears once: hoisted, not duplicated.
  [ "$(grep -cxF -- "$ROUTING_LINE" "$out")" -eq 1 ]
  grep -qF '## [2.0.0] - 2026-10-03' "$out"
}

@test "C2: v2.0.0 notes without the routing line are refused" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.0.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  printf 'deadbeef  gaia-bundle-v2.0.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.0.0 "$notes" "$sha" "$out"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "C3: an empty sha256 file is refused" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.1.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  : > "$sha"
  run bash "$COMPOSE" v2.1.0 "$notes" "$sha" "$out"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "C4: a later release without the routing line gets the notes plus the sha256 line" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.1.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  printf 'cafe  gaia-bundle-v2.1.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.1.0 "$notes" "$sha" "$out"
  [ "$status" -eq 0 ]
  grep -qF 'sha256: cafe  gaia-bundle-v2.1.0.tar.gz' "$out"
  grep -qF -- '- the entry' "$out"
  grep -qF 'FETCH_FAILED' "$out" && return 1
  true
}

@test "C5: a wrong argument count is a usage error" {
  run bash "$COMPOSE" v2.0.0
  [ "$status" -eq 2 ]
}
