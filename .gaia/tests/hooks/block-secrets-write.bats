#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-write.sh.
#
# The guard is a write-time heuristic, not a sandbox: it scans the content an
# Edit/Write/MultiEdit is about to introduce and denies four shapes of obvious
# committed secret (AWS access-key id, GitHub PAT, PEM private-key header, and a
# dotenv-style assignment to a suspicious name). It always exits 0, carrying the
# allow/deny decision in stdout JSON.
#
# The dotenv rule is the only one with an allowlist, because it is the only one
# that matches on a *name* rather than on secret-shaped material: a line whose
# name ends in _TOKEN/_SECRET/_KEY/_PASSWORD is suspicious, so the value decides.
# The allowlist therefore carries the whole weight of the rule's false-positive
# behavior, and the deny cases below are what pin down that widening it does not
# hollow it out.
#
# Writing this file is itself subject to the guard, so every secret-shaped
# fixture is concatenated at runtime from fragments that match no pattern as
# written. Do not "tidy" those into single literals; the guard will deny the
# edit that does it.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block below: bats invokes each test body through its own runner, which
# static shellcheck cannot see, so it marks the blocks unreachable. The directive
# is file-wide because the false positive is intrinsic to the bats structure, not
# to any single test, and it masks no genuine signal: SC2317 cannot reason about
# an indirectly-invoked bats suite at all.

# shellcheck disable=SC2016
# SC2016 (expressions don't expand in single quotes) fires on every fixture that
# carries a `$`, which is most of them. Not expanding is the entire point: the
# fixture has to reach the hook as the literal text a real edit would contain,
# so `printf` takes it as an unexpanded argument. The directive is file-wide for
# the same reason the one above is, the fixtures are the file, and leaving it off
# buries the oracle's real output under a warning that is correct for every hit.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-secrets-write.sh"
}

# Quote-safe delivery: the payloads below carry shell snippets with quotes of
# their own, so $json and the hook path go in as positional args rather than
# being re-wrapped in an outer quoted string.
run_hook_write() {
  local body="$1"
  local json
  json=$(jq -n --arg c "$body" '{tool_name: "Write", tool_input: {content: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_edit() {
  local body="$1"
  local json
  json=$(jq -n --arg s "$body" '{tool_name: "Edit", tool_input: {new_string: $s}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

# The two above carry no file_path, which is what every test written before the
# guard read one relies on. These carry one, for the path-scoped exemption.
run_hook_write_path() {
  local path="$1"
  local body="$2"
  local json
  json=$(jq -n --arg p "$path" --arg c "$body" \
    '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_edit_path() {
  local path="$1"
  local body="$2"
  local json
  json=$(jq -n --arg p "$path" --arg s "$body" \
    '{tool_name: "Edit", tool_input: {file_path: $p, new_string: $s}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# --- The three secret-shaped patterns still deny ---

@test "an AWS access-key id is denied" {
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write "const id = '$aws_id'"
  assert_denied
}

@test "a GitHub personal-access-token is denied" {
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write "const token = '$pat'"
  assert_denied
}

@test "a PEM private-key header is denied" {
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write "$pem"
  assert_denied
}

# --- The dotenv rule still denies a real literal value ---

@test "a dotenv assignment with a literal value is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a dotenv assignment with a literal value is denied through Edit too" {
  run_hook_edit "$(printf 'DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  assert_denied
}

@test "a literal value is denied even when a command substitution precedes it" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# The four below pin the allowlist's command-substitution arm to "wholly a
# substitution" rather than "starts with $( and ends with )". The first three
# are values a both-ends-anchored `\$\(.+\)` admits, because `.` matches the
# very `)` the closing anchor is supposed to certify; they pin the trailing
# anchor. The fourth pins the leading one, and only that one: it never starts
# with `$(`, so it is the shape a dropped `^` would silently let through.

@test "a literal value between two command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(true)sk-live-9f3a1c4e8b7d2064$(true)')"
  assert_denied
}

@test "a literal value is denied when it merely ends in a closing paren" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)sk-live-9f3a1c4e8b7d2064)')"
  assert_denied
}

@test "a literal value spliced between quoted command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '"$(a)"sk-live-9f3a1c4e8b7d2064"$(b)"')"
  assert_denied
}

@test "a literal value is denied even when a command substitution follows it" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064$(whoami)')"
  assert_denied
}

