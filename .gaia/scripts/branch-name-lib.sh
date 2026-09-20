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
# matching row wins when reading:
#
#   kind       canonical shape                      mode         unit
#   debt       debt/<a>-<b>[-<c>...]-batch          drain        <a>-<b>...
#   debt       debt/<n>[-<slug>]                    drain        <n>
#   plan       plan/spec-<nnn>[-<slug>]             plan         SPEC-<nnn>
#   plan       plan/plan-<nnn>[-<slug>]             plan         plan-<nnn>
#   chore      chore/<task>-<YYYY-MM-DD-HHMM>       maintenance  <rest>
#   release    release/v<version>                   maintenance  <rest>
#   wiki-sync  wiki-sync/<YYYY-MM-DD>-<short-sha>   maintenance  <rest>
#   gaia-ci    gaia-ci/<tool>/<rest>                maintenance  <rest>
#   (any other branch, including main and hand-named fix/ feat/ docs/)
#                                                   adhoc        unknown
#
# `mode` is a closed vocabulary: drain, plan, maintenance, adhoc. A derived
# unit that comes out empty is `unknown`. `debt` and `plan` names carry the
# unit a reader needs (the issue numbers a drain closes, the SPEC a plan
# implements); the maintenance kinds carry a timestamp so two runs never
# collide.
#
# Two kinds are minted outside bash and are therefore not arms of
# gaia_branch_name: `wiki-sync` by the GAIA CLI's wiki chain, and `gaia-ci` by
# the CI workflows the CLI renders. GAIA's own test suite pins both prefixes to
# this table, so neither can drift without a red suite.
#
# THE WORKTREE SPELLING. A worktree created with `EnterWorktree({name: <n>})`
# sits on a branch the harness names `worktree-<n>`, with every `/` in <n>
# written as `+`: `debt/42-fix` becomes `worktree-debt+42-fix`. Every reader
# below normalizes that spelling first (gaia_branch_normalize), so a worktree
# branch reads exactly as the branch it was requested as. Minted names are
# capped at 64 bytes and restricted to [A-Za-z0-9./-] (slugs and tasks are
# lowercased; a release version keeps its own case) so they are always valid
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
#   Prints the SPEC number a `plan/spec-<nnn>` branch names, leading zeros
#   stripped (`plan/spec-005-x` prints 5). Prints nothing otherwise. Returns 0.
#
# gaia_branch_list [dir]
#   Prints every local branch and every remote-tracking branch of the
#   repository at [dir] (default `.`), the remote-tracking ones with their
#   `<remote>/` prefix removed, one per line. A symbolic `<remote>/HEAD` is
#   skipped. Prints nothing outside a repository. Returns 0.
#
# gaia_branch_refs_readable [dir]
#   The fail-closed companion to gaia_branch_list, for a caller that must tell
#   an unreadable ref store from a repository with no branches. Probes both of
#   the namespaces gaia_branch_list reads, over the repository at [dir]
#   (default `.`). Prints nothing and returns 0 when both enumerate; prints the
#   first namespace that fails (`refs/heads` or `refs/remotes`) and returns 1
#   otherwise, so the caller names it in its own refusal and picks its own exit
#   code. gaia_branch_list itself stays fail-open by contract, so a ref store
#   that cannot be read reaches a caller as an empty branch list, byte for byte
#   the value a repository with no branches produces; a caller that must fail
#   closed calls this first rather than deriving the probe again. Outside a
#   repository every read fails, so this returns 1 where gaia_branch_list
#   returns 0; a caller that distinguishes "not a repository" from "refs
#   unreadable" tests for the repository itself first.
#
# gaia_branch_name <kind> <args...>
#   Prints the canonical name for a new branch, newline terminated, and
#   returns 0; on a bad argument prints a diagnostic to stderr, prints nothing
#   on stdout, and returns 2. Kinds:
#     debt <issue> [--slug <text>]        debt/<issue>[-<slug>]
#     debt <issue> <issue>... [--batch]   debt/<ascending members>-batch
#     plan <spec-NNN|plan-NNN> [--slug <text>]
#                                         plan/<id>[-<slug>]
#     chore <task>                        chore/<task>-<UTC YYYY-MM-DD-HHMM>
#     release <version>                   release/v<version>
#   <slug> and <task> are reduced to lowercase kebab-case; a slug is truncated
#   to keep the whole name within 64 bytes. Two or more distinct issues always
#   mint a batch name, which carries no slug; `--batch` is accepted and
#   changes nothing.
#
# Usage (sourced):
#   . .gaia/scripts/branch-name-lib.sh
#   branch="$(gaia_branch_name debt 2159 --slug "reconcile worktree claim")"
#
# Usage (executable):
#   bash .gaia/scripts/branch-name-lib.sh name debt 2159 --slug "reconcile worktree claim"
#   bash .gaia/scripts/branch-name-lib.sh name chore update-deps
#   bash .gaia/scripts/branch-name-lib.sh classify worktree-debt+42-fix
#   bash .gaia/scripts/branch-name-lib.sh members debt/41-42-batch
#   bash .gaia/scripts/branch-name-lib.sh spec-number plan/spec-005-cards
#   bash .gaia/scripts/branch-name-lib.sh list [dir]

