# shellcheck shell=bash
#
# GAIA shared audit re-spawn ledger helper (single-sourced).
#
# The Code Audit Team's spawn oracle (.gaia/scripts/resolve-audit-spawn.sh)
# re-dispatches a member whenever its valid current-digest earned marker is
# missing, and one cause of a missing marker is not a content change at all:
# absorbing main rotates a member's content digest without touching the
# three-dot diff the member actually reviews. This file is the one
# definition of the ledger path, the record shapes, and the retention knobs
# that instrument how often that happens, shared by four consumers: the
# writer inside the oracle, the scope-digest capture script, the retention
# sweep, and the attribution query. It records what its callers saw; it
# classifies nothing.
#
# Two record KINDS share one ledger, discriminated by a `kind` field:
#   "spawn"  one per member the oracle considers on every run (unchanged
#            shape from schema 1, `kind` inserted after `schema`).
#   "scope"  one per member that resolves a review scope
#            (.gaia/scripts/audit-scope-digest.sh --capture), recording the
#            digest that member's clearance will attest to. This is the
#            observation a spawn breadcrumb alone cannot make: a member
#            still mid-review has written no marker to lose, so a rotation
#            landing WHILE it reviews is invisible to the spawn-only pairing.
#            The attribution query pairs a scope record forward against the
#            next spawn breadcrumb for the same [branch, member] to count it.
#
# A record's `schema` value is a property of the WRITING TREE's own copy of
# this lib, not of the ledger as a whole: an unmerged worktree keeps writing
# old-shape (schema 1, no `kind`) records into the same shared ledger
# indefinitely, alongside schema-2 records another tree writes. A reader
# treats any record with `schema` below 2, with no `kind`, or with an
# unexpected `schema` value as PRE-ADDITION -- unknown for every new
# quantity, never a false. That boundary is per-record, not temporal.
#
# Sourced, never executed. No side effects at source time: defines two
# constants and functions only. Bash 3.2 compatible (macOS default: no
# associative arrays, no `mapfile`, no `${var^^}`). Never `cd`s (per
# .claude/rules/shell-cwd.md).
#
# GAIA_RESPAWN_LEDGER_REL
#   The ledger's path relative to `<root>/.gaia/local/`.
# GAIA_RESPAWN_SCHEMA
#   The `schema` field's literal value on every record this file writes.
#
# gaia_respawn_ledger_path <root>
#   Prints "<root>/.gaia/local/<GAIA_RESPAWN_LEDGER_REL>" and returns 0.
#   Prints nothing and returns 1 when <root> is empty or unset. Resolves
#   nothing and derives no root itself: <root> is the caller's already
#   resolved repo root. A linked worktree's `.gaia/local` is one wholesale
#   symlink to the main checkout's (.gaia/scripts/link-worktree.sh), so this
#   reaches the single shared copy from every tree, exactly as the clearance
#   reader (.claude/hooks/lib/audit-clearance.sh) already does for marker
#   paths.
#
# gaia_respawn_record <ledger> <ts> <branch> <head> <merge_base> <member> <digest> <cleared>
#   Appends exactly one JSON-Lines "spawn" record to <ledger>, creating the
#   parent directory if needed, keys in exactly this order:
#     {"schema":2,"kind":"spawn","ts":"...","branch":"...","head":"...",
#      "merge_base":"...","member":"...","digest":"...","cleared":true}
#   `kind` is a constant of this function, not a parameter: every other key
#   keeps its name, value, and position from schema 1. ALWAYS returns 0, on
#   every path, and ALWAYS writes nothing to stdout or stderr: the oracle's
#   stdout is its contract, and its stderr carries advisories only, so a
#   breadcrumb diagnostic on either would be a behavior change the oracle
#   must not make. Its callers run under `set -euo pipefail` and must not be
#   disturbed.
#
#   Silent no-op (still exit 0) when <ledger> is empty, <member> is empty,
#   the parent directory cannot be created, or the append itself fails (an
#   unwritable file, a <ledger> that names an existing directory).
#
#   <cleared> is normalized: exactly the string "true" emits the JSON
#   boolean `true`; every other value, including empty, emits `false`.
#
#   <branch>, <head>, <merge_base>, and <digest> may each be empty; an empty
#   value emits an empty JSON string ("") -- never a placeholder.
#
#   Escaping: two fields are free-form, <branch> and <member>, and they are
#   not escaped alike. Git ref names cannot contain a backslash or an ASCII
#   control character, so `"` is the single JSON-significant character git
#   permits in a <branch>. <member> comes from the hand-authored roster, which
#   constrains no charset, so it takes a backslash pass FIRST and then the
#   quote pass; reversing that order would re-escape the backslashes the quote
#   pass just introduced. Do not add a second pass over either field: they are
#   already fully escaped where the record is built, and escaping twice would
#   double every backslash. Both use bash parameter substitution, so no `jq` is
#   required to build a line, and none may be assumed: the oracle's
#   digest-marker filter can run on a machine with no `jq`.
#
#   One `printf` produces the whole line, appended with `>>`: a single small
#   write() under O_APPEND is what keeps concurrent appends from different
#   trees from interleaving mid-record. There is deliberately no lock.
#
# gaia_respawn_scope_record <ledger> <ts> <branch> <head> <merge_base> <member> <scope_digest>
#   Appends exactly one JSON-Lines "scope" record to <ledger>, same file as
#   the spawn breadcrumb, keys in exactly this order:
#     {"schema":2,"kind":"scope","ts":"...","branch":"...","head":"...",
#      "merge_base":"...","member":"...","scope_digest":"..."}
#   Same contract, escaping discipline (backslash pass then quote pass on
#   <member>, quote pass only on <branch>), single `printf` under `>>`, and
#   fail-open silent-on-every-path posture as gaia_respawn_record above. Do
#   not add a second escaping pass over either field.
#
# gaia_respawn_retention_days
#   Prints the retention window in days, default-then-floor (see below):
#   90 when $GAIA_AUDIT_RESPAWN_RETENTION_DAYS is unset, empty, or not a bare
#   run of digits; otherwise the override, raised to 45 when below 45.
#   Always exits 0. The 45-day floor is load-bearing: the SPEC's reopen
#   condition is measured over at least one month of accumulated
#   breadcrumbs, and the registry entry's `reaped_by` promises a sweep whose
#   retention outlasts that window, so no override may shorten it below one
#   month. Floor-clamping mirrors the janitor's existing knobs
#   (GAIA_AUDIT_FINDINGS_RETENTION_HOURS, GAIA_CACHE_ARTIFACT_RETENTION_DAYS).
#
# gaia_respawn_max_records
#   Prints the line cap, default-then-floor, same rule: 20000 when
#   $GAIA_AUDIT_RESPAWN_MAX_RECORDS is unset, empty, or not a bare run of
#   digits; otherwise the override, raised to 1000 when below 1000. Always
#   exits 0. THE CAP IS SUBORDINATE TO THE AGE WINDOW: this function only
#   reports a number, the prune sweep that consumes it may apply the cap
#   ONLY to records already outside the age window. A cap that dropped
#   in-window records would silently shorten retention below the observation
#   window the reaper exists to guarantee; on a repository whose oracle runs
#   hot enough to exceed the cap inside the window, the ledger grows past the
#   cap rather than losing the measurement. Do not read this function as a
#   hard file-size bound; it is not one.
#
# Default-then-floor, the rule both knobs above follow, in this order:
#   1. Validate. Unset, empty, or anything that is not a bare run of digits
#      (abc, -5, 12.5, 1e3, " 30 ") is not an override at all; the knob takes
#      its default.
#   2. Floor. A valid numeric override below the floor is raised to the
#      floor.
#   The floor only ever raises a number the caller actually supplied; it is
#   NOT a fallback for garbage, which already resolved to the default in
#   step 1 and is already above the floor. So
#   GAIA_AUDIT_RESPAWN_RETENTION_DAYS=abc prints 90, not 45, and
#   GAIA_AUDIT_RESPAWN_RETENTION_DAYS=10 prints 45.
#
# Usage (sourced):
#   . .gaia/scripts/audit-respawn-lib.sh
#   ledger="$(gaia_respawn_ledger_path "$repo_root")" || ledger=""
#   gaia_respawn_record "$ledger" "$ts" "$branch" "$head" "$merge_base" "$member" "$digest" "$cleared"
#   gaia_respawn_scope_record "$ledger" "$ts" "$branch" "$head" "$merge_base" "$member" "$scope_digest"
#   days="$(gaia_respawn_retention_days)"
#   cap="$(gaia_respawn_max_records)"