# --- The other allowlist arms mean "wholly" too ---
#
# The command-substitution arm is not the only one that has to resist a splice.
# `<…>` had the identical defect (`.` matches `>`), and the `your-` / `example`
# arms matched a prefix with nothing anchoring the tail, so any value merely
# *starting* like a placeholder was allowed whatever followed it.

@test "a literal value between two angle-bracket placeholders is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<a>sk-live-9f3a1c4e8b7d2064<b>')"
  assert_denied
}

@test "a literal value carrying an example- placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a literal value carrying a your- placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-key-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# --- A shell declaration keyword does not hide the assignment ---
#
# The name grep anchors the suspicious name to the start of the line, so a
# declaration keyword in front of it took the line out of the scan entirely,
# and no allowlist arm was ever consulted.

@test "an exported literal value is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a local-declared literal value is denied" {
  run_hook_write "$(printf 'local API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a readonly-declared literal value is denied through Edit too" {
  run_hook_edit "$(printf 'readonly DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  assert_denied
}

# --- The existing allowlist arms still allow ---

@test "an empty value is allowed" {
  run_hook_write "$(printf 'API_KEY=\n')"
  assert_allowed
}

@test "a bare \$VAR value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_API_KEY')"
  assert_allowed
}

@test "a braced \${VAR} value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${MY_API_KEY}')"
  assert_allowed
}

@test "a named placeholder value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'placeholder')"
  assert_allowed
}

@test "content with no secret shape at all is allowed" {
  run_hook_write "export function add(a, b) { return a + b }"
  assert_allowed
}

# The tightened arms have to stay usable: these are the placeholder values the
# arms exist to admit, and the ones a too-eager anchor would take down with the
# splices above.

@test "an angle-bracket placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<your-key-here>')"
  assert_allowed
}

@test "a your- placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-api-key-here')"
  assert_allowed
}

@test "a bare example placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example')"
  assert_allowed
}

@test "an example domain placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example.com')"
  assert_allowed
}

@test "an exported \$VAR value is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$MY_API_KEY')"
  assert_allowed
}

# Recognizing the declaration keywords pulls shell lines into a rule written for
# dotenv files, and a shell value references a variable far more often than a
# dotenv value does. These are the shapes that carry no literal secret but that
# the bare-identifier `${VAR}` arm alone would deny.

@test "an expansion carrying a default operator is allowed" {
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"${GITHUB_TOKEN:-}"')"
  assert_allowed
}

@test "a positional expansion is allowed" {
  run_hook_write "$(printf 'local CACHE_KEY=%s\n' '"${1}"')"
  assert_allowed
}

@test "an expansion followed by a literal path is allowed" {
  run_hook_write "$(printf 'readonly SIGNING_KEY=%s\n' '"${REPO_ROOT}/dev.pem"')"
  assert_allowed
}

@test "a named fake placeholder is allowed" {
  run_hook_write "$(printf 'export GH_TOKEN=%s\n' '"fake-token"')"
  assert_allowed
}

# The expansion allowance is bounded by the same segment rule as the placeholder
# arms: a secret does not stop being a secret for sitting inside a default.

@test "a literal secret inside an expansion default is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-sk-live-9f3a1c4e8b7d2064}')"
  assert_denied
}

@test "a literal secret concatenated onto an expansion is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${PREFIX}sk-live-9f3a1c4e8b7d2064"')"
  assert_denied
}

# A segmented secret has the same structure a placeholder does, so the operand
# arm requires an EMPTY operand rather than a short one: a default value is
# exactly where a real secret lands, and a UUID clears any per-segment bound.

@test "a segmented secret inside an expansion default is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-550e8400-e29b-41d4-a716-446655440000}')"
  assert_denied
}

@test "an expansion followed by a non-path literal is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}550e8400-e29b-41d4-a716-446655440000')"
  assert_denied
}

