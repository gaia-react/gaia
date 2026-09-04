#!/usr/bin/env bash
# shellcheck shell=bash
#
# Report security floors that have stopped being applied in a pnpm workspace
# root outside the repository root.
#
# WHY THIS EXISTS AT ALL. Every dependency-CVE surface in this repository runs
# `pnpm audit` from the repository root and nowhere else: the `/update-deps`
# skill's override audit, the code-review agent's advisory oracle, and the CI
# cron template. A second workspace root is invisible to all of them, because a
# root's own pnpm-workspace.yaml is what makes it a separate root in the first
# place, so root's closure never contains it. `.gaia/cli` is such a root, its
# overrides map carries security floors retired by hand, and its build inlines
# its dependencies into a binary adopters receive. Nothing reported on it.
#
# WHY IT IS A SEPARATE PROGRAM RATHER THAN A WIDER `/update-deps`. That skill
# ships to adopters, and every file constituting the second root is
# release-excluded, so an adopter has no second root to audit. Teaching the
# shipped skill about one would encode a condition that can never arise on an
# adopter's machine. An earlier attempt at the retrofit was also reverted after
# the graft ran against the grain of a skill that is single-root in every phase.
#
# THE ARMS, AND THEY FAIL DIFFERENTLY ON PURPOSE.
#
#   Parity, offline and deterministic, and it decides the exit status. The
#   overrides map in the root's pnpm-workspace.yaml must match the overrides
#   block in its lockfile exactly. Drift either way means the floor named in
#   config is not the floor the tree resolves against, which is a security pin
#   that looks present and is not. The `/update-deps` skill closes its own
#   override audit with this same assertion, against the repository root only.
#
#   Advisory, needs the network, and deliberately does NOT decide the exit
#   status. It surfaces high and critical advisories in the root's closure.
#   Reporting-not-blocking is the posture every other local `pnpm audit` in this
#   repository already takes, and it is the right one here for a second reason:
#   this runs inside a required CI context, where failing on a newly published
#   upstream advisory would red every open pull request for something none of
#   them changed.
#
# WHAT THIS DOES NOT CATCH, and saying so is load-bearing rather than modest. A
# floor whose parents have bumped their own pins past it stops being a floor and
# quietly becomes a cap, holding a dependency BELOW what the tree would resolve
# on its own. That decay passes the parity arm untouched, because config and
# lockfile still agree with each other. Detecting it means toggling each key out
# and re-resolving with `pnpm dedupe`, which rewrites the lockfile -- a check
# that runs in CI must not mutate the tree, so the toggle stays where it is, in
# the interactive skill. A green run here means the floors are applied, never
# that they are still needed.
#
# Exit status: 0 nothing to report, 1 a floor is not applied as configured,
# 2 the root could not be read or the arguments were wrong.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
usage: check-cli-workspace-floors.sh [--no-audit] [<workspace-root>]

  <workspace-root>  a directory holding its own pnpm-workspace.yaml and
                    pnpm-lock.yaml. Defaults to this repository's .gaia/cli.
  --no-audit        run the parity arm only; do not reach the network.
USAGE
}