GAIA_RESPAWN_LEDGER_REL="telemetry/audit-respawn.jsonl"
GAIA_RESPAWN_SCHEMA=2

# gaia_respawn_ledger_path <root>
gaia_respawn_ledger_path() {
  local root="${1-}"
  [ -n "$root" ] || return 1
  printf '%s/.gaia/local/%s\n' "$root" "$GAIA_RESPAWN_LEDGER_REL"
  return 0
}

# gaia_respawn_record <ledger> <ts> <branch> <head> <merge_base> <member> <digest> <cleared>
# See the contract above. Fail-open and silent on every path.
gaia_respawn_record() {
  local ledger="${1-}" ts="${2-}" branch="${3-}" head="${4-}" merge_base="${5-}"
  local member="${6-}" digest="${7-}" cleared_arg="${8-}"
  [ -n "$ledger" ] || return 0
  [ -n "$member" ] || return 0

  local cleared="false"
  [ "$cleared_arg" = "true" ] && cleared="true"

  local dir
  dir="$(dirname -- "$ledger" 2>/dev/null)" || return 0
  mkdir -p -- "$dir" 2>/dev/null || return 0

  # Escape the one JSON-significant character these fields can carry. Git ref
  # names cannot hold a backslash or a control character, so `"` is all that
  # `branch` needs. `member` is not ref-shaped at all: it comes from the
  # hand-authored roster in `.gaia/audit-ci.yml`, which no charset guard
  # constrains, so it gets the same treatment. An unescaped quote there would
  # emit a line no JSON reader can parse, and the prune sweep keeps what it
  # cannot classify, so a single malformed record would live in the ledger
  # forever, defeating the one bound the sweep exists to enforce.
  branch="${branch//\"/\\\"}"
  # Backslash first, then quote: escaping in the other order would re-escape
  # the backslashes this line just introduced. `branch` needs no backslash pass
  # because git ref names cannot carry one; `member` can, since the roster
  # parser preserves whatever the file holds.
  member="${member//\\/\\\\}"
  member="${member//\"/\\\"}"

  # Grouped so the group's OWN `2>/dev/null` is established before the
  # inner `>>` redirect is attempted: bash evaluates a simple command's
  # redirections left to right, so a bare `printf ... >>"$ledger" 2>/dev/null`
  # would still leak a failed-redirect diagnostic to the shell's stderr (the
  # trailing `2>/dev/null` is never reached). The group's redirection applies
  # first and catches it.
  {
    printf '{"schema":%s,"kind":"spawn","ts":"%s","branch":"%s","head":"%s","merge_base":"%s","member":"%s","digest":"%s","cleared":%s}\n' \
      "$GAIA_RESPAWN_SCHEMA" "$ts" "$branch" "$head" "$merge_base" "$member" "$digest" "$cleared" >>"$ledger"
  } 2>/dev/null || return 0

  return 0
}

