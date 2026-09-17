#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-read.sh.
#
# This hook carries the obligation four permissions.deny rules used to hold:
# Read(**/*.key), Read(**/*.pem), Read(**/*credential*) and Read(**/secrets/*).
# Those rules are gone because a `**` Read() deny glob arms Claude Code's
# bypass-immune deniedPathInsideDirectory circuit breaker for every directory in
# the tree, forcing a manual approval prompt on every recursive search or copy.
# The absence of all four is asserted at the bottom of this file, because a
# well-meaning re-addition of any one of them reinstates the prompt storm.
#
# The guard is heuristic defense-in-depth, not a sandbox: it always exits 0,
# carrying the allow/deny decision in stdout JSON.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-secrets-read.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

run_hook_read() {
  local path="$1"
  local json
  json=$(jq -n --arg p "$path" '{tool_name: "Read", tool_input: {file_path: $p}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_grep() {
  local path="$1" glob="$2"
  local json
  json=$(jq -n --arg p "$path" --arg g "$glob" '{
    tool_name: "Grep",
    tool_input: ({pattern: "x"}
      + (if $p == "" then {} else {path: $p} end)
      + (if $g == "" then {} else {glob: $g} end))
  }')
  invoke_hook "$json" "$HOOK_ABS"
}

# Run the hook with lib/reader-operands.sh absent, to exercise the grammar-load
# failure arm.
#
# The hook is COPIED into this test's own temporary directory and driven from
# there, with no library beside it. It must never be exercised by hiding the
# real one: both read-guard suites would target the identical absolute path,
# .gaia/tests/bats-shards.sh weighs by file size and may put them in one shard
# or in two, and .gaia/tests/run-bats-parallel.sh forks every shard into ONE
# shared workspace. One shard is if anything the stronger reason rather than a
# reprieve: the pair then runs sequentially inside a single bats invocation over
# that same one workspace.
# While one suite held the library hidden, every allow-assertion in its sibling
# would see the fail-closed deny, so the pair would flake against each other and
# the concurrency-safety claim that runner makes would be false. The live
# session's own Read, Grep and Bash calls run through these same hooks and would
# be denied for the width of that window too.
#
# The hook resolves its library as `dirname "${BASH_SOURCE[0]}"/lib`, so a copy
# in a directory with an empty lib/ beside it reaches for a file that is not
# there, which is the missing-library arm exactly. The directory is created and
# left empty rather than omitted so the arm under test is the absent FILE rather
# than an unresolvable lib dir; both deny, and pinning the narrower one is what
# makes this a test of the probe instead of a test of `cd`.
run_hook_without_library() {
  local json dir
  dir="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$dir/lib"
  cp "$HOOK_ABS" "$dir/"
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "cat README.md"}}')
  invoke_hook "$json" "$dir/$(basename "$HOOK_ABS")"
}

# --- Read-tool denies, one per path class the removed Read() globs covered ---

@test "Read certs/server.key is denied" {
  run_hook_read "certs/server.key"
  assert_denied_by_json
}

@test "Read certs/server.pem is denied" {
  run_hook_read "certs/server.pem"
  assert_denied_by_json
}

@test "Read config/aws-credentials.json is denied" {
  run_hook_read "config/aws-credentials.json"
  assert_denied_by_json
}

@test "Read secrets/prod.json is denied" {
  run_hook_read "secrets/prod.json"
  assert_denied_by_json
}

@test "Read a nested deploy/secrets/live/token.txt is denied" {
  # The replaced glob matched only a file DIRECTLY inside secrets/. Covering the
  # whole subtree is a deliberate widening: a secret one level deeper is not
  # less of a secret.
  run_hook_read "deploy/secrets/live/token.txt"
  assert_denied_by_json
}

@test "Read config/AWS_Credentials.json is denied (case-insensitive)" {
  # The replaced glob was case-sensitive. This is the second deliberate widening.
  run_hook_read "config/AWS_Credentials.json"
  assert_denied_by_json
}

# --- Read-tool allows: the near-misses a substring match would get wrong ---

@test "Read app/components/Button/index.tsx is allowed" {
  run_hook_read "app/components/Button/index.tsx"
  assert_allowed_by_json
}

@test "Read app/lib/keychain.ts is allowed (not a .key extension)" {
  run_hook_read "app/lib/keychain.ts"
  assert_allowed_by_json
}

