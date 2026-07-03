#!/usr/bin/env bash

# Serena code-search guard (PreToolUse, matcher: Grep, Bash).
#
# Routes symbol-level searches to Serena's LSP-backed MCP tools instead of
# ripgrep. The routing RULE lives in .claude/rules/code-search.md, but that rule
# is path-scoped to app/** and test/** EDITS, so it is usually not in context
# during exploration, which is exactly when the grep-vs-Serena decision gets
# made. This hook fires at the moment of the search call, closing that gap.
#
# BEHAVIOR: when the pattern is a bare identifier searched over indexed TS/TSX
# source, the search is blocked (exit 2) with a message pointing at Serena's
# find_symbol / find_referencing_symbols / get_symbols_overview. A bare
# identifier over source is a "where is X / what calls X" query, precisely what
# Serena answers with type resolution where grep only string-matches.
#
# TWO MATCHERS, ONE SCRIPT. The Grep tool exposes its pattern/path/glob/type as
# structured fields; the Bash tool exposes only a raw command line, so real
# symbol searches also arrive as shell grep/rg/ag. Branch on .tool_name:
#   - Grep -> read .tool_input.pattern/path/glob/type (structured gates below).
#   - Bash -> read .tool_input.command and fire only on a SINGLE grep/rg/ag
#     invocation whose lone pattern is a bare identifier scoped to app/** or
#     test/** TS/TSX. The Bash detection is deliberately shallow and biased
#     toward allowing: a pipeline, a sequenced or compound command, a command
#     substitution, a redirection, a quoted/regex/multi-word pattern, multiple
#     patterns, a non-TS scope, or a scope that cannot be resolved to app/test
#     source all pass through. Blocking legitimate shell work is worse than
#     missing a symbol grep, so every ambiguous case allows.
#   - any other tool -> allow (never seen in practice).
#
# ESCAPE (block-once): re-running the IDENTICAL search within 2 minutes passes.
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
# gate. Any ambiguity resolves toward allowing the search.
#
# No `set -e`: this is a routing guard, not a security gate. On any parse failure
# the checks resolve empty and the search is allowed.

command -v jq >/dev/null 2>&1 || exit 0   # can't parse input; allow

input=$(cat)

tool_name=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null)

# Strip one matching pair of surrounding quotes from a shell token.
strip_quotes() {
  local s=$1
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
}