# The path arm bounds each segment the way the placeholder arms do, so the
# separator buys a path suffix and not an unbounded tail. Without these three
# the arm's allow direction is pinned and its failure mode is not: a secret
# behind the separator is exactly what the separator must not admit.

@test "a literal secret behind a slash separator is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}/sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a literal secret behind a dot separator is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}.sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a segmented secret behind a path separator is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${VAULT}/550e8400-e29b-41d4-a716-446655440000"')"
  assert_denied
}

# A variable reference inside a command-substitution body must not buy the
# value an expansion arm: that would re-open the very splice the `$(…)` arm
# exists to close.

@test "a substitution whose body references a variable is still spliced, so denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(echo ${X})550e8400-e29b-41d4-a716-446655440000')"
  assert_denied
}

# The placeholder arms require a separator BETWEEN segments. Making it optional
# would let one unbroken run be read as several short ones, which is the bound
# defeating itself.

@test "an unbroken run behind a placeholder prefix cannot be read as segments" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'example550e8400e29b41d4a716446655440000')"
  assert_denied
}

# Segmented placeholders pass at any length; an unbroken run does not. A length
# cap gets both of these backwards, which is why the arms bound the segment.

@test "a long but segmented your- placeholder is allowed" {
  run_hook_write "$(printf 'GITHUB_TOKEN=%s\n' 'your-github-personal-access-token')"
  assert_allowed
}

@test "an underscore-segmented your_ placeholder is allowed" {
  run_hook_write "$(printf 'SUPABASE_ANON_KEY=%s\n' 'your_supabase_anon_key_here')"
  assert_allowed
}

@test "a short unbroken run behind a placeholder prefix is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-aB3xK9pQ7zR2wL5t')"
  assert_denied
}

# --- A computed value is allowed: the source line holds no literal secret ---
#
# A value that is wholly a command substitution is resolved at run time, so the
# source line carries nothing to leak. Denying it taught callers to launder the
# assignment through a throwaway variable or an off-target name, which is
# unexplained residue in exchange for no security.
#
# The arm reads shape, not meaning, and the deny cases above are the price of
# keeping that shape honest. A nested `$(op read op://vault/$(hostname))` is
# denied, and `$(echo <a-literal-secret>)` is allowed: no regex tells those
# apart from `$(mint_key)` without reading the command. Neither is pinned here,
# because neither is behavior worth freezing.

