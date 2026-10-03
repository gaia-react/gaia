#!/usr/bin/env bats
#
# revendor-playwright-cli.sh offline, using --tarball and --integrity with a
# fabricated tarball. Every case works on a scratch root under $BATS_TEST_TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/revendor-playwright-cli.sh"
  VERIFY="$REPO_ROOT/.gaia/scripts/verify-vendored-skills.sh"
  SCRATCH_ROOT="$BATS_TEST_TMPDIR/root"
  TARGET="$SCRATCH_ROOT/frontend/.claude/skills/playwright-cli"
  MARKER="$SCRATCH_ROOT/.gaia/vendor/playwright-cli.json"
  mkdir -p "$SCRATCH_ROOT"
  make_tarball
}

# A package/skills/playwright-cli tree packed the way npm packs it.
make_tarball() {
  local package_directory="$BATS_TEST_TMPDIR/pack/package/skills/playwright-cli"
  mkdir -p "$package_directory/references"
  printf 'skill body\n' >"$package_directory/SKILL.md"
  printf 'reference body\n' >"$package_directory/references/one.md"
  TARBALL="$BATS_TEST_TMPDIR/fabricated.tgz"
  tar -czf "$TARBALL" -C "$BATS_TEST_TMPDIR/pack" package
  INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$TARBALL" | base64 | tr -d '\n')"
}

# One hash over every file under $1 plus the marker, to compare states.
tree_digest() {
  find "$TARGET" "$MARKER" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    cat "$file"
  done | openssl dgst -sha256
}

@test "a matching integrity replaces the folder wholesale and writes the marker" {
  mkdir -p "$TARGET"
  printf 'stale\n' >"$TARGET/stale.md"
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --integrity "$INTEGRITY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET/stale.md" ]
  [ "$(cat "$TARGET/SKILL.md")" = "skill body" ]
  [ "$(jq -r .version "$MARKER")" = "9.9.9" ]
  [ "$(jq -r .integrity "$MARKER")" = "$INTEGRITY" ]
  [ "$(jq -r '.files | keys | join(",")' "$MARKER")" = "SKILL.md,references/one.md" ]
  run "$VERIFY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
}

@test "the marker records keys in the contract order" {
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --integrity "$INTEGRITY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys_unsorted | join(",")' "$MARKER")" = "package,version,integrity,source,target,files" ]
}

@test "re-running with the same tarball and version leaves everything byte-identical" {
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --integrity "$INTEGRITY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  local before
  before="$(tree_digest)"
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --integrity "$INTEGRITY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  [ "$(tree_digest)" = "$before" ]
}

@test "a wrong integrity exits non-zero and writes nothing" {
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --integrity "$INTEGRITY" --root "$SCRATCH_ROOT"
  [ "$status" -eq 0 ]
  printf 'local edit\n' >>"$TARGET/SKILL.md"
  local before
  before="$(tree_digest)"
  run "$SCRIPT" --version 1.0.0 --tarball "$TARBALL" --integrity "sha512-AAAA" --root "$SCRATCH_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"integrity mismatch"* ]]
  [ "$(tree_digest)" = "$before" ]
}

@test "a wrong integrity on a fresh root creates neither folder nor marker" {
  run "$SCRIPT" --version 1.0.0 --tarball "$TARBALL" --integrity "sha512-AAAA" --root "$SCRATCH_ROOT"
  [ "$status" -ne 0 ]
  [ ! -e "$TARGET" ]
  [ ! -e "$MARKER" ]
}

@test "--tarball without --integrity is a usage error" {
  run "$SCRIPT" --version 9.9.9 --tarball "$TARBALL" --root "$SCRATCH_ROOT"
  [ "$status" -eq 2 ]
}

@test "a missing --version is a usage error" {
  run "$SCRIPT" --root "$SCRATCH_ROOT"
  [ "$status" -eq 2 ]
}
