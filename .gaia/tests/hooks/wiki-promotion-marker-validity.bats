#!/usr/bin/env bats
# A wiki promotion commit lands after every Code Audit Team member has cleared,
# so it must not rotate any member's marker. Each marker is keyed to its
# member's content digest, and wiki pages are ownerless and allowlisted, so a
# commit touching only wiki pages leaves every digest byte-identical. The red
# twin proves the comparison can fail: a commit inside a member's remit rotates
# that member's digest.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../../.." && pwd )"
  DIGEST_CLI="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "no sha256 tool"
  fi
  SANDBOX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SANDBOX/frontend/app" "$SANDBOX/frontend/.playwright/e2e/x" "$SANDBOX/.gaia/scripts" \
    "$SANDBOX/.gaia/cli/src" "$SANDBOX/.github/workflows" "$SANDBOX/wiki/concepts"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  seed_audit_roster "$SANDBOX"
  echo "export const x = 1;" > "$SANDBOX/frontend/app/x.ts"
  echo "export const spec = 1;" > "$SANDBOX/frontend/.playwright/e2e/x/y.spec.ts"
  echo "#!/usr/bin/env bash" > "$SANDBOX/.gaia/scripts/foo.sh"
  echo "export const y = 2;" > "$SANDBOX/.gaia/cli/src/index.ts"
  echo "name: ci" > "$SANDBOX/.github/workflows/ci.yml"
  echo "page" > "$SANDBOX/wiki/concepts/page.md"
  echo "index" > "$SANDBOX/wiki/index.md"
  echo "log" > "$SANDBOX/wiki/log.md"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "seed"
}

roster_members() {
  awk '/^auditors:/ { inside = 1; next } inside && /^[A-Za-z_]/ { exit } inside && /^[[:space:]]*-[[:space:]]*name:/ { sub(/.*name:[[:space:]]*/, ""); print }' "$1/.gaia/audit-ci.yml"
}

repository_roster_members() {
  roster_members "$REPO_ROOT"
}

# Prints "<member> <digest>" for every roster member at <ref>.
all_digests() {
  local ref="$1" member digest
  while IFS= read -r member; do
    digest="$(bash "$DIGEST_CLI" --root "$SANDBOX" --member "$member" --ref "$ref")" || return 1
    printf '%s %s\n' "$member" "$digest"
  done < <(roster_members "$SANDBOX")
}

@test "the member set iterated is non-empty and equals the committed roster" {
  run roster_members "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  sandbox_members="$output"
  run repository_roster_members
  [ "$status" -eq 0 ]
  [ "$output" = "$sandbox_members" ]
}

@test "a commit touching only wiki pages leaves every member's digest unchanged" {
  before="$(all_digests HEAD)"
  [ -n "$before" ]
  echo "promoted" >> "$SANDBOX/wiki/concepts/page.md"
  echo "promoted" >> "$SANDBOX/wiki/index.md"
  echo "promoted" >> "$SANDBOX/wiki/log.md"
  git -C "$SANDBOX" commit --quiet -am "promote wiki pages"
  after="$(all_digests HEAD)"
  [ "$after" = "$before" ]
}

@test "red twin: a commit inside code-audit-frontend's remit rotates its digest" {
  before="$(bash "$DIGEST_CLI" --root "$SANDBOX" --member code-audit-frontend --ref HEAD)"
  [ -n "$before" ]
  echo "export const changed = 1;" >> "$SANDBOX/frontend/.playwright/e2e/x/y.spec.ts"
  git -C "$SANDBOX" commit --quiet -am "edit a rendered spec"
  after="$(bash "$DIGEST_CLI" --root "$SANDBOX" --member code-audit-frontend --ref HEAD)"
  [ -n "$after" ]
  [ "$after" != "$before" ]
}
