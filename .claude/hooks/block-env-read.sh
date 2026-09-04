#!/usr/bin/env bash
# PreToolUse Read + Grep + Bash hook: read-side secret guard for dotenv files.
#
# This hook is the WHOLE read-side guard for dotenv paths. It carries no
# settings.json backstop behind it, and that is deliberate: a Read() deny rule
# in permissions.deny arms Claude Code's deniedPathInsideDirectory circuit
# breaker, which is bypass-immune and forces a manual approval prompt for every
# grep, rg, diff, git, cp and mv whose target directory could contain a denied
# path -- which, for a rule written with a `**` glob, is every directory in the
# tree. The prompt is unconditional and cannot be waived by an allow rule, so
# the cost is paid on every recursive search forever. Moving the whole
# obligation here buys that back. What it costs is stated honestly below.
#
# What this guard covers:
#   - the Read tool against .env and any variant (.env.local, .env.production,
#     .env.<anything>), excluding the committed .env.example placeholder;
#   - the Grep tool's `path` and `glob`, which in content mode return file
#     contents and so read a path exactly as Read does;
#   - Bash readers against the same set: cat, head, tail, sed, xxd, od,
#     hexdump, strings, nl, less, more, diff, cut, tac, paste, awk, perl, and
#     the grep family (grep, egrep, fgrep, rgrep, rg);
#   - sourcing (source / .), redirection from a dotenv path (< / $(<...)), and
#     `env FOO=1 <reader> <path>`, where env runs a reader rather than dumping;
#   - bare process-environment dumps (env, printenv, set, export -p, declare -p,
#     compgen -v) that read the shell environment rather than a file, so no
#     file-permission rule ever governed them.
#
# The grep family needs argument grammar rather than a token sweep, because
# `grep PATTERN FILE` puts a non-path in first position and `grep '.env'
# .gitignore` must stay allowed. That grammar lives in lib/reader-operands.sh
# and is shared with block-secrets-read.sh rather than written twice.
#
# HONEST LIMITS. This is heuristic defense-in-depth, not a sandbox: it
# pattern-matches command text and can be evaded by determined obfuscation. It
# does not reach MCP-mediated shell execution (e.g. Serena's
# execute_shell_command), a subprocess that opens the file itself (a Node or
# Python script reading it directly), or a deliberately obfuscated reader.
#
# ONE MORE SPELLING IS OPEN AND IS NONE OF THOSE. The operand walk splits a
# segment on whitespace before quotes are stripped, so a quoted path CONTAINING
# A SPACE arrives as two fragments and neither one strips to the real path:
# `cat "my file.key"` is allowed where `cat my\ file.key` is denied. Coalescing
# the fragments is tokenizer work rather than a table entry, and a half-done
# tokenizer is how the flag tables above went wrong, so it is named here instead
# of guessed at. Treat this list as the spellings known to be open, never as a
# closed set.
#
# THE PERMISSION RULE SHARED ALL OF THOSE LIMITS AT THE TOOL TIER, and it had
# one this hook cannot have. A Read() deny merges into the OS sandbox boundary,
# so `Read(.env)` also denied a subprocess spawned by sandboxed Bash, including
# the app's own tooling when Claude ran it. A hook sees tool-call text and never
# a subprocess open(), so deleting the rule would have dropped that tier in
# silence for every adopter who enabled the sandbox. It is declared directly
# instead: `sandbox.filesystem.denyRead` in .claude/settings.json now carries
# .env and its variants. That key is not a permission rule, so it does not arm
# the breaker, and it is inert until a machine enables the sandbox, which is the
# owner-recommends / machine-resolves split `wiki/concepts/OS Sandbox.md` sets
# out. At the tool tier, which is this hook's tier, the exchange costs no
# coverage that was real.
set -euo pipefail

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=''
# Bracketed against an unparseable target, not merely a missing one: under
# errexit a library carrying a syntax error aborts the hook mid-source, and a
# hook that dies before reading its payload denies nothing while looking like it
# ran. The load is allowed to fail quietly so the capability probe below is the
# single place that decides.
set +e
# shellcheck source=lib/reader-operands.sh
[ -n "$_lib_dir" ] && [ -f "$_lib_dir/reader-operands.sh" ] && . "$_lib_dir/reader-operands.sh" 2>/dev/null
set -e
if ! type gaia_reader_operands >/dev/null 2>&1 \
  || ! type gaia_reader_strip_env_prefix >/dev/null 2>&1 \
  || ! type gaia_reader_strip_quotes >/dev/null 2>&1; then
  # A guard that cannot load its own grammar must not report clean, and only a
  # structured deny achieves that. A non-zero exit other than 2 is a NON-BLOCKING
  # error in the PreToolUse contract (`wiki/concepts/Claude Hooks.md`): the tool
  # call proceeds and the status is advisory, so the `exit 1` this replaced left
  # every dotenv read allowed with a stderr line as the only trace. The deny is
  # emitted with printf rather than through deny() below, because deny() shells
  # out to jq and this arm must hold even when the environment is the reason the
  # load failed. Denying every Read, Grep and Bash call is the intended cost: a
  # missing or unparseable library means this hook is not guarding anything, and
  # a loud stop is preferable to a silent one on a broken install.
  printf 'block-env-read.sh: cannot load lib/reader-operands.sh\n' >&2
  # Spelled in jq's own output shape, spaces included, because that is the
  # form every other deny in this tree emits and the form the suites' shared
  # assertion matches on. A compact spelling is equally valid JSON and would
  # deny correctly while reading as an allow to the harness.
  cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: block-env-read.sh could not load lib/reader-operands.sh, so the read-side dotenv guard is not running. This denial is fail-closed by design. Restore .claude/hooks/lib/reader-operands.sh to clear it."
  }
}
DENY_JSON
  exit 0
