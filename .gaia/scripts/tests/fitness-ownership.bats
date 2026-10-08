#!/usr/bin/env bats
#
# Suite for .gaia/scripts/fitness-ownership.sh, the classifier /gaia-fitness
# runs before its heal phase to decide which files it may edit. Each class has
# a green case and a red twin: the same path with that class's evidence removed
# (the vendor pin, the ignore line, the manifest entry) lands in another class,
# so every rule is shown to decide the answer rather than merely agree with it.
# The fail-closed exits follow, because the caller heals nothing on a non-zero
# exit and a classifier that answered without its inputs would let it edit.
#
# Every test builds its own throwaway git repository. Set
# FITNESS_OWNERSHIP_SCRIPT to run the same assertions against a scratch copy.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/fitness-ownership.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${FITNESS_OWNERSHIP_SCRIPT:-$REPO_ROOT/.gaia/scripts/fitness-ownership.sh}"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT/.gaia/vendor" "$PROJECT/.claude/skills"
  git -C "$PROJECT" init -q
  write_manifest '{".claude/skills/gaia/references/fitness.md": "owned", "CLAUDE.md": "shared", "wiki/index.md": "wiki-owned", "frontend/.claude/skills/playwright-cli/SKILL.md": "owned"}'
  write_vendor_pin playwright-cli frontend/.claude/skills/playwright-cli
  printf '**/.claude/skills/react-doctor/\n' >"$PROJECT/.gitignore"
}

# write_manifest <files-object-json>: the project's .gaia/manifest.json.
write_manifest() {
  jq -n --argjson files "$1" '{version: "2.0.0", files: $files}' >"$PROJECT/.gaia/manifest.json"
}

# write_vendor_pin <name> <target>: a .gaia/vendor pin for one vendored tree.
write_vendor_pin() {
  jq -n --arg target "$2" '{package: "pkg", version: "1.0.0", target: $target, files: {}}' \
    >"$PROJECT/.gaia/vendor/$1.json"
}

classify() {
  run bash "$SCRIPT" --root "$PROJECT" "$@"
}

# class_of <path>: the class column of the output line for <path>.
class_of() {
  local line
  while IFS= read -r line; do
    if [ "${line#*$'\t'}" = "$1" ]; then
      printf '%s' "${line%%$'\t'*}"
      return 0
    fi
  done <<<"$output"
  return 1
}

# --- gaia-shipped ---

@test "gaia-shipped: a manifest owned path classifies gaia-shipped" {
  classify .claude/skills/gaia/references/fitness.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/gaia/references/fitness.md)" = "gaia-shipped" ]
}

@test "gaia-shipped: the manifest itself classifies gaia-shipped" {
  classify .gaia/manifest.json
  [ "$status" -eq 0 ]
  [ "$(class_of .gaia/manifest.json)" = "gaia-shipped" ]
}

@test "gaia-shipped red twin: without its manifest entry the same path classifies adopter" {
  write_manifest '{"CLAUDE.md": "shared"}'
  classify .claude/skills/gaia/references/fitness.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/gaia/references/fitness.md)" = "adopter" ]
}

# --- adopter ---

@test "adopter: a path the manifest does not list classifies adopter" {
  classify .claude/skills/deploy/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/deploy/SKILL.md)" = "adopter" ]
}

@test "adopter: shared and wiki-owned manifest paths classify adopter (GAIA seeds, the adopter customizes)" {
  classify CLAUDE.md wiki/index.md
  [ "$status" -eq 0 ]
  [ "$(class_of CLAUDE.md)" = "adopter" ]
  [ "$(class_of wiki/index.md)" = "adopter" ]
}

@test "adopter red twin: marked owned in the manifest the same path classifies gaia-shipped" {
  write_manifest '{"CLAUDE.md": "owned"}'
  classify CLAUDE.md
  [ "$status" -eq 0 ]
  [ "$(class_of CLAUDE.md)" = "gaia-shipped" ]
}

# --- third-party: vendor pins ---

