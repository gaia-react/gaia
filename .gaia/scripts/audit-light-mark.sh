#!/usr/bin/env bash
# audit-light-mark.sh: the only path that turns a light reviewer's reply into a
# clearance. It persists the reply, re-derives the route from the current tree
# instead of trusting the stored record, validates the reply against that
# record, and only then writes the light sidecar and an earned marker carrying
# `review: light` through the shared clearance writer.
#
#   audit-light-mark.sh --root <abs-checkout-root> --member <name> --verdict -
#                       [--reviewer-tokens <int>] [--reviewer-duration-ms <int>]
#                       < <the reviewer's reply, verbatim>
#
# stdout is exactly one line, `light-cleared` or `full\t<reason>`; exit 0 on
# both. Exit 2 is a usage error. Every consumer reads exit 2, any reason, and
# any other output as Full, so the member is dispatched on the same tree.
#
# Steps, in order. The first failing step prints its reason and stops; no
# later step runs, so no marker is written after a failure:
#   1. usage validation
#   2. the member digest and the HEAD tree (degraded: nothing is persisted, as
#      the verdict path is keyed by the digest)
#   3. the reply, byte for byte, to <light>/<digest>.<member>.verdict.json
#   4. the route record: no-route-record, route-not-light, route-stale
#   5. a fresh router run (--check): recheck-full
#   6. the no-op classification of the reply: verdict-noop
#   7. the reply against the record: verdict-malformed, verdict-mismatch,
#      escalate
#   8. a refusal for this digest: refusal-present
#   9. the light sidecar: sidecar-failed
#  10. the marker through the writer: write-failed
#
# The persisted reply is the record of what the reviewer said and survives
# every outcome after step 2. Every outcome after step 3 appends one line to
# the light-review ledger, `<light>/<branch-slug>.reviews.jsonl`; a ledger or
# telemetry failure never changes the output line or the exit code.
#
# Guarantee: a marker exists only for a digest and tree the router currently
# calls light, from a reply that is well formed, clear on every routed file, and
# names exactly the routed files. Not a guarantee: that the reply came from the
# reviewer. This script checks well-formedness and routing integrity, never
# authorship, so it is no defense against a forged reply. The writer's own
# scope-digest and route-record checks are the last line.
#
# Bash 3.2 compatible, BWK awk safe. `cd` only inside a command substitution.
set -uo pipefail

_light_mark_usage() {
  printf 'usage: audit-light-mark.sh --root <abs-checkout-root> --member <name> --verdict - [--reviewer-tokens <int>] [--reviewer-duration-ms <int>]\n' >&2
}

_light_mark_degraded() {
  printf 'full\tdegraded\n'
  exit 0
}

# _light_mark_record_outcome <clear|escalate|failed>: the ledger line and the
# telemetry event. Neither can alter the decision already made.
_light_mark_record_outcome() {
  local outcome="$1" ledger_path
  if [ -n "$branch_slug" ]; then
    ledger_path="$light_directory/$branch_slug.reviews.jsonl"
    jq -n -c --arg member "$member" --arg digest "$digest" --arg tree "$head_tree" \
      --arg verdict "$outcome" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{member: $member, digest: $digest, tree: $tree, verdict: $verdict, at: $at}' >>"$ledger_path" 2>/dev/null || true
  fi
  # gaia:maintainer-only:start
  if [ -f "$root/.gaia/scripts/audit-light-telemetry.sh" ]; then
    local -a telemetry_arguments=(outcome --root "$root" --member "$member" --digest "$digest" --tree "$head_tree" --verdict "$outcome")
    [ -z "$reviewer_tokens" ] || telemetry_arguments+=(--tokens "$reviewer_tokens")
    [ -z "$reviewer_duration" ] || telemetry_arguments+=(--duration-ms "$reviewer_duration")
    bash "$root/.gaia/scripts/audit-light-telemetry.sh" ${telemetry_arguments[@]+"${telemetry_arguments[@]}"} >/dev/null 2>&1 || true
  fi
  # gaia:maintainer-only:end
  return 0
}

# _light_mark_full <reason> [ledger-verdict]: every Full outcome after the reply
# was persisted.
_light_mark_full() {
  _light_mark_record_outcome "${2:-failed}"
  printf 'full\t%s\n' "$1"
  exit 0
}