GAIA_BRANCH_NAME_MAX=64

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

# _gaia_branch_leading_digits <text>: the leading run of ASCII digits.
# `${text:$i:1}`, not bash's bare `${text:i:1}`: zsh reads a bare identifier
# after the colon as a history modifier and aborts the walk.
_gaia_branch_leading_digits() {
  local LC_ALL=C
  local text="${1-}" out="" i len c
  len="${#text}"
  for ((i = 0; i < len; i++)); do
    c="${text:$i:1}"
    case "$c" in
      [0-9]) out="${out}${c}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
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

gaia_branch_normalize() {
  local text="${1-}"
  text="${text#worktree-}"
  # `\+`: an escaped literal means the same thing in bash and zsh.
  text="${text//\+//}"
  printf '%s' "$text"
}

gaia_branch_classify() {
  local nb mode="adhoc" unit="" rest="" id="" lead=""
  nb="$(gaia_branch_normalize "${1-}")"

  case "$nb" in
    debt/*)
      mode="drain"
      rest="${nb#debt/}"
      # The batch row is tested first: a batch's unit is every member, and
      # falling through would record only the first.
      case "$rest" in
        *-batch)
          if _gaia_branch_is_members "${rest%-batch}"; then
            unit="${rest%-batch}"
          fi
          ;;
      esac
      [ -n "$unit" ] || unit="$(_gaia_branch_leading_digits "$rest")"
      ;;
    plan/*)
      mode="plan"
      rest="${nb#plan/}"
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
    chore/* | release/* | wiki-sync/* | gaia-ci/*)
      mode="maintenance"
      unit="${nb#*/}"
      ;;
  esac

  [ -n "$unit" ] || unit="unknown"
  printf '%s %s\n' "$mode" "$unit"
  return 0
}

