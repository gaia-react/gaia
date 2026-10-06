# shellcheck shell=bash
#
# GAIA branch-naming convention (single-sourced).
#
# The one definition of how GAIA names the branches it creates, in both
# directions: minting a name (gaia_branch_name) and reading one back
# (gaia_branch_classify, gaia_branch_members, gaia_branch_spec_number). Every
# reader that recovers meaning from a branch name reads it through here, and
# every bash flow that cuts a branch or a worktree mints its name here; the two
# kinds minted outside bash are pinned to this table by the suite instead, as
# the note below the table states. So a convention change is one edit to this
# file and its suite.
#
# THE CONVENTION. Every GAIA branch is `<kind>/<rest>`, one kind per row, first
# matching row wins when reading. The prefix says which workflow produced the
# branch, except for a plan branch, whose prefix is the commit type
# (`.gaia/conventional-commits.json`) of the change the plan implements.
#
#   kind        canonical shape                         mode         unit
#   debt        debt/<a>-<b>[-<c>...]-batch             drain        <a>-<b>...
#   debt        debt/<n>[-<slug>]                       drain        <n>
#   plan        <type>/spec-<nnn>[-<slug>]              plan         SPEC-<nnn>
#   plan        <type>/plan-<nnn>[-<slug>]              plan         plan-<nnn>
#   audit       audit/<YYYY-MM-DD-HHMM>                 maintenance  <rest>
#   harden      harden/<YYYY-MM-DD-HHMM>                maintenance  <rest>
#   fitness     fitness/<YYYY-MM-DD-HHMM>               maintenance  <rest>
#   residue     residue/<YYYY-MM-DD-HHMM>               maintenance  <rest>
#   deps        deps/<YYYY-MM-DD-HHMM>                  maintenance  <rest>
#   update      update/v<version>-<YYYY-MM-DD-HHMM>     maintenance  <rest>
#   release     release/v<version>                      maintenance  <rest>
#   wiki sync   wiki/sync-<YYYY-MM-DD>-<short-sha>      maintenance  <rest>
#   forensics   forensics/<issue>-<class-slug>          maintenance  <rest>
#   chore       chore/<task>-<YYYY-MM-DD-HHMM>          maintenance  <rest>  (legacy)
#   wiki-sync   wiki-sync/<YYYY-MM-DD>-<short-sha>      maintenance  <rest>  (legacy)
#   plan        plan/spec-<nnn>[-<slug>]                plan         SPEC-<nnn>  (legacy)
#   plan        plan/plan-<nnn>[-<slug>]                plan         plan-<nnn>  (legacy)
#   (any other branch, including main, a `chore/` or `wiki/` branch outside
#   the rows above, and hand-named `<type>/[<issue>-]<slug>` branches)
#                                                       adhoc        unknown
#
# `mode` is a closed vocabulary: drain, plan, maintenance, adhoc. A derived
# unit that comes out empty is `unknown`. `debt` and `plan` names carry the
# unit a reader needs (the issue numbers a drain closes, the SPEC a plan
# implements); the maintenance kinds carry a timestamp so two runs never
# collide. A plan branch is recognized by its unit (`plan-<nnn>` or
# `spec-<nnn>`) under any lowercase prefix that is not a workflow kind above,
# so the type is matched by shape here and enforced by gaia_branch_validate
# and by gaia_branch_name, which read the JSON. A hand-named
# `<type>/planning-notes` has no digits after `plan-`, so it stays adhoc.
#
# Legacy spellings (`chore/<task>-<ts>`, `wiki-sync/`, `plan/`, and the
# `worktree-*` spelling below) are read so existing branches, PR heads, and ledgers keep
# classifying; none is minted. The `chore/` row requires the timestamp suffix,
# so a hand-named `chore/fix-typo` stays adhoc.
#
# Two kinds are minted outside bash and are therefore not arms of
# gaia_branch_name: `wiki/sync-`, by the GAIA CLI's wiki chain, and
# `forensics/`, by `forensics-triage.yml`. GAIA's own test suite pins each
# prefix to this table, so neither can drift without a red suite.
#
# THE WORKTREE SPELLING. A worktree created with `EnterWorktree({name: <n>})`
# sits on a branch the harness names `worktree-<n>`, with every `/` in <n>
# written as `+`: `debt/42-fix` becomes `worktree-debt+42-fix`. GAIA renames
# that branch to its canonical name right after creation
# (`.claude/skills/gaia/references/isolation.md`), so a branch it created
# carries the canonical name. Every reader below still normalizes the spelling
# first (gaia_branch_normalize), so a branch that predates the rename reads
# exactly as the branch it was requested as. Minted names are capped at 64
# bytes and restricted to [A-Za-z0-9./-] (slugs and tasks are lowercased; a
# release or update version keeps its own case) so they are always valid
# EnterWorktree names as well as valid git refs.
#
# Functions (all defined at source time; sourcing has no side effects and runs
# no external command, so it succeeds under `set -u` with PATH empty, and every
# function is safe under zsh as well as bash 3.2+):
#
# gaia_branch_normalize <branch>
#   Prints <branch> with one leading `worktree-` stripped and every `+`
#   replaced by `/`, both unconditional, in that order. Returns 0.
#
# gaia_branch_classify <branch>
#   Normalizes <branch>, matches it against the table, prints "<mode> <unit>".
#   Returns 0 on every input.
#
# gaia_branch_members <branch>
#   Prints the issue numbers a `debt` branch names, one per line: every member
#   of a batch, or the leading issue of a single. Prints nothing for any other
#   branch. Returns 0.
#
# gaia_branch_spec_number <branch>
#   Prints the SPEC number a `<type>/spec-<nnn>` or legacy `plan/spec-<nnn>`
#   branch names, leading zeros stripped (`refactor/spec-005-x` prints 5).
#   Prints nothing otherwise. Returns 0.
#
# gaia_branch_plan_number <branch>
#   Prints the plan number a `<type>/plan-<nnn>` or legacy `plan/plan-<nnn>`
#   branch names (the worktree spelling included), leading zeros stripped
#   (`feat/plan-031-x` prints 31). Prints nothing otherwise. Returns 0.
#
# gaia_branch_plan_type <branch>
#   Prints the commit type a type-prefixed plan branch carries (`feat` for
#   `feat/plan-024-x`). Prints nothing for a legacy `plan/` branch and for every
#   non-plan branch. Returns 0.
#
# gaia_branch_list [directory]
#   Prints every local branch and every remote-tracking branch of the
#   repository at [dir] (default `.`), the remote-tracking ones with their
#   `<remote>/` prefix removed, one per line. A symbolic `<remote>/HEAD` is
#   skipped. Prints nothing outside a repository. Returns 0.
#
# gaia_branch_name <kind> <args...>
#   Prints the canonical name for a new branch, newline terminated, and
#   returns 0; on a bad argument prints a diagnostic to stderr, prints nothing
#   on stdout, and returns 2. Kinds:
#     debt <issue> [--slug <text>]        debt/<issue>[-<slug>]
#     debt <issue> <issue>... [--batch]   debt/<ascending members>-batch
#     plan <spec-NNN|plan-NNN> --type <type> [--slug <text>]
#                                         <type>/<id>[-<slug>]
#     audit | harden | fitness | residue | deps
#                                         <kind>/<UTC YYYY-MM-DD-HHMM>
#     update <version>                    update/v<version>-<UTC YYYY-MM-DD-HHMM>
#     release <version>                   release/v<version>
#   A leading `v` on <version> is stripped. The retired `chore` kind exits 2.
#   `--type` is required for `plan` and is lowercase letters; when `jq` and
#   `.gaia/conventional-commits.json` are readable it must also be one of the
#   JSON's `types`, and without them the shape check alone applies.
#   <slug> is reduced to lowercase kebab-case; a slug is truncated
#   to keep the whole name within 64 bytes. Two or more distinct issues always
#   mint a batch name, which carries no slug; `--batch` is accepted and
#   changes nothing.
#
# gaia_branch_validate <branch>
#   Decides whether <branch> is a name GAIA accepts for a new pull request.
#   Returns 0 when valid; 1 when invalid, after one stderr line naming the
#   reason and the fix; 2 when it cannot decide (no `jq` or `git` on PATH, or
#   `.gaia/conventional-commits.json` unreadable, found relative to this file,
#   never the working directory). Rules: `dependabot/*` is always valid; a
#   `worktree-*` name is invalid and the message names the canonical name and
#   `git branch -m`, or, when the stripped name has no `<type>/` part, a
#   `<type>/<stripped name>` form to rename to; otherwise at most 64 bytes, lowercase [a-z0-9./-] (a
#   `release/` or `update/` version may keep its case), exactly one `/`, a
#   remainder that is non-empty with no leading or trailing `-`, a valid ref
#   name, and a prefix that is a workflow kind in the table or a `types`
#   entry of the JSON. Legacy `wiki-sync/` is invalid; legacy
#   `chore/<task>-<ts>` passes as a hand-named `chore/<slug>`. A `plan/` branch
#   is valid only as `plan/plan-<nnn>[-<slug>]` or `plan/spec-<nnn>[-<slug>]`.
#
# Usage (sourced):
#   . .gaia/scripts/branch-name-lib.sh
#   branch="$(gaia_branch_name debt 2159 --slug "reconcile worktree claim")"
#
# Usage (executable):
#   bash .gaia/scripts/branch-name-lib.sh name debt 2159 --slug "reconcile worktree claim"
#   bash .gaia/scripts/branch-name-lib.sh name deps
#   bash .gaia/scripts/branch-name-lib.sh name update v2.0.0
#   bash .gaia/scripts/branch-name-lib.sh classify worktree-debt+42-fix
#   bash .gaia/scripts/branch-name-lib.sh members debt/41-42-batch
#   bash .gaia/scripts/branch-name-lib.sh name plan spec-005 --type feat --slug cards
#   bash .gaia/scripts/branch-name-lib.sh spec-number feat/spec-005-cards
#   bash .gaia/scripts/branch-name-lib.sh plan-number feat/plan-024-cards
#   bash .gaia/scripts/branch-name-lib.sh plan-type feat/plan-024-cards
#   bash .gaia/scripts/branch-name-lib.sh list [directory]
#   bash .gaia/scripts/branch-name-lib.sh validate fix/2450-statusline-nudge

