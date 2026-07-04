#!/usr/bin/env bash
# Shared Serena language-sync library.
#
# Detects "additive drift": a language present on disk via a git-tracked
# high-signal manifest but absent from Serena's effective configured
# `languages:` set, and performs a safe, byte-identical, consent-gated append
# to the `languages:` list in `.serena/project.yml`.
#
# Dual interface:
#   (a) source it and call the `serena_*` functions, or
#   (b) run it as `serena-lang.sh <subcommand> ...` (dispatch guarded at the
#       bottom by `[ "${BASH_SOURCE[0]}" = "$0" ]`).
#
# Runtime dependencies: bash + jq + POSIX text tools (grep, sed, awk, git).
# There is NO `yq` and NO `python` on the runtime path by design.
#
# Do NOT add `set -e`. On any parse failure this library resolves to the safe
# direction (empty drift for detection, a printed FALLBACK for append), never a
# crash and never a false positive.

# Serena's known-language set (base + alternative-server variant tokens). This
# is the single authoritative source for serena_valid_token. It is a working
# subset of Serena's Language enum, sufficient for this feature: the marker map
# only ever emits the seven base tokens, all present here.
SERENA_KNOWN_LANGUAGES="al bash clojure cpp csharp csharp_omnisharp dart elixir elm erlang fortran fsharp go groovy haskell haxe java julia kotlin lua markdown matlab nix pascal perl php php_phpactor powershell python python_jedi python_ty r rego ruby ruby_solargraph rust scala swift terraform toml typescript typescript_vts vue yaml zig"

# --- Token helpers ----------------------------------------------------------

# serena_normalize_token <token> — print the base language for a variant/alias;
# print the token unchanged when it is already a base token.
serena_normalize_token() {
  case "$1" in
    python_jedi|python_ty) printf 'python\n' ;;
    csharp_omnisharp) printf 'csharp\n' ;;
    ruby_solargraph) printf 'ruby\n' ;;
    php_phpactor) printf 'php\n' ;;
    typescript_vts) printf 'typescript\n' ;;
    javascript) printf 'typescript\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# serena_valid_token <token> — exit 0 if the token is in Serena's known set.
serena_valid_token() {
  local token="$1" known
  for known in $SERENA_KNOWN_LANGUAGES; do
    [ "$known" = "$token" ] && return 0
  done
  return 1
}

# _serena_clean_token <raw> — strip surrounding whitespace and a single pair of
# matching quotes. Print the cleaned token (no trailing newline).
_serena_clean_token() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  case "$t" in
    \"*\") t="${t#\"}"; t="${t%\"}" ;;
    \'*\') t="${t#\'}"; t="${t%\'}" ;;
  esac
  printf '%s' "$t"
}

# --- Serena registration ----------------------------------------------------

# serena_registered <root> — exit 0 if Serena is a registered MCP server.
# Deliberate parallel to the inline serena_registered() in
# .claude/hooks/serena-code-search-guard.sh, but WITHOUT its tsconfig gate so
# detection fires for non-TS projects. Requires jq; exit 1 if jq is absent.
serena_registered() {
  local root="$1"
  command -v jq >/dev/null 2>&1 || return 1
  if [ -f "$HOME/.claude.json" ]; then
    {
      jq -r '(.mcpServers // {}) | keys[]?' "$HOME/.claude.json" 2>/dev/null
      jq -r '(.projects // {}) | .[]?.mcpServers // {} | keys[]?' "$HOME/.claude.json" 2>/dev/null
    } | grep -qx 'serena' && return 0
  fi
  [ -f "$root/.mcp.json" ] && jq -e '.mcpServers.serena // empty' "$root/.mcp.json" >/dev/null 2>&1 && return 0
  return 1
}

# --- Configured (effective) languages ---------------------------------------