gaia_branch_members() {
  local classified mode unit
  classified="$(gaia_branch_classify "${1-}")"
  mode="${classified%% *}"
  unit="${classified#* }"
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

gaia_branch_list() {
  local dir="${1:-.}"
  git -C "$dir" for-each-ref --format='%(refname:lstrip=2)' refs/heads 2>/dev/null || true
  # A remote-tracking ref is refs/remotes/<remote>/<branch>; lstrip=3 drops
  # the remote. `<remote>/HEAD` is a symbolic pointer, not a branch.
  git -C "$dir" for-each-ref --format='%(refname:lstrip=3)' refs/remotes 2>/dev/null \
    | grep -vx 'HEAD' || true
  return 0
}

# The fail-closed companion to gaia_branch_list above, which returns 0 whatever
# the ref read does. Read the whole namespace rather than the first ref: a
# packed-refs file is parsed as a unit, so a short read can succeed over a file
# a full read rejects. Which of a corrupt packed-refs, an unreadable ref file,
# or a permission denial produced the failure is not distinguishable here, so
# the namespace is all this prints and the caller's message names all three.
gaia_branch_refs_readable() {
  local dir="${1:-.}" ns
  for ns in refs/heads refs/remotes; do
    if ! git -C "$dir" for-each-ref --format=x "$ns" >/dev/null 2>&1; then
      printf '%s\n' "$ns"
      return 1
    fi
  done
  return 0
}

# _gaia_branch_kebab <text>: lowercase, every run of other bytes one `-`,
# no leading or trailing `-`.
_gaia_branch_kebab() {
  printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# _gaia_branch_emit <prefix> <slug>: <prefix>[-<slug>], the slug cut so the
# whole name fits GAIA_BRANCH_NAME_MAX, then the result validated as a ref.
_gaia_branch_emit() {
  local prefix="$1" slug="$2" name room
  if [ -n "$slug" ]; then
    room=$((GAIA_BRANCH_NAME_MAX - ${#prefix} - 1))
    if [ "$room" -gt 0 ]; then
      slug="${slug:0:$room}"
      slug="$(printf '%s' "$slug" | LC_ALL=C sed -E 's/-+$//')"
    else
      slug=""
    fi
  fi
  name="$prefix"
  [ -z "$slug" ] || name="${prefix}-${slug}"
  if [ "${#name}" -gt "$GAIA_BRANCH_NAME_MAX" ]; then
    printf 'gaia_branch_name: %s is longer than %s bytes\n' "$name" "$GAIA_BRANCH_NAME_MAX" >&2
    return 2
  fi
  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    printf 'gaia_branch_name: %s is not a valid branch name\n' "$name" >&2
    return 2
  fi
  printf '%s\n' "$name"
}

gaia_branch_name() {
  local kind="${1-}" slug="" arg="" members="" id="" task="" version="" count=0
  [ "$#" -gt 0 ] && shift

  case "$kind" in
    debt)
      while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
          --slug)
            [ "$#" -gt 0 ] || { echo "gaia_branch_name: --slug needs a value" >&2; return 2; }
            slug="$(_gaia_branch_kebab "$1")"
            shift
            ;;
          --batch) ;;
          *)
            arg="${arg#\#}"
            _gaia_branch_is_digits "$arg" || {
              printf 'gaia_branch_name: %s is not an issue number\n' "$arg" >&2
              return 2
            }
            members="${members}$(_gaia_branch_strip_zeros "$arg")
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
          *)
            printf 'gaia_branch_name: unexpected argument %s\n' "$1" >&2
            return 2
            ;;
        esac
      done
      _gaia_branch_emit "plan/${id}" "$slug"
      ;;
    chore)
      task="$(_gaia_branch_kebab "${1-}")"
      [ -n "$task" ] || { echo "gaia_branch_name: chore needs a task name" >&2; return 2; }
      _gaia_branch_emit "chore/${task}-$(date -u +%Y-%m-%d-%H%M)" ""
      ;;
    release)
      version="${1-}"
      version="${version#v}"
      case "$version" in
        "" | *[!0-9A-Za-z.-]*)
          echo "gaia_branch_name: release needs a version such as 1.4.0" >&2
          return 2
          ;;
      esac
      _gaia_branch_emit "release/v${version}" ""
      ;;
    *)
      printf 'gaia_branch_name: unknown kind %s (debt, plan, chore, release)\n' "${kind:-<none>}" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  sub="${1-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    name) gaia_branch_name "$@"; exit $? ;;
    classify) gaia_branch_classify "${1-}" ;;
    members) gaia_branch_members "${1-}" ;;
    spec-number) gaia_branch_spec_number "${1-}" ;;
    normalize) gaia_branch_normalize "${1-}"; printf '\n' ;;
    list) gaia_branch_list "${1-}" ;;
    *)
      echo "usage: branch-name-lib.sh name|classify|members|spec-number|normalize|list <args>" >&2
      exit 2
      ;;
  esac
  exit 0
fi
