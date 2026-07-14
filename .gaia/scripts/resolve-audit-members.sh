#!/usr/bin/env bash
# resolve-audit-members.sh: Code Audit Team dispatch resolver.
#
# Turns the current branch's diff into the DISPATCHED MEMBER SET, the deduped,
# lexically-sorted set of auditor member names that own at least one changed
# file. The local merge gate (pr-merge-audit-check.sh) and the member-aware
# GAIA-Audit status POST both consume this to require a per-member clearance
# for every dispatched member; a diff touching two members' surfaces cannot
# merge until BOTH clear.
#
# Usage:
#   resolve-audit-members.sh [--base <ref>]
#     --base <ref>  Diff base override. Without it, the base is resolved the
#                   same way pr-merge-audit-check.sh does: the remote default
#                   branch (origin/HEAD, fallback main), then the merge-base of
#                   HEAD with it (fallback: local <default> merge-base).
#     --help | -h   Print this usage and exit.
#
# Output contract:
#   One dispatched member name per line on stdout, deduped and lexically
#   sorted. EMPTY stdout means zero-match: the entire diff is out of audit
#   scope. Exit code is 0 on EVERY path (empty diff, unresolvable base, not in
#   a git repo, unknown flag) so consumers can parse stdout unconditionally.
#
# Dispatch algorithm, per changed file:
#   1. Every SPECIALIZED (non-default) member whose globs match the path is
#      added.
#   2. Else, if the path is in the AUDITABLE-BASE SET (below) and a default
#      member exists, the default member is added.
#   3. Else the file has no owner (out of scope).
#
# Auditable-base set (the default member's implicit domain; mirrors the CI
# has_source gate exactly). A changed file not claimed by a specialized member
# and not in this set is out of scope:
#   - directory prefixes:  app/  test/  .storybook/  .github/workflows/
#   - root files (no slash): package.json, pnpm-lock.yaml, pnpm-workspace.yaml,
#     tsconfig*.json, *.config.{ts,mts,mjs,cjs,js}
#
# Roster-source precedence:
#   1. The `auditors:` block in <repo-root>/.gaia/audit-ci.yml, when present
#      and non-empty.
#   2. Otherwise the BUILT-IN DEFAULT ROSTER hard-coded below. Its maintainer-
#      only entries sit inside `# gaia:maintainer-only` markers so the release
#      scrub strips them from the shipped script; an adopter's built-in
#      fallback is therefore the default (frontend) member only.
#   The resolver iterates the roster GENERICALLY: it emits whatever member
#   names the roster defines and is not hard-coded to any specific member, so
#   an adopter adds a member with a config entry plus an agent file, no script
#   edit.
#
# Glob semantics (matched against repo-relative POSIX paths), mirroring the
# release scrub's globToRegex:
#   **/ -> (.*/)?  (any depth, INCLUDING zero segments, spanning /)
#   **  -> .*
#   *   -> [^/]*   (any run within one path segment, never crossing /)
# So `.gaia/**/*.sh` matches `.gaia/x.sh` and `.gaia/scripts/y.sh`;
# `.github/**/*.sh` matches a top-level `.github/x.sh` as well as
# `.github/workflows/y.sh` (the `**/` collapses to zero segments);
# `.specify/extensions/gaia/lib/*.sh` matches only direct children;
# `app/**` matches anything under app/.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. No `cd` (per .claude/rules/shell-cwd.md); the repo root is
# resolved via `git rev-parse --show-toplevel` and every git call is scoped
# to it with `git -C`.

set -euo pipefail

# --- Parse arguments ----------------------------------------------------------

BASE_OVERRIDE=""