@test "Read mysecrets/notes.md is allowed (segment-bounded, not a substring)" {
  run_hook_read "mysecrets/notes.md"
  assert_allowed_by_json
}

@test "Read secrets-old/notes.md is allowed (segment-bounded, not a prefix)" {
  run_hook_read "secrets-old/notes.md"
  assert_allowed_by_json
}

# --- Bash denies: readers against a secret path ---

@test "cat certs/server.key is denied" {
  run_hook_bash "cat certs/server.key"
  assert_denied_by_json
}

@test "grep TOKEN certs/server.pem is denied" {
  run_hook_bash "grep TOKEN certs/server.pem"
  assert_denied_by_json
}

@test "rg TOKEN secrets/prod.json is denied" {
  run_hook_bash "rg TOKEN secrets/prod.json"
  assert_denied_by_json
}

@test "grep -f certs/server.key foo.txt is denied (the pattern FILE is the secret)" {
  run_hook_bash "grep -f certs/server.key foo.txt"
  assert_denied_by_json
}

# The rest of reader-operands.sh's plain-file flags, whose value IS a file the
# reader opens. _GAIA_RO_SHORT_FILE and _GAIA_RO_LONG_FILE_PATTERN also supply
# the pattern, so the positional after them is an ordinary file;
# _GAIA_RO_LONG_FILE_PLAIN names a file of globs and supplies no pattern, so one
# still has to follow. Each command below is written in the spelling that puts
# the secret in the flag's own value.
#
# These are named literally rather than driven from the same tables the derived
# test below reads, and the split is what makes the pair worth having. A
# derivation cannot notice an entry deleted from the table it reads: the set
# just comes back shorter and every member of it still passes. Only a named
# spelling reds when its entry is dropped. The derivation earns its own place
# from the other side: it drives whatever the tables hold at the time it runs,
# so a member added later is covered without anyone remembering to write a test
# for it, and a regression in the operand walk reds against every member rather
# than only against the spellings someone thought to pin.

@test "grep --file certs/server.key foo.txt is denied (the pattern FILE is the secret)" {
  run_hook_bash "grep --file certs/server.key foo.txt"
  assert_denied_by_json
}

@test "grep --exclude-from certs/server.key TOKEN . is denied (the glob FILE is the secret)" {
  run_hook_bash "grep --exclude-from certs/server.key TOKEN ."
  assert_denied_by_json
}

@test "rg --ignore-file certs/server.key TOKEN app is denied (the glob FILE is the secret)" {
  run_hook_bash "rg --ignore-file certs/server.key TOKEN app"
  assert_denied_by_json
}

# --- Bash: filter flags whose value SELECTS the files a search reads ---
#
# The Grep tool arm already denies a `glob` naming a secret class; these pin the
# Bash spellings of the same filter to the same verdict.

@test "rg -g '*.key' TOKEN is denied (the filter selects the secret class)" {
  run_hook_bash "rg -g '*.key' TOKEN"
  assert_denied_by_json
}

@test "rg --glob '*.key' TOKEN is denied" {
  run_hook_bash "rg --glob '*.key' TOKEN"
  assert_denied_by_json
}

@test "rg --iglob '*.key' TOKEN is denied" {
  run_hook_bash "rg --iglob '*.key' TOKEN"
  assert_denied_by_json
}

@test "grep -r TOKEN --include='*.key' . is denied" {
  run_hook_bash "grep -r TOKEN --include='*.key' ."
  assert_denied_by_json
}

@test "grep -r TOKEN --include='*.pem' . is denied" {
  run_hook_bash "grep -r TOKEN --include='*.pem' ."
  assert_denied_by_json
}

@test "rg -g '!*.key' TOKEN is allowed (a negated glob excludes the class)" {
  run_hook_bash "rg -g '!*.key' TOKEN"
  assert_allowed_by_json
}

@test "grep -r TOKEN --exclude=*.key . is allowed (--exclude names files not read)" {
  run_hook_bash "grep -r TOKEN --exclude=*.key ."
  assert_allowed_by_json
}

@test "grep -r TOKEN --exclude-dir=secrets . is allowed" {
  run_hook_bash "grep -r TOKEN --exclude-dir=secrets ."
  assert_allowed_by_json
}

