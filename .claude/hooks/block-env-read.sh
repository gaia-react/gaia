#!/usr/bin/env bash
# PreToolUse Read + Bash hook: read-side secret guard for dotenv files.
#
# Read(.env) in settings.json already enforces against the Read tool and
# against the Bash file commands Claude Code recognizes (cat, head, tail,
# sed) targeting a file literally named .env, at any depth. This hook does
# not re-implement that coverage.
#
# It closes the residual gaps the built-in rule leaves open:
#   - variant dotenv files (.env.local, .env.production, .env.<anything>,
#     excluding the committed .env.example placeholder) are not matched by
#     Read(.env), so the Read tool and even a recognized reader
#     (cat/head/tail/sed) against a variant are otherwise unguarded.
#   - residual Bash read paths: sourcing (source / .), redirection from a
#     dotenv path (< / $(<...)), and readers outside the recognized
#     cat/head/tail/sed set.
#   - bare process-environment dumps (env, printenv, set, export -p,
#     declare -p, compgen -v) that read the shell environment rather than a
#     file, so no file-permission rule governs them.
#
# This is heuristic defense-in-depth, not a sandbox: it pattern-matches
# command text and can be evaded by determined obfuscation. The airtight
# enforcement for arbitrary subprocesses that open the file directly is the
# OS-level sandbox (sandbox.filesystem deny-read rules, merged with the
# Read/Edit permission denies). This hook does not reach MCP-mediated shell
# execution (e.g. Serena's execute_shell_command), arbitrary subprocesses
# that open the file themselves (a Node or Python script reading it
# directly), or deliberate obfuscation of a read command.
set -euo pipefail

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

DENY_READ_TOOL="BLOCKED: reading '.env' / '.env.*' files is denied to protect local secrets. Only '.env.example' is readable. This guard is heuristic defense-in-depth, not a sandbox."
DENY_DUMP="BLOCKED: a bare environment dump (env/printenv/set) is denied so exported secrets cannot be printed into the transcript. Use 'env NAME=value <cmd>' to set a variable for a command. Heuristic defense-in-depth, not a sandbox."
DENY_READ="BLOCKED: reading a .env / .env.* file (sourcing, redirection, or a non-recognized reader) is denied to protect local secrets. '.env.example' is exempt. Heuristic defense-in-depth, not a sandbox."

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

# Strip one matching pair of surrounding quotes from a token.
strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
}

# Dotenv path definition: the basename (after stripping surrounding quotes)
# matches .env or .env.<token>(.<token>)*, and is not exactly .env.example.
is_dotenv_path() {
  local p="$1" base
  p=$(strip_quotes "$p")
  [[ -n "$p" ]] || return 1
  base=$(basename -- "$p")
  [[ "$base" =~ ^\.env(\.[A-Za-z0-9_-]+)*$ ]] || return 1
  [[ "$base" == ".env.example" ]] && return 1
  return 0
}

# Command-position anchoring (mirrors block-bare-test.sh): strip leading
# NAME=value env-var assignments so the real command word is exposed.
strip_env_prefix() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//'
}

# Deny if any remaining token (after the command word) is a dotenv path.
check_reader_args() {
  local a
  for a in "$@"; do
    a=$(strip_quotes "$a")
    is_dotenv_path "$a" && deny "$DENY_READ"
  done
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
# `env -0`). Otherwise it is a runner: strip `env` and any leading
# NAME=value assignments, then re-evaluate the wrapped command.
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

  process_tokens "${toks[@]:$i}"
  return 0
}

# Redirection FROM a dotenv path: `< <dotenv>` or `$(< <dotenv>)`. Applies
# regardless of command word, since the target may be a bare assignment
# (`x=$(<.env)`) with no recognizable command word at all.
check_redirect_from_dotenv() {
  local seg="$1" rest cand
  case "$seg" in
    *'<'*) : ;;
    *) return 0 ;;
  esac
  rest=$(printf '%s' "$seg" | sed -E 's/^.*<[[:space:]]*//')
  cand=$(printf '%s' "$rest" | sed -E 's/[[:space:])].*$//')
  cand=$(strip_quotes "$cand")
  is_dotenv_path "$cand" && deny "$DENY_READ"
  return 0
}

# Command-word dispatch shared by the top-level segment walk and the `env`
# runner re-evaluation.
process_tokens() {
  local toks=("$@")
  local cmdword="${toks[0]:-}"
  cmdword=$(strip_quotes "$cmdword")

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
    source | .)
      check_reader_args "${toks[@]:1}"
      ;;
    cat | head | tail | sed | xxd | od | hexdump | strings | nl | less | more | diff | cut | tac | paste | awk | perl)
      check_reader_args "${toks[@]:1}"
      ;;
  esac
  return 0
}

# Split the command on pipeline/separator boundaries (mirrors
# block-bare-test.sh) and evaluate each segment independently.
process_segment() {
  local seg="$1"
  local seg_cmd
  local toks

  seg_cmd=$(strip_env_prefix "$seg")
  read -r -a toks <<<"$seg_cmd"

  process_tokens "${toks[@]}"
  check_redirect_from_dotenv "$seg"
  return 0
}

case "$tool_name" in
  Read)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_dotenv_path "$file_path" && deny "$DENY_READ_TOOL"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    while IFS= read -r seg; do
      process_segment "$seg"
    done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