case "$tool_name" in
  Grep)
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

    # --- Gate 1: pattern must be a bare identifier --------------------------
    # A symbol query is a single identifier token, >= 3 chars. Anything with
    # spaces, quotes, dots, slashes, or regex metacharacters is prose / a string
    # literal / a real regex, and belongs to grep.
    [[ "$pattern" =~ ^[A-Za-z_$][A-Za-z0-9_$]*$ ]] || exit 0
    [ "${#pattern}" -ge 3 ] || exit 0

    # --- Gate 2: scope must not be narrowed away from TS/TSX source ----------
    # type set to a non-TS language -> allow.
    if [ -n "$gtype" ] && ! [[ "$gtype" =~ ^(ts|tsx|typescript|typescriptreact)$ ]]; then
      exit 0
    fi
    # glob set but not targeting .ts/.tsx -> allow. The `\.tsx?` anchor requires
    # a literal-dot extension, so it will not false-match "test" and friends.
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

    key=$(printf '%s\037%s\037%s\037%s\037%s' "$pattern" "$gpath" "$glob" "$gtype" "$sid" | cksum | cut -d' ' -f1)
    ;;

  Bash)
    IFS=$'\037' read -r cmd sid <<<"$(
      jq -r '[.tool_input.command // "",
              .session_id // ""] | join("\u001f")' <<<"$input" 2>/dev/null
    )"

    [ -n "$cmd" ] || exit 0

    # A lone symbol grep is a SINGLE simple invocation. A pipe, a sequence or
    # compound operator, a command substitution, a backtick, or a redirection
    # means the grep is wired into a larger command (git diff | grep, pnpm lint
    # | grep, playwright ... | grep, echo x && grep) and is not a symbol query,
    # so allow. A regex-alternation pattern like "foo|bar" also lands here,
    # which is the desired allow.
    # shellcheck disable=SC2016  # '$(' and '`' are literal match targets, not expansions
    case "$cmd" in
      *'|'* | *';'* | *'&'* | *'$('* | *'`'* | *'>'* | *'<'*) exit 0 ;;
    esac

    # Tokenize on whitespace. Quotes stay literal in each token and are stripped
    # per token below; a quoted multi-word or regex pattern therefore stays
    # un-identifier-like and falls through to allow.
    read -ra toks <<<"$cmd"
    [ "${#toks[@]}" -ge 1 ] || exit 0

    # Skip leading VAR=value env assignments, then require grep/rg/ag as the
    # command word. `git commit -m "grep useBreakpoint ..."` has command word
    # git, so a prose `grep` inside its quoted arg never triggers.
    i=0
    while [ "$i" -lt "${#toks[@]}" ] && [[ "${toks[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      i=$((i + 1))
    done
    case "${toks[$i]:-}" in
      grep | rg | ag) ;;
      *) exit 0 ;;
    esac
    i=$((i + 1))

    # First non-flag token is the pattern; later non-flag tokens are path
    # candidates; --include/--glob/-g carry a scope glob. -e/-f/--regexp/--file
    # mean multiple or file-driven patterns, so allow.
    pat=""
    seen_pattern=0
    have_scope_path=0
    glob_narrows_away=0
    while [ "$i" -lt "${#toks[@]}" ]; do
      tok=${toks[$i]}
      case "$tok" in
        -e | --regexp | --regexp=* | -f | --file | --file=*)
          exit 0 ;;
        --include=*)
          g=$(strip_quotes "${tok#--include=}")
          [[ "$g" =~ \.tsx?$ ]] || glob_narrows_away=1 ;;
        --glob=*)
          g=$(strip_quotes "${tok#--glob=}")
          [[ "$g" =~ \.tsx?$ ]] || glob_narrows_away=1 ;;
        --include | --glob | -g)
          i=$((i + 1))
          g=$(strip_quotes "${toks[$i]:-}")
          [[ "$g" =~ \.tsx?$ ]] || glob_narrows_away=1 ;;
        -*)
          : ;;   # other flag, ignore (shallow by design)
        *)
          if [ "$seen_pattern" -eq 0 ]; then
            pat=$(strip_quotes "$tok")
            seen_pattern=1
          else
            p=$(strip_quotes "$tok")
            p=${p#./}
            p=${p%/}
            case "$p" in
              app | app/* | test | test/*)
                # In app/test: count it only if it is a directory-like token or
                # a .ts/.tsx file. A concrete non-TS file (app/foo.md) does not.
                base=${p##*/}
                case "$base" in
                  *.*) [[ "$base" =~ \.tsx?$ ]] && have_scope_path=1 ;;
                  *)   have_scope_path=1 ;;
                esac
                ;;
            esac
          fi
          ;;
      esac
      i=$((i + 1))
    done

    # All must hold; every miss allows (favor false-negatives over blocking
    # legitimate shell work).
    [ "$seen_pattern" -eq 1 ] || exit 0
    [[ "$pat" =~ ^[A-Za-z_$][A-Za-z0-9_$]*$ ]] || exit 0
    [ "${#pat}" -ge 3 ] || exit 0
    [ "$glob_narrows_away" -eq 0 ] || exit 0
    [ "$have_scope_path" -eq 1 ] || exit 0

    pattern="$pat"
    key=$(printf '%s\037%s' "$cmd" "$sid" | cksum | cut -d' ' -f1)
    ;;

  *)
    exit 0 ;;   # never block a tool this guard was not meant to see
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

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