@test "a value that is wholly a command substitution is allowed" {
  run_hook_write "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}

@test "an unquoted command substitution value is allowed" {
  run_hook_write "$(printf 'SESSION_TOKEN=%s\n' '$(mint_token)')"
  assert_allowed
}

@test "a command substitution is allowed through Edit too" {
  run_hook_edit "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}

# --- The declaration keyword carries its options ---
#
# `declare -r` and `local -r` are the idiomatic spellings in careful bash, so a
# keyword group that only accepts the bare keyword takes the very lines it was
# widened for back out of the scan. The flags are part of the declaration, not
# part of the name.

@test "a secret behind declare -r is denied" {
  run_hook_write "$(printf 'declare -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret behind local -r is denied" {
  run_hook_write "$(printf 'local -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret behind readonly -g is denied" {
  run_hook_write "$(printf 'readonly -g API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret behind an end-of-options marker is denied" {
  run_hook_write "$(printf 'export -- API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret behind two declaration flags is denied" {
  run_hook_write "$(printf 'declare -r -x API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# --- Ordinary secret-free shell lines stay allowed ---
#
# Pulling shell lines into a rule written for dotenv files means the rule now
# sees shapes a dotenv file never carries: a trailing comment, a trailing
# operator, an unbraced positional, two references concatenated. None of them
# holds a literal, and denying them is a hard block whose stated remedy ("use
# environment variables") is what the line already does.

@test "a trailing comment does not defeat the value extraction" {
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"$GH_PAT" # for gh cli')"
  assert_allowed
}

@test "a trailing or-clause does not defeat the value extraction" {
  run_hook_write "$(printf 'local API_KEY=%s\n' '"$1" || true')"
  assert_allowed
}

@test "an unbraced positional is allowed" {
  run_hook_write "$(printf 'local API_KEY=%s\n' '"$1"')"
  assert_allowed
}

@test "two concatenated references are allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${A}${B}"')"
  assert_allowed
}

# A trailing comment strips the comment, not the scan: a literal secret ahead of
# one is still the value, and still denied.

@test "a literal secret ahead of a trailing comment is still denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '"sk-live-9f3a1c4e8b7d2064" # from vault')"
  assert_denied
}

# The tail comes off the value but is never discarded unread. A placeholder on
# the left with the real key parked in the comment is the plausible accident;
# a second assignment after `;` is worse in kind, because the discarded text is
# executable. Without these the tail-strip trades a false positive for a hole.

@test "a secret parked in a trailing comment is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_VAR # sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret parked beside an empty value is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '  # sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a secret parked behind a placeholder is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste> # sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a second assignment after a statement separator is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '"" ; API_TOKEN=sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# Ordinary prose in a comment is not secret-shaped, so the tail check has to
# stay quiet for it or it re-creates the false positive it was added beside.

@test "ordinary prose in a trailing comment is allowed" {
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"$GH_PAT" # authentication for the gh cli')"
  assert_allowed
}

# `typeset` is bash's synonym for `declare`, so it belongs with the other three.

@test "a secret behind typeset -r is denied" {
  run_hook_write "$(printf 'typeset -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# A `;`, `&&`, or `||` can sit INSIDE the value rather than after it, and the
# tail strip is a regex with no quoting or substitution context, so it cannot
# tell the two apart on its own. Judging the untrimmed value FIRST is what
# bounds the strip to turning a deny into an allow and never the reverse. The
# guarded-substitution idiom below is how this repo's own audit scripts write a
# fallible command substitution, so getting the order wrong hard-blocks them.

@test "an or-separator inside a command substitution is allowed" {
  run_hook_write "$(printf 'AUDIT_KEY=%s\n' '"$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"')"
  assert_allowed
}

@test "an and-separator inside a command substitution is allowed" {
  run_hook_write "$(printf 'GH_TOKEN=%s\n' '$(gh auth token 2>/dev/null && :)')"
  assert_allowed
}

@test "a separator inside an angle-bracket placeholder is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste || generate>')"
  assert_allowed
}

# The tail's shape rule only sees a run of 13+ alphanumerics mixing letters and
# digits, so an assignment parked after a separator clears it whenever the value
# is shorter than that or carries no digit. The feeder grep is line-anchored and
# never re-reads the fragment, so shape alone leaves the hole open; an executable
# tail carrying an assignment is judged by the assignment rule instead.

@test "a short second assignment after a separator is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '"" ; API_TOKEN=abc123xyz')"
  assert_denied
}

@test "an all-letter second assignment after a separator is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste> ; REAL_KEY=correcthorsebattery')"
  assert_denied
}

# The rescan reuses the value allowlist rather than denying on the name alone,
# so a parked assignment whose value is an ordinary reference stays allowed.

@test "an allowed assignment in an executable tail is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$X ; OTHER_TOKEN=${Y}')"
  assert_allowed
}

# The fragment split is a `tr`, not a parser, so a `||` or `&&` INSIDE a parked
# assignment's value reads as a separator unless the substitution is taken out of
# the operators' way first. The guarded-substitution idiom is as ordinary after a
# `;` as it is before one, and truncating it at the `||` leaves a fragment with
# no closing paren that no arm can match, which is the same false deny the
# untrimmed-first ordering fixes for the primary value.

@test "a guarded substitution in a parked assignment is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; export API_TOKEN=$(gh auth token 2>/dev/null || true)')"
  assert_allowed
}

@test "an and-guarded substitution in a parked assignment is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; export GH_TOKEN=$(gh auth token 2>/dev/null && :)')"
  assert_allowed
}

# ...and the bound runs one way only. A sibling fragment carrying a literal is
# still denied, so keeping the substitution whole does not hollow out the rescan.