GAIA_BRANCH_NAME_MAXIMUM_LENGTH=64

# _gaia_branch_is_digits <text>: 0 when <text> is one or more ASCII digits.
_gaia_branch_is_digits() {
  local text="${1-}"
  [ -n "$text" ] || return 1
  case "$text" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# _gaia_branch_is_members <text>: 0 when <text> matches ^[0-9]+(-[0-9]+)*$.
# Four glob rejections rather than a regex, so the file stays plain bash 3.2.
_gaia_branch_is_members() {
  local text="${1-}"
  [ -n "$text" ] || return 1
  case "$text" in
    -* | *- | *--* | *[!0-9-]*) return 1 ;;
  esac
  return 0
}

# The readers below are built on setters that assign a global rather than
# print, so a caller reading thousands of branch names in one shell (the usage
# ledger's read side) pays no subshell per name. The printing functions stay
# the public interface.

# _gaia_branch_set_leading_digits <text>: sets _gaia_branch_digits to the
# leading run of ASCII digits.
# `${text:$i:1}`, not bash's bare `${text:i:1}`: zsh reads a bare identifier
# after the colon as a history modifier and aborts the walk.
_gaia_branch_set_leading_digits() {
  local LC_ALL=C
  local text="${1-}" leading_digits="" i length character
  length="${#text}"
  for ((i = 0; i < length; i++)); do
    character="${text:$i:1}"
    case "$character" in
      [0-9]) leading_digits="${leading_digits}${character}" ;;
      *) break ;;
    esac
  done
  _gaia_branch_digits="$leading_digits"
}

