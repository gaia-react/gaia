#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-write-findings.sh, the ONE shared writer for a
# Code Audit Team member's findings sidecar.
#
# The sidecar is the report of record: the artifact an orchestrator reads to
# learn what a member found, and the only place a withheld marker's grounds
# survive. Its defect class is not "the file is missing" but "the file is
# present and says nothing actionable", so most of this suite is about the
# writer REFUSING an entry that cannot name its file, line, defect,
# verification, and repair.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS's system bash 3.2
# does not fail a @test on a false bare `[[ ]]` that is not the last command,
# so non-final checks use POSIX `[ ]`, `grep -q`, or an explicit `return 1`, and
# an absence assertion is written as `<bad-case> && return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  WRITER="$THIS_DIR/../audit-write-findings.sh"
  [ -x "$WRITER" ] || skip "audit-write-findings.sh not executable"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" > "$ROOT/README.md"
  git -C "$ROOT" add README.md
  git -C "$ROOT" commit --quiet -m "init"
  BASE="$(git -C "$ROOT" rev-parse HEAD)"
  # An off-main branch, so the key's branch half is a real discriminator and the
  # slug's percent-encoding is exercised rather than trivially a no-op.
  git -C "$ROOT" checkout --quiet -b "feat/x"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
  MEMBER="code-audit-maintainer-shell"
  # gaia_key_slug percent-encodes every byte outside [A-Za-z0-9_-], so "/" is
  # "%2F"; the expected path is spelled out rather than derived, so a change to
  # the encoding fails here instead of silently agreeing with itself.
  EXPECTED="$AUDIT_DIR/${BASE}.feat%2Fx.${MEMBER}.findings.json"
}

# A complete, valid finding. Callers override one field at a time to prove each
# rule fires on its own.
complete_finding() {
  cat <<'JSON'
{"finding_class":"holistic/secret-exposure","severity":"warning",
 "path":".claude/hooks/block-secrets-write.sh","line":113,
 "title":"the expansion-then-path arm admits arbitrary trailing text",
 "failure_mode":"once a separator follows the closing brace the tail is unbounded over the character set a literal secret uses, so a live token assigned behind one is allowed",
 "verified_by":"ran the hook on the braced-expansion fixture at base and at HEAD: base denies, HEAD allows",
 "suggested_fix":"bound each trailing segment so the token run exceeds the bound"}
JSON
}

