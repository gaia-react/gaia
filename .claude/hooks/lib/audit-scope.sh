#!/usr/bin/env bash
# audit-scope.sh: the one ownership classifier for the Code Audit Team.
# Sourced, never executed; does no work at source time. Parsing happens only
# when audit_scope_init is called, and it parses the roster ONCE per run,
# never once per path: this is a sourced library with batch predicates that
# consume a path list, never a process spawned per path.
#
# Three different questions live here, and they are NOT the same question:
#
#   audit_out_of_scope_allowlisted the merge gate's out-of-scope allowlist,
#                                  consulted only on its legacy branch
#   audit_self_mod_classify        an ORDERED THREE-WAY classification
#                                  (out-of-scope / the audit workflow itself /
#                                  in-scope), never a boolean
#   audit_owner_for_path           roster ownership: which member (if any)
#                                  owns a path, in two precedence tiers:
#                                  every claimant's globs first, first-match-
#                                  wins over roster order, then the default
#                                  member's own declared globs; otherwise
#                                  ownerless
#
# Conflating any two of these is a merge-gate bypass. In particular, the
# out-of-scope allowlist is NOT an audit-skip predicate: a path can be both
# allowlisted here (reached only when the roster dispatches nobody) and
# roster-owned (dispatched, and gated on that owner's clearance) at the same
# time. Keep them separate.
#
# Glob semantics (matched against repo-relative POSIX paths), mirroring the
# release scrub's globToRegex:
#   **/ -> (.*/)?  (any depth, INCLUDING zero segments, spanning /)
#   **  -> .*
#   *   -> [^/]*   (any run within one path segment, never crossing /)
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. Never `cd`.

# --- The merge gate's out-of-scope allowlist ---------------------------------
#
# The ONE literal. After this module exists, this case-arm literal occurs in
# exactly one tracked file. Consulted only on the merge gate's legacy branch,
# reached only when the roster dispatches nobody for the diff: a path can be
# allowlisted here and roster-owned at the same time, and when it is, the
# roster-owned path always wins (a non-empty dispatched set means the legacy
# branch is never reached).
#
# Exit 0 iff the path is out-of-scope-allowlisted: wiki/, .claude/,
# .specify/, .gaia/, docs/, or a root-level (no slash) *.md file.

audit_out_of_scope_allowlisted() {
  case "$1" in
    wiki/*|.claude/*|.specify/*|.gaia/*|docs/*) return 0 ;;
    */*) return 1 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

# --- The self-mod-only GAIA-update bypass's classification -------------------
#
# An ORDERED THREE-WAY classification, never a boolean: folding it into a
# generalized out-of-scope predicate breaks the update bypass this exists
# for. Prints exactly one of: out-of-scope | audit-workflow | in-scope.
#
# The audit-workflow arm is a single literal path, checked BEFORE the
# general "any other nested path is in-scope" arm, exactly mirroring the
# precedence a caller needs to detect "the only in-scope change is the audit
# workflow file itself".

audit_self_mod_classify() {
  case "$1" in
    wiki/*|.claude/*|.specify/*|.gaia/*|docs/*) printf 'out-of-scope\n' ;;
    ".github/workflows/code-review-audit.yml") printf 'audit-workflow\n' ;;
    */*) printf 'in-scope\n' ;;
    *.md) printf 'out-of-scope\n' ;;
    *) printf 'in-scope\n' ;;
  esac
  return 0
}

# --- Roster parsing (moved, not copied) --------------------------------------
#
# Used only when <root>/.gaia/audit-ci.yml has no `auditors:` block. Emitted
# as the same YAML shape the config uses, so ONE parser handles both. Its
# members and their globs mirror the committed .gaia/audit-ci.yml roster and
# must stay in step with it: a glob present there but missing here leaves that
# path ownerless in the degraded fallback, so the merge gate dispatches nobody
# for a change to it. The maintainer-only entries are wrapped in
# `# gaia:maintainer-only` markers;
# the release scrub strips marker-delimited blocks from shipped `.sh` files,
# so a shipped script's fallback carries only the default (frontend) member
# and the workflows member, both adopter-scope.
# These markers MUST survive verbatim: dropping, reflowing, or moving them
# makes an adopter's merge gate demand clearances from members whose agent
# definitions the adopter does not have, a permanent local merge deadlock.

_audit_scope_builtin_roster() {
  cat <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
      - ".github/workflows/**"
      - "package.json"
      - "pnpm-lock.yaml"
      - "pnpm-workspace.yaml"
      - "tsconfig*.json"
      - "*.config.ts"
      - "*.config.mts"
      - "*.config.mjs"
      - "*.config.cjs"
      - "*.config.js"
    scope: adopter
    push_fixes: true
    default: true
  - name: code-audit-github-workflows
    globs:
      - ".github/workflows/*.yml"
      - ".github/workflows/*.yaml"
      - ".github/actions/**/*.yml"
      - ".github/actions/**/*.yaml"
    scope: adopter
    push_fixes: false
  # gaia:maintainer-only:start
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/**/*.sh"
      - ".gaia/**/*.bats"
      - ".claude/hooks/**/*.sh"
      - ".specify/extensions/gaia/lib/*.sh"
      - ".github/**/*.sh"
      - ".github/**/*.bats"
      - ".gaia/audit-ci.yml"
      - ".gaia/VERSION"
      - ".claude/agents/code-audit-*.md"
      - ".claude/rules/**"
    scope: maintainer-only
    push_fixes: false
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**/*.ts"
      - ".gaia/cli/src/**/*.tmpl"
      - ".gaia/cli/src/**/*.snap"
      - ".gaia/cli/src/**/.gitkeep"
    scope: maintainer-only
    push_fixes: false
  # gaia:maintainer-only:end
YAML
}