@test "rg -g '*.ts' server.key app is allowed (the select flag still consumes its value)" {
  # If -g stopped consuming its value, '*.ts' would be taken as the pattern and
  # server.key emitted as a file operand.
  run_hook_bash "rg -g '*.ts' server.key app"
  assert_allowed_by_json
}

@test "every plain-file and select flag reader-operands.sh carries denies a secret passed as its value" {
  local lib="$HOOKS_SRC/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$lib"

  # Which tables exist is the library's to say, so read it rather than restate
  # it. Each table needs its own grammar arm below, so one added there and not
  # here would leave this test driving a subset under a name claiming the whole
  # set; comparing the two reds instead, and names the arm to write.
  #
  local declared mentioned missed found known
  declared=$(grep -oE '^_GAIA_RO_[A-Z0-9_]+=' "$lib" | sed 's/=$//' | sort -u)

  # That anchor reads a bare column-0 assignment, which is how this library
  # declares every table today. Rather than widen it once per declaration
  # keyword someone might later reach for, sweep every _GAIA_RO_ name the file
  # mentions at all and require the anchor to have reached each one. A table
  # declared in a shape the anchor cannot read then reds here, rather than
  # sitting outside the comparison below with nothing left to notice it.
  mentioned=$(grep -ohE '_GAIA_RO_[A-Z0-9_]+' "$lib" | sort -u)
  missed=$(comm -23 <(printf '%s\n' "$mentioned") <(printf '%s\n' "$declared"))
  if [ -n "$missed" ]; then
    echo "lib/reader-operands.sh names tables this test's discovery cannot read:" >&2
    echo "  $(echo "$missed" | tr '\n' ' ')" >&2
    return 1
  fi

  # Subtract the tables that carry no flag whose value reaches the predicate,
  # rather than selecting the ones that do by name. Selecting would rest the
  # comparison on a naming convention this test cannot enforce; subtracting puts
  # the burden the other way, so a new table is a mismatch until someone either
  # gives it a grammar arm below or writes it into this list. Deliberately not
  # judged tables: PLAIN_READERS and GREP_READERS hold command words rather than
  # flags, and SHORT_DISCARD and LONG_DISCARD hold the flags whose value the
  # walk throws away. The FILE tables name a file the reader opens; the SELECT
  # tables name a glob choosing which files a recursive search opens.
  found=$(printf '%s\n' "$declared" \
    | grep -vxE '_GAIA_RO_(PLAIN_READERS|GREP_READERS|SHORT_DISCARD|LONG_DISCARD)') || true
  known=$(printf '%s\n' _GAIA_RO_LONG_FILE_PATTERN _GAIA_RO_LONG_FILE_PLAIN _GAIA_RO_SHORT_FILE \
    _GAIA_RO_LONG_SELECT _GAIA_RO_SHORT_SELECT | sort)
  if [ "$found" != "$known" ]; then
    echo "the judged-flag tables in lib/reader-operands.sh are not the ones this test builds commands for" >&2
    echo "  lib:  $(echo "$found" | tr '\n' ' ')" >&2
    echo "  test: $(echo "$known" | tr '\n' ' ')" >&2
    return 1
  fi

  # An empty table contributes no command and leaves this test asserting
  # nothing, which reads exactly like a pass. A table emptied in place passes
  # the comparison above, since the name is still there, so name whichever one
  # went hollow rather than iterating a set that quietly shrank.
  local name
  for name in $known; do
    if [ -z "${!name}" ]; then
      echo "$name is empty in lib/reader-operands.sh" >&2
      return 1
    fi
  done

  # Two spellings per flag, because the walk reaches the value down two
  # different paths: a separate token arrives through the pending branch, an
  # attached or `=` value through the emit beside it. Driving one leaves the
  # other free to be deleted with nothing red.
  #
  # The tables are the union of GNU grep's flags and ripgrep's, so no single
  # command word spells every member and the mismatches below are deliberate.
  # What is under test is the flag's grammar, which the guard reads the same way
  # for every word in its grep family, so one word per grammar is enough.
  local cmds=() f c i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_FILE}" ]; do
    c="${_GAIA_RO_SHORT_FILE:$i:1}"
    cmds+=("grep -$c certs/server.key foo.txt")
    cmds+=("grep -${c}certs/server.key foo.txt")
    i=$((i + 1))
  done
  for f in $_GAIA_RO_LONG_FILE_PATTERN; do
    cmds+=("grep $f certs/server.key foo.txt")
    cmds+=("grep $f=certs/server.key foo.txt")
  done
  for f in $_GAIA_RO_LONG_FILE_PLAIN; do
    cmds+=("rg $f certs/server.key TOKEN app")
    cmds+=("rg $f=certs/server.key TOKEN app")
  done
  i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    c="${_GAIA_RO_SHORT_SELECT:$i:1}"
    cmds+=("rg -$c '*.key' TOKEN")
    cmds+=("rg -$c*.key TOKEN")
    i=$((i + 1))
  done
  for f in $_GAIA_RO_LONG_SELECT; do
    cmds+=("rg $f '*.key' TOKEN")
    cmds+=("rg $f='*.key' TOKEN")
  done

  local cmd allowed=0
  for cmd in "${cmds[@]}"; do
    run_hook_bash "$cmd"
    if [ "$status" -ne 0 ] || ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not denied: $cmd" >&2
      allowed=1
    fi
  done
  [ "$allowed" -eq 0 ]
}