fi

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

DENY_READ_TOOL="BLOCKED: reading '.env' / '.env.*' files is denied to protect local secrets. Only '.env.example' is readable. This guard is heuristic defense-in-depth, not a sandbox."
DENY_DUMP="BLOCKED: a bare environment dump (env/printenv/set) is denied so exported secrets cannot be printed into the transcript. Use 'env NAME=value <cmd>' to set a variable for a command. Heuristic defense-in-depth, not a sandbox."
DENY_READ="BLOCKED: reading a .env / .env.* file (a reader, sourcing, or redirection) is denied to protect local secrets. '.env.example' is exempt. Heuristic defense-in-depth, not a sandbox."

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Dotenv path definition: the basename (after stripping surrounding quotes)
# matches .env or .env.<token>(.<token>)*, and is not exactly .env.example.
is_dotenv_path() {
  local p="$1" base
  p=$(gaia_reader_strip_quotes "$p")
  [[ -n "$p" ]] || return 1
  base=$(basename -- "$p")
  [[ "$base" =~ ^\.env(\.[A-Za-z0-9_-]+)*$ ]] || return 1
  [[ "$base" == ".env.example" ]] && return 1
  return 0
}

# `set` with no args, or whose first arg does not start with -/+, is a dump.
# `set -e`, `set -euo pipefail`, `set +x` are shell options, not a dump.
check_set_tokens() {
  if [ "$#" -eq 0 ]; then
    deny "$DENY_DUMP"
  fi
  case "$1" in
    -* | +*) : ;;
    *) deny "$DENY_DUMP" ;;
  esac
  return 0
}

# `env` is a dump with no command operand (bare `env`, option flags only,
# `env -0`). With a command operand it is a runner, and the operand walk in
# lib/reader-operands.sh judges whatever it wraps, so this arm only has to
# decide the dump question.
check_env_tokens() {
  local toks=("$@")
  local n=${#toks[@]}
  local i=0

  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done

  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done

  if [ "$i" -ge "$n" ]; then
    deny "$DENY_DUMP"
  fi
  return 0
}

# Process-environment dumps only. File reads are the operand walk's job.
check_dump_tokens() {
  local toks=("$@")
  local cmdword="${toks[0]:-}"
  cmdword=$(gaia_reader_strip_quotes "$cmdword")

  case "$cmdword" in
    env)
      check_env_tokens "${toks[@]:1}"
      ;;
    printenv)
      # printenv has no runner form; with or without a NAME it only ever
      # prints the environment, so any invocation is a dump.
      deny "$DENY_DUMP"
      ;;
    set)
      check_set_tokens "${toks[@]:1}"
      ;;
    export)
      [[ "${toks[1]:-}" == "-p" ]] && deny "$DENY_DUMP"
      ;;
    declare)
      [[ "${toks[1]:-}" == "-p" ]] && deny "$DENY_DUMP"
      ;;
    compgen)
      [[ "${toks[1]:-}" == "-v" ]] && deny "$DENY_DUMP"
      ;;
  esac
  return 0
}

process_segment() {
  local seg="$1"
  local seg_cmd operand
  local toks

  seg_cmd=$(gaia_reader_strip_env_prefix "$seg")
  read -r -a toks <<<"$seg_cmd"

  # An empty segment (e.g. between the two words of `true && cat .env.local`,
  # which the |&;() split turns into an empty run) yields an empty toks array.
  # On bash 3.2 under `set -u`, a bare "${toks[@]}" on an empty array aborts
  # with "unbound variable" before later segments are evaluated, so guard it.
  [ "${#toks[@]}" -eq 0 ] || check_dump_tokens "${toks[@]}"

  while IFS= read -r operand; do
    if is_dotenv_path "$operand"; then
      deny "$DENY_READ"
    fi
  done < <(gaia_reader_operands "$seg")
  return 0
}

case "$tool_name" in
  Read)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_dotenv_path "$file_path" && deny "$DENY_READ_TOOL"
    exit 0
    ;;

  Grep)
    # The Grep tool returns file CONTENT in content mode, so it reads a path the
    # same way Read does. `path` is the file or directory searched; `glob` is the
    # filter, and a filter naming a dotenv path selects exactly the files this
    # guard exists to keep out of the transcript. The glob arm is best-effort by
    # construction: it reads a pattern with the path predicate, so it catches a
    # literal `.env` or `.env.local` and not every glob that could expand onto
    # one. There is no dump arm here, because the Grep tool reads files only.
    grep_path=$(jq -r '.tool_input.path // empty' <<<"$payload")
    grep_glob=$(jq -r '.tool_input.glob // empty' <<<"$payload")
    [[ -n "$grep_path" ]] && is_dotenv_path "$grep_path" && deny "$DENY_READ_TOOL"
    [[ -n "$grep_glob" ]] && is_dotenv_path "$grep_glob" && deny "$DENY_READ_TOOL"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    # The backtick is in the set for the same reason the parens are: a
    # substitution hides a whole command inside another one, and only splitting
    # on it puts that command's own word in first position where the walk reads
    # it. Without it the two substitution spellings disagree, `$(cat <secret>)`
    # denying while the backtick form of the identical read is allowed, so
    # coverage would turn on which spelling the caller happened to use.
    while IFS= read -r seg; do
      process_segment "$seg"
    done < <(printf '%s\n' "$cmd" | tr '|&;()`' '\n')

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