# _gaia_branch_strip_zeros <digits>: <digits> without leading zeros, `0` for
# all zeros. Pure parameter expansion, so no arithmetic reads it as octal.
_gaia_branch_strip_zeros() {
  local text="${1-}"
  while [ "${#text}" -gt 1 ] && [ "${text:0:1}" = "0" ]; do
    text="${text:1}"
  done
  printf '%s' "$text"
}

# _gaia_branch_set_normalized <branch>: sets _gaia_branch_normalized_name.
_gaia_branch_set_normalized() {
  local text="${1-}"
  text="${text#worktree-}"
  # `\+`: an escaped literal means the same thing in bash and zsh.
  text="${text//\+//}"
  _gaia_branch_normalized_name="$text"
}

gaia_branch_normalize() {
  _gaia_branch_set_normalized "${1-}"
  printf '%s' "$_gaia_branch_normalized_name"
}

# _gaia_branch_set_class <branch>: sets _gaia_branch_mode and _gaia_branch_unit.
_gaia_branch_set_class() {
  local LC_ALL=C
  local normalized_name mode="adhoc" unit="" rest="" id="" lead="" prefix=""
  _gaia_branch_set_normalized "${1-}"
  normalized_name="$_gaia_branch_normalized_name"
  # Trailing newlines dropped, as a command substitution of the normalized
  # name would drop them, so a name git would refuse still classifies the same.
  while :; do
    case "$normalized_name" in *$'\n') normalized_name="${normalized_name%$'\n'}" ;; *) break ;; esac
  done

  case "$normalized_name" in
    debt/*)
      mode="drain"
      rest="${normalized_name#debt/}"
      # The batch row is tested first: a batch's unit is every member, and
      # falling through would record only the first.
      case "$rest" in
        *-batch)
          if _gaia_branch_is_members "${rest%-batch}"; then
            unit="${rest%-batch}"
          fi
          ;;
      esac
      if [ -z "$unit" ]; then
        _gaia_branch_set_leading_digits "$rest"
        unit="$_gaia_branch_digits"
      fi
      ;;
    plan/*)
      mode="plan"
      rest="${normalized_name#plan/}"
      case "$rest" in
        spec-* | plan-*)
          id="${rest%%-*}"
          lead="${rest#*-}"
          lead="${lead%%-*}"
          if _gaia_branch_is_digits "$lead"; then
            if [ "$id" = "spec" ]; then
              unit="SPEC-${lead}"
            else
              unit="plan-${lead}"
            fi
          fi
          ;;
      esac
      ;;
    audit/* | harden/* | fitness/* | residue/* | deps/* | update/* | release/* | forensics/* \
      | wiki/sync-* | wiki-sync/* \
      | chore/*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9])
      mode="maintenance"
      unit="${normalized_name#*/}"
      ;;
    [a-z]*/spec-* | [a-z]*/plan-*)
      prefix="${normalized_name%%/*}"
      case "$prefix" in
        *[!a-z]*) ;;
        *)
          rest="${normalized_name#*/}"
          case "$rest" in
            spec-* | plan-*)
              id="${rest%%-*}"
              lead="${rest#*-}"
              lead="${lead%%-*}"
              if _gaia_branch_is_digits "$lead"; then
                mode="plan"
                if [ "$id" = "spec" ]; then
                  unit="SPEC-${lead}"
                else
                  unit="plan-${lead}"
                fi
              fi
              ;;
          esac
          ;;
      esac
      ;;
  esac

  [ -n "$unit" ] || unit="unknown"
  _gaia_branch_mode="$mode" _gaia_branch_unit="$unit"
}