@test "a literal beside a guarded substitution in a tail is still denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; API_TOKEN=hunter2xyz ; GH_TOKEN=$(gh auth token 2>/dev/null || true)')"
  assert_denied
}

# The mask has to stop at the first `)`, the same way the allowlist's own
# substitution arm does. A greedy one spans from the first `$(` to the last `)`,
# swallowing whatever is parked BETWEEN two substitutions and handing the rescan
# a tail with nothing left to judge.

@test "a literal parked between two substitutions in a tail is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; GH_TOKEN=$(gh auth token 2>/dev/null || true) ; API_TOKEN=hunter2xyz ; OTHER_KEY=$(id -u || true)')"
  assert_denied
}

# ...and it has to be global. Mask only the first substitution and a second
# guarded one keeps its `||`, which collapses to a separator and truncates that
# fragment, false-denying a tail carrying no literal at all. The deny case above
# cannot observe this: it asserts a deny, so a mutation that only adds denies
# leaves it green.

@test "two guarded substitutions in one tail are allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; A_TOKEN=$(gh auth token 2>/dev/null || true) ; B_TOKEN=$(id -u 2>/dev/null || true)')"
  assert_allowed
}

# The mask is not verdict-preserving: erasing a substitution body erases what
# the body held. Two widenings follow, both deliberate, so both are pinned here
# rather than left incidental. First, an assignment between a `$(` and its first
# `)` goes away with the body.

@test "an assignment inside a substitution body in a tail is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; A_TOKEN=$(foo ; B_KEY=hunter2xyz123 )')"
  assert_allowed
}

# Second, the erased body takes an inner `>` with it, so a `<…>` wrapper that
# the `>` used to disqualify reads as a whole placeholder. The primary value
# does not reach this one, which makes the tail briefly the more permissive of
# the two. It conceals nothing an unwrapped `$(…)`, allowed in both positions
# already, does not conceal too.

@test "a bracket-wrapped substitution carrying a redirect in a tail is allowed" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; A_TOKEN=<$(gh auth token 2>/dev/null)>')"
  assert_allowed
}

# Erasing a body erases any assignment inside it, so the flag has to come off
# the UNMASKED tail. Read it off the masked one and a tail whose only watched
# assignment sits in a substitution falls through to the shape rule, which then
# denies on the very material the mask claimed to remove. Here that material is
# an ordinary commit sha and both values are references, so there is no literal
# anywhere on the line.

@test "an assignment inside a substitution does not expose the tail to the shape rule" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; OUT=$(cd repo ; export GH_TOKEN=$T ; git checkout 3ea35f1756b5375b0691436907e14ee8d2dbc43b)')"
  assert_allowed
}

# The same line, long enough that the flag pass's reader is still writing when
# its `grep -q` leaves on the first match. Written as a bare pipeline the flag
# pass then takes SIGPIPE, reports 141 under `pipefail`, drops the flag on a
# tail that plainly carries an assignment, and denies. Only length exposes it,
# so the fixture has to outrun grep's read buffer; the short twin above passes
# either way.

@test "a long tail whose assignment sits in a substitution is allowed" {
  local filler
  filler=$(head -c 40000 < /dev/zero | tr '\0' 'a')
  run_hook_write "$(printf 'export API_KEY=%s\n' "\$X ; OUT=\$(cd repo ; export GH_TOKEN=\$T ; echo ${filler} ; git checkout 3ea35f1756b5375b0691436907e14ee8d2dbc43b)")"
  assert_allowed
}

# ...and the shape backstop survives that split. A tail carrying no watched
# assignment at all still reaches the shape rule, masked substitution or not.

@test "secret-shaped material in a substitution with no assignment is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; OUT=$(echo hunter2xyz123)')"
  assert_denied
}

# The mask declines an empty body, matching the substitution arm's own `[^)]+`.
# With `*` the tail would allow a value the primary position denies.

@test "an empty substitution in a tail is denied" {
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; A_TOKEN=$()')"
  assert_denied
}