# _serena_raw_tokens <file> — print raw (un-normalized, un-cleaned) language
# tokens found in ONE YAML file across the three supported forms: block list,
# single-line flow list, and legacy singular `language:` scalar. Best-effort
# and line-based; full-line comments are ignored. Prints nothing on any form it
# does not recognize (false-negative bias).
_serena_raw_tokens() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    {
      line = $0
      # Full-line comment: ignore, and it terminates an open block list.
      if (line ~ /^[[:space:]]*#/) { inblock = 0; next }
      if (inblock) {
        if (line ~ /^[[:space:]]*-[[:space:]]*[^[:space:]]/) {
          item = line
          sub(/^[[:space:]]*-[[:space:]]*/, "", item)
          sub(/[[:space:]]+#.*$/, "", item)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
          if (item != "") print item
          next
        }
        inblock = 0
        # fall through to re-test this line for other forms
      }
      # Single-line flow list: languages: [ ... ]
      if (line ~ /^[[:space:]]*languages:[[:space:]]*\[/) {
        inner = line
        sub(/^[[:space:]]*languages:[[:space:]]*\[/, "", inner)
        sub(/\].*$/, "", inner)
        n = split(inner, arr, ",")
        for (i = 1; i <= n; i++) {
          t = arr[i]
          sub(/[[:space:]]+#.*$/, "", t)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
          if (t != "") print t
        }
        next
      }
      # Block-list start: languages: with an empty (or comment-only) value.
      if (line ~ /^[[:space:]]*languages:[[:space:]]*$/ || line ~ /^[[:space:]]*languages:[[:space:]]*#/) {
        inblock = 1
        next
      }
      # Legacy singular scalar: language: <value>
      if (line ~ /^[[:space:]]*language:[[:space:]]*[^[:space:]#]/) {
        val = line
        sub(/^[[:space:]]*language:[[:space:]]*/, "", val)
        sub(/[[:space:]]+#.*$/, "", val)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (val != "") print val
      }
    }
  ' "$file"
}

# _serena_file_norm_tokens <file> — cleaned + normalized + de-duplicated tokens
# from a single file.
_serena_file_norm_tokens() {
  local file="$1" raw t
  _serena_raw_tokens "$file" | while IFS= read -r raw; do
    t=$(_serena_clean_token "$raw")
    [ -n "$t" ] || continue
    serena_normalize_token "$t"
  done | awk '!seen[$0]++'
}

# serena_effective_languages <root> — print newline-separated, normalized
# base-language tokens = the union across .serena/project.yml and
# .serena/project.local.yml. Print nothing if the primary file is absent.
serena_effective_languages() {
  local root="$1"
  local primary="$root/.serena/project.yml"
  [ -f "$primary" ] || return 0
  local local_yml="$root/.serena/project.local.yml"
  {
    _serena_file_norm_tokens "$primary"
    [ -f "$local_yml" ] && _serena_file_norm_tokens "$local_yml"
  } | awk '!seen[$0]++'
}

# --- Manifest-derived languages ---------------------------------------------

# serena_manifest_languages <root> — map git-tracked high-signal manifests to
# base-language tokens. Conservative map (git-tracked files only); gitignored or
# vendored files never appear in `git ls-files` and are auto-excluded.
serena_manifest_languages() {
  local root="$1"
  local seen=" " f base token
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f##*/}
    token=""
    case "$base" in
      go.mod) token=go ;;
      Cargo.toml) token=rust ;;
      pyproject.toml|setup.py) token=python ;;
      pom.xml|build.gradle) token=java ;;
      Gemfile) token=ruby ;;
      composer.json) token=php ;;
      *.csproj|*.sln) token=csharp ;;
      *.gemspec) token=ruby ;;
    esac
    [ -n "$token" ] || continue
    case "$seen" in
      *" $token "*) ;;
      *) seen="$seen$token "; printf '%s\n' "$token" ;;
    esac
  done < <(git -C "$root" ls-files 2>/dev/null)
}

# --- Top-level drift detector -----------------------------------------------

# serena_lang_drift <root> — print a compact JSON array of missing base tokens
# = sorted(manifest_languages - effective_languages). Print [] when jq is
# unavailable, Serena is not registered, .serena/project.yml is absent, or there
# is no drift. Always exit 0.
serena_lang_drift() {
  local root="$1"
  command -v jq >/dev/null 2>&1 || { printf '[]\n'; return 0; }
  serena_registered "$root" || { printf '[]\n'; return 0; }
  [ -f "$root/.serena/project.yml" ] || { printf '[]\n'; return 0; }
  local manifests effective
  manifests=$(serena_manifest_languages "$root")
  effective=$(serena_effective_languages "$root")
  jq -nc --arg m "$manifests" --arg e "$effective" '
    def toks: split("\n") | map(select(length > 0));
    (($m | toks) - ($e | toks)) | unique
  '
}

# --- Form classification (append safety) ------------------------------------