# gaia_respawn_scope_record <ledger> <ts> <branch> <head> <merge_base> <member> <scope_digest>
# The scope-resolution sibling of gaia_respawn_record above. See the contract
# above. Fail-open and silent on every path.
gaia_respawn_scope_record() {
  local ledger="${1-}" ts="${2-}" branch="${3-}" head="${4-}" merge_base="${5-}"
  local member="${6-}" scope_digest="${7-}"
  [ -n "$ledger" ] || return 0
  [ -n "$member" ] || return 0

  local dir
  dir="$(dirname -- "$ledger" 2>/dev/null)" || return 0
  mkdir -p -- "$dir" 2>/dev/null || return 0

  # Same escaping discipline as gaia_respawn_record: quote pass only on
  # `branch` (git ref names cannot carry a backslash or a control character),
  # backslash pass then quote pass on `member`. Do not add a second pass over
  # either field.
  branch="${branch//\"/\\\"}"
  member="${member//\\/\\\\}"
  member="${member//\"/\\\"}"

  {
    printf '{"schema":%s,"kind":"scope","ts":"%s","branch":"%s","head":"%s","merge_base":"%s","member":"%s","scope_digest":"%s"}\n' \
      "$GAIA_RESPAWN_SCHEMA" "$ts" "$branch" "$head" "$merge_base" "$member" "$scope_digest" >>"$ledger"
  } 2>/dev/null || return 0

  return 0
}

# _gaia_respawn_default_then_floor <value> <default> <floor>
# The one shared implementation of the two-step rule both public knobs
# below follow. Always exits 0.
_gaia_respawn_default_then_floor() {
  local v="${1-}" default="$2" floor="$3"
  case "$v" in
    '' | *[!0-9]*) v="$default" ;;
  esac
  # Normalize the base before anything reads the number. `test` parses base 10
  # while `$(( ))` reads a leading zero as octal, so an override like `050`
  # would clear the floor compare below as 50 and then reach a consumer's
  # arithmetic as 40, shortening the window under the floor the header promises
  # no override can shorten. `08` and `09` are not octal at all and abort the
  # consumer outright. `10#` settles it once, here, so the check and every
  # caller share one base. Safe unconditionally: the case arm above has already
  # guaranteed a non-empty bare run of digits.
  v=$((10#$v))
  [ "$v" -lt "$floor" ] && v="$floor"
  printf '%s\n' "$v"
  return 0
}

# gaia_respawn_retention_days
gaia_respawn_retention_days() {
  _gaia_respawn_default_then_floor "${GAIA_AUDIT_RESPAWN_RETENTION_DAYS-}" 90 45
  return 0
}

# gaia_respawn_max_records
gaia_respawn_max_records() {
  _gaia_respawn_default_then_floor "${GAIA_AUDIT_RESPAWN_MAX_RECORDS-}" 20000 1000
  return 0
}
