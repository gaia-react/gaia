#!/usr/bin/env bats

# Tests for .claude/hooks/block-rm-rf.sh.
#
# The guard denies the well-known `rm -rf` footguns (root, $HOME / ~, cwd,
# unscoped glob, .git, node_modules, --no-preserve-root) while letting the
# whitelisted scratch paths and unknown relative paths through. It is
# best-effort defense-in-depth, not airtight: it always exits 0, carrying the
# allow/deny decision in stdout JSON, and broader policy lives in
# settings.json permissions.
#
# The quoting axis is the point of this suite. `read -r -a` word-splits but
# does not remove quote characters, so a target must be matched with its
# quotes stripped: `rm -rf "$HOME"` is the *careful* way to write the
# expansion and has to be denied exactly like the bare `rm -rf $HOME`. Each
# dangerous target is therefore asserted in three shapes, bare, double-quoted,
# and single-quoted, plus the partially-quoted `"$HOME"/projects` form where
# the quotes sit inside the token rather than around it.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-rm-rf.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Quote-safe delivery (mandatory): every payload here is about quoting, so the
# command text must reach the hook byte-for-byte. Passing $json and $HOME_ABS
# as positional args means no outer re-quoting can strip the inner quotes
# under test. Payloads are written in single quotes so `$HOME` stays the
# literal 5-character string the guard must match, never this machine's home.
run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# Asserts the deny fired for the *stated* reason, not merely that some deny
# fired. Without this, a target denied by the wrong case arm (say, `$HOME`
# caught by the absolute-path arm) still reads as a pass.
assert_denied_because() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  grep -qF -- "$1" <<<"$output"
}

# --- denied: bare targets ---

@test "rm -rf / is denied" {
  run_hook_bash 'rm -rf /'
  assert_denied
}

@test "rm -rf \$HOME is denied" {
  run_hook_bash 'rm -rf $HOME'
  assert_denied
}

@test "rm -rf ~ is denied" {
  run_hook_bash 'rm -rf ~'
  assert_denied
}

@test "rm -rf ~/ is denied" {
  run_hook_bash 'rm -rf ~/'
  assert_denied
}

@test "rm -rf \$HOME/projects is denied" {
  run_hook_bash 'rm -rf $HOME/projects'
  assert_denied
}

@test "rm -rf . is denied" {
  run_hook_bash 'rm -rf .'
  assert_denied
}

@test "rm -rf * is denied" {
  run_hook_bash 'rm -rf *'
  assert_denied
}

@test "rm -rf .git is denied" {
  run_hook_bash 'rm -rf .git'
  assert_denied
}

@test "rm -rf node_modules is denied" {
  run_hook_bash 'rm -rf node_modules'
  assert_denied
}

@test "rm -fr / (reversed flags) is denied" {
  run_hook_bash 'rm -fr /'
  assert_denied
}

@test "rm --no-preserve-root -rf / is denied" {
  run_hook_bash 'rm --no-preserve-root -rf /'
  assert_denied
}

# --- denied: double-quoted targets ---
#
# Quoting the expansion is the correct, careful shell idiom, and it is exactly
# the shape a quote-blind guard misses. These must deny identically to the
# bare forms above.

@test "rm -rf \"\$HOME\" (quoted) is denied" {
  run_hook_bash 'rm -rf "$HOME"'
  assert_denied
}

@test "rm -rf \"/\" (quoted) is denied" {
  run_hook_bash 'rm -rf "/"'
  assert_denied
}

@test "rm -rf \".\" (quoted) is denied" {
  run_hook_bash 'rm -rf "."'
  assert_denied
}

@test "rm -rf \"*\" (quoted) is denied" {
  run_hook_bash 'rm -rf "*"'
  assert_denied
}

@test "rm -rf \"~\" (quoted) is denied" {
  run_hook_bash 'rm -rf "~"'
  assert_denied
}

@test "rm -rf \".git\" (quoted) is denied" {
  run_hook_bash 'rm -rf ".git"'
  assert_denied
}

@test "rm -rf \"node_modules\" (quoted) is denied" {
  run_hook_bash 'rm -rf "node_modules"'
  assert_denied
}

@test "rm -rf \"\$HOME/projects\" (fully quoted path) is denied" {
  run_hook_bash 'rm -rf "$HOME/projects"'
  assert_denied
}

@test "rm -rf \"\$HOME\"/projects (quotes inside the token) is denied" {
  # Quoting only the expansion and leaving the rest bare is just as idiomatic,
  # and leaves the quote characters mid-token rather than surrounding it.
  run_hook_bash 'rm -rf "$HOME"/projects'
  assert_denied
}

# --- denied: single-quoted targets ---

@test "rm -rf '\$HOME' (single-quoted) is denied" {
  run_hook_bash "rm -rf '\$HOME'"
  assert_denied
}

@test "rm -rf '/' (single-quoted) is denied" {
  run_hook_bash "rm -rf '/'"
  assert_denied
}

@test "rm -rf '.git' (single-quoted) is denied" {
  run_hook_bash "rm -rf '.git'"
  assert_denied
}

# --- denied: the ${HOME} brace form ---
#
# `${HOME}` is, if anything, the more deliberate spelling of the expansion, so
# omitting it reproduces the very bug this suite exists to lock down: the guard
# catching the casual form and missing the careful one.

@test "rm -rf \${HOME} (brace form) is denied" {
  run_hook_bash 'rm -rf ${HOME}'
  assert_denied
}

@test "rm -rf \"\${HOME}\" (quoted brace form) is denied" {
  run_hook_bash 'rm -rf "${HOME}"'
  assert_denied
}

@test "rm -rf \"\${HOME}/projects\" (quoted brace path) is denied" {
  run_hook_bash 'rm -rf "${HOME}/projects"'
  assert_denied
}

@test "rm -rf \${HOME}/.config (brace path) is denied" {
  run_hook_bash 'rm -rf ${HOME}/.config'
  assert_denied
}