# write <json-array> -> runs the writer with the array on stdin
write() {
  printf '%s' "$1" | bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings -
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

@test "usage: --help exits 0 with usage text" {
  run bash "$WRITER" --help
  [ "$status" -eq 0 ]
  grep -qF "usage: audit-write-findings.sh" <<<"$output"
}

@test "usage: each required flag is named when omitted" {
  run bash "$WRITER" --member "$MEMBER" --base "$BASE" --findings -
  [ "$status" -eq 2 ]
  grep -qF "root is required" <<<"$output"

  run bash "$WRITER" --root "$ROOT" --base "$BASE" --findings -
  [ "$status" -eq 2 ]
  grep -qF "member is required" <<<"$output"

  run bash "$WRITER" --root "$ROOT" --member "$MEMBER" --findings -
  [ "$status" -eq 2 ]
  grep -qF "base is required" <<<"$output"

  run bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE"
  [ "$status" -eq 2 ]
  grep -qF "findings is required" <<<"$output"
}

@test "usage: an unrecognized flag exits 2" {
  run bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings - --bogus
  [ "$status" -eq 2 ]
  grep -qF "unrecognized argument" <<<"$output"
}

@test "usage: a --findings file that does not exist exits 2" {
  run bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  grep -qF "does not exist" <<<"$output"
}

# -----------------------------------------------------------------------------
# The happy path: keying, shape, atomicity
# -----------------------------------------------------------------------------

@test "writes the sidecar at the gaia_audit_key path (base sha + branch slug + member)" {
  out="$(write "[$(complete_finding)]")"
  [ "$out" = "$EXPECTED" ]
  [ -f "$EXPECTED" ]
  [ "$(jq -r .schema "$EXPECTED")" = "1" ]
  [ "$(jq -r .member "$EXPECTED")" = "$MEMBER" ]
  [ "$(jq '(.findings | type) == "array"' "$EXPECTED")" = "true" ]
}

@test "every actionable field round-trips verbatim" {
  write "[$(complete_finding)]" >/dev/null
  entry="$(jq -c '.findings[0]' "$EXPECTED")"
  [ "$(jq -r .finding_class <<<"$entry")" = "holistic/secret-exposure" ]
  [ "$(jq -r .severity <<<"$entry")" = "warning" ]
  [ "$(jq -r .path <<<"$entry")" = ".claude/hooks/block-secrets-write.sh" ]
  [ "$(jq -r .line <<<"$entry")" = "113" ]
  grep -qF "arbitrary trailing text" <<<"$(jq -r .title <<<"$entry")"
  grep -qF "unbounded" <<<"$(jq -r .failure_mode <<<"$entry")"
  grep -qF "base denies, HEAD allows" <<<"$(jq -r .verified_by <<<"$entry")"
  grep -qF "bound each trailing segment" <<<"$(jq -r .suggested_fix <<<"$entry")"
}

@test "an empty findings array is valid and meaningful (the member ran, found nothing)" {
  out="$(write '[]')"
  [ "$out" = "$EXPECTED" ]
  [ "$(jq -c '.findings' "$EXPECTED")" = "[]" ]
}

@test "area_tags defaults to the finding's own directory" {
  write "[$(complete_finding)]" >/dev/null
  [ "$(jq -r '.findings[0].area_tags[0]' "$EXPECTED")" = ".claude/hooks" ]
  [ "$(jq '.findings[0].area_tags | length' "$EXPECTED")" = "1" ]
}

@test "area_tags defaults to \".\" for a repo-root path with no directory" {
  entry="$(complete_finding | jq -c '.path = "CHANGELOG.md"')"
  write "[$entry]" >/dev/null
  [ "$(jq -r '.findings[0].area_tags[0]' "$EXPECTED")" = "." ]
}

@test "an explicit area_tags is preserved, never overwritten by the dirname default" {
  entry="$(complete_finding | jq -c '.area_tags = ["gate-machinery","secrets"]')"
  write "[$entry]" >/dev/null
  [ "$(jq -c '.findings[0].area_tags' "$EXPECTED")" = '["gate-machinery","secrets"]' ]
}

@test "--findings accepts a file as well as stdin" {
  printf '[%s]' "$(complete_finding)" > "$BATS_TEST_TMPDIR/f.json"
  out="$(bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings "$BATS_TEST_TMPDIR/f.json")"
  [ "$out" = "$EXPECTED" ]
  [ "$(jq '.findings | length' "$EXPECTED")" = "1" ]
}

@test "a second write replaces the first and leaves no stray temp file" {
  write "[$(complete_finding)]" >/dev/null
  write '[]' >/dev/null
  [ "$(jq -c '.findings' "$EXPECTED")" = "[]" ]
  leftover="$(find "$AUDIT_DIR" -name '.audit-write-findings.*' 2>/dev/null)"
  [ -z "$leftover" ]
}

@test "structural: writes atomically via a temp file in the target dir + mv" {
  grep -qF "mktemp" "$WRITER"
  grep -qF "mv -f" "$WRITER"
}

# -----------------------------------------------------------------------------
# The point of the writer: an entry that cannot brief a repair is REJECTED, and
# nothing is written. One test per rule, each derived from the complete finding
# so it can only fail for the reason it names.
# -----------------------------------------------------------------------------

@test "rejects a finding with no path" {
  run write "[$(complete_finding | jq -c 'del(.path)')]"
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: path must be" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding with no line" {
  run write "[$(complete_finding | jq -c 'del(.line)')]"
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: line must be an integer" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a non-integer or out-of-range line" {
  run write "[$(complete_finding | jq -c '.line = 0')]"
  [ "$status" -eq 2 ]
  grep -qF "line must be an integer >= 1" <<<"$output"

  run write "[$(complete_finding | jq -c '.line = 4.5')]"
  [ "$status" -eq 2 ]
  grep -qF "line must be an integer >= 1" <<<"$output"

  run write "[$(complete_finding | jq -c '.line = "113"')]"
  [ "$status" -eq 2 ]
  grep -qF "line must be an integer >= 1" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding with no failure_mode" {
  run write "[$(complete_finding | jq -c 'del(.failure_mode)')]"
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: failure_mode must be" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding with no verified_by (how it was verified)" {
  run write "[$(complete_finding | jq -c 'del(.verified_by)')]"
  [ "$status" -eq 2 ]
  grep -qF "verified_by must be a non-empty string" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding with no suggested_fix (the recommended repair)" {
  run write "[$(complete_finding | jq -c 'del(.suggested_fix)')]"
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: suggested_fix must be" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding with no title" {
  run write "[$(complete_finding | jq -c 'del(.title)')]"
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: title must be" <<<"$output"
}

@test "rejects an empty string where a field is required" {
  run write "[$(complete_finding | jq -c '.suggested_fix = ""')]"
  [ "$status" -eq 2 ]
  grep -qF "suggested_fix must be" <<<"$output"

  run write "[$(complete_finding | jq -c '.path = ""')]"
  [ "$status" -eq 2 ]
  grep -qF "path must be" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a finding_class that is absent or not a string" {
  run write "[$(complete_finding | jq -c 'del(.finding_class)')]"
  [ "$status" -eq 2 ]
  grep -qF "finding_class must be a non-empty string" <<<"$output"

  run write "[$(complete_finding | jq -c '.finding_class = 7')]"
  [ "$status" -eq 2 ]
  grep -qF "finding_class must be a non-empty string" <<<"$output"
}

@test "rejects a severity outside error|warning|suggestion" {
  # `critical` is the re-run ledger's vocabulary, not the sidecar's; the two
  # scales are deliberately different and confusing them must not pass.
  run write "[$(complete_finding | jq -c '.severity = "critical"')]"
  [ "$status" -eq 2 ]
  grep -qF "severity must be one of error|warning|suggestion" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "accepts each of the three valid severities" {
  for sev in error warning suggestion; do
    write "[$(complete_finding | jq -c --arg s "$sev" '.severity = $s')]" >/dev/null
    [ "$(jq -r '.findings[0].severity' "$EXPECTED")" = "$sev" ]
  done
}

@test "rejects a malformed area_tags" {
  run write "[$(complete_finding | jq -c '.area_tags = [3]')]"
  [ "$status" -eq 2 ]
  grep -qF "area_tags, when present, must be an array of strings" <<<"$output"

  run write "[$(complete_finding | jq -c '.area_tags = "app"')]"
  [ "$status" -eq 2 ]
  grep -qF "area_tags, when present, must be an array of strings" <<<"$output"
}

@test "names the OFFENDING INDEX, not just the first entry" {
  first="$(complete_finding | jq -c '.')"
  bad="$(complete_finding | jq -c 'del(.verified_by)')"
  run write "[$first,$first,$bad]"
  [ "$status" -eq 2 ]
  grep -qF "findings[2]: verified_by" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

@test "rejects a non-object entry" {
  run write '["a finding, as prose"]'
  [ "$status" -eq 2 ]
  grep -qF "findings[0]: not a JSON object" <<<"$output"
}

@test "rejects input that is not a JSON array" {
  run write '{"schema":1,"member":"m","findings":[]}'
  [ "$status" -eq 2 ]
  grep -qF "must hold a JSON array" <<<"$output"
  [ ! -f "$EXPECTED" ]

  run write 'not json at all'
  [ "$status" -eq 2 ]
  grep -qF "must hold a JSON array" <<<"$output"
}

@test "a rejected write leaves the audit dir untouched: no file, no temp, no dir creation" {
  run write "[$(complete_finding | jq -c 'del(.line)')]"
  [ "$status" -eq 2 ]
  # Validation runs before any filesystem work, so a rejected run does not even
  # provision the audit directory.
  [ -d "$AUDIT_DIR" ] && return 1
  [ ! -f "$EXPECTED" ]
}

@test "a validator that cannot run FAILS CLOSED rather than accepting everything" {
  # The rules live in one jq program. A jq error there once silently accepted
  # every finding, so the writer checks jq's status and refuses on error.
  grep -qF 'cannot validate the findings input' "$WRITER"
  # Prove it end to end with a jq that always errors.
  stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  cat > "$stub/jq" <<'STUB'
#!/usr/bin/env bash
# Answer the `type == "array"` pre-check truthfully so the run reaches the
# validator, then fail on the validation program itself.
case "$*" in
  *'type == "array"'*) exit 0 ;;
esac
echo "jq: error: simulated" >&2
exit 5
STUB
  chmod +x "$stub/jq"
  printf '[]' > "$BATS_TEST_TMPDIR/empty.json"
  run env PATH="$stub:$PATH" bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings "$BATS_TEST_TMPDIR/empty.json"
  [ "$status" -eq 2 ]
  grep -qF "cannot validate the findings input" <<<"$output"
  [ ! -f "$EXPECTED" ]
}

# -----------------------------------------------------------------------------
# Fail-open: an unresolvable key declines instead of inventing a path
# -----------------------------------------------------------------------------

@test "detached HEAD: declines audit key unresolved, exit 0, writes nothing" {
  git -C "$ROOT" checkout --quiet --detach HEAD
  run write '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "findings-sidecar: declined: audit key unresolved" ]
  [ -d "$AUDIT_DIR" ] && return 1
  [ ! -f "$EXPECTED" ]
}

@test "a non-git root: declines audit key unresolved, exit 0" {
  other="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$other"
  run bash -c 'printf "[]" | bash "$1" --root "$2" --member "$3" --base "$4" --findings -' \
    _ "$WRITER" "$other" "$MEMBER" "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "findings-sidecar: declined: audit key unresolved" ]
}

@test "the branch is read from --root, never the caller's CWD" {
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init --quiet --initial-branch=elsewhere
  out="$( cd "$other" && printf '[]' | bash "$WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings - )"
  [ "$out" = "$EXPECTED" ]
  grep -qF "elsewhere" <<<"$out" && return 1
  [ -f "$EXPECTED" ]
}

@test "two branches sharing a base sha never collide on one path" {
  write '[]' >/dev/null
  git -C "$ROOT" checkout --quiet -b "feat/y"
  other_out="$(write '[]')"
  [ "$other_out" != "$EXPECTED" ]
  [ -f "$EXPECTED" ]
  [ -f "$other_out" ]
}

# -----------------------------------------------------------------------------
# Repo hygiene
# -----------------------------------------------------------------------------

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  grep -nE '(^|[^[:alnum:]_])cd[[:space:]]' "$WRITER" | grep -vF 'dirname' | grep -vF '#' && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -nE "/Users/|/home/" "$WRITER" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  run shellcheck "$WRITER"
  [ "$status" -eq 0 ]
}
