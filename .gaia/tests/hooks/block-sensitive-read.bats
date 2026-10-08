#!/usr/bin/env bats

# Tests for .claude/hooks/block-sensitive-read.sh.
#
# One read-side guard for two path classes. The dotenv class covers the Read
# tool and the Bash readers (including the grep family) against .env and every
# variant (.env.local, .env.*, not .env.example), sourcing, redirection, and
# bare environment dumps (env/printenv). The secret-path class covers the paths
# four Read() deny globs used to hold: *.key, *.pem, any name containing
# "credential", and anything under a secrets/ directory. When an input matches
# both classes the dotenv reason is the one emitted.
#
# The guard is heuristic defense-in-depth, not a sandbox: it always exits 0,
# carrying the allow/deny decision in stdout JSON.
#
# The settings.json assertions pin the absence of every Read() deny rule. That
# absence is load-bearing rather than incidental: a single Read() rule re-arms
# Claude Code's bypass-immune deniedPathInsideDirectory circuit breaker, which
# forces a manual approval prompt on every recursive search or copy in the tree.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-sensitive-read.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
}

# Several payloads below carry Bash commands with single quotes of their own
# (grep '.env' .gitignore), so delivery goes through `invoke_hook`
# (helpers/run-hook.sh) rather than any local variant.
run_hook_read() {
  local path="$1"
  local json
  json=$(jq -n --arg file_path "$path" '{tool_name: "Read", tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_bash() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_grep() {
  local path="$1" glob="$2"
  local json
  json=$(jq -n --arg search_path "$path" --arg glob "$glob" '{
    tool_name: "Grep",
    tool_input: ({pattern: "x"}
      + (if $search_path == "" then {} else {path: $search_path} end)
      + (if $glob == "" then {} else {glob: $glob} end))
  }')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# Run the hook with lib/reader-operands.sh absent, to exercise the grammar-load
# failure arm.
#
# The hook is COPIED into this test's own temporary directory and driven from
# there, with no library beside it. It must never be exercised by hiding the
# real one: every other suite and the live session's own Read, Grep and Bash calls
# run through the real hook at the identical absolute path, and would see the
# fail-closed deny for the width of the window the library was hidden.
#
# The hook resolves its library as `dirname "${BASH_SOURCE[0]}"/lib`, so a copy
# in a directory with an empty lib/ beside it reaches for a file that is not
# there, which is the missing-library arm exactly. The directory is created and
# left empty rather than omitted so the arm under test is the absent FILE rather
# than an unresolvable lib dir; both deny, and pinning the narrower one is what
# makes this a test of the probe instead of a test of `cd`.
run_hook_without_library() {
  local json directory command_line="${1:-cat README.md}"
  directory="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$directory/lib"
  cp "$HOOK_ABSOLUTE_PATH" "$directory/"
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$directory/$(basename "$HOOK_ABSOLUTE_PATH")"
}



# --- Read-tool denies ---

@test "Read .env.local is denied" {
  run_hook_read ".env.local"
  assert_denied_by_json
}

@test "Read .env.production is denied" {
  run_hook_read ".env.production"
  assert_denied_by_json
}

@test "Read a nested packages/api/.env.production is denied" {
  run_hook_read "packages/api/.env.production"
  assert_denied_by_json
}

# --- Read-tool allow ---

@test "Read .env.example is allowed" {
  run_hook_read ".env.example"
  assert_allowed_by_json
}

# --- Bash denies: recognized readers against variants ---

@test "cat .env.local is denied" {
  run_hook_bash "cat .env.local"
  assert_denied_by_json
}

@test "cat .env.production is denied" {
  run_hook_bash "cat .env.production"
  assert_denied_by_json
}

@test "cat a nested packages/api/.env.production is denied" {
  run_hook_bash "cat packages/api/.env.production"
  assert_denied_by_json
}

# --- Bash denies: residual read paths ---

@test "source .env is denied" {
  run_hook_bash "source .env"
  assert_denied_by_json
}

@test ". ./.env is denied" {
  run_hook_bash ". ./.env"
  assert_denied_by_json
}

@test "x=\$(<.env) is denied" {
  # The single-quoting is deliberate: the payload must reach the hook verbatim
  # so it classifies the literal command text. Never double-quote it, which
  # would expand $(<.env) here and defeat the test.
  # shellcheck disable=SC2016
  run_hook_bash 'x=$(<.env)'
  assert_denied_by_json
}

@test "xxd .env is denied" {
  run_hook_bash "xxd .env"
  assert_denied_by_json
}

@test "true && cat .env.local is denied (compound-command segment walk)" {
  run_hook_bash "true && cat .env.local"
  assert_denied_by_json
}

@test "cd /tmp; cat .env.local is denied (semicolon segment walk)" {
  run_hook_bash "cd /tmp; cat .env.local"
  assert_denied_by_json
}

@test "false || cat .env.local is denied (or segment walk)" {
  run_hook_bash "false || cat .env.local"
  assert_denied_by_json
}

# --- Bash denies: bare environment dumps ---

@test "bare env is denied" {
  run_hook_bash "env"
  assert_denied_by_json
}

@test "bare printenv is denied" {
  run_hook_bash "printenv"
  assert_denied_by_json
}

@test "printenv NODE_ENV is denied (printenv has no runner form)" {
  run_hook_bash "printenv NODE_ENV"
  assert_denied_by_json
}

# --- Bash allows: env as a runner ---

@test "env NODE_ENV=production node app.js is allowed" {
  run_hook_bash "env NODE_ENV=production node app.js"
  assert_allowed_by_json
}

# --- Bash allows: false-positive guards ---

@test "pnpm dev is allowed" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "pnpm i && pnpm dev is allowed (benign compound command)" {
  run_hook_bash "pnpm i && pnpm dev"
  assert_allowed_by_json
}

@test "cat app/services/env.ts is allowed" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed_by_json
}

@test "cat README.md is allowed" {
  run_hook_bash "cat README.md"
  assert_allowed_by_json
}

@test "cp .env.example .env is allowed" {
  run_hook_bash "cp .env.example .env"
  assert_allowed_by_json
}

@test "grep '.env' .gitignore is allowed (pattern, not a file read)" {
  run_hook_bash "grep '.env' .gitignore"
  assert_allowed_by_json
}

# --- Bash denies: the grep family, which needs argument grammar ---

@test "grep SECRET .env is denied" {
  run_hook_bash "grep SECRET .env"
  assert_denied_by_json
}

@test "grep -rn SECRET .env.local is denied" {
  run_hook_bash "grep -rn SECRET .env.local"
  assert_denied_by_json
}

@test "rg SECRET .env.production is denied" {
  run_hook_bash "rg SECRET .env.production"
  assert_denied_by_json
}

@test "grep -f pats.txt .env.local is denied (the target file, not the pattern file)" {
  # -f names a file of patterns, which grep opens itself; this walk does not
  # treat that value as a candidate. The positional target file after it still
  # is.
  run_hook_bash "grep -f pats.txt .env.local"
  assert_denied_by_json
}

# --- Bash allows: the grep family, pattern operand not mistaken for a path ---

@test "grep -e .env .gitignore is allowed (-e supplies the pattern)" {
  run_hook_bash "grep -e .env .gitignore"
  assert_allowed_by_json
}

@test "grep --include=*.ts SECRET app is allowed" {
  run_hook_bash "grep --include=*.ts SECRET app"
  assert_allowed_by_json
}

# --- Bash: filter flags whose value SELECTS the files a search reads ---

@test "grep -r SECRET --include='.env' . is denied (the filter selects the dotenv class)" {
  run_hook_bash "grep -r SECRET --include='.env' ."
  assert_denied_by_json
}

@test "rg -g '.env*' SECRET is denied" {
  run_hook_bash "rg -g '.env*' SECRET"
  assert_denied_by_json
}

@test "rg --glob=.env.local SECRET is denied" {
  run_hook_bash "rg --glob=.env.local SECRET"
  assert_denied_by_json
}

@test "rg -g '!.env*' SECRET stays allowed" {
  # Not a guard on the negation skip: is_dotenv_path never matches a basename
  # starting with `!`, so this stays green with the skip removed. The skip is
  # guarded by the table-driven negated-glob test further down this file.
  run_hook_bash "rg -g '!.env*' SECRET"
  assert_allowed_by_json
}

@test "grep -r -g '!*.md,.env*' SECRET . is denied (ugrep negates each comma-list element alone)" {
  run_hook_bash "grep -r -g '!*.md,.env*' SECRET ."
  assert_denied_by_json
}

@test "grep -r -g '*.md,.env.local' SECRET . is denied (each comma-list element is judged)" {
  run_hook_bash "grep -r -g '*.md,.env.local' SECRET ."
  assert_denied_by_json
}

@test "grep -r SECRET --exclude=.env . is allowed (--exclude names files not read)" {
  run_hook_bash "grep -r SECRET --exclude=.env ."
  assert_allowed_by_json
}

@test "rg -g '*.ts' .env app is allowed (the select flag still consumes its value)" {
  run_hook_bash "rg -g '*.ts' .env app"
  assert_allowed_by_json
}

@test "grep SECRET .env.example is allowed" {
  run_hook_bash "grep SECRET .env.example"
  assert_allowed_by_json
}

@test "rg --ignore-file .rgignore SECRET app is allowed" {
  # --ignore-file names a file of globs and supplies no pattern, so the
  # positional after it is still the pattern rather than a path.
  run_hook_bash "rg --ignore-file .rgignore SECRET app"
  assert_allowed_by_json
}

@test "ls -la .env is allowed (non-reading)" {
  run_hook_bash "ls -la .env"
  assert_allowed_by_json
}

@test "cat .env.example is allowed " {
  run_hook_bash "cat .env.example"
  assert_allowed_by_json
}

# --- Structural ---

@test "block-sensitive-read.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh under the Read matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Read")' block-sensitive-read.sh
}

