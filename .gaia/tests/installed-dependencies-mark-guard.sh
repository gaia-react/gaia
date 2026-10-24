#!/usr/bin/env bash
# installed-dependencies-mark-guard.sh: derive which bats suites read installed
# dependencies and fail when the installed-dependencies marks disagree.
#
# A dependency bump (a manifest or lockfile change) runs, under change-scoped
# legs, the suites the change selector picks plus every suite carrying the
# installed-dependencies mark, in full. That is only safe while something
# derives the set from the suites and fails when the marks drift, the same
# derive-and-compare move the apt-package check makes for the zsh and YAML
# parser suites. This is that something. The mark is the file tag
# `installed-dependencies`; its pattern is the
# verify_installed_dependencies_mark_pattern variable in
# .gaia/tests/helpers/verify-harness-bats-lib.sh, read from there, never
# restated here.
#
# Scope: the suites some bats leg runs, which is the union of
# `bats-shards.sh files <id>` over `bats-shards.sh shards`. The commitlint,
# sandbox and concurrency suites are outside it: those legs install their own
# workspace and run whole on their own arming. A root with no sharder of its own
# (a fixture) scopes to every discovered suite.
#
# A suite is a user when its own text, or the text of a helper it sources from
# a `helpers/` directory (one level of `load`, `source` or `.` with a literal or
# $BATS_TEST_DIRNAME-relative path), outside comments and heredoc bodies, holds
# a command word that is:
#   - pnpm, npx, playwright or vitest;
#   - node running a script that resolves workspace packages: a script under
#     .gaia/scripts or .gaia/cli that createRequires or imports a bare
#     (non-relative, non-built-in) specifier, named literally or through a
#     variable the file assigns from it; or node with -e, -p or --eval text
#     holding a bare require, import or from specifier;
#   - require_node_typescript.
# A command word is read after assignments, `run` and its flags, `!`, `if`,
# `then`, `do`, `while`, `exec`, `env`, `nohup`, `time`, `timeout <n>` and
# `sudo`; after `|`, `;`, `&&`, `||`, `&`, a subshell or a command
# substitution; and inside `bash -c`, `sh -c` and `eval` text. A name inside a
# quoted string, a comment or a heredoc body is never a command word.
#
# Not a user: a command word that resolves to a stub the file creates. A stub is
# a function with that name, a file with that name written, copied, linked or
# made executable, or a call to a helper named for stubs, fakes, shims or mocks
# that passes the name. The rule is about the command word, so it names no suite.
#
# Provisioning: a marked suite that skips, rather than fails, when its
# dependency is absent on a CI runner is a green that asserts nothing. A skip
# counts when its statement names node_modules, typescript, chromium,
# playwright, vitest, tsx or a pnpm/npx presence probe. It is provisioned when
# it sits in a function that consults GITHUB_ACTIONS and returns non-zero
# before the skip (as require_node_typescript does), or when the suite carries
# the backstop line
#   # installed-dependencies backstop: .github/workflows/<file>.yml
# naming an existing workflow whose text names the suite's basename. A backstop
# line that names a missing workflow, or one that does not name the suite, is a
# finding whether or not the suite skips.
#
# Residual limits, each failing toward a missed user rather than a false one:
# a command word built from a variable, a helper reached through a variable or
# a second hop, and a node script path assembled at run time are not seen.
#
# Maintainer-only: .gaia/tests is release-excluded wholesale.
#
# Usage:
#   bash .gaia/tests/installed-dependencies-mark-guard.sh [--root <repo>]
#   ... --list-derived      the derived set, one repo-relative path per line
#   ... --list-backstopped  the marked suites carrying a valid backstop line
# Exit: 0 the derived set equals the marked set and every marked suite is
# provisioned; 1 a difference, each finding on its own line naming the suite;
# 2 a usage error, an empty discovery set, or a scan that could not run.

set -u

usage() {
  echo "usage: installed-dependencies-mark-guard.sh [--root <repo>] [--list-derived | --list-backstopped]" >&2
}

root=""
list_mode=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      root="$2"
      shift 2
      ;;
    --list-derived | --list-backstopped)
      list_mode="$1"
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

guard_directory="${BASH_SOURCE[0]%/*}"
if [ "$guard_directory" = "${BASH_SOURCE[0]}" ]; then guard_directory="."; fi