# --- denied: a dangerous target in a non-first rm segment ---
#
# `rm -rf node_modules && rm -rf dist` is an ordinary cleanup chain, so a guard
# that inspects only the first rm segment lets a dangerous target ride behind a
# harmless one.

@test "a dangerous target in the second rm segment (&&) is denied" {
  run_hook_bash 'rm -rf dist && rm -rf /'
  assert_denied
}

@test "a dangerous target in the second rm segment (;) is denied" {
  run_hook_bash 'rm -rf dist ; rm -rf ~'
  assert_denied
}

@test "a dangerous target in the second rm segment (||) is denied" {
  run_hook_bash 'rm -rf dist || rm -rf .git'
  assert_denied
}

@test "a dangerous target in the third rm segment is denied" {
  run_hook_bash 'cd /tmp && rm -rf build && rm -rf $HOME'
  assert_denied
}

# --- denied: operand-first flag order ---
#
# GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME` and
# deletes home on Linux. BSD/macOS rm does not permute, which is why this shape
# looks harmless when hand-tested on a Mac and must be covered by the suite.

@test "rm \$HOME -rf (operand before flags) is denied" {
  run_hook_bash 'rm $HOME -rf'
  assert_denied
}

@test "rm .git -rf (operand before flags) is denied" {
  run_hook_bash 'rm .git -rf'
  assert_denied
}

@test "rm ~ -rf (operand before flags) is denied" {
  run_hook_bash 'rm ~ -rf'
  assert_denied
}

# --- denied: backslash-newline continuations ---
#
# Both greps in the hook are line-oriented, so a target parked on a continuation
# line carries no `rm` token of its own and, unspliced, is never extracted. The
# multi-line form is idiomatic and the target is a plain literal token, so it
# must deny exactly like the one-liner it is equivalent to.

@test "a continuation-line \$HOME target is denied" {
  run_hook_bash 'rm -rf \
  $HOME/.cache/foo'
  assert_denied
}

@test "a continuation-line root target is denied" {
  run_hook_bash 'rm -rf \
  /'
  assert_denied
}

@test "a continuation-line quoted brace target is denied" {
  run_hook_bash 'rm -rf \
  "${HOME}"'
  assert_denied
}

@test "a continuation split between rm and its flags is denied" {
  run_hook_bash 'rm \
  -rf /'
  assert_denied
}

@test "a benign continuation-line cleanup is allowed" {
  # Splicing continuations must not turn an ordinary multi-line cleanup into a deny.
  run_hook_bash 'rm -rf \
  dist \
  build/output'
  assert_allowed
}

# A continuation may split a token mid-word. Bash removes the backslash-newline
# with nothing, so the fragments reassemble into one token and the command runs
# against the reassembled target. The splice must join the same way: a space-join
# would cut the token into fragments that match no pattern, which is a bypass.

@test "a continuation splitting \$HOME mid-token is denied" {
  run_hook_bash 'rm -rf $HOM\
E'
  assert_denied
}

@test "a continuation splitting a quoted \$HOME mid-token is denied" {
  run_hook_bash 'rm -rf "$HO\
ME"'
  assert_denied
}

@test "a continuation splitting node_modules mid-token is denied" {
  run_hook_bash 'rm -rf node_modul\
es'
  assert_denied
}

@test "a continuation splitting .git mid-token is denied" {
  run_hook_bash 'rm -rf .gi\
t'
  assert_denied
}

# --- denied: backslash-escaped targets ---
#
# Bash strips a backslash before an ordinary character, so the escaped token
# reassembles into the dangerous one and rm receives the real target. Stripping
# quotes but not escapes would be half a fix.

@test "rm -rf \\\\/ (escaped root) is denied" {
  run_hook_bash 'rm -rf \/'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf \\\\.git (escaped .git) is denied" {
  run_hook_bash 'rm -rf \.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf .\\\\git (escape inside the token) is denied" {
  run_hook_bash 'rm -rf .\git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf \\\\node_modules (escaped node_modules) is denied" {
  run_hook_bash 'rm -rf \node_modules'
  assert_denied_because 'BLOCKED: rm -rf of node_modules is forbidden'
}