@test "third-party: a file under a vendor pin target classifies third-party even when the manifest owns it" {
  classify frontend/.claude/skills/playwright-cli/SKILL.md frontend/.claude/skills/playwright-cli/references/x.md
  [ "$status" -eq 0 ]
  [ "$(class_of frontend/.claude/skills/playwright-cli/SKILL.md)" = "third-party" ]
  [ "$(class_of frontend/.claude/skills/playwright-cli/references/x.md)" = "third-party" ]
}

@test "third-party: a sibling sharing the vendor target as a name prefix is not vendored" {
  classify frontend/.claude/skills/playwright-cli-extra/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of frontend/.claude/skills/playwright-cli-extra/SKILL.md)" = "adopter" ]
}

@test "third-party red twin: without the vendor pin the same path classifies gaia-shipped" {
  rm "$PROJECT/.gaia/vendor/playwright-cli.json"
  classify frontend/.claude/skills/playwright-cli/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of frontend/.claude/skills/playwright-cli/SKILL.md)" = "gaia-shipped" ]
}

# --- third-party: outside the project tree ---

@test "third-party: an absolute path outside the project (a plugin skill) classifies third-party" {
  classify "$BATS_TEST_TMPDIR/plugins/cache/some-plugin/skills/x/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$(class_of "$BATS_TEST_TMPDIR/plugins/cache/some-plugin/skills/x/SKILL.md")" = "third-party" ]
}

@test "third-party: a path that climbs out with .. classifies third-party" {
  classify .claude/skills/../../outside/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/../../outside/SKILL.md)" = "third-party" ]
}

@test "third-party red twin: an absolute path inside the project is classified by its repo-relative form" {
  classify "$PROJECT/.claude/skills/deploy/SKILL.md" "$PROJECT/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/deploy/SKILL.md)" = "adopter" ]
  [ "$(class_of CLAUDE.md)" = "adopter" ]
}

# --- ignored ---

@test "ignored: a gitignored installer-managed skill classifies ignored" {
  classify .claude/skills/react-doctor/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/react-doctor/SKILL.md)" = "ignored" ]
}

@test "ignored red twin: without the ignore line the same path classifies adopter" {
  : >"$PROJECT/.gitignore"
  classify .claude/skills/react-doctor/SKILL.md
  [ "$status" -eq 0 ]
  [ "$(class_of .claude/skills/react-doctor/SKILL.md)" = "adopter" ]
}

# --- input forms ---

@test "a finding's :line suffix and a leading ./ are stripped before classifying" {
  classify ./CLAUDE.md:14 .claude/skills/gaia/references/fitness.md:3
  [ "$status" -eq 0 ]
  [ "$(class_of CLAUDE.md)" = "adopter" ]
  [ "$(class_of .claude/skills/gaia/references/fitness.md)" = "gaia-shipped" ]
}

@test "one output line per input path, in input order" {
  classify CLAUDE.md .gaia/manifest.json .claude/skills/react-doctor/SKILL.md
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'adopter\tCLAUDE.md' ]
  [ "${lines[1]}" = $'gaia-shipped\t.gaia/manifest.json' ]
  [ "${lines[2]}" = $'ignored\t.claude/skills/react-doctor/SKILL.md' ]
}

# --- fail-closed exits ---

@test "no path argument is a usage error" {
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"fitness-ownership:"* ]]
}

@test "an unknown option is a usage error" {
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT" --bogus CLAUDE.md
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a missing manifest fails closed rather than calling every file adopter" {
  rm "$PROJECT/.gaia/manifest.json"
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT" CLAUDE.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"manifest"* ]]
}

@test "a manifest without a files object fails closed" {
  printf '{"version": "2.0.0"}' >"$PROJECT/.gaia/manifest.json"
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT" CLAUDE.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a vendor pin with no target fails closed rather than skipping the pin" {
  printf '{"package": "pkg"}' >"$PROJECT/.gaia/vendor/broken.json"
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT" CLAUDE.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"broken.json"* ]]
}

@test "a root that is not a git work tree fails closed" {
  rm -rf "$PROJECT/.git"
  run --separate-stderr bash "$SCRIPT" --root "$PROJECT" CLAUDE.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "missing jq fails closed" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  run --separate-stderr env PATH="$bin" "$BASH" "$SCRIPT" --root "$PROJECT" CLAUDE.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"jq"* ]]
}