# shellcheck source=.gaia/scripts/awk-interp-lib.sh
[ -f "$guard_directory/../scripts/awk-interp-lib.sh" ] && . "$guard_directory/../scripts/awk-interp-lib.sh" 2>/dev/null
if [ -z "${GAIA_AWK:-}" ] || [ "${GAIA_AWK_STATUS:-0}" != 0 ]; then
  echo "installed-dependencies-mark-guard: no sanctioned awk interpreter resolved (mawk or the system awk)" >&2
  exit 2
fi

# shellcheck source=.gaia/tests/helpers/verify-harness-bats-lib.sh
. "$guard_directory/helpers/verify-harness-bats-lib.sh" 2>/dev/null
if [ -z "${verify_installed_dependencies_mark_pattern:-}" ]; then
  echo "installed-dependencies-mark-guard: the mark pattern did not load from $guard_directory/helpers/verify-harness-bats-lib.sh" >&2
  exit 2
fi

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "installed-dependencies-mark-guard: not inside a git repository; pass --root <repo>" >&2
    exit 2
  }
fi
[ -d "$root" ] || {
  echo "installed-dependencies-mark-guard: not a directory: $root" >&2
  exit 2
}

work_directory="$(mktemp -d)" || {
  echo "installed-dependencies-mark-guard: cannot create a temporary directory" >&2
  exit 2
}
trap 'rm -rf "$work_directory"' EXIT

# Node built-ins: a require or import of one of these needs no installed package.
node_builtins="assert async_hooks buffer child_process cluster console constants crypto dgram diagnostics_channel dns domain events fs http http2 https inspector module net os path perf_hooks process punycode querystring readline repl stream string_decoder sys test timers tls trace_events tty url util v8 vm wasi worker_threads zlib"

# ---- discovery ------------------------------------------------------------

discover_tracked() {
  local pathspec="$1" listing
  listing="$(git -C "$root" -c core.quotepath=false ls-files -z "$pathspec" 2>/dev/null | tr '\0' '\n')"
  if [ -z "$listing" ]; then
    listing="$(find "$root" -type f -name "$pathspec" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' 2>/dev/null | sed "s|^$root/||")"
  fi
  printf '%s\n' "$listing" | LC_ALL=C sort | sed '/^$/d'
}

discover_tracked '*.bats' >"$work_directory/all-suites"
if [ ! -s "$work_directory/all-suites" ]; then
  echo "installed-dependencies-mark-guard: no bats suite found under $root; a guard over nothing is not clean" >&2
  exit 2
fi

sharder="$root/.gaia/tests/bats-shards.sh"
if [ -f "$sharder" ]; then
  : >"$work_directory/scope-raw"
  shard_ids="$(bash "$sharder" shards)" || {
    echo "installed-dependencies-mark-guard: the sharder could not list its shards" >&2
    exit 2
  }
  for shard_id in $shard_ids; do
    shard_files="$(bash "$sharder" files "$shard_id")" || {
      echo "installed-dependencies-mark-guard: the sharder could not list shard $shard_id" >&2
      exit 2
    }
    printf '%s\n' "$shard_files" >>"$work_directory/scope-raw"
  done
  sed -e "s|^$root/||" -e '/^$/d' "$work_directory/scope-raw" | LC_ALL=C sort -u >"$work_directory/scope"
  if [ ! -s "$work_directory/scope" ]; then
    echo "installed-dependencies-mark-guard: the sharder resolved no suite; a guard over nothing is not clean" >&2
    exit 2
  fi
else
  cp "$work_directory/all-suites" "$work_directory/scope"
fi

# Scripts under .gaia/scripts and .gaia/cli that resolve workspace packages,
# by basename: node running one of them needs the installed workspace.
: >"$work_directory/script-names"
for pattern in '*.mjs' '*.js' '*.cjs'; do
  discover_tracked "$pattern" | grep -E '^\.gaia/(scripts|cli)/' | grep -v '/node_modules/' >>"$work_directory/script-paths" || true