gaia_branch_classify() {
  _gaia_branch_set_class "${1-}"
  printf '%s %s\n' "$_gaia_branch_mode" "$_gaia_branch_unit"
  return 0
}

gaia_branch_members() {
  local mode unit
  _gaia_branch_set_class "${1-}"
  mode="$_gaia_branch_mode"
  unit="$_gaia_branch_unit"
  [ "$mode" = "drain" ] || return 0
  [ "$unit" != "unknown" ] || return 0
  # Walk the dash-joined list by parameter expansion rather than IFS
  # splitting, which zsh does not perform on an unquoted expansion.
  while [ -n "$unit" ]; do
    printf '%s\n' "${unit%%-*}"
    case "$unit" in
      *-*) unit="${unit#*-}" ;;
      *) unit="" ;;
    esac
  done
  return 0
}

gaia_branch_spec_number() {
  local classified unit
  classified="$(gaia_branch_classify "${1-}")"
  unit="${classified#* }"
  case "$classified" in
    "plan SPEC-"*) printf '%s\n' "$(_gaia_branch_strip_zeros "${unit#SPEC-}")" ;;
  esac
  return 0
}

gaia_branch_plan_number() {
  local classified unit
  classified="$(gaia_branch_classify "${1-}")"
  unit="${classified#* }"
  case "$classified" in
    "plan plan-"*) printf '%s\n' "$(_gaia_branch_strip_zeros "${unit#plan-}")" ;;
  esac
  return 0
}

gaia_branch_plan_type() {
  _gaia_branch_set_class "${1-}"
  [ "$_gaia_branch_mode" = "plan" ] || return 0
  [ "$_gaia_branch_unit" != "unknown" ] || return 0
  [ "${_gaia_branch_normalized_name%%/*}" != "plan" ] || return 0
  printf '%s\n' "${_gaia_branch_normalized_name%%/*}"
  return 0
}