# gaia_cwf_overrides <yaml-file>
#   Print the file's top-level `overrides:` mapping as normalized
#   <key><TAB><value> lines, sorted. Quoting is stripped from both halves
#   because the two files being compared disagree about it on a correct tree:
#   pnpm quotes a key it has to and writes the same key bare into the lockfile
#   it generates. Prints nothing when the file declares no overrides.
gaia_cwf_overrides() {
  awk '
    function unquote(s,   q) {
      if (length(s) >= 2) {
        q = substr(s, 1, 1)
        if ((q == "\"" || q == "\047") && substr(s, length(s), 1) == q)
          return substr(s, 2, length(s) - 2)
      }
      return s
    }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    /^overrides:[[:space:]]*$/ { in_block = 1; next }
    # A key at column zero closes the mapping. A comment does not, and neither
    # does a blank line: the lockfile puts one between the block and
    # `importers:`, and stopping there would read every nested key under it.
    in_block && /^[^[:space:]#]/ { in_block = 0 }
    in_block {
      line = trim($0)
      if (line == "" || substr(line, 1, 1) == "#") next
      c = substr(line, 1, 1)
      if (c == "\"" || c == "\047") {
        endq = index(substr(line, 2), c)
        if (endq == 0) next
        key = substr(line, 2, endq - 1)
        rest = substr(line, endq + 2)
        if (substr(rest, 1, 1) != ":") next
        val = substr(rest, 2)
      } else {
        i = index(line, ":")
        if (i == 0) next
        key = substr(line, 1, i - 1)
        val = substr(line, i + 1)
      }
      key = unquote(trim(key))
      val = unquote(trim(val))
      if (key == "") next
      print key "\t" val
    }
  ' "$1" | sort
}

gaia_cwf_main() {
  local run_audit=1 root=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-audit) run_audit=0; shift ;;
      -h|--help) usage; return 2 ;;
      --*) printf 'check-cli-workspace-floors: unknown flag %s\n' "$1" >&2; usage; return 2 ;;
      *)
        if [ -n "$root" ]; then
          printf 'check-cli-workspace-floors: more than one workspace root given\n' >&2
          return 2
        fi
        root="$1"; shift ;;
    esac
  done

  [ -n "$root" ] || root="$SELF_DIR/../cli"
  # Canonicalize so the reported root reads as a path someone can act on. The
  # default arrives relative to this script, and a caller's argument may be
  # relative to their cwd; neither is worth printing verbatim. A root that does
  # not resolve keeps the string it was given, which is what the caller needs to
  # see in the error below.
  [ -d "$root" ] && root="$(cd "$root" && pwd)"

  local ws_file="$root/pnpm-workspace.yaml"
  local lock_file="$root/pnpm-lock.yaml"
  local missing=""
  [ -d "$root" ] || missing="the root itself"
  [ -n "$missing" ] || [ -f "$ws_file" ] || missing="pnpm-workspace.yaml"
  [ -n "$missing" ] || [ -f "$lock_file" ] || missing="pnpm-lock.yaml"
  if [ -n "$missing" ]; then
    printf 'check-cli-workspace-floors: %s is missing under %s\n' "$missing" "$root" >&2
    return 2
  fi

  printf 'workspace root: %s\n' "$root"

  local configured locked rc=0
  configured="$(gaia_cwf_overrides "$ws_file")"
  locked="$(gaia_cwf_overrides "$lock_file")"

  # A reader that stops recognizing the shape pnpm emits returns empty for both
  # files, and empty compared against empty agrees. That is indistinguishable
  # from a workspace declaring no floors, so the gate would report clean over
  # the exact surface it exists to watch, with every fixture test still green on
  # its own hand-written shape. The block header is therefore checked textually
  # rather than inferred from the parse. Refusing at 2 rather than reporting at
  # 1 is deliberate: a declared block yielding no entries is a question this
  # reader cannot answer, and it cannot separate a genuinely empty map from a
  # shape it does not know, so it says so instead of choosing one.
  local f
  for f in "$ws_file" "$lock_file"; do
    if grep -q '^overrides:' "$f"; then
      case "$f" in
        "$ws_file") [ -n "$configured" ] && continue ;;
        *) [ -n "$locked" ] && continue ;;
      esac
      printf 'check-cli-workspace-floors: %s declares an overrides block yielding no entries; either the map is empty or this reader no longer matches the shape pnpm emits\n' \
        "$f" >&2
      return 2
    fi
  done

  if [ -z "$configured" ] && [ -z "$locked" ]; then
    printf 'no overrides declared; no floors to check\n'
  else
    # One pass over both lists. The report wordings are pinned by the sibling
    # suite, so they stay byte-identical.
    local report flag line
    report="$(awk -F'\t' '
      $1 == "" { next }
      NR == FNR { cfg[$1] = $2; order[++n] = $1; next }
      { lock[$1] = $2; lorder[++m] = $1 }
      END {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (!(k in lock))
            printf "1\tFLOOR NOT APPLIED: %s is pinned to %s in pnpm-workspace.yaml and absent from the lockfile\n", k, cfg[k]
          else if (lock[k] != cfg[k])
            printf "1\tFLOOR NOT APPLIED: %s is pinned to %s in pnpm-workspace.yaml and locked at %s\n", k, cfg[k], lock[k]
          else
            printf "0\tfloor applied: %s at %s\n", k, cfg[k]
        }
        for (j = 1; j <= m; j++) {
          k = lorder[j]
          if (!(k in cfg))
            printf "1\tUNDECLARED OVERRIDE: %s is locked at %s with no entry in pnpm-workspace.yaml\n", k, lock[k]
        }
      }
    ' <(printf '%s\n' "$configured") <(printf '%s\n' "$locked"))"

    while IFS="$(printf '\t')" read -r flag line; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"
      if [ "$flag" = "1" ]; then
        rc=1
      fi
    done <<<"$report"
  fi

  if [ "$run_audit" -eq 0 ]; then
    printf 'advisory arm skipped: --no-audit\n'
  elif ! command -v pnpm >/dev/null 2>&1; then
    printf 'advisory arm skipped: pnpm is not on PATH\n'
  elif ! command -v jq >/dev/null 2>&1; then
    printf 'advisory arm skipped: jq is not on PATH\n'
  else
    local audit_json advisories declared
    audit_json="$(pnpm -C "$root" audit --json 2>/dev/null || true)"
    # The exit status cannot separate a scan that failed from one that
    # succeeded, because `pnpm audit` exits non-zero precisely when it FINDS
    # advisories. The shape of stdout is what separates them, and it has to be
    # read positively: an unreachable registry writes `{"error":{...}}`, which
    # parses perfectly well as an object, so treating a merely-parseable payload
    # as a report reads an absent advisory set as an empty one. That turns the
    # likeliest failure into the most reassuring line this file can print, on
    # the one closure its own header says nothing else audits. Require the
    # `advisories` key present and no `error` key; anything else, including a
    # future payload shape naming its findings something other than
    # `advisories`, is unread rather than clean. The same reasoning applies
    # one level down, to the entries behind that key: a container this
    # reader can name says nothing about whether it can read what the
    # container holds.
    if ! printf '%s' "$audit_json" \
      | jq -e 'type == "object" and has("advisories") and (has("error") | not)' >/dev/null 2>&1; then
      printf 'advisory arm: pnpm audit could not be read; this closure was NOT audited\n'
      return "$rc"
    fi
    # Every entry must carry the two fields the filter below reads. An entry
    # schema this reader does not know filters to nothing and would otherwise
    # print the clean line, which is the container-level false clean repeated
    # one level down. An empty `advisories` object passes and is correct: that
    # is a scan that ran and found nothing.
    if ! printf '%s' "$audit_json" | jq -e '
      (.advisories | type) == "object"
      and (.advisories | to_entries | all(.value
        | (type == "object") and has("severity") and has("module_name")))' >/dev/null 2>&1; then
      printf 'advisory arm: pnpm audit named advisories in a shape this reader cannot read; this closure was NOT audited\n'
      return "$rc"
    fi
    advisories="$(printf '%s' "$audit_json" | jq -r '
      (.advisories // {}) | to_entries[]
      | select(.value.severity == "high" or .value.severity == "critical")
      | "\(.value.severity)\t\(.value.module_name)\t\(.value.title)"' 2>/dev/null)"
    if [ -z "$advisories" ]; then
      # Cross-check the report's own second statement of the same fact before
      # printing the most reassuring line this file can print. A count above
      # zero with nothing parsed means the report names findings this reader
      # did not see, which is what a future shape that moves them out of
      # `advisories` while leaving the empty key behind looks like from here.
      # Only a literal zero earns the clean line. Every other answer, a count
      # above zero, a count stated in some type this reader does not know, a
      # `metadata` shape `jq` cannot index at all, or `jq` itself failing, is
      # the same fact from here: the report says something about high and
      # critical advisories that this reader did not manage to read.
      declared="$(printf '%s' "$audit_json" | jq -r '
        [(.metadata.vulnerabilities.high // 0), (.metadata.vulnerabilities.critical // 0)]
        | if all(type == "number") then add else "unreadable" end' 2>/dev/null || true)"
      case "$declared" in
      0)
        printf 'advisory arm: no high or critical advisories in this closure\n'
        ;;
      *)
        printf 'advisory arm: the report does not state zero high or critical advisories (%s) and this reader parsed none; this closure was NOT audited\n' "${declared:-unreadable}"
        ;;
      esac
    else
      # Reported, never fatal: see the posture note in this file's header.
      printf '%s\n' "$advisories" | while IFS="$(printf '\t')" read -r sev mod title; do
        printf 'ADVISORY (%s, not fatal here): %s -- %s\n' "$sev" "$mod" "$title"
      done
    fi
  fi

  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  gaia_cwf_main "$@"
  exit $?
fi