# _serena_block_scan <file> <key_lno> — scan the block list following the
# `languages:` key at <key_lno>. Print one tab-separated line:
#   <status>\t<indent>\t<last_item_lno>
# status is one of: block (safe), complex, malformed, empty (no list items).
_serena_block_scan() {
  local file="$1" key_lno="$2"
  awk -v kl="$key_lno" '
    NR <= kl { next }
    status == "" {
      line = $0
      c = line
      sub(/[[:space:]]#.*$/, "", c)   # strip inline comment for anchor test
      if (first == 0) {
        if (line ~ /^[[:space:]]*-[[:space:]]+[^[:space:]#]/) {
          match(line, /^[[:space:]]*/); indent = substr(line, 1, RLENGTH)
          last = NR; first = 1
          if (c ~ /[&*]/) status = "complex"
        } else {
          status = "empty"
        }
        next
      }
      if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) { status = "block"; next }
      if (line ~ /^[[:space:]]*-[[:space:]]/) {
        match(line, /^[[:space:]]*/); ind2 = substr(line, 1, RLENGTH)
        if (ind2 != indent) status = "malformed"
        else if (c ~ /[&*]/) status = "complex"
        else last = NR
        next
      }
      status = "block"   # a new key or other content ends the list
    }
    END {
      if (status == "") { if (first == 1) status = "block"; else status = "empty" }
      printf "%s\t%s\t%s\n", status, indent, last
    }
  ' "$file"
}

# serena_classify_form <project_yml> — print block:<indent> | flow |
# unsafe:<reason>. Exit 0 for safe forms, non-zero for unsafe.
serena_classify_form() {
  local file="$1"
  [ -f "$file" ] || { printf 'unsafe:malformed\n'; return 1; }
  local n_keys
  n_keys=$(grep -cE '^[[:space:]]*languages:([[:space:]]|$|\[)' "$file" 2>/dev/null)
  case "$n_keys" in ''|*[!0-9]*) n_keys=0 ;; esac
  if [ "$n_keys" -gt 1 ]; then
    printf 'unsafe:multiple-keys\n'; return 1
  fi
  if [ "$n_keys" -eq 0 ]; then
    if grep -qE '^[[:space:]]*language:[[:space:]]*[^[:space:]#]' "$file" 2>/dev/null; then
      printf 'unsafe:legacy-scalar\n'; return 1
    fi
    if grep -qE '^[[:space:]]*#.*languages:' "$file" 2>/dev/null; then
      printf 'unsafe:comment-only\n'; return 1
    fi
    printf 'unsafe:no-key\n'; return 1
  fi
  local key_lno key_line value
  key_lno=$(grep -nE '^[[:space:]]*languages:([[:space:]]|$|\[)' "$file" | head -1 | cut -d: -f1)
  key_line=$(sed -n "${key_lno}p" "$file")
  value="${key_line#*languages:}"
  value=$(printf '%s' "$value" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$value" ]; then
    local scan status indent
    scan=$(_serena_block_scan "$file" "$key_lno")
    status=$(printf '%s' "$scan" | cut -f1)
    indent=$(printf '%s' "$scan" | cut -f2)
    case "$status" in
      block) printf 'block:%s\n' "$indent"; return 0 ;;
      complex) printf 'unsafe:complex\n'; return 1 ;;
      malformed) printf 'unsafe:malformed\n'; return 1 ;;
      *) printf 'unsafe:not-a-list\n'; return 1 ;;
    esac
  fi
  case "$value" in
    *['&*']*) printf 'unsafe:complex\n'; return 1 ;;
  esac
  case "$value" in
    \[*)
      if printf '%s' "$value" | grep -qE '^\[[^][]*\]$'; then
        printf 'flow\n'; return 0
      fi
      printf 'unsafe:complex\n'; return 1
      ;;
    *)
      printf 'unsafe:not-a-list\n'; return 1
      ;;
  esac
}

# --- Consent-gated append ---------------------------------------------------