gaia_branch_list() {
  local directory="${1:-.}"
  git -C "$directory" for-each-ref --format='%(refname:lstrip=2)' refs/heads 2>/dev/null || true
  # A remote-tracking ref is refs/remotes/<remote>/<branch>; lstrip=3 drops
  # the remote. `<remote>/HEAD` is a symbolic pointer, not a branch.
  git -C "$directory" for-each-ref --format='%(refname:lstrip=3)' refs/remotes 2>/dev/null \
    | grep -vx 'HEAD' || true
  return 0
}

# _gaia_branch_kebab <text>: lowercase, every run of other bytes one `-`,
# no leading or trailing `-`.
_gaia_branch_kebab() {
  printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# _gaia_branch_emit <prefix> <slug>: <prefix>[-<slug>], the slug cut so the
# whole name fits GAIA_BRANCH_NAME_MAXIMUM_LENGTH, then the result validated as a ref.
_gaia_branch_emit() {
  local prefix="$1" slug="$2" name room
  if [ -n "$slug" ]; then
    room=$((GAIA_BRANCH_NAME_MAXIMUM_LENGTH - ${#prefix} - 1))
    if [ "$room" -gt 0 ]; then
      slug="${slug:0:$room}"
      slug="$(printf '%s' "$slug" | LC_ALL=C sed -E 's/-+$//')"
    else
      slug=""
    fi
  fi
  name="$prefix"
  [ -z "$slug" ] || name="${prefix}-${slug}"
  if [ "${#name}" -gt "$GAIA_BRANCH_NAME_MAXIMUM_LENGTH" ]; then
    printf 'gaia_branch_name: %s is longer than %s bytes\n' "$name" "$GAIA_BRANCH_NAME_MAXIMUM_LENGTH" >&2
    return 2
  fi
  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    printf 'gaia_branch_name: %s is not a valid branch name\n' "$name" >&2
    return 2
  fi
  printf '%s\n' "$name"
}

# _gaia_branch_load_types: sets _gaia_branch_types to the space-joined `types`
# of the JSON beside this library and returns 0. Returns 1 with the reason in
# _gaia_branch_types_error when jq or the file is unusable, so a caller decides
# whether that is fatal (validate) or falls back to a shape check (name).
_gaia_branch_load_types() {
  local library_path="${BASH_SOURCE[0]:-}" library_directory="" types_file
  _gaia_branch_types=""
  command -v jq >/dev/null 2>&1 || {
    _gaia_branch_types_error="jq is not on PATH; install jq"
    return 1
  }
  case "$library_path" in
    */*) library_directory="${library_path%/*}" ;;
    "") library_directory="" ;;
    *) library_directory="." ;;
  esac
  types_file="${library_directory}/../conventional-commits.json"
  if [ -z "$library_directory" ] || [ ! -r "$types_file" ]; then
    _gaia_branch_types_error=".gaia/conventional-commits.json is not readable beside this library"
    return 1
  fi
  _gaia_branch_types="$(jq -er 'if (.types | type == "array" and length > 0 and all(type == "string")) then .types | join(" ") else empty end' "$types_file" 2>/dev/null)" || _gaia_branch_types=""
  if [ -z "$_gaia_branch_types" ]; then
    _gaia_branch_types_error=".gaia/conventional-commits.json has no usable types list"
    return 1
  fi
  return 0
}

gaia_branch_name() {
  local kind="${1-}" slug="" argument="" members="" id="" version="" count=0 type=""
  [ "$#" -gt 0 ] && shift

  case "$kind" in
    debt)
      while [ "$#" -gt 0 ]; do
        argument="$1"
        shift
        case "$argument" in
          --slug)
            [ "$#" -gt 0 ] || { echo "gaia_branch_name: --slug needs a value" >&2; return 2; }
            slug="$(_gaia_branch_kebab "$1")"
            shift
            ;;
          --batch) ;;
          *)
            argument="${argument#\#}"
            _gaia_branch_is_digits "$argument" || {
              printf 'gaia_branch_name: %s is not an issue number\n' "$argument" >&2
              return 2
            }
            members="${members}$(_gaia_branch_strip_zeros "$argument")
"
            count=$((count + 1))
            ;;
        esac
      done
      [ "$count" -gt 0 ] || { echo "gaia_branch_name: debt needs an issue number" >&2; return 2; }
      # Ascending and de-duplicated, so the same unit always mints the same
      # name; a unit that collapses to one issue is a single, not a batch.
      members="$(printf '%s' "$members" | LC_ALL=C sort -un | LC_ALL=C tr '\n' '-')"
      members="${members%-}"
      case "$members" in
        *-*) _gaia_branch_emit "debt/${members}-batch" "" ;;
        *) _gaia_branch_emit "debt/${members}" "$slug" ;;
      esac
      ;;
    plan)
      id="$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      [ "$#" -gt 0 ] && shift
      case "$id" in
        spec-* | plan-*) ;;
        *) id="" ;;
      esac
      _gaia_branch_is_digits "${id#*-}" || {
        echo "gaia_branch_name: plan needs a spec-NNN or plan-NNN id" >&2
        return 2
      }
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --slug)
            shift
            [ "$#" -gt 0 ] || { echo "gaia_branch_name: --slug needs a value" >&2; return 2; }
            slug="$(_gaia_branch_kebab "$1")"
            shift
            ;;
          --type)
            shift
            [ "$#" -gt 0 ] || { echo "gaia_branch_name: --type needs a value" >&2; return 2; }
            type="$1"
            shift
            ;;
          *)
            printf 'gaia_branch_name: unexpected argument %s\n' "$1" >&2
            return 2
            ;;
        esac
      done
      [ -n "$type" ] || {
        echo "gaia_branch_name: plan needs --type <type>, the commit type of the change the plan implements, for example --type feat" >&2
        return 2
      }
      case "$type" in
        *[!a-z]*)
          printf 'gaia_branch_name: --type %s must be lowercase letters only\n' "$type" >&2
          return 2
          ;;
      esac
      # Minting must not depend on jq: when the type list is unreadable the
      # shape check above is all that applies, and validate is the backstop.
      if _gaia_branch_load_types; then
        case " ${_gaia_branch_types} " in
          *" ${type} "*) ;;
          *)
            printf 'gaia_branch_name: --type %s is not a commit type; use one of: %s\n' "$type" "$_gaia_branch_types" >&2
            return 2
            ;;
        esac
      fi
      _gaia_branch_emit "${type}/${id}" "$slug"
      ;;
    audit | harden | fitness | residue | deps)
      if [ "$#" -gt 0 ]; then
        printf 'gaia_branch_name: unexpected argument %s\n' "$1" >&2
        return 2
      fi
      _gaia_branch_emit "${kind}/$(date -u +%Y-%m-%d-%H%M)" ""
      ;;
    release | update)
      version="${1-}"
      version="${version#v}"
      case "$version" in
        "" | *[!0-9A-Za-z.-]*)
          printf 'gaia_branch_name: %s needs a version such as 1.4.0\n' "$kind" >&2
          return 2
          ;;
      esac
      if [ "$kind" = "update" ]; then
        _gaia_branch_emit "update/v${version}-$(date -u +%Y-%m-%d-%H%M)" ""
      else
        _gaia_branch_emit "release/v${version}" ""
      fi
      ;;
    *)
      printf 'gaia_branch_name: unknown kind %s (debt, plan, audit, harden, fitness, residue, deps, update, release)\n' "${kind:-<none>}" >&2
      return 2
      ;;
  esac
}

# gaia_branch_validate <branch>: see the header. The checks that need no data
# run first; the commit-type set is read from the JSON beside this library
# only when they pass, and an unreadable JSON returns 2, never 0.
gaia_branch_validate() {
  local LC_ALL=C
  local branch="${1-}" normalized prefix remainder types="" plan_id plan_lead

  case "$branch" in
    dependabot/*) return 0 ;;
    worktree-*)
      _gaia_branch_set_normalized "$branch"
      normalized="$_gaia_branch_normalized_name"
      # A worktree requested without a `<type>/` part strips to a name the
      # rule below refuses, so suggesting it verbatim would send the reader
      # through a second rename, and renaming a pull request's head closes it.
      case "$normalized" in
        */*)
          printf 'gaia_branch_validate: %s is a worktree spelling; rename it with: git branch -m %s %s, then push %s\n' \
            "$branch" "$branch" "$normalized" "$normalized" >&2
          ;;
        *)
          printf 'gaia_branch_validate: %s is a worktree spelling with no <type>/ part; rename it with: git branch -m %s <type>/%s, for example fix/%s, then push it\n' \
            "$branch" "$branch" "$normalized" "$normalized" >&2
          ;;
      esac
      return 1
      ;;
  esac

  if [ "${#branch}" -gt "$GAIA_BRANCH_NAME_MAXIMUM_LENGTH" ]; then
    printf 'gaia_branch_validate: %s is longer than %s bytes; shorten the slug\n' "$branch" "$GAIA_BRANCH_NAME_MAXIMUM_LENGTH" >&2
    return 1
  fi
  case "$branch" in
    */*/*)
      printf 'gaia_branch_validate: %s has more than one slash; use <type>/<slug> with a single slash\n' "$branch" >&2
      return 1
      ;;
    */*) ;;
    *)
      printf 'gaia_branch_validate: %s has no <prefix>/ part; name it <type>/<slug>, for example fix/<slug>\n' "$branch" >&2
      return 1
      ;;
  esac
  prefix="${branch%%/*}"
  remainder="${branch#*/}"
  case "$prefix" in
    "" | *[!a-z0-9.-]*)
      printf 'gaia_branch_validate: %s has an empty prefix or one outside [a-z0-9.-]; use <type>/<slug> in lowercase\n' "$branch" >&2
      return 1
      ;;
  esac
  case "$prefix" in
    release | update)
      case "$remainder" in
        *[!A-Za-z0-9./-]*)
          printf 'gaia_branch_validate: %s has a character outside [A-Za-z0-9./-]; use letters, digits, dot, slash and dash\n' "$branch" >&2
          return 1
          ;;
      esac
      ;;
    *)
      case "$remainder" in
        *[!a-z0-9./-]*)
          printf 'gaia_branch_validate: %s has a character outside [a-z0-9./-]; use lowercase letters, digits, dot, slash and dash\n' "$branch" >&2
          return 1
          ;;
      esac
      ;;
  esac
  case "$remainder" in
    "" | -* | *-)
      printf 'gaia_branch_validate: %s needs a slug that is not empty and does not start or end with a dash\n' "$branch" >&2
      return 1
      ;;
  esac

  if [ "$prefix" = "plan" ]; then
    plan_id="${remainder%%-*}"
    plan_lead="${remainder#*-}"
    plan_lead="${plan_lead%%-*}"
    case "$plan_id" in
      spec | plan) _gaia_branch_is_digits "$plan_lead" ;;
      *) false ;;
    esac || {
      printf 'gaia_branch_validate: %s uses the legacy plan/ prefix, which only plan-<nnn> and spec-<nnn> names may keep; name it <type>/plan-<nnn>-<slug>, for example feat/plan-024-slug\n' "$branch" >&2
      return 1
    }
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "gaia_branch_validate: cannot decide: jq is not on PATH; install jq" >&2
    return 2
  }
  command -v git >/dev/null 2>&1 || {
    echo "gaia_branch_validate: cannot decide: git is not on PATH" >&2
    return 2
  }
  _gaia_branch_load_types || {
    printf 'gaia_branch_validate: cannot decide: %s\n' "$_gaia_branch_types_error" >&2
    return 2
  }
  types="$_gaia_branch_types"

  case " debt plan audit harden fitness residue deps update release forensics ${types} " in
    *" ${prefix} "*) ;;
    *)
      printf 'gaia_branch_validate: %s has the prefix %s, which is neither a GAIA workflow nor a commit type; use one of: %s\n' "$branch" "$prefix" "$types" >&2
      return 1
      ;;
  esac
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    printf 'gaia_branch_validate: %s is not a valid git branch name; remove a double dot, a .lock ending, or the other ref-format violation\n' "$branch" >&2
    return 1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  subcommand="${1-}"
  [ "$#" -gt 0 ] && shift
  case "$subcommand" in
    name) gaia_branch_name "$@"; exit $? ;;
    classify) gaia_branch_classify "${1-}" ;;
    members) gaia_branch_members "${1-}" ;;
    spec-number) gaia_branch_spec_number "${1-}" ;;
    plan-number) gaia_branch_plan_number "${1-}" ;;
    plan-type) gaia_branch_plan_type "${1-}" ;;
    normalize) gaia_branch_normalize "${1-}"; printf '\n' ;;
    list) gaia_branch_list "${1-}" ;;
    validate) gaia_branch_validate "${1-}"; exit $? ;;
    *)
      echo "usage: branch-name-lib.sh name|classify|members|spec-number|plan-number|plan-type|normalize|list|validate <args>" >&2
      exit 2
      ;;
  esac
  exit 0
fi