light_mark_main() {
  root=""
  member=""
  reviewer_tokens=""
  reviewer_duration=""
  local verdict_flag="" argument_name
  while [ "$#" -gt 0 ]; do
    argument_name="$1"
    case "$argument_name" in
      --root | --member | --verdict | --reviewer-tokens | --reviewer-duration-ms)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'audit-light-mark: %s requires a value\n' "$argument_name" >&2; _light_mark_usage; exit 2; }
        case "$argument_name" in
          --root) root="$2" ;;
          --member) member="$2" ;;
          --verdict) verdict_flag="$2" ;;
          --reviewer-tokens) reviewer_tokens="$2" ;;
          --reviewer-duration-ms) reviewer_duration="$2" ;;
        esac
        shift 2
        ;;
      *) printf 'audit-light-mark: unknown argument: %s\n' "$argument_name" >&2; _light_mark_usage; exit 2 ;;
    esac
  done
  [ -n "$root" ] && [ -n "$member" ] && [ "$verdict_flag" = "-" ] || { _light_mark_usage; exit 2; }
  case "$root" in /*) ;; *) printf 'audit-light-mark: --root must be absolute\n' >&2; exit 2 ;; esac
  # The member names the verdict, route record and sidecar paths.
  case "$member" in */* | *..* | -*) printf 'audit-light-mark: --member is not a plain name\n' >&2; exit 2 ;; esac
  case "$reviewer_tokens" in *[!0-9]*) printf 'audit-light-mark: --reviewer-tokens must be an integer\n' >&2; exit 2 ;; esac
  case "$reviewer_duration" in *[!0-9]*) printf 'audit-light-mark: --reviewer-duration-ms must be an integer\n' >&2; exit 2 ;; esac
  [ -d "$root" ] || { printf 'audit-light-mark: --root is not a directory\n' >&2; exit 2; }

  command -v jq >/dev/null 2>&1 || _light_mark_degraded
  command -v git >/dev/null 2>&1 || _light_mark_degraded

  digest="$(bash "$root/.gaia/scripts/audit-member-digest.sh" --root "$root" --member "$member" 2>/dev/null)" || digest=""
  case "$digest" in *[!0-9a-f]* | '') _light_mark_degraded ;; esac
  [ "${#digest}" -eq 64 ] || _light_mark_degraded
  head_tree="$(git -C "$root" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null)" || _light_mark_degraded
  [ -n "$head_tree" ] || _light_mark_degraded

  local library_directory
  library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || _light_mark_degraded
  [ -f "$library_directory/audit-clearance.sh" ] || _light_mark_degraded
  # shellcheck source=/dev/null
  . "$library_directory/audit-clearance.sh" 2>/dev/null
  command -v clearance_member_refused >/dev/null 2>&1 || _light_mark_degraded
  # shellcheck source=/dev/null
  . "$(dirname "${BASH_SOURCE[0]}")/audit-key-lib.sh" 2>/dev/null
  branch_slug="$(gaia_branch_slug "$root" 2>/dev/null)" || branch_slug=""

  light_directory="$root/.gaia/local/audit/light"
  local verdict_path="$light_directory/$digest.$member.verdict.json"
  local record_path="$light_directory/$digest.$member.route.json"

  # Step 3: the reply, byte for byte, before any check that can fail.
  local temporary_file
  mkdir -p "$light_directory" 2>/dev/null || _light_mark_degraded
  temporary_file="$(mktemp "$light_directory/.verdict.XXXXXX" 2>/dev/null)" || _light_mark_degraded
  if ! cat >"$temporary_file" 2>/dev/null || ! mv -f "$temporary_file" "$verdict_path" 2>/dev/null; then
    rm -f "$temporary_file"
    _light_mark_degraded
  fi

  # Step 4: the route record.
  if [ ! -f "$record_path" ] || ! jq -e 'type == "object" and (.route | type == "string") and (.files | type == "array")' "$record_path" >/dev/null 2>&1; then
    _light_mark_full no-route-record
  fi
  local record_route record_digest record_tree
  record_route="$(jq -r '.route' "$record_path" 2>/dev/null)" || _light_mark_full no-route-record
  [ "$record_route" = "light" ] || _light_mark_full route-not-light
  record_digest="$(jq -r '.digest // ""' "$record_path" 2>/dev/null)" || _light_mark_full no-route-record
  record_tree="$(jq -r '.tree // ""' "$record_path" 2>/dev/null)" || _light_mark_full no-route-record
  [ "$record_digest" = "$digest" ] && [ "$record_tree" = "$head_tree" ] || _light_mark_full route-stale

  # Step 5: the stored record is not trusted; the router decides again.
  local recheck_output recheck_route
  recheck_output="$(bash "$root/.gaia/scripts/audit-light-route.sh" --root "$root" --member "$member" --check 2>/dev/null)" \
    || _light_mark_full recheck-full
  recheck_route="${recheck_output%%$'\t'*}"
  [ "$recheck_route" = "light" ] || _light_mark_full recheck-full

  # Step 6: a silent or truncated reviewer must not read as a clean one.
  local expected_count
  expected_count="$(jq -r '.files | length' "$record_path" 2>/dev/null)" || _light_mark_full no-route-record
  bash "$root/.gaia/scripts/audit-noop-detect.sh" --shape agent-report-file --path "$verdict_path" \
    --report-key files --expect-count "$expected_count" >/dev/null 2>&1 \
    || _light_mark_full verdict-noop

  # Step 7: the reply against the record.
  local classification
  classification="$(jq -r -s --slurpfile record "$record_path" '
    ($record[0]) as $route
    | if length != 1 then "malformed"
      else .[0] as $verdict
      | if ($verdict | type) != "object" then "malformed"
        elif $verdict.schema != 1 then "malformed"
        elif ($verdict.verdict | IN("clear", "escalate") | not) then "malformed"
        elif ($verdict.files | type) != "array" then "malformed"
        elif ([$verdict.files[] | (type == "object") and ((.path | type) == "string") and (.verdict | IN("clear", "escalate"))] | all | not) then "malformed"
        elif ($verdict.member != $route.member or $verdict.digest != $route.digest or $verdict.tree != $route.tree) then "mismatch"
        elif (([$verdict.files[].path] | sort) != ([$route.files[].path] | sort)) then "mismatch"
        elif ($verdict.verdict == "escalate" or any($verdict.files[]; .verdict == "escalate")) then "escalate"
        else "ok"
        end
      end' "$verdict_path" 2>/dev/null)" || classification="malformed"
  case "$classification" in
    ok) ;;
    mismatch) _light_mark_full verdict-mismatch ;;
    escalate) _light_mark_full escalate escalate ;;
    *) _light_mark_full verdict-malformed ;;
  esac

  # Step 8: a light clearance never supersedes or sits beside a refusal.
  if clearance_member_refused "$root" "$digest" "$member"; then
    _light_mark_full refusal-present
  fi

  # Step 9: the light sidecar, keyed by the shared base exactly as members key
  # theirs. The resolver has no --root flag and reads its repository from the
  # working directory, so it runs in a subshell rooted at --root; the cwd of
  # this script never changes.
  local resolver_output shared_reference shared_base sidecar_path
  resolver_output="$(cd "$root" && bash "$root/.github/audit/resolve-audit-base.sh" --member "$member" 2>/dev/null)" \
    || _light_mark_full sidecar-failed
  # A degraded answer means the resolver could not read its repository, and its
  # shared base is then the main ref by default rather than a derivation.
  [ "$(printf '%s\n' "$resolver_output" | sed -n '2p')" != "degraded" ] || _light_mark_full sidecar-failed
  shared_reference="$(printf '%s\n' "$resolver_output" | sed -n '3p')"
  [ -n "$shared_reference" ] || _light_mark_full sidecar-failed
  # Line 3 is a ref; members key their artifacts by its merge-base with HEAD.
  shared_base="$(git -C "$root" merge-base "$shared_reference" HEAD 2>/dev/null)" || _light_mark_full sidecar-failed
  [ -n "$shared_base" ] || _light_mark_full sidecar-failed
  sidecar_path="$(printf '[]' | bash "$root/.gaia/scripts/audit-write-findings.sh" --root "$root" --member "$member" \
    --base "$shared_base" --findings - --review light 2>/dev/null)" || _light_mark_full sidecar-failed
  if [ ! -f "$sidecar_path" ] || ! jq -e '.review == "light"' "$sidecar_path" >/dev/null 2>&1; then
    _light_mark_full sidecar-failed
  fi

  # Step 10: the marker. The writer re-derives the digest and tree and refuses
  # a record that no longer matches.
  bash "$root/.gaia/scripts/audit-write-clearance.sh" --root "$root" --member "$member" --provenance earned \
    --review light --route-record "$record_path" --scope-digest "$record_digest" >/dev/null 2>&1 \
    || _light_mark_full write-failed

  _light_mark_record_outcome clear
  printf 'light-cleared\n'
  exit 0
}

light_mark_main "$@"