done
if [ -f "$work_directory/script-paths" ]; then
  while IFS= read -r script_path; do
    [ -f "$root/$script_path" ] || continue
    resolves=""
    if grep -q 'createRequire' "$root/$script_path"; then
      resolves=yes
    else
      specs="$(grep -oE "(from[[:space:]]+|import[[:space:]]*\(?[[:space:]]*|require\([[:space:]]*)['\"][^'\"]+['\"]" "$root/$script_path" | sed -E "s/^.*['\"]([^'\"]+)['\"]$/\1/")"
      for spec in $specs; do
        case "$spec" in
          . | .* | /* | node:*) continue ;;
        esac
        first="${spec%%/*}"
        case " $node_builtins " in
          *" $first "*) continue ;;
        esac
        resolves=yes
      done
    fi
    [ -n "$resolves" ] && printf '%s\n' "${script_path##*/}" >>"$work_directory/script-names"
  done <"$work_directory/script-paths"
fi
script_names="$(LC_ALL=C sort -u "$work_directory/script-names" | tr '\n' ' ')"

# ---- per-file scan --------------------------------------------------------

# The scanner reads one file and prints tab-separated records:
#   U <word>      a command word that reads installed dependencies
#   S <word>      a stub the file creates for that command word
#   H <operand>   a load, source or . operand
#   K <gated|ungated>  a skip that names a dependency
#   R <ordinal>   a heredoc opener that never closed: the opener is text
#                 inside a quoted fixture, so the caller rescans ignoring it
#   E <message>   the file could not be read to its end
# shellcheck disable=SC2016
readonly SCANNER_AWK='
function out(kind, detail) { printf "%s\t%s\n", kind, detail }
function desync(message) { if (scan_depth == 0) out("E", message) }


function bare_spec(spec,   first) {
  if (spec == "" || spec ~ /^[.\/$]/ || spec ~ /^node:/) return 0
  if (spec !~ /^@?[a-z0-9][a-z0-9._-]*(\/.*)?$/) return 0
  first = spec; sub(/\/.*$/, "", first)
  if (index(" " builtins " ", " " first " ") > 0) return 0
  return 1
}

# True when text holds a require, import or from with a bare package specifier.
function text_has_bare_spec(text,   rest, spec, patterns, p) {
  patterns[1] = "require\\(\\\\?[\"\047]"
  patterns[2] = "from[ \t]+\\\\?[\"\047]"
  patterns[3] = "import\\(\\\\?[\"\047]"
  patterns[4] = "import[ \t]+\\\\?[\"\047]"
  for (p = 1; p <= 4; p++) {
    rest = text
    while (match(rest, patterns[p])) {
      rest = substr(rest, RSTART + RLENGTH)
      spec = rest
      sub(/[\\"\047].*$/, "", spec)
      if (bare_spec(spec)) return 1
    }
  }
  return 0
}

# True when the end of prefix sits inside a quoted span of this one line.
function quoted_before(prefix,   i, n, c, state) {
  n = length(prefix); state = ""
  for (i = 1; i <= n; i++) {
    c = substr(prefix, i, 1)
    if (state == "\047") { if (c == "\047") state = ""; continue }
    if (c == "\\") { i++; continue }
    if (state == "\"") { if (c == "\"") state = ""; continue }
    if (c == "\047" || c == "\"") state = c
  }
  return state != ""
}

function strip_quotes(t) { gsub(/["\047]/, "", t); return t }

# The text a shell would hand the command for one raw token: quotes removed,
# single-quoted spans literal, backslashes resolved.
function unquote_whole(t,   i, n, c, nx, out_text, in_double, j) {
  n = length(t); out_text = ""; in_double = 0
  for (i = 1; i <= n; i++) {
    c = substr(t, i, 1)
    if (!in_double && c == "\047") {
      j = index(substr(t, i + 1), "\047")
      if (j == 0) { out_text = out_text substr(t, i + 1); break }
      out_text = out_text substr(t, i + 1, j - 1); i += j
      continue
    }
    if (c == "\"") { in_double = !in_double; continue }
    if (c == "\\") {
      nx = substr(t, i + 1, 1)
      if (!in_double || nx == "\"" || nx == "$" || nx == "\\" || nx == "`") { out_text = out_text nx; i++; continue }
    }
    out_text = out_text c
  }
  return out_text
}

function is_assignment(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ }

function classify(L,   i, n, t, word, rest, k, name, args, sname, ref, j, variable) {
  n = ntok[L]
  i = 1
  while (i <= n) {
    t = tokv[L, i]
    if (is_assignment(t)) { i++; continue }
    word = strip_quotes(t)
    if (word == "run") {
      i++
      while (i <= n && tokv[L, i] ~ /^-/) i++
      continue
    }
    if (word == "!" || word == "if" || word == "then" || word == "else" || word == "elif" || word == "do" || word == "while" || word == "until" || word == "time" || word == "exec" || word == "nohup" || word == "sudo") { i++; continue }
    if (word == "command" || word == "builtin") {
      if (i < n && tokv[L, i + 1] ~ /^-/) return
      i++; continue
    }
    if (word == "timeout") {
      i++
      while (i <= n && tokv[L, i] ~ /^-/) i++
      if (i <= n && tokv[L, i] ~ /^[0-9.]+[smhd]?$/) i++
      continue
    }
    if (word == "env") {
      i++
      while (i <= n && (tokv[L, i] ~ /^-/ || is_assignment(tokv[L, i]))) i++
      continue
    }
    break
  }
  if (i > n) return
  word = strip_quotes(tokv[L, i])
  if (index(word, "/") > 0) sub(/^.*\//, "", word)

  if (word == "pnpm" || word == "npx" || word == "playwright" || word == "vitest") { out("U", word); return }
  if (word == "require_node_typescript") { out("U", "require_node_typescript"); return }
  if (word == "load" || word == "source" || word == ".") {
    if (i < n) out("H", tokv[L, i + 1])
    return
  }
  if (word == "bash" || word == "sh" || word == "zsh" || word == "dash") {
    for (j = i + 1; j < n; j++) {
      if (tokv[L, j] ~ /^-[A-Za-z]*c$/) { nested_scan(unquote_whole(tokv[L, j + 1])); return }
    }
    return
  }
  if (word == "eval") {
    rest = ""
    for (j = i + 1; j <= n; j++) rest = rest " " unquote_whole(tokv[L, j])
    nested_scan(rest)
    return
  }
  if (word == "node") {
    args = ""
    for (j = i + 1; j <= n; j++) args = args " " tokv[L, j]
    for (k = 1; k <= script_count; k++) {
      if (index(args, script_list[k]) > 0) { out("U", "node"); return }
    }
    for (j = i + 1; j <= n; j++) {
      ref = tokv[L, j]
      while (match(ref, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
        variable = substr(ref, RSTART, RLENGTH)
        sub(/^\$\{?/, "", variable)
        if (variable in script_variable) { out("U", "node"); return }
        ref = substr(ref, RSTART + RLENGTH)
      }
    }
    for (j = i + 1; j <= n; j++) {
      if (tokv[L, j] == "-e" || tokv[L, j] == "-p" || tokv[L, j] == "--eval" || tokv[L, j] == "--print" || tokv[L, j] ~ /^--input-type/) {
        if (text_has_bare_spec(args)) { out("U", "node"); return }
        break
      }
    }
    return
  }
}

function nested_scan(text) {
  if (scan_depth >= 3) return
  scan_depth++
  scan(text, scan_depth * 100)
  scan_depth--
}

function reset_level(L) { ntok[L] = 0; cur[L] = ""; hascur[L] = 0; parens[L] = 0 }
function addc(L, s) { cur[L] = cur[L] s; hascur[L] = 1 }
function endtok(L) {
  if (hascur[L]) { ntok[L]++; tokv[L, ntok[L]] = cur[L]; cur[L] = ""; hascur[L] = 0 }
}
function endstmt(L) { if (ntok[L] > 0) classify(L); ntok[L] = 0 }

# The closing index of a ${...} span starting at the brace, honoring nesting.
function brace_end(text, start,   i, depth, c, n) {
  n = length(text); depth = 0
  for (i = start; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "{") depth++
    else if (c == "}") { depth--; if (depth == 0) return i }
  }
  return n
}

# The closing index of a parenthesized literal starting at the open paren.
function paren_end(text, start,   i, depth, c, n, q) {
  n = length(text); depth = 0; q = ""
  for (i = start; i <= n; i++) {
    c = substr(text, i, 1)
    if (q != "") { if (c == q) q = ""; continue }
    if (c == "\\") { i++; continue }
    if (c == "\047") { q = c; continue }
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) return i }
  }
  return n
}

function ansi_end(text, start,   i, n, c) {
  n = length(text)
  for (i = start; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "\\") { i++; continue }
    if (c == "\047") return i
  }
  return n
}

function scan(text, base,   n, i, c, nx, L, j, inner, previous) {
  n = length(text); L = base
  reset_level(L); mode[L] = "C"; kind[L] = "T"
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    nx = substr(text, i + 1, 1)
    if (mode[L] == "D") {
      if (c == "\\") { addc(L, c nx); i++; continue }
      if (c == "\"") { addc(L, c); mode[L] = "C"; continue }
      if (c == "$" && nx == "(") { frame_open(L, "S", i + 2); L++; i++; continue }
      if (c == "$" && nx == "{") { j = brace_end(text, i + 1); addc(L, substr(text, i, j - i + 1)); i = j; continue }
      if (c == "`") { frame_open(L, "B", i + 1); L++; continue }
      addc(L, c)
      continue
    }
    if (c == "\\") {
      if (nx == "\n" || nx == "") { endtok(L); i++ } else { addc(L, c nx); i++ }
      continue
    }
    if (c == "\047") {
      j = index(substr(text, i + 1), "\047")
      if (j == 0) { desync("unterminated single quote"); return }
      addc(L, substr(text, i, j + 1)); i += j
      continue
    }
    if (c == "\"") { addc(L, c); mode[L] = "D"; continue }
    if (c == "$") {
      if (nx == "\047") { j = ansi_end(text, i + 2); addc(L, substr(text, i, j - i + 1)); i = j; continue }
      if (nx == "(") { frame_open(L, "S", i + 2); L++; i++; continue }
      if (nx == "{") { j = brace_end(text, i + 1); addc(L, substr(text, i, j - i + 1)); i = j; continue }
      addc(L, c)
      continue
    }
    if (c == "`") {
      if (L > base && kind[L] == "B") { L = frame_close(L, text, i - 1); continue }
      frame_open(L, "B", i + 1); L++
      continue
    }
    if (c == "#" && !hascur[L]) {
      j = index(substr(text, i), "\n")
      if (j == 0) i = n; else i += j - 2
      continue
    }
    if (c == " " || c == "\t") { endtok(L); continue }
    if (c == "\n" || c == ";" || c == "&" || c == "|") { endtok(L); endstmt(L); continue }
    if (c == "(") {
      previous = substr(cur[L], length(cur[L]), 1)
      if (hascur[L] && previous == "=") { j = paren_end(text, i); addc(L, substr(text, i, j - i + 1)); i = j; continue }
      if (nx == ")" && ntok[L] == 0 && hascur[L]) { cur[L] = ""; hascur[L] = 0; i++; continue }
      endtok(L); endstmt(L); parens[L]++
      continue
    }
    if (c == ")") {
      endtok(L)
      if (parens[L] > 0) { endstmt(L); parens[L]--; continue }
      if (L > base && kind[L] == "S") { L = frame_close(L, text, i - 1); continue }
      endstmt(L)
      continue
    }
    if (c == "{" || c == "}") {
      if (!hascur[L] && (nx == " " || nx == "\t" || nx == "\n" || nx == "")) { endstmt(L); continue }
      addc(L, c)
      continue
    }
    addc(L, c)
  }
  endtok(L); endstmt(L)
  if (L != base || mode[L] != "C") desync("unbalanced quote or substitution")
}

function frame_open(L, frame_kind, start) {
  frame_start[L + 1] = start
  reset_level(L + 1); mode[L + 1] = "C"; kind[L + 1] = frame_kind
}

# Close the frame at level L, whose text ends at index last_index, and append
# its text to the enclosing token. Returns the enclosing level.
function frame_close(L, text, last_index,   inner) {
  endtok(L); endstmt(L)
  inner = substr(text, frame_start[L], last_index - frame_start[L] + 1)
  L--
  addc(L, "$(" inner ")")
  return L
}

BEGIN {
  script_count = split(script_names, script_list, " ")
  ignored_count = split(ignored_openers, ignored_list, " ")
  for (g = 1; g <= ignored_count; g++) ignored[ignored_list[g]] = 1
  opener_count = 0
  heredoc_word = ""
  nk = 0; in_function = 0; saw_ci = 0; saw_failure = 0
  split("pnpm npx playwright vitest node", stub_words, " ")
}

{
  line = $0
  sub(/\r$/, "", line)
  if (heredoc_word != "") {
    check = line
    if (heredoc_dash) sub(/^\t+/, "", check)
    if (check == heredoc_word) heredoc_word = ""
    next
  }
  # Comment lines stay in the stream: a multi-line quoted string can hold one
  # that carries its closing quote, so the scanner decides what is a comment.
  kept[++nk] = line
  if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next

  if (match(line, /(^|[^<])<<-?[ \t]*[\\"\047]*[A-Za-z_][A-Za-z0-9_]*/) && !quoted_before(substr(line, 1, RSTART)) && !((++opener_count) "" in ignored)) {
    opener_last = opener_count
    opener = substr(line, RSTART, RLENGTH)
    sub(/^[^<]*<</, "", opener)
    heredoc_dash = (substr(opener, 1, 1) == "-")
    gsub(/^-|[ \t\\"\047]/, "", opener)
    heredoc_word = opener
  }

  if (line ~ /^[A-Za-z_@][^ ]*[ \t]*\(\)/ || line ~ /^function[ \t]/ || line ~ /^@test[ \t]/) {
    in_function = 1; saw_ci = 0; saw_failure = 0
  }
  if (in_function) {
    if (line ~ /GITHUB_ACTIONS/) saw_ci = 1
    if (saw_ci && line ~ /(return|exit)[ \t]+[1-9]/) saw_failure = 1
  }
  if (line ~ /(^[ \t]*|(\|\||&&|;|\{|\(|then|else|do)[ \t]*)skip([ \t"\047]|$)/ &&
      (line ~ /node_modules|typescript|chromium|playwright|vitest|[ \t"]tsx[ \t"]|command -v[ \t]+(pnpm|npx|playwright|vitest|tsx)/)) {
    out("K", (in_function && saw_ci && saw_failure) ? "gated" : "ungated")
  }
  if (line ~ /^\}/) in_function = 0

  for (s = 1; s <= 5; s++) {
    w = stub_words[s]
    if (line ~ ("^[ \t]*(function[ \t]+)?" w "[ \t]*\\(\\)") || line ~ ("^[ \t]*function[ \t]+" w "([ \t]|\\{|$)")) out("S", w)
    else if (line ~ (">[>|]?[ \t]*[\"\047]?[^ \t\"\047|;&<>]*/" w "([\"\047 \t;)]|$)")) out("S", w)
    else if (line ~ ("(^|[ \t])(tee|chmod|ln|cp|touch|mv|install)[ \t][^;|&]*/" w "([\"\047 \t;)]|$)")) out("S", w)
    else if (line ~ ("(^|[ \t])[A-Za-z_]*(stub|fake|shim|mock)[A-Za-z_]*[ \t]+[\"\047]?" w "[\"\047]?([ \t]|$)")) out("S", w)
  }
}

END {
  if (heredoc_word != "") { out("R", opener_last); exit 0 }

  # Variables assigned from a workspace-resolving script, or from one of those.
  for (m = 1; m <= nk; m++) {
    if (match(kept[m], /^[ \t]*((export|readonly|local|declare)[ \t]+(-[A-Za-z]+[ \t]+)?)?[A-Za-z_][A-Za-z0-9_]*=/)) {
      assigned = substr(kept[m], RSTART, RLENGTH - 1)
      sub(/^.*[ \t]/, "", assigned)
      assignment_text[assigned] = assignment_text[assigned] " " kept[m]
    }
  }
  for (pass = 1; pass <= 4; pass++) {
    for (name in assignment_text) {
      if (name in script_variable) continue
      for (k = 1; k <= script_count; k++) {
        if (index(assignment_text[name], script_list[k]) > 0) { script_variable[name] = 1; break }
      }
      if (name in script_variable) continue
      for (other in script_variable) {
        if (assignment_text[name] ~ ("\\$\\{?" other "([^A-Za-z0-9_]|$)")) { script_variable[name] = 1; break }
      }
    }
  }

  body = ""
  for (m = 1; m <= nk; m++) body = body kept[m] "\n"
  scan_depth = 0
  scan(body, 0)
}
'

scan_unit() {
  local unit="$1" cache_file
  cache_file="$work_directory/scan-$(printf '%s' "$unit" | tr '/ ' '__')"
  if [ ! -f "$cache_file" ]; then
    ignored_openers=""
    rescans=0
    while :; do
      "$GAIA_AWK" -v script_names="$script_names" -v builtins="$node_builtins" \
        -v ignored_openers="$ignored_openers" \
        "$SCANNER_AWK" "$root/$unit" >"$cache_file" || {
        echo "installed-dependencies-mark-guard: the scan of $unit failed; this guard cannot certify it" >&2
        exit 2
      }
      unclosed="$(sed -n 's/^R\t//p' "$cache_file" | head -1)"
      [ -n "$unclosed" ] || break
      ignored_openers="$ignored_openers $unclosed"
      rescans=$((rescans + 1))
      if [ "$rescans" -gt 300 ]; then
        echo "installed-dependencies-mark-guard: $unit: heredoc openers never close; this guard cannot certify it" >&2
        exit 2
      fi
    done
  fi
  printf '%s\n' "$cache_file"
}

# resolve_helper <suite> <operand>: print the repo-relative helper path an
# operand names, or nothing. Only a file under a helpers directory counts.
resolve_helper() {
  local suite="$1" operand="$2" suite_directory candidate collapsed
  suite_directory="${suite%/*}"
  operand="${operand//\"/}"
  operand="${operand//\'/}"
  operand="${operand//\$\{BATS_TEST_DIRNAME\}/$suite_directory}"
  operand="${operand//\$BATS_TEST_DIRNAME/$suite_directory}"
  case "$operand" in
    "$suite_directory"/*) ;;
    \$\{*) operand="${operand#*\}}"; operand="${operand#/}" ;;
    \$[A-Za-z_]*) operand="${operand#\$}"; operand="${operand#*/}" ;;
  esac
  case "$operand" in
    *\$* | "") return 0 ;;
  esac
  for candidate in "$operand" "$operand.bash" "$operand.sh" "$suite_directory/$operand" "$suite_directory/$operand.bash" "$suite_directory/$operand.sh"; do
    while :; do
      collapsed="$(printf '%s\n' "$candidate" | sed -E -e 's|/\./|/|g' -e 's|[^/.][^/]*/\.\./||')"
      [ "$collapsed" != "$candidate" ] || break
      candidate="$collapsed"
    done
    case "$candidate" in
      */helpers/*) ;;
      *) continue ;;
    esac
    if [ -f "$root/$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

: >"$work_directory/derived"
: >"$work_directory/ungated-skip"
: >"$work_directory/derived-words"
while IFS= read -r suite; do
  [ -f "$root/$suite" ] || continue
  units="$suite"
  suite_scan="$(scan_unit "$suite")" || exit 2
  while IFS="$(printf '\t')" read -r record_kind record_detail; do
    [ "$record_kind" = E ] && {
      echo "installed-dependencies-mark-guard: $suite: $record_detail; this guard cannot certify it" >&2
      exit 2
    }
    if [ "$record_kind" = H ]; then
      helper="$(resolve_helper "$suite" "$record_detail")"
      if [ -n "$helper" ]; then
        case "
$units
" in
          *"
$helper
"*) ;;
          *) units="$units
$helper" ;;
        esac
      fi
    fi
  done <"$suite_scan"

  stub_words_seen=""
  use_words=""
  ungated=""
  while IFS= read -r unit; do
    unit_scan="$(scan_unit "$unit")" || exit 2
    while IFS="$(printf '\t')" read -r record_kind record_detail; do
      case "$record_kind" in
        E)
          echo "installed-dependencies-mark-guard: $unit: $record_detail; this guard cannot certify it" >&2
          exit 2
          ;;
        S) stub_words_seen="$stub_words_seen $record_detail " ;;
        U) use_words="$use_words $record_detail" ;;
        K) [ "$record_detail" = ungated ] && ungated=yes ;;
      esac
    done <"$unit_scan"
  done <<EOF
$units
EOF

  reasons=""
  for word in $use_words; do
    case "$stub_words_seen" in
      *" $word "*) continue ;;
    esac
    case " $reasons " in
      *" $word "*) ;;
      *) reasons="$reasons $word" ;;
    esac
  done
  if [ -n "$reasons" ]; then
    printf '%s\n' "$suite" >>"$work_directory/derived"
    printf '%s\t%s\n' "$suite" "${reasons# }" >>"$work_directory/derived-words"
    [ -n "$ungated" ] && printf '%s\n' "$suite" >>"$work_directory/ungated-skip"
  fi
done <"$work_directory/scope"

LC_ALL=C sort -u "$work_directory/derived" -o "$work_directory/derived"

# ---- marks and backstops --------------------------------------------------

: >"$work_directory/marked"
: >"$work_directory/findings"
while IFS= read -r suite; do
  mark_line="$(grep -nE "$verify_installed_dependencies_mark_pattern" "$root/$suite" | head -1 | cut -d: -f1)"
  [ -n "$mark_line" ] || continue
  first_test="$(grep -nE '^@test[[:space:]]' "$root/$suite" | head -1 | cut -d: -f1)"
  if [ -n "$first_test" ] && [ "$mark_line" -gt "$first_test" ]; then
    printf '%s: the installed-dependencies mark at line %s sits after the first test, so bats never applies it\n' "$suite" "$mark_line" >>"$work_directory/findings"
    continue
  fi
  printf '%s\n' "$suite" >>"$work_directory/marked"
done <"$work_directory/all-suites"

# valid_backstop <suite>: exit 0 with the workflow path printed when the suite
# carries a backstop line naming an existing workflow that names the suite.
backstop_target() {
  sed -n 's|^# installed-dependencies backstop: \(\.github/workflows/[A-Za-z0-9._-]*\.yml\)[[:space:]]*$|\1|p' "$root/$1" | head -1
}

: >"$work_directory/backstopped"
while IFS= read -r suite; do
  grep -qxF "$suite" "$work_directory/derived" || continue
  target="$(backstop_target "$suite")"
  if ! grep -qE '^# installed-dependencies backstop:' "$root/$suite"; then continue; fi
  if [ -z "$target" ]; then
    printf '%s: the installed-dependencies backstop line does not name a .github/workflows/<file>.yml workflow\n' "$suite" >>"$work_directory/findings"
  elif [ ! -f "$root/$target" ]; then
    printf '%s: the installed-dependencies backstop names %s, which does not exist\n' "$suite" "$target" >>"$work_directory/findings"
  elif ! grep -qF -- "${suite##*/}" "$root/$target"; then
    printf '%s: the installed-dependencies backstop names %s, which does not name %s\n' "$suite" "$target" "${suite##*/}" >>"$work_directory/findings"
  else
    printf '%s\n' "$suite" >>"$work_directory/backstopped"
  fi
done <"$work_directory/marked"
LC_ALL=C sort -u "$work_directory/backstopped" -o "$work_directory/backstopped"

case "$list_mode" in
  --list-derived)
    cat "$work_directory/derived"
    exit 0
    ;;
  --list-backstopped)
    cat "$work_directory/backstopped"
    exit 0
    ;;
esac

# ---- compare --------------------------------------------------------------

while IFS= read -r suite; do
  grep -qxF "$suite" "$work_directory/marked" && continue
  # shellcheck disable=SC2016
  words="$("$GAIA_AWK" -F '\t' -v s="$suite" '$1 == s { print $2 }' "$work_directory/derived-words")"
  printf '%s: reads installed dependencies (%s) but carries no installed-dependencies mark; add a file tag line "# bats file_tags=installed-dependencies" before the first test\n' "$suite" "$words" >>"$work_directory/findings"
done <"$work_directory/derived"

while IFS= read -r suite; do
  if ! grep -qxF "$suite" "$work_directory/derived"; then
    printf '%s: stale installed-dependencies mark: the suite reads no installed dependency or no bats leg runs it; remove the mark\n' "$suite" >>"$work_directory/findings"
    continue
  fi
  if grep -qxF "$suite" "$work_directory/ungated-skip" && ! grep -qxF "$suite" "$work_directory/backstopped"; then
    printf '%s: marked suite skips, rather than fails, when its dependency is absent on CI and is provisioned nowhere; fail under GITHUB_ACTIONS or add "# installed-dependencies backstop: .github/workflows/<file>.yml" naming a workflow that runs it by name\n' "$suite" >>"$work_directory/findings"
  fi
done <"$work_directory/marked"

if [ -s "$work_directory/findings" ]; then
  LC_ALL=C sort -u "$work_directory/findings"
  echo "installed-dependencies-mark-guard: the marks and the derivation disagree (see the lines above)"
  exit 1
fi

echo "installed-dependencies-mark-guard: the marked set equals the derived set and every marked suite is provisioned"
exit 0