@test "every select flag reader-operands.sh carries allows a negated glob naming the secret class" {
  local lib="$HOOKS_SRC/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$lib"

  # The test above holds the select tables to the library's declarations, so
  # this one only refuses a table emptied in place before deriving from it.
  if [ -z "$_GAIA_RO_SHORT_SELECT" ] || [ -z "$_GAIA_RO_LONG_SELECT" ]; then
    echo "a select table is empty in lib/reader-operands.sh" >&2
    return 1
  fi

  local cmds=() f c i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    c="${_GAIA_RO_SHORT_SELECT:$i:1}"
    cmds+=("rg -$c '!*.key' TOKEN")
    cmds+=("rg -$c!*.key TOKEN")
    i=$((i + 1))
  done
  for f in $_GAIA_RO_LONG_SELECT; do
    cmds+=("rg $f '!*.key' TOKEN")
    cmds+=("rg $f='!*.key' TOKEN")
  done

  local cmd denied=0
  for cmd in "${cmds[@]}"; do
    run_hook_bash "$cmd"
    if [ "$status" -ne 0 ] || grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not allowed: $cmd" >&2
      denied=1
    fi
  done
  [ "$denied" -eq 0 ]
}

@test "x=\$(<certs/server.key) is denied (redirection)" {
  # The single-quoting is deliberate: the payload must reach the hook verbatim
  # so it classifies the literal command text. Never double-quote it, which
  # would expand the substitution here and defeat the test.
  # shellcheck disable=SC2016
  run_hook_bash 'x=$(<certs/server.key)'
  assert_denied_by_json
}

@test "true && cat certs/server.key is denied (compound-command segment walk)" {
  run_hook_bash "true && cat certs/server.key"
  assert_denied_by_json
}

@test "env FOO=1 cat certs/server.key is denied (env as a runner)" {
  run_hook_bash "env FOO=1 cat certs/server.key"
  assert_denied_by_json
}

# --- Bash allows: false-positive guards ---

@test "grep server.key .gitignore is allowed (pattern, not a file read)" {
  # The single most important allow in this file. Without grep argument
  # grammar the pattern operand reads as a path and this denies.
  run_hook_bash "grep server.key .gitignore"
  assert_allowed_by_json
}

@test "ls -la certs/server.key is allowed (non-reading)" {
  run_hook_bash "ls -la certs/server.key"
  assert_allowed_by_json
}

@test "cat mysecrets/notes.md is allowed (segment-bounded)" {
  run_hook_bash "cat mysecrets/notes.md"
  assert_allowed_by_json
}

@test "pnpm dev is allowed" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "cat app/services/env.ts is allowed" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed_by_json
}

@test "bare env is allowed (process dumps are the dotenv guard's remit)" {
  # This hook judges paths only. block-env-read.sh owns the dump question, and
  # duplicating it here would give one command two different refusals.
  run_hook_bash "env"
  assert_allowed_by_json
}

# --- Structural ---

@test "block-secrets-read.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers block-secrets-read.sh under the Read matcher" {
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Read")' block-secrets-read.sh
}