# _serena_append_flow <file> <token...> — append tokens to a single-line flow
# list, preserving surrounding spacing and any trailing comment.
_serena_append_flow() {
  local file="$1"; shift
  local key_lno line prefix rest inner suffix inner_trim new_inner tok new_line tmp dir
  key_lno=$(grep -nE '^[[:space:]]*languages:([[:space:]]|$|\[)' "$file" | head -1 | cut -d: -f1)
  [ -n "$key_lno" ] || return 1
  line=$(sed -n "${key_lno}p" "$file")
  prefix="${line%%\[*}"
  rest="${line#*\[}"
  inner="${rest%%\]*}"
  suffix="${rest#*\]}"
  inner_trim=$(printf '%s' "$inner" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$inner_trim" ]; then
    new_inner=""
    for tok in "$@"; do
      if [ -z "$new_inner" ]; then new_inner="$tok"; else new_inner="$new_inner, $tok"; fi
    done
  else
    new_inner="$inner"
    for tok in "$@"; do new_inner="$new_inner, $tok"; done
  fi
  new_line="${prefix}[${new_inner}]${suffix}"
  dir=$(dirname "$file")
  tmp=$(mktemp "$dir/.serena-lang.XXXXXX" 2>/dev/null) || tmp="$file.tmp.$$"
  {
    head -n "$((key_lno - 1))" "$file"
    printf '%s\n' "$new_line"
    tail -n "+$((key_lno + 1))" "$file"
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then mv "$tmp" "$file"; else rm -f "$tmp"; return 1; fi
}

# _serena_append_block <file> <token...> — append tokens as new list items at
# the block list's exact indentation, immediately after the last item.
_serena_append_block() {
  local file="$1"; shift
  local key_lno scan status indent last_lno inserts tok tmp dir
  key_lno=$(grep -nE '^[[:space:]]*languages:([[:space:]]|$|\[)' "$file" | head -1 | cut -d: -f1)
  [ -n "$key_lno" ] || return 1
  scan=$(_serena_block_scan "$file" "$key_lno")
  status=$(printf '%s' "$scan" | cut -f1)
  indent=$(printf '%s' "$scan" | cut -f2)
  last_lno=$(printf '%s' "$scan" | cut -f3)
  [ "$status" = "block" ] || return 1
  case "$last_lno" in ''|*[!0-9]*) return 1 ;; esac
  inserts=""
  for tok in "$@"; do
    inserts="${inserts}${indent}- ${tok}
"
  done
  dir=$(dirname "$file")
  tmp=$(mktemp "$dir/.serena-lang.XXXXXX" 2>/dev/null) || tmp="$file.tmp.$$"
  {
    head -n "$last_lno" "$file"
    printf '%s' "$inserts"
    tail -n "+$((last_lno + 1))" "$file"
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then mv "$tmp" "$file"; else rm -f "$tmp"; return 1; fi
}

# serena_lang_append <project_yml> <token> [token...] — on a safe form, append
# each not-already-present, validated token reusing the list's exact style; keep
# every other line byte-identical. Exit 0. On any unsafe form or invalid token,
# write nothing, print FALLBACK:<reason>, exit non-zero. Idempotent set-union
# against THIS file's own `languages:` list.
serena_lang_append() {
  local project_yml="$1"; shift
  [ -f "$project_yml" ] || { printf 'FALLBACK:malformed\n'; return 1; }
  [ "$#" -ge 1 ] || return 0
  local form rc reason
  form=$(serena_classify_form "$project_yml")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="${form#unsafe:}"
    printf 'FALLBACK:%s\n' "$reason"
    return 1
  fi
  local existing
  existing=$(_serena_file_norm_tokens "$project_yml")
  local -a to_add=()
  local tok normtok present e a
  for tok in "$@"; do
    normtok=$(serena_normalize_token "$tok")
    present=0
    while IFS= read -r e; do
      [ "$e" = "$normtok" ] && { present=1; break; }
    done <<EOF
$existing
EOF
    [ "$present" -eq 1 ] && continue
    for a in "${to_add[@]}"; do
      [ "$a" = "$tok" ] && { present=1; break; }
    done
    [ "$present" -eq 1 ] && continue
    if ! serena_valid_token "$tok"; then
      printf 'FALLBACK:invalid-token\n'
      return 1
    fi
    to_add+=("$tok")
  done
  [ "${#to_add[@]}" -ge 1 ] || return 0
  case "$form" in
    flow)
      _serena_append_flow "$project_yml" "${to_add[@]}" || { printf 'FALLBACK:malformed\n'; return 1; }
      ;;
    block:*)
      _serena_append_block "$project_yml" "${to_add[@]}" || { printf 'FALLBACK:malformed\n'; return 1; }
      ;;
    *)
      printf 'FALLBACK:malformed\n'; return 1
      ;;
  esac
  return 0
}

# --- Executable subcommand dispatch -----------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="$1"
  shift 2>/dev/null
  case "$cmd" in
    registered) serena_registered "$1"; exit $? ;;
    drift)      serena_lang_drift "$1"; exit $? ;;
    effective)  serena_effective_languages "$1"; exit $? ;;
    manifests)  serena_manifest_languages "$1"; exit $? ;;
    classify)   serena_classify_form "$1"; exit $? ;;
    append)     serena_lang_append "$@"; exit $? ;;
    normalize)  serena_normalize_token "$1"; exit $? ;;
    valid)      serena_valid_token "$1"; exit $? ;;
    *)
      printf 'usage: serena-lang.sh {registered|drift|effective|manifests|classify|append|normalize|valid} ...\n' >&2
      exit 2
      ;;
  esac
fi