@test "rm -rf \\\\\$HOME denies, though it is a fail-safe false deny, not a closed hole" {
  # Honest framing: bash hands rm a file literally NAMED '$HOME' here, not the
  # home directory, so this shape was never dangerous. It denies, which fails
  # safe, and that is all this asserts. Unlike its four siblings above it does
  # NOT gate the backslash strip: the legacy '\$HOME' case arm catches the raw
  # token even with the strip deleted. Kept as a behavior lock, not as evidence
  # the strip works.
  run_hook_bash 'rm -rf \$HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

# --- denied: remaining flag-shape gaps ---

@test "rm --no-preserve-root / (no recursive flag) is denied" {
  # The bare form carries no -r/-f at all, so only the widened short-circuit
  # reaches it. The -rf variant above does not cover this path.
  run_hook_bash 'rm --no-preserve-root /'
  assert_denied
}

@test "rm \${HOME} -rf (brace form, operand first) is denied" {
  run_hook_bash 'rm ${HOME} -rf'
  assert_denied
}

# --- denied: for the right reason ---
#
# assert_denied alone cannot tell a correct deny from a deny by the wrong arm.

@test "\$HOME denies via the \$HOME arm, not the absolute-path arm" {
  run_hook_bash 'rm -rf "$HOME"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "\${HOME} denies via the \$HOME arm" {
  run_hook_bash 'rm -rf "${HOME}"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "/ denies via the absolute-path arm" {
  run_hook_bash 'rm -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test ". denies via the cwd arm" {
  run_hook_bash 'rm -rf "."'
  assert_denied_because "BLOCKED: rm -rf of cwd ('.') is forbidden."
}

@test ".git denies via the .git arm" {
  run_hook_bash 'rm -rf ".git"'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "node_modules denies via the node_modules arm" {
  run_hook_bash 'rm -rf "node_modules"'
  assert_denied_because 'BLOCKED: rm -rf of node_modules is forbidden'
}

@test "--no-preserve-root denies via its own arm" {
  run_hook_bash 'rm --no-preserve-root -rf /'
  assert_denied_because 'BLOCKED: rm with --no-preserve-root is forbidden.'
}

@test "a chained dangerous segment denies via the target's own arm" {
  # Proves the second segment is what fired, not an accidental match on the first.
  run_hook_bash 'rm -rf dist && rm -rf .git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

# --- denied: the dotfile glob ---
#
# `rm -rf .*` sits precisely between `rm -rf .` and `rm -rf *`, both denied, and
# it removes .git and .claude. It is the one hole in the glob arm that is
# plausibly an ACCIDENT rather than evasion: the person reaching for `.*` is
# trying to clear dotfiles, which is exactly when .git is what they least want
# to lose.

@test "rm -rf .* (dotfile glob) is denied" {
  run_hook_bash 'rm -rf .*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf ./.* (dotfile glob behind ./) is denied" {
  run_hook_bash 'rm -rf ./.*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf .[!.]* (the skip-dot-and-dotdot idiom) is denied" {
  # The idiom people reach for to avoid `.` and `..` still matches `.git`, so it
  # is the same hole, not a safer spelling of it.
  run_hook_bash 'rm -rf .[!.]*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf ..?* (the other skip-dotdot idiom) is denied" {
  run_hook_bash 'rm -rf ..?*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf {.,}* (brace form of the dotfile glob) is denied" {
  # Expands to `.* *`: the dotfile glob and the unscoped glob at once, spelled
  # so that neither arm sees it.
  run_hook_bash 'rm -rf {.,}*'
  assert_denied_because 'unscoped brace glob'
}

@test "rm -rf {,.}* (reversed brace form) is denied" {
  run_hook_bash 'rm -rf {,.}*'
  assert_denied_because 'unscoped brace glob'
}

@test "rm .* -rf (dotfile glob, operand first) is denied" {
  run_hook_bash 'rm .* -rf'
  assert_denied_because 'dotfile glob'
}

# A `./` prefix is cosmetic and repeatable, and bash collapses `//`, so `././.*`
# and `.//.*` reach the cwd exactly like `.*`. Stripping a single `./` would
# close the accidental spelling and leave its evasion spellings open, which is
# the half-fix this arm exists to avoid.

@test "rm -rf ././.* (repeated ./ prefix) is denied" {
  run_hook_bash 'rm -rf ././.*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf .//.* (collapsed // prefix) is denied" {
  run_hook_bash 'rm -rf .//.*'
  assert_denied_because 'dotfile glob'
}

@test "rm -rf ././.git (repeated ./ prefix) is denied" {
  run_hook_bash 'rm -rf ././.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf .///.git (repeated slashes) is denied" {
  run_hook_bash 'rm -rf .///.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf .//node_modules is denied" {
  run_hook_bash 'rm -rf .//node_modules'
  assert_denied_because 'BLOCKED: rm -rf of node_modules is forbidden'
}

# --- denied: $PWD and ~user spellings of a target that already has an arm ---

@test "rm -rf \$PWD/.git is denied" {
  run_hook_bash 'rm -rf $PWD/.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf \${PWD}/.git (brace form) is denied" {
  run_hook_bash 'rm -rf ${PWD}/.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf \$PWD (bare) denies via the cwd arm" {
  # `$PWD` IS the cwd, so it must land on the same arm as a bare `.`.
  run_hook_bash 'rm -rf $PWD'
  assert_denied_because "BLOCKED: rm -rf of cwd ('.') is forbidden."
}

@test "rm -rf \$PWD/* denies via the unscoped-glob arm" {
  run_hook_bash 'rm -rf $PWD/*'
  assert_denied_because "BLOCKED: rm -rf of unscoped glob ('*') is forbidden."
}

@test "rm -rf \$PWD/ (trailing slash) denies via the cwd arm" {
  # `$PWD/` is still the cwd. Rewriting the prefix must not leave an empty token
  # that falls through to the catch-all.
  run_hook_bash 'rm -rf $PWD/'
  assert_denied_because "BLOCKED: rm -rf of cwd ('.') is forbidden."
}

@test "rm -rf \${PWD}/ (brace form, trailing slash) denies via the cwd arm" {
  run_hook_bash 'rm -rf ${PWD}/'
  assert_denied_because "BLOCKED: rm -rf of cwd ('.') is forbidden."
}

@test "rm -rf ~root (a named user's home) is denied" {
  run_hook_bash 'rm -rf ~root'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

# --- denied: a quoted ; & or | in an operand ---
#
# Segment extraction stops at the first `;`, `&`, or `|` byte, on the assumption
# that those bytes always terminate a command. Inside quotes they do not: they
# are ordinary characters in an operand. `rm -rf ";" $HOME` hands bash the argv
# [-rf] [;] [$HOME] and deletes home, while an unrepaired guard extracts only
# `rm -rf "`, never tokenizes $HOME, and allows it.

@test "a quoted ; before the target does not hide it (\$HOME)" {
  run_hook_bash 'rm -rf ";" $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "a quoted ; before the target does not hide it (root)" {
  run_hook_bash 'rm -rf ";" /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "a quoted & before the target does not hide it" {
  run_hook_bash 'rm -rf "a&b" .git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "a quoted | before the target does not hide it" {
  run_hook_bash 'rm -rf "x|y" ~'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "a quoted ; between rm and its flags does not defeat the short-circuit" {
  # The short-circuit grep is quote-blind the same way, and it runs first: if it
  # exits here, none of the deny logic is ever reached. GNU getopt permutes argv,
  # so this deletes home on Linux.
  run_hook_bash 'rm ";" -rf $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "a trailing quoted ; inside the target still reaches the \$HOME arm" {
  # Neutralizing the quoted separator must not glue a stray byte onto the token:
  # the arms are anchored, so `$HOME;` would match none of them.
  run_hook_bash 'rm -rf "$HOME;"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "a dangerous rm after a command carrying a quoted ; is denied" {
  run_hook_bash 'echo "a;b" && rm -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

# --- denied: .claude, the framework config ---
#
# `.git` and `.claude` are the same class of target: the one you least want to
# lose, sitting in the cwd of every session. The dotfile-glob arm above already
# denies the glob that sweeps up both, and names both in its message, so the
# direct spelling of either has to deny too.

@test "rm -rf .claude is denied" {
  run_hook_bash 'rm -rf .claude'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm -rf \".claude\" (quoted) is denied" {
  run_hook_bash 'rm -rf ".claude"'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm -rf ./.claude is denied" {
  run_hook_bash 'rm -rf ./.claude'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm -rf .claude/* is denied" {
  run_hook_bash 'rm -rf .claude/*'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm -rf .claude/hooks (a path inside .claude) is denied" {
  run_hook_bash 'rm -rf .claude/hooks'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm -rf \$PWD/.claude is denied" {
  run_hook_bash 'rm -rf $PWD/.claude'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

@test "rm .claude -rf (operand before flags) is denied" {
  run_hook_bash 'rm .claude -rf'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

# --- denied: spellings of the rm command word ---
#
# Bash removes quote and backslash bytes from a word before resolving it, so
# `r""m`, `"r"m`, and `r\m` are all the command `rm`, and macOS ships a
# case-insensitive volume by default, so `/bin/RM` really is `/bin/rm`. The
# guard's target matching already normalizes that way; its command-word matching
# has to agree, or a spelling of the word carries every protected target out
# through the short-circuit before a single deny arm is reachable.

@test "RM -rf ~ (uppercase command word) is denied" {
  run_hook_bash 'RM -rf ~'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "Rm -rf \$HOME (mixed-case command word) is denied" {
  run_hook_bash 'Rm -rf $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "rM -rf / (mixed-case command word) is denied" {
  run_hook_bash 'rM -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "RM -rf .git (uppercase command word) is denied" {
  run_hook_bash 'RM -rf .git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "r\"\"m -rf / (quote-split command word) is denied" {
  run_hook_bash 'r""m -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "\"r\"m -rf / (leading-quoted command word) is denied" {
  run_hook_bash '"r"m -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "r\"m\" -rf \$HOME (trailing-quoted command word) is denied" {
  run_hook_bash 'r"m" -rf $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "'r'm -rf .git (single-quote-split command word) is denied" {
  run_hook_bash "'r'm -rf .git"
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "\"rm\" -rf / (fully quoted command word) is denied" {
  run_hook_bash '"rm" -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "r\\\\m -rf / (backslash-split command word) is denied" {
  # Bash strips a backslash before an ordinary character, so `r\m` IS `rm`, the
  # same defect as the quote-split spellings and the same fix.
  run_hook_bash 'r\m -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

# The command-word rule has to hold at all three `rm`-matching sites, not just
# the two greps. The quoted-separator walk is gated on the command looking like
# an `rm` at all, so a gate that only knows the literal lowercase spelling skips
# the walk here, segment extraction then stops at the quoted `;`, and the target
# behind it is never tokenized.

@test "RM -rf \";\" \$HOME (uppercase word + quoted separator) is denied" {
  run_hook_bash 'RM -rf ";" $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "r\"\"m -rf \";\" / (quote-split word + quoted separator) is denied" {
  run_hook_bash 'r""m -rf ";" /'
  assert_denied_because 'rm -rf of absolute path'
}

# --- the command word may be PATH-QUALIFIED ---
#
# `/bin/rm` and `/usr/bin/rm` are the command `rm`, spelled with a path. The
# anchor's leading boundary byte is the `/` in front of the word, so segment
# extraction begins at `/rm …` and the token `/rm` gets judged as though it were a
# TARGET: it trips the absolute-path arm, denies a whitelisted target, and blames
# `/rm`, a path the user never wrote.
#
# The word is skipped by POSITION (it is always the segment's first token), never by
# spelling. A spelling test broad enough to cover `/rm` (say `*/[Rr][Mm]`) would
# equally skip `/usr/bin/rm` when it is the TARGET, turning an absolute-path deny
# into an allow. Both directions are pinned below.

@test "/bin/rm -rf dist (path-qualified word, whitelisted target) is allowed" {
  run_hook_bash '/bin/rm -rf dist'
  assert_allowed
}

@test "/usr/bin/rm -rf dist (path-qualified word, whitelisted target) is allowed" {
  run_hook_bash '/usr/bin/rm -rf dist'
  assert_allowed
}

@test "/bin/RM -rf dist (path-qualified, uppercase word) is allowed" {
  run_hook_bash '/bin/RM -rf dist'
  assert_allowed
}

@test "/bin/rm -rf build/output (path-qualified word) is allowed" {
  run_hook_bash '/bin/rm -rf build/output'
  assert_allowed
}

@test "echo hi && /bin/rm -rf dist (path-qualified word in a later segment) is allowed" {
  run_hook_bash 'echo hi && /bin/rm -rf dist'
  assert_allowed
}

# The dangerous shapes must still deny, and must deny via the TARGET's own arm.
# They deny today as well, but for the wrong reason: the `/rm` token is what trips
# the absolute-path arm, not the operand. So a fix that merely stops `/rm` being
# read as a target could silently turn these into allows. assert_denied_because is
# what pins the right reason, and therefore the real fix.

@test "/bin/rm -rf / denies via the target's own absolute-path arm" {
  run_hook_bash '/bin/rm -rf /'
  assert_denied_because "BLOCKED: rm -rf of absolute path '/' is forbidden."
}

@test "/bin/rm -rf \$HOME denies via the \$HOME arm" {
  run_hook_bash '/bin/rm -rf $HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "/bin/rm -rf .git denies via the .git arm" {
  run_hook_bash '/bin/rm -rf .git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "/usr/bin/rm -rf .claude denies via the .claude arm" {
  run_hook_bash '/usr/bin/rm -rf .claude'
  assert_denied_because 'BLOCKED: rm -rf of .claude is forbidden'
}

# The rm binary as the TARGET is an absolute path and stays denied. This is the
# case that forbids recognizing the command word by spelling.

@test "rm -rf /usr/bin/rm (the rm binary as the target) is denied" {
  run_hook_bash 'rm -rf /usr/bin/rm'
  assert_denied_because "BLOCKED: rm -rf of absolute path '/usr/bin/rm' is forbidden."
}

@test "rm -rf /bin/rm (the rm binary as the target) is denied" {
  run_hook_bash 'rm -rf /bin/rm'
  assert_denied_because "BLOCKED: rm -rf of absolute path '/bin/rm' is forbidden."
}

# --- allowed: whitelisted scratch paths ---

@test "rm -rf .gaia/local/plans/x is allowed" {
  run_hook_bash 'rm -rf .gaia/local/plans/x'
  assert_allowed
}

@test "rm -rf .gaia/local/cache/x is allowed" {
  run_hook_bash 'rm -rf .gaia/local/cache/x'
  assert_allowed
}

@test "rm -rf dist is allowed" {
  run_hook_bash 'rm -rf dist'
  assert_allowed
}

@test "rm -rf build/output is allowed" {
  run_hook_bash 'rm -rf build/output'
  assert_allowed
}

@test "rm -rf \"dist\" (quoted whitelist entry) is allowed" {
  # Quote-stripping must not turn a benign quoted target into a denial.
  run_hook_bash 'rm -rf "dist"'
  assert_allowed
}

@test "rm -rf ./\"dist\" (quotes inside a benign token) is allowed" {
  run_hook_bash 'rm -rf ./"dist"'
  assert_allowed
}

# --- allowed: the ABSOLUTE spelling of a whitelisted scratch path ---
#
# `.claude/rules/shell-cwd.md` mandates an absolute path on every Bash call,
# repo-wide, because a single `cd` persists for the rest of the session and breaks
# every relative-path hook. A guard that whitelists a scratch directory in its
# relative spelling only denies the exact form that rule requires, so an agent
# cannot satisfy both at once. The absolute spelling is authoritative; both are
# accepted, and these arms are what make the rule and the guard agree.
#
# The match is a SUFFIX on the scratch segment, never a resolved root. Computing
# the repo root would need a live `git rev-parse`, which this guard deliberately
# does without, and baking a literal absolute prefix into a `.claude/`-distributed
# file would violate .claude/rules/instruction-files.md. A suffix match needs
# neither.

@test "rm -f of an absolute .gaia/local/audit path is allowed" {
  run_hook_bash 'rm -f /Users/you/projects/my-app/.gaia/local/audit/issue-body-x.md'
  assert_allowed
}

@test "rm -rf of an absolute .gaia/local/plans path is allowed" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/.gaia/local/plans/x'
  assert_allowed
}

@test "rm -rf of an absolute dist path is allowed" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/dist'
  assert_allowed
}

@test "rm -rf of an absolute build path is allowed" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/build/output'
  assert_allowed
}

# The suffix match must not reach up to a filesystem-root directory. `/dist` is a
# top-level removal that happens to share a name with a build output, and the
# whitelist is about scratch INSIDE a project, so a non-empty parent segment is
# required.

@test "rm -rf /dist (whitelist name at the filesystem root) is denied" {
  run_hook_bash 'rm -rf /dist'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /.gaia/local/audit/x (scratch at the filesystem root) is denied" {
  run_hook_bash 'rm -rf /.gaia/local/audit/x'
  assert_denied_because 'rm -rf of absolute path'
}

# A `.` or `..` parent segment must not satisfy the non-empty-parent guard. Both
# `/./dist` and `/../dist` resolve to `/dist`, the filesystem-root removal the
# arm above exists to refuse, so pinning the intent in the bare spelling alone
# leaves the whole family of dot-segment spellings open. This is the same class
# the `//` collapse already handles, and it is normalized the same way rather
# than being given arms of its own.

@test "rm -rf /./dist (dot parent segment) is denied" {
  run_hook_bash 'rm -rf /./dist'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /../dist (dotdot parent segment) is denied" {
  run_hook_bash 'rm -rf /../dist'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /.//dist (dot segment plus doubled slash) is denied" {
  run_hook_bash 'rm -rf /.//dist'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /././dist (repeated dot segments) is denied" {
  # The collapse has to run to a fixed point, not once.
  run_hook_bash 'rm -rf /././dist'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /./build (dot parent segment, build) is denied" {
  run_hook_bash 'rm -rf /./build'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /./.gaia/local/audit/x (dot parent segment, scratch) is denied" {
  run_hook_bash 'rm -rf /./.gaia/local/audit/x'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf /.. (bare dotdot at the root) is denied" {
  run_hook_bash 'rm -rf /..'
  assert_denied_because 'rm -rf of absolute path'
}

@test "an interior ./ inside a genuinely whitelisted absolute path is allowed" {
  # Collapsing the dot segment must land the token ON the whitelist, not merely
  # off the deny arm: this is the same directory as the plain spelling.
  run_hook_bash 'rm -rf /Users/you/projects/my-app/./dist'
  assert_allowed
}

# A `..` segment makes an absolute path resolve somewhere the spelling does not
# name, so it can never reach the whitelist: this one spells the audit directory
# and resolves to `.git`. Relative `..` escapes stay out of reach by design (see
# the hook header), but an absolute one is denied today and must stay denied.

@test "an absolute whitelisted path with a .. escape is denied" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/.gaia/local/audit/../../../.git'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf of an absolute node_modules path is denied" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/node_modules'
  assert_denied_because 'rm -rf of absolute path'
}

# --- the observed worktree-cleanup incident ---
#
# An agent working inside a linked worktree could not delete its own scratch
# files. `rm`, `rm -f`, and `rm -rf` on the absolute path were ALL denied, and it
# completed the deletion with `find -delete` instead. That is the motivating
# repro for this whole arm: the guard did not prevent a removal, it redirected a
# competent agent to a tool the deny list does not inspect at all.
#
# The path below is the real shape: a worktree checkout under `.claude/worktrees/`
# whose branch directory carries a hyphenated name, reaching the `.gaia/local/`
# scratch that is symlinked back to the main checkout. It exercises both defects
# at once, which is why all three shapes denied rather than just the flagged one.

@test "rm -rf of worktree scratch under .gaia/local is allowed" {
  run_hook_bash 'rm -rf /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md'
  assert_allowed
}

@test "rm -f of worktree scratch under .gaia/local is allowed" {
  run_hook_bash 'rm -f /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md'
  assert_allowed
}

@test "flagless rm of worktree scratch under .gaia/local is allowed" {
  run_hook_bash 'rm /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md'
  assert_allowed
}

@test "the same scratch path resolved to the main checkout is allowed" {
  # `.gaia/local/audit` is a symlink out of the worktree, so an agent may spell
  # either end of it. Both are the same directory and both must be allowed.
  run_hook_bash 'rm -f /Users/you/projects/my-app/.gaia/local/audit/issue-body.md'
  assert_allowed
}

# --- a hyphenated PATH COMPONENT is not a destructive flag ---
#
# The flag probe matches `-[a-zA-Z]*[rRfF]`, which a hyphenated path component
# ending in `r` or `f` satisfies: `my-matcher`, `my-perf`, and the incident's own
# `c-text-matcher-guards` all contain one. So a flagless `rm <abs path>` was read
# as a destructive `rm -r` purely because of a directory name, which is the half
# of the incident neither issue explains.
#
# A genuine flag is always its own shell word, so the probe now requires a token
# boundary in front of the dash. Quote and backslash bytes count as boundaries,
# because bash drops them during quote removal and `rm "-rf" /` is a real flag.

@test "a hyphenated path component ending in r is not read as a flag" {
  run_hook_bash 'rm /Users/you/projects/my-matcher/notes.md'
  assert_allowed
}

@test "a hyphenated path component ending in f is not read as a flag" {
  run_hook_bash 'rm /Users/you/projects/my-perf/notes.md'
  assert_allowed
}

@test "rm \"-rf\" / (quoted flag) is still denied" {
  # The boundary set includes the quote bytes precisely so this stays denied.
  run_hook_bash 'rm "-rf" /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf / with a hyphenated path component is still denied" {
  # A real flag beside a flag-shaped directory name must not be masked by the fix.
  run_hook_bash 'rm -rf /Users/you/projects/my-matcher'
  assert_denied_because 'rm -rf of absolute path'
}

@test "a genuine flag after an operand is still found" {
  # GNU getopt permutes argv, so the flag may follow the target. The boundary
  # requirement must not cost the operand-first shape.
  run_hook_bash 'rm /Users/you/projects/my-matcher -rf'
  assert_denied_because 'rm -rf of absolute path'
}

# --- a segment is judged only when IT carries a destructive flag ---
#
# The flag test and the target test have to apply to the same segment. The guard
# short-circuits on a flag found anywhere in the command, then extracts and judges
# every `rm` segment; a segment carrying no `-r`/`-f` at all therefore got judged
# on the strength of a flag belonging to a different command entirely.
#
# That was never a security property. `rm /abs/path/file` on its own is allowed
# (the guard's whole advertised scope is `rm -rf`), and it stayed allowed however
# it was spelled, so the denial only ever fired when a harmless sibling like
# `rm -rf dist` happened to share the invocation. Nothing was prevented that
# dropping the sibling would not have carried straight through; the cost was
# denying prose that quotes a non-recursive `rm`, including this repo's own
# always-loaded shell-cwd rule.

@test "an unflagged rm segment is not judged on a sibling's flag" {
  run_hook_bash 'rm -rf dist && rm /abs/path/file'
  assert_allowed
}

@test "a heredoc quoting shell-cwd.md's own example beside a real rm -rf is allowed" {
  run_hook_bash 'rm -rf dist
cat > /tmp/body.md <<EOF
- `rm /abs/path/file`, not `cd /abs/path && rm file`
EOF'
  assert_allowed
}

@test "a FLAGGED sibling segment is still judged" {
  # The narrowing is per-segment, not per-command: a second segment that carries
  # its own -rf is a real removal and stays fully inspected.
  run_hook_bash 'rm -rf dist && rm -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test "a flagged rm inside a quoted string is still denied" {
  # The documented false-deny direction is deliberate and unchanged: a text matcher
  # cannot tell `bash -c "rm -rf /"` from prose quoting it, and of the two failure
  # directions the false deny is the safe one.
  run_hook_bash 'git commit -m "fix: stop rm -rf $HOME from bypassing the guard"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

# --- allowed: everything the guard deliberately does not gate ---

@test "rm -rf on an unknown relative path is allowed" {
  run_hook_bash 'rm -rf some/scratch/dir'
  assert_allowed
}

@test "rm -rf on an unrelated quoted variable is allowed" {
  run_hook_bash 'rm -rf "$SCRATCH_DIR"'
  assert_allowed
}

@test "rm -rf \${HOMEBREW_PREFIX} (a \$HOME-prefixed neighbour) is allowed" {
  # The brace arms must be anchored, not prefix matches: a variable whose name
  # merely starts with HOME is not $HOME.
  run_hook_bash 'rm -rf ${HOMEBREW_PREFIX}'
  assert_allowed
}

@test "rm -rf \${PWD}/dist (a \$PWD-prefixed whitelist entry) is allowed" {
  # `$PWD/x` IS `x`, so rewriting the prefix must land this on the dist
  # whitelist. Denying every $PWD path would be the easy over-fix.
  run_hook_bash 'rm -rf ${PWD}/dist'
  assert_allowed
}

@test "rm -rf \$PWD/.gaia/local/cache/x is allowed" {
  run_hook_bash 'rm -rf $PWD/.gaia/local/cache/x'
  assert_allowed
}

# --- allowed: globs and dots the dotfile-glob arm must not swallow ---
#
# The dotfile glob is dangerous because it expands in the CWD. A glob deeper in
# the path expands inside a named directory, which is the ordinary cleanup shape
# the whitelist exists for, so only the first path segment can trip the arm.

@test "rm -rf .gaia/local/plans/* (a glob inside a whitelisted path) is allowed" {
  run_hook_bash 'rm -rf .gaia/local/plans/*'
  assert_allowed
}

@test "rm -rf .gaia/local/audit/*/findings is allowed" {
  run_hook_bash 'rm -rf .gaia/local/audit/*/findings'
  assert_allowed
}

@test "rm -rf .gitignore (a dotfile with no glob) is allowed" {
  # Starting with a dot is not the hazard; expanding in the cwd is.
  run_hook_bash 'rm -rf .gitignore'
  assert_allowed
}

@test "rm -rf dist/{a,b} (a scoped brace list with no glob) is allowed" {
  run_hook_bash 'rm -rf dist/{a,b}'
  assert_allowed
}

# --- allowed: quoted separators must not manufacture a denial ---

@test "a benign chain whose first command carries a quoted ; is allowed" {
  run_hook_bash 'echo "a;b" && rm -rf dist'
  assert_allowed
}

@test "a benign quoted chain is still split on its real separators" {
  run_hook_bash 'rm -rf dist && rm -rf "build/output"'
  assert_allowed
}

@test "a benign multi-segment rm chain is allowed" {
  # Inspecting every segment must not turn an ordinary cleanup chain into a deny.
  run_hook_bash 'rm -rf dist && rm -rf build/output'
  assert_allowed
}

@test "rm -rf node_modules_backup (a node_modules-prefixed neighbour) is allowed" {
  run_hook_bash 'rm -rf node_modules_backup'
  assert_allowed
}

@test "rm without -rf is allowed" {
  run_hook_bash 'rm file.txt'
  assert_allowed
}

@test "a command with no rm at all is allowed" {
  run_hook_bash 'ls -la node_modules'
  assert_allowed
}

# --- allowed: the .claude arm must not swallow its neighbours ---

@test "rm -rf .claudia (a .claude-prefixed neighbour) is allowed" {
  # The arm is anchored, not a prefix match: a directory whose name merely starts
  # with `.claude` is not `.claude`.
  run_hook_bash 'rm -rf .claudia'
  assert_allowed
}

# --- allowed: the command-word rule must not manufacture a denial ---
#
# Matching the word the way bash resolves it widens what gets INSPECTED. The case
# arms still decide what gets blocked, so a benign target stays benign no matter
# how its command word is spelled.

@test "RM file.txt (uppercase word, no -rf) is allowed" {
  run_hook_bash 'RM file.txt'
  assert_allowed
}

@test "r\"\"m file.txt (quote-split word, no -rf) is allowed" {
  run_hook_bash 'r""m file.txt'
  assert_allowed
}

@test "RM -rf dist (uppercase word, whitelisted target) is allowed" {
  run_hook_bash 'RM -rf dist'
  assert_allowed
}

@test "r\"\"m -rf build/output (quote-split word, whitelisted target) is allowed" {
  run_hook_bash 'r""m -rf build/output'
  assert_allowed
}

@test "charm -rf x (a word merely ENDING in rm) is allowed" {
  # The leading boundary is what keeps the widened command-word match from firing
  # on every word that happens to contain `rm`.
  run_hook_bash 'charm -rf x'
  assert_allowed
}

@test "git commit -m \"warm restart\" (rm inside a word) is allowed" {
  run_hook_bash 'git commit -m "warm restart"'
  assert_allowed
}

# --- the walk's position-preserving invariant, asserted directly ---
#
# The `*rm*` fast-path gate skips the quoted-separator walk for any command whose
# raw text holds no `rm`. That skip is a no-op ONLY because the walk is
# position-preserving: it writes every character back into its own slot and the
# only byte it ever writes is a space, so it can never close a gap and manufacture
# an `rm` the raw text lacked. A deletion could: a quoted `r;m` would close up into
# `rm`.
#
# Nothing above can catch a regression here. Substitution-plus-gate and
# deletion-plus-gate return identical verdicts on every command a caller could
# actually send, so a contributor who "simplifies" `ch=' '` to a `continue` breaks
# the gate's justification while all 130+ behavioral cases stay green. The invariant
# is a property of the helper, so it is asserted on the helper, which is what the
# hook's sourceable entry point exists for.

source_hook() {
  # The hook body sits behind a `main` that runs only when the file is executed, so
  # sourcing defines the helpers and consumes no stdin.
  # shellcheck source=/dev/null
  source "$HOOK_ABS"
}

assert_position_preserving() {
  local s=$1 out len i si oi
  out=$(neutralize_quoted_separators "$s")

  # 1. Length is preserved: the walk substitutes, it never inserts or deletes.
  [ "${#out}" -eq "${#s}" ] || return 1

  len=${#s}
  for ((i = 0; i < len; i++)); do
    si=${s:i:1}
    oi=${out:i:1}
    if [ "$si" != "$oi" ]; then
      # 2. The only byte it ever writes is a space...
      [ "$oi" = " " ] || return 1
      # 3. ...and it only ever writes one over a `;`, `&`, or `|`.
      case "$si" in
        ';' | '&' | '|') ;;
        *) return 1 ;;
      esac
    fi
  done

  # 4. The consequence the fast-path gate actually leans on: no `rm` appears at an
  #    offset where the input held none. A deletion falsifies exactly this.
  for ((i = 0; i + 2 <= len; i++)); do
    if [ "${out:i:2}" = "rm" ] && [ "${s:i:2}" != "rm" ]; then
      return 1
    fi
  done
  return 0
}

@test "the walk substitutes rather than deletes: a quoted r;m never closes into rm" {
  source_hook
  local out
  out=$(neutralize_quoted_separators '"r;m"')

  # Substitution writes a space into the separator's slot, giving `"r m"`. A
  # deletion would close the gap into `"rm"` and manufacture the very token the
  # fast-path gate assumes the walk can never create. Both spellings produce the
  # same end-to-end verdict (bash resolves `"r;m"` to a command literally named
  # `r;m`, never to `rm`), which is precisely why only a direct assertion catches it.
  [ "$out" = '"r m"' ] || return 1
  grep -qF -- 'rm' <<<"$out" && return 1
  return 0
}

@test "the walk is position-preserving across an adversarial corpus" {
  source_hook
  # Each string attacks the invariant: separators wedged between the letters of
  # `rm`, quoted and unquoted separators, nested and unbalanced quotes.
  local corpus=(
    'r;m'
    '"r;m"'
    "'r;m'"
    'r|m'
    'r&m'
    '"r|m" "r&m"'
    'a"r;m"b'
    '"r;;m"'
    'r"";m'
    'echo "r;m"'
    'rm -rf ";" $HOME'
    'echo "a;b" && rm -rf dist'
    'git commit -m "fix: a;b|c&d"'
    'rm -rf dist && rm -rf build/output'
    'unbalanced " quote ; here'
    'no separators or quotes at all'
    ';&|'
    '""'
  )
  local s
  for s in "${corpus[@]}"; do
    if ! assert_position_preserving "$s"; then
      printf 'position-preserving invariant broken on: %s\n' "$s" >&2
      return 1
    fi
  done
}

# --- _rm_whitelisted_abs: the registry-driven absolute-whitelist matcher ---
#
# Tested directly against a SYNTHETIC tsv, no fixture repo and no real
# registry read: the helper takes the whitelist as an argument precisely so
# its match logic can be pinned here independent of the real registry's
# contents.

@test "_rm_whitelisted_abs: a child under a children_only base matches" {
  source_hook
  run _rm_whitelisted_abs "/x/y/.gaia/local/audit/f" $'.gaia/local/audit\ttrue'
  [ "$status" -eq 0 ]
}

@test "_rm_whitelisted_abs: the bare base itself does NOT match when children_only" {
  source_hook
  run _rm_whitelisted_abs "/x/y/.gaia/local/plans" $'.gaia/local/plans\ttrue'
  [ "$status" -eq 1 ]
}

@test "_rm_whitelisted_abs: the bare base matches when children_only is false" {
  source_hook
  run _rm_whitelisted_abs "/x/y/dist" $'dist\tfalse'
  [ "$status" -eq 0 ]
}

@test "_rm_whitelisted_abs: a child under a children_only=false base also matches" {
  source_hook
  run _rm_whitelisted_abs "/x/y/dist/a" $'dist\tfalse'
  [ "$status" -eq 0 ]
}

@test "_rm_whitelisted_abs: a non-empty parent segment is required" {
  source_hook
  run _rm_whitelisted_abs "/dist" $'dist\tfalse'
  [ "$status" -eq 1 ]
}

@test "_rm_whitelisted_abs: a base absent from the tsv does not match" {
  source_hook
  run _rm_whitelisted_abs "/x/y/notlisted" $'dist\tfalse'
  [ "$status" -eq 1 ]
}

@test "_rm_whitelisted_abs: a base ADDED to the tsv matches with no hook edit" {
  # The auto-extend proof: a new registry base is whitelisted with no hook
  # edit, the 3.3 analog of the write-guard's own catch.
  source_hook
  run _rm_whitelisted_abs "/x/y/newbase" $'dist\tfalse\nnewbase\tfalse'
  [ "$status" -eq 0 ]
}

@test "_rm_whitelisted_abs: an empty tsv matches nothing (the fail-toward-deny substrate)" {
  source_hook
  run _rm_whitelisted_abs "/x/y/dist" ""
  [ "$status" -eq 1 ]
}

# --- structural ---

@test "the hook is sourceable: sourcing defines the helpers and runs no body" {
  # `payload=$(cat)` at the top level blocks on stdin, so a suite that sources the
  # hook to reach an internal helper hangs instead of defining one. The `main`
  # entry point is what makes the invariant cases above reachable at all: sourcing
  # must define the helper, consume no stdin, and emit nothing.
  run bash -c 'printf %s SENTINEL | { source "$1"; printf "helper=%s stdin=%s" "$(type -t neutralize_quoted_separators)" "$(cat)"; }' _ "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- 'helper=function' <<<"$output"
  grep -qF -- 'stdin=SENTINEL' <<<"$output"
}

@test "sourcing the hook does not push its shell options onto the caller" {
  # `set -euo pipefail` sits inside `main`, not at the top level, so a `source`
  # cannot silently switch on errexit/nounset/pipefail in the sourcing shell. At
  # the top level it would, and every caller that sources the hook to reach a
  # helper would inherit them.
  run bash -c 'source "$1"; o=""; [[ -o errexit ]] && o="${o}e"; [[ -o nounset ]] && o="${o}u"; [[ -o pipefail ]] && o="${o}p"; printf "leaked=[%s]" "$o"' _ "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- 'leaked=[]' <<<"$output"
}

@test "block-rm-rf.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/block-rm-rf.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