@test "settings.json registers block-secrets-read.sh under the Bash matcher" {
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Bash")' block-secrets-read.sh
}

@test "permissions.deny carries none of the four replaced Read() globs" {
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

# --- Regression: a discard-listed flag that is value-less for the invoked tool ---
#
# Each of these was ALLOWED before the flag tables dropped -r, -T and the bare
# --color/--colour spelling. The flag ate the pattern, the path was then taken
# as the pattern, and the walk emitted no operand at all, so the guard passed a
# secret read through in silence. `-rn` denied throughout, which is what kept
# the class invisible: the idiomatic spelling sat untested beside a working one.

@test "grep -r TOKEN certs/server.key is denied (bare -r is value-less for grep)" {
  run_hook_bash "grep -r TOKEN certs/server.key"
  assert_denied_by_json
}

@test "grep -r TOKEN secrets/prod.json is denied" {
  run_hook_bash "grep -r TOKEN secrets/prod.json"
  assert_denied_by_json
}

@test "grep -T TOKEN certs/server.pem is denied (bare -T is value-less for grep)" {
  run_hook_bash "grep -T TOKEN certs/server.pem"
  assert_denied_by_json
}

@test "grep --color TOKEN certs/server.key is denied (optional-value for grep)" {
  run_hook_bash "grep --color TOKEN certs/server.key"
  assert_denied_by_json
}

@test "grep --colour TOKEN certs/server.key is denied" {
  run_hook_bash "grep --colour TOKEN certs/server.key"
  assert_denied_by_json
}

@test "rg -r X secrets/prod.json is denied (over-reads the pattern, fail-closed)" {
  run_hook_bash "rg -r X secrets/prod.json"
  assert_denied_by_json
}

@test "grep --color=auto server.key .gitignore is allowed (= form supplies its own value)" {
  run_hook_bash "grep --color=auto server.key .gitignore"
  assert_allowed_by_json
}

# --- Grep tool: content mode returns file contents, so it reads a path ---

@test "Grep path certs/server.key is denied" {
  run_hook_grep "certs/server.key" ""
  assert_denied_by_json
}

@test "Grep path secrets/prod.json is denied" {
  run_hook_grep "secrets/prod.json" ""
  assert_denied_by_json
}

@test "Grep glob *.key is denied (the filter selects the secret class)" {
  run_hook_grep "" "*.key"
  assert_denied_by_json
}

@test "Grep path app/lib/keychain.ts is allowed" {
  run_hook_grep "app/lib/keychain.ts" ""
  assert_allowed_by_json
}

@test "settings.json registers block-secrets-read.sh under the Grep matcher" {
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Grep")' block-secrets-read.sh
}

# --- Fail-closed on a grammar-load failure ---
#
# The arm this pins used to be `exit 1`. Only exit 2 or a structured deny blocks
# a PreToolUse call, so a missing library allowed every secret read with a
# stderr line as the only trace. Asserting the deny payload rather than the exit
# status is the point: the exit status was 1 then and is 0 now, and neither
# value distinguishes a guard that is running from one that is not.

@test "a missing lib/reader-operands.sh denies rather than allowing the call" {
  run_hook_without_library
  assert_denied_by_json
}

# --- The sandbox tier the removed Read() rules used to carry ---

@test "settings.json declares sandbox.filesystem.denyRead for the secret classes" {
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ["**/*.key", "**/*.pem", "**/*credential*", "**/secrets/**"]
    | all(. as $needle | $d | index($needle) != null)
  ' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

# --- Regression: a command substitution in either spelling ---
#
# The segment split reaches into `$(...)` because the parens are in its
# character set, and used not to reach into a backtick pair. The two spellings
# of one read therefore disagreed, and the backtick form was allowed.

@test "x=\$(cat certs/server.key) is denied (dollar-paren substitution)" {
  run_hook_bash 'x=$(cat certs/server.key)'
  assert_denied_by_json
}

@test "x=\`cat certs/server.key\` is denied (backtick substitution)" {
  run_hook_bash 'x=`cat certs/server.key`'
  assert_denied_by_json
}

@test "echo \`cat secrets/prod.json\` is denied (reader hidden inside a backtick pair)" {
  run_hook_bash 'echo `cat secrets/prod.json`'
  assert_denied_by_json
}