print_usage() {
  cat <<'USAGE'
Usage: resolve-audit-members.sh [--base <ref>]
  Emits the dispatched auditor member set (one name per line, sorted) for the
  current branch's diff. Empty output = entire diff out of scope. Exit 0 always.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        echo "resolve-audit-members: --base requires a <ref> argument" >&2
        exit 0
      fi
      BASE_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "resolve-audit-members: unrecognized argument '$1'" >&2
      print_usage >&2
      exit 0
      ;;
  esac
done

# --- Resolve the repo root + config path -------------------------------------
#
# Not in a git repo -> nothing to diff; emit nothing and exit 0.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || exit 0
config_file="$repo_root/.gaia/audit-ci.yml"

# --- Built-in default roster --------------------------------------------------
#
# Used only when audit-ci.yml has no `auditors:` block. Emitted as the same
# YAML shape the config uses so ONE parser handles both. The maintainer-only
# entries are wrapped in `# gaia:maintainer-only` markers; the release scrub
# strips marker-delimited blocks from shipped `.sh` files, so the shipped
# script's fallback carries only the default (frontend) member.

builtin_roster() {
  cat <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
    scope: adopter
    push_fixes: true
    default: true
  # gaia:maintainer-only:start
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/**/*.sh"
      - ".gaia/**/*.bats"
      - ".claude/hooks/**/*.sh"
      - ".specify/extensions/gaia/lib/*.sh"
      - ".github/**/*.sh"
      - ".github/**/*.bats"
    scope: maintainer-only
    push_fixes: false
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**"
    scope: maintainer-only
    push_fixes: false
  # gaia:maintainer-only:end
YAML
}

# --- Roster parser ------------------------------------------------------------
#
# Reads a YAML `auditors:` list-of-maps on stdin and emits one record per line:
#   DEFAULT <name>            the single default member's name
#   GLOB <name> <regex>       one specialized-member glob, pre-compiled to an
#                             anchored ERE (default-member globs are NOT emitted;
#                             the default owns the auditable-base set instead)
# Member names and the compiled regexes contain no spaces, so downstream
# `read -r kind a b` splits them cleanly.

parse_auditors() {
  awk '
    function unq(s) {
      if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
      if (s ~ /^'\''.*'\''$/) return substr(s, 2, length(s) - 2)
      return s
    }
    # Convert a posix glob (**, *) into an anchored ERE, matched against
    # repo-relative POSIX paths. Mirrors scrub.ts globToRegex: escape ERE
    # specials (not *), then handle **/, **, * via sentinels so single-* is
    # not re-substituted.
    function glob_to_regex(glob,   g) {
      g = glob
      gsub(/\\/, "\\\\", g)
      gsub(/\./, "\\.", g)
      gsub(/\+/, "\\+", g)
      gsub(/\^/, "\\^", g)
      gsub(/\$/, "\\$", g)
      gsub(/\(/, "\\(", g)
      gsub(/\)/, "\\)", g)
      gsub(/\[/, "\\[", g)
      gsub(/\]/, "\\]", g)
      gsub(/\{/, "\\{", g)
      gsub(/\}/, "\\}", g)
      gsub(/\|/, "\\|", g)
      gsub(/\*\*\//, "@@DIRSTAR@@", g)
      gsub(/\*\*/,   "@@STAR@@", g)
      gsub(/\*/,     "[^/]*", g)
      gsub(/@@STAR@@/,   ".*", g)
      gsub(/@@DIRSTAR@@/, "(.*/)?", g)
      return "^" g "$"
    }
    function flush(   i) {
      if (have_member) {
        if (is_default) {
          print "DEFAULT " member
        } else {
          for (i = 1; i <= nglobs; i++) print "GLOB " member " " glob_to_regex(globs[i])
        }
      }
      have_member = 0; member = ""; is_default = 0; nglobs = 0; in_globs = 0
    }
    BEGIN { in_auditors = 0; in_globs = 0; have_member = 0; member = ""; is_default = 0; nglobs = 0 }
    {
      raw = $0
      # Top-level `auditors:` key opens the block.
      if (raw ~ /^auditors[[:space:]]*:/) { in_auditors = 1; next }
      if (!in_auditors) next
      # Any other top-level key (column 0, a letter) closes the block.
      if (raw ~ /^[A-Za-z_]/) { flush(); in_auditors = 0; next }
      # Blank lines and comments (including the maintainer-only markers) are
      # skipped and never end a member or the block.
      if (raw ~ /^[[:space:]]*$/) next
      if (raw ~ /^[[:space:]]*#/) next
      # New member: `- name: X`.
      if (raw ~ /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/) {
        flush()
        have_member = 1
        v = raw
        sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        member = unq(v)
        next
      }
      # `globs:` opens the glob sublist.
      if (raw ~ /^[[:space:]]+globs[[:space:]]*:/) { in_globs = 1; next }
      # `default: <bool>`.
      if (raw ~ /^[[:space:]]+default[[:space:]]*:/) {
        in_globs = 0
        v = raw
        sub(/^[[:space:]]+default[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (tolower(v) == "true") is_default = 1
        next
      }
      # Any other member-level scalar key (scope, push_fixes, ...) ends globs.
      if (raw ~ /^[[:space:]]+[A-Za-z_]+[[:space:]]*:/) { in_globs = 0; next }
      # A `- <value>` list item while inside globs is one glob.
      if (in_globs && raw ~ /^[[:space:]]*-[[:space:]]+/) {
        g = raw
        sub(/^[[:space:]]*-[[:space:]]+/, "", g)
        sub(/[[:space:]]+#.*$/, "", g)
        sub(/^[[:space:]]+/, "", g); sub(/[[:space:]]+$/, "", g)
        g = unq(g)
        if (g != "") { nglobs++; globs[nglobs] = g }
        next
      }
    }
    END { flush() }
  '
}

# Roster records: prefer the config `auditors:` block; fall back to built-in.
records=""
if [ -f "$config_file" ]; then
  records="$(parse_auditors < "$config_file")"
fi
if [ -z "$records" ]; then
  records="$(builtin_roster | parse_auditors)"
fi

# Load records into parallel arrays (bash 3.2: indexed arrays, no assoc).
default_member=""
spec_count=0
spec_member=()
spec_regex=()
# Split each record on whitespace (default IFS): `KIND NAME [REGEX]`. The
# regex is the trailing field and carries no spaces, so it lands in `b` whole.
while read -r kind a b; do
  case "$kind" in
    DEFAULT)
      default_member="$a"
      ;;
    GLOB)
      spec_member[spec_count]="$a"
      spec_regex[spec_count]="$b"
      spec_count=$((spec_count + 1))
      ;;
  esac
done <<EOF
$records
EOF

# --- Auditable-base set (default member's implicit domain) -------------------

in_auditable_base() {
  case "$1" in
    app/*|test/*|.storybook/*|.github/workflows/*) return 0 ;;
    */*) return 1 ;;
    package.json|pnpm-lock.yaml|pnpm-workspace.yaml) return 0 ;;
    tsconfig*.json) return 0 ;;
    *.config.ts|*.config.mts|*.config.mjs|*.config.cjs|*.config.js) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Resolve the diff base + changed files -----------------------------------

resolve_base() {
  if [ -n "$BASE_OVERRIDE" ]; then
    printf '%s' "$BASE_OVERRIDE"
    return 0
  fi
  local default_branch base
  default_branch="$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
  [ -n "$default_branch" ] || default_branch="main"
  base="$(git -C "$repo_root" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
    || git -C "$repo_root" merge-base HEAD "${default_branch}" 2>/dev/null \
    || true)"
  printf '%s' "$base"
}

base="$(resolve_base)"
[ -n "$base" ] || exit 0

changed="$(git -C "$repo_root" diff --name-only "${base}...HEAD" 2>/dev/null || true)"
[ -n "$changed" ] || exit 0

# --- Dispatch ----------------------------------------------------------------

members_out=""
add_member() {
  members_out="${members_out}$1
"
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  matched_specialized=0
  i=0
  while [ "$i" -lt "$spec_count" ]; do
    if [[ "$path" =~ ${spec_regex[$i]} ]]; then
      add_member "${spec_member[$i]}"
      matched_specialized=1
    fi
    i=$((i + 1))
  done
  if [ "$matched_specialized" -eq 0 ] && [ -n "$default_member" ]; then
    if in_auditable_base "$path"; then
      add_member "$default_member"
    fi
  fi
done <<EOF
$changed
EOF

# Deduped, lexically-sorted member names. Empty input -> empty output.
printf '%s' "$members_out" | LC_ALL=C sort -u