# The fragment loop is fed by process substitution rather than a pipe so it runs
# in this shell and `tail_has_assignment` survives it. A pipe-fed rewrite is
# invisible until the tail is BOTH assignment-carrying and secret-shaped: only
# then is the lost flag observable, as the shape rule firing on a tail the
# allowlist has already cleared.

@test "an allowed assignment in a secret-shaped executable tail is allowed" {
  local ref="LONGVARNAME""1234567"
  run_hook_write "$(printf 'API_KEY=%s\n' "\$X ; OTHER_TOKEN=\${$ref}")"
  assert_allowed
}

# `secret_shaped` is fed by process substitution for the same reason the flag
# pass is, and it fails in the worse direction. Under `pipefail` the pipeline's
# status IS the function's return value, and its `grep -q` leaves on the first
# match; on a tail carrying enough runs that the producer is still writing, the
# producer takes SIGPIPE and the pipeline reports 141. Written as a bare
# pipeline the shape backstop then reports NOT secret-shaped on exactly the
# tails densest with secret-shaped material, so the guard fails OPEN. Only
# length exposes it, and the short twin above ("a secret parked in a trailing
# comment is denied") passes either way.

@test "a long secret-shaped comment tail is denied" {
  local runs
  runs=$(yes 'hunter2xyz123' | head -n 4000 | tr '\n' ' ')
  run_hook_write "$(printf 'export API_KEY=%s\n' "\$X # ${runs}")"
  assert_denied
}

# --- `.env.example` is exempt from the ASSIGNMENT rule, and only that rule ---
#
# `.env.example` is a committed file whose entire purpose is to carry
# placeholder assignments, and both sibling guards already say so: the read
# guard exempts it while denying the rest of the dotenv family, and the env
# write guard exempts it by the same basename on this very matcher. The
# assignment rule was the one holdout, so the file that exists to hold
# placeholders could not be edited, and its deny told the author to use a
# gitignored `.env`, which is backwards for exactly this file. Its own tracked
# `SESSION_SECRET` line is the worked example: five letters, so it clears no
# placeholder arm and is not secret-shaped.
#
# The exemption is deliberately NOT a bypass of the hook. The three
# high-confidence pattern rules keep running, so the pastes that actually matter
# in a committed file are still caught; what it gives up is the generic literal,
# which is the honest cost of the file being a placeholder file.

@test "a short placeholder assignment in .env.example is allowed" {
  run_hook_write_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_allowed
}

@test "the tracked .env.example content is allowed whole" {
  run_hook_write_path '.env.example' "$(printf '%s\n%s\n%s\n' \
    'SITE_URL=http://localhost:5173' 'SESSION_SECRET=local' 'MSW_ENABLED=true')"
  assert_allowed
}

@test "a literal assignment in .env.example is allowed through Edit too" {
  run_hook_edit_path '.env.example' "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_allowed
}

@test "a nested .env.example is matched by basename" {
  run_hook_write_path 'packages/api/.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_allowed
}

# The three pattern rules do not care which file they are writing into.

@test "an AWS access-key id in .env.example is still denied" {
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write_path '.env.example' "$(printf 'AWS_ACCESS_KEY_ID=%s\n' "$aws_id")"
  assert_denied
}

@test "a GitHub PAT in .env.example is still denied" {
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write_path '.env.example' "$(printf 'GH_TOKEN=%s\n' "$pat")"
  assert_denied
}

@test "a PEM private-key header in .env.example is still denied" {
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write_path '.env.example' "$pem"
  assert_denied
}

# The exemption is scoped to that one basename, and nothing near it.

@test "the same short value outside .env.example is still denied" {
  run_hook_write_path 'app/config.ts' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_denied
}

@test "a real dotenv file is not exempt" {
  run_hook_write_path '.env' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_denied
}

@test "a name merely starting with .env.example is not exempt" {
  run_hook_write_path '.env.example.local' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_denied
}

# A payload carrying no file_path cannot be exempted, so it is scanned. This is
# what keeps every test written before the guard read a path meaningful, and it
# is the fail-closed direction.

@test "a payload with no file_path is still scanned" {
  run_hook_write "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_denied
}