@test "settings.json registers block-sensitive-read.sh on the Bash|Monitor matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-sensitive-read.sh
}

# The Bash|Monitor matcher delivers Monitor payloads too, and a Monitor
# command reads files exactly as a Bash command does.
run_hook_monitor() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Monitor", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

@test "Monitor cat .env.local is denied" {
  run_hook_monitor "cat .env.local"
  assert_denied_by_json
}

@test "Monitor tail on a secret path is denied" {
  run_hook_monitor "tail -f secrets/api.key"
  assert_denied_by_json
}

@test "Monitor tail on an ordinary log is allowed" {
  run_hook_monitor "tail -f app.log"
  assert_allowed_by_json
}

@test "permissions.deny carries no Read() rule at all" {
  # Not merely "no Read(.env)": ANY Read() deny rule arms the bypass-immune
  # deniedPathInsideDirectory breaker, so the guarantee this hook is paid to
  # provide is the empty set, and a well-meaning re-addition of any one of them
  # silently reinstates the prompt storm this suite exists to keep away.
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "permissions.deny keeps the write-side .env backstop" {
  # Edit(.env) blocks every file-writing tool (Write, Edit, MultiEdit,
  # NotebookEdit), so a separate Write(.env) deny is redundant and is
  # intentionally absent. Only the READ half moved to the hook layer; an Edit()
  # rule arms no read breaker and therefore costs nothing to keep.
  run jq -e '.permissions.deny | index("Edit(.env)")' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "permissions.deny adds no .env.example deny and no .env.* glob" {
  run jq -e '[.permissions.deny[] | select(contains(".env.example") or contains(".env.*"))] | length == 0' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# --- Regression: a discard-listed flag that is value-less for the invoked tool ---
#
# Each of these was ALLOWED before the flag tables dropped -r, -T and the bare
# --color/--colour spelling. The flag ate the pattern, the path was then taken
# as the pattern, and the walk emitted no operand at all, so the guard passed a
# dotenv read through in silence. `-rn` and `-R` denied throughout, which is
# what kept the class invisible: `grep -r PATTERN PATH` is the most idiomatic
# recursive spelling there is, and it sat untested beside two working ones.

@test "grep -r SECRET .env is denied (bare -r is value-less for grep)" {
  run_hook_bash "grep -r SECRET .env"
  assert_denied_by_json
}

@test "grep -ir PASSWORD .env.production is denied (clustered, -r last)" {
  run_hook_bash "grep -ir PASSWORD .env.production"
  assert_denied_by_json
}

@test "grep -T SECRET .env is denied (bare -T is value-less for grep)" {
  run_hook_bash "grep -T SECRET .env"
  assert_denied_by_json
}

@test "grep --color SECRET .env is denied (optional-value for grep)" {
  run_hook_bash "grep --color SECRET .env"
  assert_denied_by_json
}

@test "grep --colour SECRET .env is denied" {
  run_hook_bash "grep --colour SECRET .env"
  assert_denied_by_json
}

@test "rg -r X .env.local is denied (over-reads the pattern, fail-closed)" {
  run_hook_bash "rg -r X .env.local"
  assert_denied_by_json
}

@test "grep --color=auto .env .gitignore is allowed (= form supplies its own value)" {
  run_hook_bash "grep --color=auto .env .gitignore"
  assert_allowed_by_json
}

# --- Grep tool: content mode returns file contents, so it reads a path ---

@test "Grep path .env.production is denied" {
  run_hook_grep ".env.production" ""
  assert_denied_by_json
}

@test "Grep glob .env is denied (the filter selects the dotenv class)" {
  run_hook_grep "" ".env"
  assert_denied_by_json
}

@test "Grep path .env.example is allowed" {
  run_hook_grep ".env.example" ""
  assert_allowed_by_json
}

@test "Grep path app/routes is allowed" {
  run_hook_grep "app/routes" ""
  assert_allowed_by_json
}

@test "settings.json registers block-sensitive-read.sh under the Grep matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Grep")' block-sensitive-read.sh
}

# --- Fail-closed on a grammar-load failure ---
#
# The arm this pins used to be `exit 1`. Only exit 2 or a structured deny blocks
# a PreToolUse call, so a missing library allowed every dotenv read with a
# stderr line as the only trace. Asserting the deny payload rather than the exit
# status is the point: the exit status was 1 then and is 0 now, and neither
# value distinguishes a guard that is running from one that is not.

@test "a missing lib/reader-operands.sh denies a dotenv read rather than allowing the call" {
  run_hook_without_library 'cat .env.local'
  assert_denied_by_json
  grep -qF -- 'BLOCKED: block-sensitive-read.sh could not load lib/reader-operands.sh, so the read-side dotenv and secret-path guard is not running. This denial is fail-closed by design. Restore .claude/hooks/lib/reader-operands.sh to clear it.' <<<"$output"
}

# --- The sandbox tier the removed Read(.env) rule used to carry ---
#
# Read(.env) merged into the OS sandbox boundary, where it reached a subprocess
# spawned by sandboxed Bash. A hook never sees a subprocess open(), so deleting
# the rule without this declaration would have dropped that tier in silence.

@test "settings.json declares sandbox.filesystem.denyRead for the dotenv class" {
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ($d | index(".env")) != null and ($d | index(".env.*")) != null
  ' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# A sandbox filesystem path with no prefix resolves against the project root, so
# the bare pair above reaches the root dotenv and nothing deeper. This hook
# decides on the basename and denies a dotenv at any depth, so without the
# depth-qualified pair the tool tier and the subprocess tier disagree about the
# same file in a monorepo.
@test "settings.json denies the dotenv class at any depth, not only at the root" {
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ($d | index("**/.env")) != null and ($d | index("**/.env.*")) != null
  ' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json keeps .env.example readable inside the sandbox deny" {
  run jq -e '
    .sandbox.filesystem.allowRead as $a
    | ($a | index(".env.example")) != null
      and ($a | index("**/.env.example")) != null
  ' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# --- Regression: a command substitution ---
#
# The segment split reaches into `$(...)` because the parens are in its
# character set.

@test "x=\$(cat .env) is denied (dollar-paren substitution)" {
  run_hook_bash 'x=$(cat .env)'
  assert_denied_by_json
}

# --- Regression: a glob spelling of a dotenv read ---
#
# `.env*` and `.env.*` each expand to every dotenv file in the directory, so they
# read the same bytes the literal path does. The predicate matches the literal
# spellings with a regex, which no metacharacter satisfies, so the globs were
# allowed while `cat .env` beside them was denied. The sibling secrets predicate
# never had the gap, because it matches with `case` globs.

@test "cat .env* is denied (glob spelling of the dotenv read)" {
  run_hook_bash 'cat .env*'
  assert_denied_by_json
}

@test "cat .env.* is denied (dotted glob spelling)" {
  run_hook_bash 'cat .env.*'
  assert_denied_by_json
}

@test "cat .env? is denied (single-character glob)" {
  run_hook_bash 'cat .env?'
  assert_denied_by_json
}

@test "cat .environment is allowed (the stem is not a dotenv variant)" {
  run_hook_bash 'cat .environment'
  assert_allowed_by_json
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

@test "Read app/components/button/index.tsx is allowed" {
  run_hook_read "app/components/button/index.tsx"
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

@test "grep -f pats.txt certs/server.key is denied (the target file, not the pattern file)" {
  run_hook_bash "grep -f pats.txt certs/server.key"
  assert_denied_by_json
}

# --file (long form of -f) supplies the pattern the same way -e/--regexp does,
# so the positional after it is still an ordinary target file; --exclude-from
# and --ignore-file name a file of globs and supply no pattern, so one still
# has to follow. None of the three flags' own values reach the predicate: grep
# opens them itself, but this walk does not treat them as candidates.

@test "grep --file pats.txt certs/server.key is denied (the target file, not the pattern file)" {
  run_hook_bash "grep --file pats.txt certs/server.key"
  assert_denied_by_json
}

@test "grep --exclude-from globs.txt TOKEN certs/server.key is denied (the target file, not the glob file)" {
  run_hook_bash "grep --exclude-from globs.txt TOKEN certs/server.key"
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

@test "grep -r -g '!*.md,*.key' TOKEN . is denied (ugrep negates each comma-list element alone)" {
  run_hook_bash "grep -r -g '!*.md,*.key' TOKEN ."
  assert_denied_by_json
}

@test "grep -r --glob='*.md,*.key' TOKEN . is denied (each comma-list element is judged)" {
  run_hook_bash "grep -r --glob='*.md,*.key' TOKEN ."
  assert_denied_by_json
}

@test "grep -r -g '!*.key,!*.pem' TOKEN . is allowed (every element negated)" {
  run_hook_bash "grep -r -g '!*.key,!*.pem' TOKEN ."
  assert_allowed_by_json
}

@test "grep -r -g '^*.key' TOKEN . is allowed (ugrep reads a leading ^ as an exclusion)" {
  run_hook_bash "grep -r -g '^*.key' TOKEN ."
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

@test "every select flag reader-operands.sh carries denies a secret passed as its value" {
  local library_path="$HOOKS_SOURCE_DIRECTORY/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$library_path"

  # Which tables exist is the library's to say, so read it rather than restate
  # it. Each table needs its own grammar arm below, so one added there and not
  # here would leave this test driving a subset under a name claiming the whole
  # set; comparing the two reds instead, and names the arm to write.
  #
  local declared mentioned missed found known
  declared=$(grep -oE '^_GAIA_RO_[A-Z0-9_]+=' "$library_path" | sed 's/=$//' | sort -u)

  # That anchor reads a bare column-0 assignment, which is how this library
  # declares every table today. Rather than widen it once per declaration
  # keyword someone might later reach for, sweep every _GAIA_RO_ name the file
  # mentions at all and require the anchor to have reached each one. A table
  # declared in a shape the anchor cannot read then reds here, rather than
  # sitting outside the comparison below with nothing left to notice it.
  mentioned=$(grep -ohE '_GAIA_RO_[A-Z0-9_]+' "$library_path" | sort -u)
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
  # walk throws away (including the file-of-patterns/globs flags: their value is
  # opened by grep itself, but this walk does not treat it as a candidate). The
  # SELECT tables name a glob choosing which files a recursive search opens.
  found=$(printf '%s\n' "$declared" \
    | grep -vxE '_GAIA_RO_(PLAIN_READERS|GREP_READERS|SHORT_DISCARD|LONG_DISCARD)') || true
  known=$(printf '%s\n' _GAIA_RO_LONG_SELECT _GAIA_RO_SHORT_SELECT | sort)
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
  local command_lines=() long_flag flag_letter i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    flag_letter="${_GAIA_RO_SHORT_SELECT:$i:1}"
    command_lines+=("rg -$flag_letter '*.key' TOKEN")
    command_lines+=("rg -$flag_letter*.key TOKEN")
    i=$((i + 1))
  done
  for long_flag in $_GAIA_RO_LONG_SELECT; do
    command_lines+=("rg $long_flag '*.key' TOKEN")
    command_lines+=("rg $long_flag='*.key' TOKEN")
  done

  local command_line allowed=0
  for command_line in "${command_lines[@]}"; do
    run_hook_bash "$command_line"
    if [ "$status" -ne 0 ] || ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not denied: $command_line" >&2
      allowed=1
    fi
  done
  [ "$allowed" -eq 0 ]
}

@test "every select flag reader-operands.sh carries allows a negated glob naming the secret class" {
  local library_path="$HOOKS_SOURCE_DIRECTORY/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$library_path"

  # The test above holds the select tables to the library's declarations, so
  # this one only refuses a table emptied in place before deriving from it.
  if [ -z "$_GAIA_RO_SHORT_SELECT" ] || [ -z "$_GAIA_RO_LONG_SELECT" ]; then
    echo "a select table is empty in lib/reader-operands.sh" >&2
    return 1
  fi

  local command_lines=() long_flag flag_letter i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    flag_letter="${_GAIA_RO_SHORT_SELECT:$i:1}"
    command_lines+=("rg -$flag_letter '!*.key' TOKEN")
    command_lines+=("rg -$flag_letter!*.key TOKEN")
    i=$((i + 1))
  done
  for long_flag in $_GAIA_RO_LONG_SELECT; do
    command_lines+=("rg $long_flag '!*.key' TOKEN")
    command_lines+=("rg $long_flag='!*.key' TOKEN")
  done

  local command_line denied=0
  for command_line in "${command_lines[@]}"; do
    run_hook_bash "$command_line"
    if [ "$status" -ne 0 ] || grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not allowed: $command_line" >&2
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

@test "pnpm dev is allowed by the secret-path class" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "cat app/services/env.ts is allowed by the secret-path class" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed_by_json
}

@test "bare env is denied with the dump reason, not a secret-path reason" {
  run_hook_bash "env"
  assert_denied_by_json
  grep -qF -- 'a bare environment dump' <<<"$output"
  grep -qF -- 'key, certificate, or credential' <<<"$output" && return 1
  return 0
}

# --- Structural ---

@test "no settings.json handler names a retired read guard" {
  run jq -e '[.. | strings | select(contains("block-env-read.sh") or contains("block-secrets-read.sh") or contains("block-env-write.sh"))] | length == 0' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh exactly once under the Read matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh exactly once on the Bash|Monitor matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "permissions.deny carries none of the four replaced Read() globs" {
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS_ABSOLUTE_PATH"
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

@test "settings.json registers block-sensitive-read.sh exactly once under the Grep matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Grep") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# --- Fail-closed on a grammar-load failure ---
#
# The arm this pins used to be `exit 1`. Only exit 2 or a structured deny blocks
# a PreToolUse call, so a missing library allowed every secret read with a
# stderr line as the only trace. Asserting the deny payload rather than the exit
# status is the point: the exit status was 1 then and is 0 now, and neither
# value distinguishes a guard that is running from one that is not.

@test "a missing lib/reader-operands.sh denies a secret-path read rather than allowing the call" {
  run_hook_without_library 'cat certs/server.key'
  assert_denied_by_json
  grep -qF -- 'BLOCKED: block-sensitive-read.sh could not load lib/reader-operands.sh, so the read-side dotenv and secret-path guard is not running. This denial is fail-closed by design. Restore .claude/hooks/lib/reader-operands.sh to clear it.' <<<"$output"
}

# --- The sandbox tier the removed Read() rules used to carry ---

@test "settings.json declares sandbox.filesystem.denyRead for the secret classes" {
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ["**/*.key", "**/*.pem", "**/*credential*", "**/secrets/**"]
    | all(. as $needle | $d | index($needle) != null)
  ' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# --- Regression: a command substitution ---
#
# The segment split reaches into `$(...)` because the parens are in its
# character set.

@test "x=\$(cat certs/server.key) is denied (dollar-paren substitution)" {
  run_hook_bash 'x=$(cat certs/server.key)'
  assert_denied_by_json
}

# --- Each path class keeps its own deny reason, dotenv ruling first ---

@test "Read .env.local is denied with the dotenv tool reason" {
  run_hook_read ".env.local"
  assert_denied_by_json
  grep -qF -- "reading '.env' / '.env.*' files is denied to protect local secrets. Only '.env.example' is readable." <<<"$output"
}

@test "Read id_rsa.pem is denied with the secret-path tool reason" {
  run_hook_read "id_rsa.pem"
  assert_denied_by_json
  grep -qF -- "reading key, certificate, and credential files is denied to protect local secrets." <<<"$output"
}

@test "cat .env is denied with the dotenv reader reason" {
  run_hook_bash "cat .env"
  assert_denied_by_json
  grep -qF -- "reading a .env / .env.* file (a reader, sourcing, or redirection) is denied" <<<"$output"
}

@test "cat certs/server.key is denied with the secret-path reader reason" {
  run_hook_bash "cat certs/server.key"
  assert_denied_by_json
  grep -qF -- "a command here reads a key, certificate, or credential path" <<<"$output"
}

@test "printenv is denied with the dump reason" {
  run_hook_bash "printenv"
  assert_denied_by_json
  grep -qF -- "a bare environment dump (env/printenv) is denied" <<<"$output"
}

@test "Grep with path secrets/ is denied with the secret-path tool reason" {
  run_hook_grep "secrets/" ""
  assert_denied_by_json
  grep -qF -- "reading key, certificate, and credential files is denied" <<<"$output"
}

@test "Read secrets/.env emits the dotenv reason, not the secret-path one" {
  run_hook_read "secrets/.env"
  assert_denied_by_json
  grep -qF -- "reading '.env' / '.env.*' files is denied" <<<"$output"
  grep -qF -- "reading key, certificate, and credential files" <<<"$output" && return 1
  return 0
}

@test "a command naming a key path before a dotenv path emits the dotenv reason" {
  run_hook_bash "cat certs/server.key; cat .env.local"
  assert_denied_by_json
  grep -qF -- "reading a .env / .env.* file" <<<"$output"
  grep -qF -- "reads a key, certificate, or credential path" <<<"$output" && return 1
  return 0
}

# --- the shared payload reader ---

# A scratch copy of the hooks directory with lib/hook-payload.sh removed, so the
# real library is never hidden from the live session's own calls.
@test "a missing lib/hook-payload.sh refuses a dotenv read rather than allowing the call" {
  local scratch_directory="$BATS_TEST_TMPDIR/no-payload-lib" json
  mkdir -p "$scratch_directory"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch_directory/lib"
  rm -f "$scratch_directory/lib/hook-payload.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch_directory/"
  json=$(jq -n --arg file_path ".env" '{tool_name: "Read", tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$scratch_directory/block-sensitive-read.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/hook-payload.sh' <<<"$output"
}

@test "an ordinary Bash call and a Read call each run at most one jq" {
  local shim_directory="$BATS_TEST_TMPDIR/shim" real_jq json
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  PATH="$shim_directory:$PATH" invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log")" -le 1 ]
  rm -f "$BATS_TEST_TMPDIR/calls.log"
  json=$(jq -n '{tool_name: "Read", tool_input: {file_path: "app/root.tsx"}}')
  PATH="$shim_directory:$PATH" invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log")" -le 1 ]
}
