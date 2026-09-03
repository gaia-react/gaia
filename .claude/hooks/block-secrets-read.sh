#!/usr/bin/env bash
# PreToolUse Read + Bash hook: read-side guard for key, certificate, and
# credential paths. The read-side counterpart to block-secrets-write.sh, which
# judges write CONTENT; this one judges read PATHS.
#
# It carries the obligation four permissions.deny rules used to hold:
#
#   Read(**/*.key)  Read(**/*.pem)  Read(**/*credential*)  Read(**/secrets/*)
#
# Those rules are gone, and this hook exists because of how they failed rather
# than because they were wrong. A `**` Read() deny glob arms Claude Code's
# deniedPathInsideDirectory circuit breaker for EVERY directory in the tree,
# since a `**` pattern can always match something inside any directory. The
# breaker is bypass-immune, so every recursive grep, rg, diff, git, cp and mv
# demanded a manual approval that no allow rule could waive. A guard nobody can
# afford to leave on is not protection. This one costs nothing per command.
#
# WHAT COUNTS AS A SECRET PATH, and how it differs from the globs above:
#   - basename ending .key or .pem            (same as the globs)
#   - basename containing "credential"        (CASE-INSENSITIVE; the glob was
#                                              case-sensitive, so this is
#                                              strictly wider)
#   - any path under a directory named secrets (the glob matched only a file
#                                              DIRECTLY inside it, so this is
#                                              strictly wider)
# Both widenings are deliberate. A guard replacing another guard should not be
# the narrower of the two, and neither widening can produce a false deny on a
# path the old rule would have allowed for a good reason.
#
# HONEST LIMITS, and they are the same ones the rules it replaces had: this is
# heuristic defense-in-depth, not a sandbox. It pattern-matches command text and
# can be evaded by obfuscation. It does not reach MCP-mediated shell execution
# (e.g. Serena's execute_shell_command) or a subprocess that opens the file
# itself. The airtight tier is the OS-level sandbox (sandbox.filesystem
# deny-read rules), which this repo does not configure.
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
if ! type gaia_reader_operands >/dev/null 2>&1; then
  # A guard that cannot load its own grammar must not report clean.
  printf 'block-secrets-read.sh: cannot load lib/reader-operands.sh\n' >&2
  exit 1
fi

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

DENY_READ_TOOL="BLOCKED: reading key, certificate, and credential files is denied to protect local secrets. This covers '*.key', '*.pem', any name containing 'credential', and anything under a 'secrets/' directory. Heuristic defense-in-depth, not a sandbox."
DENY_READ="BLOCKED: a command here reads a key, certificate, or credential path ('*.key', '*.pem', a name containing 'credential', or anything under a 'secrets/' directory). Denied to protect local secrets. Heuristic defense-in-depth, not a sandbox."

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

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
}

is_secret_path() {
  local p="$1" base lower
  p=$(strip_quotes "$p")
  [[ -n "$p" ]] || return 1

  base=$(basename -- "$p")
  case "$base" in
    *.key | *.pem) return 0 ;;
  esac

  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *credential*) return 0 ;;
  esac

  # A `secrets` directory anywhere on the path. The leading and trailing slashes
  # make the comparison segment-bounded, so `mysecrets/` and `secrets-old/` do
  # not match while `a/secrets/b/c` does.
  case "/$p/" in
    */secrets/*) return 0 ;;
  esac

  return 1
}

process_segment() {
  local seg="$1"
  local operand

  while IFS= read -r operand; do
    if is_secret_path "$operand"; then
      deny "$DENY_READ"
    fi
  done < <(gaia_reader_operands "$seg")
  return 0
}

case "$tool_name" in
  Read)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_secret_path "$file_path" && deny "$DENY_READ_TOOL"
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