# Reads a YAML `auditors:` list-of-maps on stdin and emits one record per line:
#   DEFAULT <name>              the single default member's name
#   GLOB <name> <regex>         one CLAIMANT member's glob, pre-compiled to an
#                               anchored ERE
#   DEFAULTGLOB <name> <regex>  one DEFAULT member's glob, pre-compiled to an
#                               anchored ERE; a distinct precedence tier, never
#                               folded into GLOB (the default is the roster's
#                               first entry and ownership resolution is
#                               first-match-wins, so compiling its globs as
#                               claimant globs would make it beat every
#                               claimant and invert the precedence the whole
#                               design depends on)
# Member names and the compiled regexes contain no spaces, so downstream
# `read -r kind a b` splits them cleanly.

_audit_scope_parse_auditors() {
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
          for (i = 1; i <= nglobs; i++) print "DEFAULTGLOB " member " " glob_to_regex(globs[i])
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

# --- audit_scope_init <root> --------------------------------------------------
#
# Parses the roster ONCE per run: <root>/.gaia/audit-ci.yml when it defines
# an `auditors:` block, else the built-in default roster above. Populates
# the module's internal state consumed by audit_owner_for_path /
# audit_owners_for_paths. Safe to call more than once (each call resets and
# re-parses); callers should still call it only once per run.

audit_scope_init() {
  local root="$1" config_file records

  config_file="${root}/.gaia/audit-ci.yml"

  _AUDIT_SCOPE_DEFAULT_MEMBER=""
  _AUDIT_SCOPE_SPEC_COUNT=0
  _AUDIT_SCOPE_SPEC_MEMBER=()
  _AUDIT_SCOPE_SPEC_REGEX=()
  _AUDIT_SCOPE_DEFAULT_GLOB_COUNT=0
  _AUDIT_SCOPE_DEFAULT_REGEX=()

  records=""
  if [ -f "$config_file" ]; then
    records="$(_audit_scope_parse_auditors < "$config_file")"
  fi
  if [ -z "$records" ]; then
    records="$(_audit_scope_builtin_roster | _audit_scope_parse_auditors)"
  fi

  while read -r kind a b; do
    case "$kind" in
      DEFAULT)
        _AUDIT_SCOPE_DEFAULT_MEMBER="$a"
        ;;
      GLOB)
        _AUDIT_SCOPE_SPEC_MEMBER[_AUDIT_SCOPE_SPEC_COUNT]="$a"
        _AUDIT_SCOPE_SPEC_REGEX[_AUDIT_SCOPE_SPEC_COUNT]="$b"
        _AUDIT_SCOPE_SPEC_COUNT=$((_AUDIT_SCOPE_SPEC_COUNT + 1))
        ;;
      DEFAULTGLOB)
        _AUDIT_SCOPE_DEFAULT_REGEX[_AUDIT_SCOPE_DEFAULT_GLOB_COUNT]="$b"
        _AUDIT_SCOPE_DEFAULT_GLOB_COUNT=$((_AUDIT_SCOPE_DEFAULT_GLOB_COUNT + 1))
        ;;
    esac
  done <<EOF
$records
EOF
}

# --- Internal: classify one path with no subshell and no stdout -------------
#
# Sets _AUDIT_SCOPE_OWNER_RESULT (empty when ownerless). Shared by the two
# public entry points below so neither one forks a process per path.

_audit_scope_owner_of() {
  local path="$1" i=0

  _AUDIT_SCOPE_OWNER_RESULT=""

  while [ "$i" -lt "$_AUDIT_SCOPE_SPEC_COUNT" ]; do
    if [[ "$path" =~ ${_AUDIT_SCOPE_SPEC_REGEX[$i]} ]]; then
      _AUDIT_SCOPE_OWNER_RESULT="${_AUDIT_SCOPE_SPEC_MEMBER[$i]}"
      return 0
    fi
    i=$((i + 1))
  done

  if [ -n "$_AUDIT_SCOPE_DEFAULT_MEMBER" ]; then
    i=0
    while [ "$i" -lt "$_AUDIT_SCOPE_DEFAULT_GLOB_COUNT" ]; do
      if [[ "$path" =~ ${_AUDIT_SCOPE_DEFAULT_REGEX[$i]} ]]; then
        _AUDIT_SCOPE_OWNER_RESULT="$_AUDIT_SCOPE_DEFAULT_MEMBER"
        return 0
      fi
      i=$((i + 1))
    done
  fi

  return 0
}

# --- audit_owner_for_path <path> ---------------------------------------------
#
# Ownership is a classification with precedence, not a per-member glob test:
# claimant globs are matched first, first-match-wins over roster order; the
# default member's own declared globs form a second tier evaluated only after
# every claimant has failed to match; otherwise the path is ownerless. Prints
# the owning member name on stdout, or nothing when ownerless. Requires
# audit_scope_init to have run first; never spawns a process.

audit_owner_for_path() {
  _audit_scope_owner_of "$1"
  [ -n "$_AUDIT_SCOPE_OWNER_RESULT" ] && printf '%s\n' "$_AUDIT_SCOPE_OWNER_RESULT"
  return 0
}

# --- audit_owners_for_paths ---------------------------------------------------
#
# BATCH: reads paths on stdin, prints "<path>\t<owner|->" per path on stdout.
# One in-process pass over the roster parsed once by audit_scope_init; never
# a process spawned per path (a 500-path input costs zero forks here, no
# command substitution in the loop).

audit_owners_for_paths() {
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    _audit_scope_owner_of "$path"
    printf '%s\t%s\n' "$path" "${_AUDIT_SCOPE_OWNER_RESULT:--}"
  done

  return 0
}
