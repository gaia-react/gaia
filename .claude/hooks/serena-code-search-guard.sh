#!/usr/bin/env bash

# Serena code-search guard (PreToolUse, matcher: Grep).
#
# Routes symbol-level searches to Serena's LSP-backed MCP tools instead of
# ripgrep. The routing RULE lives in .claude/rules/code-search.md, but that rule
# is path-scoped to app/** and test/** EDITS, so it is usually not in context
# during exploration, which is exactly when the grep-vs-Serena decision gets
# made. This hook fires at the moment of the Grep call, closing that gap.
#
# BEHAVIOR: when the pattern is a bare identifier searched over indexed TS/TSX
# source, the grep is blocked (exit 2) with a message pointing at Serena's
# find_symbol / find_referencing_symbols / get_symbols_overview. A bare
# identifier over source is a "where is X / what calls X" query, precisely what
# Serena answers with type resolution where grep only string-matches.
#
# ESCAPE (block-once): re-running the IDENTICAL grep within 2 minutes passes.
# Genuine string-literal / comment / cross-language searches that happen to be
# identifier-shaped are rare; the re-run lets them through without a permanent
# wall, honoring the "safe direction is to allow" posture of the sibling guards.
#
# ADOPTER SAFETY: no-ops silently unless Serena is actually registered as an MCP
# server (user scope in ~/.claude.json, or project .mcp.json) AND the repo has a
# tsconfig.json for Serena to index. Adopters without Serena never see it.
#
# CONSERVATIVE BY DESIGN: fires only on a bare identifier (>= 3 chars, no spaces,
# quotes, dots, or regex metacharacters) whose scope is not narrowed away from
# TS/TSX source. Prose, string literals, and real regexes never pass the pattern
# gate. Any ambiguity resolves toward allowing the grep.
#
# No `set -e`: this is a routing guard, not a security gate. On any parse failure
# the checks resolve empty and the grep is allowed.

command -v jq >/dev/null 2>&1 || exit 0   # can't parse input; allow

input=$(cat)

# Extract every field in one jq pass, joined by the unit separator (0x1f). A
# NON-whitespace separator is essential: `read` folds consecutive whitespace
# (including tabs), which would collapse empty middle fields and shift later
# values into earlier variables. 0x1f is not folded, so empty fields survive.
IFS=$'\037' read -r pattern gpath glob gtype sid <<<"$(
  jq -r '[.tool_input.pattern // "",
          .tool_input.path // "",
          .tool_input.glob // "",
          .tool_input.type // "",
          .session_id // ""] | join("\u001f")' <<<"$input" 2>/dev/null
)"

[ -n "$pattern" ] || exit 0

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# --- Gate 1: pattern must be a bare identifier ------------------------------
# A symbol query is a single identifier token, >= 3 chars. Anything with spaces,
# quotes, dots, slashes, or regex metacharacters is prose / a string literal /
# a real regex, and belongs to grep.
[[ "$pattern" =~ ^[A-Za-z_$][A-Za-z0-9_$]*$ ]] || exit 0
[ "${#pattern}" -ge 3 ] || exit 0

# --- Gate 2: scope must not be narrowed away from TS/TSX source --------------
# type set to a non-TS language -> allow.
if [ -n "$gtype" ] && ! [[ "$gtype" =~ ^(ts|tsx|typescript|typescriptreact)$ ]]; then
  exit 0
fi
# glob set but not targeting .ts/.tsx -> allow. The `\.tsx?` anchor requires a
# literal-dot extension, so it will not false-match "test" and friends.
if [ -n "$glob" ] && ! [[ "$glob" =~ \.tsx?([^a-zA-Z]|$) ]]; then
  exit 0
fi
# path set but outside app/ and test/ -> allow. Strip a leading ./ first.
if [ -n "$gpath" ]; then
  p=${gpath#./}
  case "$p" in
    app | app/* | test | test/*) : ;;   # in scope
    *) exit 0 ;;
  esac
fi

# --- Gate 3: Serena must actually be available ------------------------------
# tsconfig is what Serena indexes; no tsconfig -> nothing to route to.
[ -f "$ROOT/tsconfig.json" ] || exit 0

serena_registered() {
  # user scope (how GAIA registers Serena) + any per-project block
  if [ -f "$HOME/.claude.json" ]; then
    {
      jq -r '(.mcpServers // {}) | keys[]?' "$HOME/.claude.json" 2>/dev/null
      jq -r '(.projects // {}) | .[]?.mcpServers // {} | keys[]?' "$HOME/.claude.json" 2>/dev/null
    } | grep -qx 'serena' && return 0
  fi
  # project scope
  [ -f "$ROOT/.mcp.json" ] && jq -e '.mcpServers.serena // empty' "$ROOT/.mcp.json" >/dev/null 2>&1 && return 0
  return 1
}
serena_registered || exit 0

# --- Block-once escape ------------------------------------------------------
STATE_DIR="$ROOT/.gaia/cache/serena-guard"
key=$(printf '%s\037%s\037%s\037%s\037%s' "$pattern" "$gpath" "$glob" "$gtype" "$sid" | cksum | cut -d' ' -f1)

# Prune stale markers (> 10 min) so the cache never grows unbounded.
[ -d "$STATE_DIR" ] && find "$STATE_DIR" -type f -mmin +10 -delete 2>/dev/null

# A fresh marker for this exact call means this is the acknowledged re-run.
if [ -n "$(find "$STATE_DIR" -name "$key" -mmin -2 2>/dev/null)" ]; then
  rm -f "$STATE_DIR/$key"
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null
: > "$STATE_DIR/$key"

cat >&2 <<EOF
BLOCKED (serena-code-search guard): "$pattern" is a bare identifier searched
over TS/TSX source, i.e. a symbol query. Serena resolves these against the
language server; grep only string-matches.

Use Serena instead:
  - find_symbol               where "$pattern" is defined, and its type
  - find_referencing_symbols  what calls / imports "$pattern"
  - get_symbols_overview      the symbol shape of a file or module

Genuinely searching a string literal, comment, JSX text, or across languages?
Re-run the IDENTICAL grep and it will pass.

Rule: .claude/rules/code-search.md
EOF
exit 2
