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
#   repository already takes.
#
#   THE ADVISORY ARM IS NOT RUN IN CI, and that is measured rather than
#   cautious. Across four runs of the job that gates this check it reached the
#   registry twice and failed twice, taking between 107s and 251s either way,
#   so its duration says nothing about whether it worked. It is a network call
#   inside a declared-required context whose own cap it competes for, buying a
#   result about half the time. CI therefore passes `--no-audit` and gates on
#   the parity arm alone; this arm is for a maintainer running the check by
#   hand, where a slow or failed call costs nothing and can be re-run.
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
#
#   THIS IS A STRICT RECOGNIZER, NOT A PERMISSIVE PARSER, and that is the whole
#   design. It is not a YAML reader, so every shape it does not recognize is a
#   shape it would otherwise have to GUESS at, and review caught it guessing
#   two different ones wrong: a key not ended where YAML ends it, and a comment
#   tail read as part of the pinned version, which printed FLOOR NOT APPLIED
#   over a tree whose floors were all applied. A wrong guess is
#   indistinguishable from a reading, so every shape this does not recognize
#   refuses at 2 and names the file, the line number and the line. A
#   legal-but-unusual line refusing is the accepted cost of that: it fails
#   toward "I cannot read this", never toward a verdict.
#
#   Returns 2 and prints the offending line when it meets something it does not
#   recognize. THE CALLER MUST CHECK, and does; a bare command substitution
#   discards the status and hands an empty map to a comparison that then agrees
#   with itself, which is the same false-clean shape the advisory arm below was
#   reworked to close.
gaia_cwf_overrides() {
  local out
  out="$(
    awk '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
      }
      function unquote(s,   q) {
        if (length(s) >= 2) {
          q = substr(s, 1, 1)
          if ((q == "\"" || q == "\047") && substr(s, length(s), 1) == q)
            return substr(s, 2, length(s) - 2)
        }
        return s
      }
      # Refuse rather than guess. Every arm that used to `next` past a shape it
      # could not read now lands here, because skipping a line silently drops a
      # declared floor out of the comparison and the comparison then agrees.
      function refuse(what, raw) {
        printf "check-cli-workspace-floors: %s:%d declares %s, which this reader does not recognize: %s\n", \
          FILENAME, FNR, what, raw > "/dev/stderr"
        exit 2
      }
      # A value ends at an unquoted comment tail. YAML starts a comment only at
      # a # preceded by whitespace, so a # with no space before it is part of
      # the scalar and is left alone. A quoted value keeps everything inside
      # its quotes and may carry a comment after the closing one.
      function strip_comment(s,   q, endq, rest) {
        if (s == "") return s
        q = substr(s, 1, 1)
        if (q == "\"" || q == "\047") {
          endq = index(substr(s, 2), q)
          if (endq == 0) return s
          rest = trim(substr(s, endq + 2))
          if (rest != "" && substr(rest, 1, 1) != "#") return s
          return substr(s, 1, endq + 1)
        }
        sub(/[[:space:]]+#.*$/, "", s)
        return s
      }
      /^overrides:[[:space:]]*$/ { in_block = 1; next }
      # A key at column zero closes the mapping. A comment does not, and
      # neither does a blank line: a hand-edited map may group its entries with
      # one, and closing there would silently drop every entry below the gap.
      # The lockfile also puts a blank line between the block and `importers:`,
      # but that case is already covered by the column-zero rule reaching
      # `importers:` itself, so it is not what decides this.
      in_block && /^[^[:space:]#]/ { in_block = 0 }
      in_block {
        raw = $0
        line = trim(raw)
        if (line == "" || substr(line, 1, 1) == "#") next
        c = substr(line, 1, 1)
        if (c == "\"" || c == "\047") {
          endq = index(substr(line, 2), c)
          if (endq == 0) refuse("a quoted key with no closing quote", raw)
          key = substr(line, 2, endq - 1)
          rest = substr(line, endq + 2)
          if (substr(rest, 1, 1) != ":") refuse("a quoted key not followed by a colon", raw)
          val = substr(rest, 2)
        } else {
          # A plain YAML key ends at the first colon FOLLOWED BY whitespace, or
          # at a colon ending the line, not at the first colon. A bare alias
          # spelling such as `foo@npm:bar: 1.2.3` carries a colon inside the
          # key itself, and splitting on the first one takes `foo@npm` with the
          # rest as its value. That reports the declared floor absent and
          # invents an undeclared override in the same run, on a correct tree.
          n = length(line)
          i = 0
          for (p = 1; p <= n; p++) {
            if (substr(line, p, 1) != ":") continue
            nx = substr(line, p + 1, 1)
            if (p == n || nx == " " || nx == "\t") { i = p; break }
          }
          if (i == 0) refuse("a mapping line with no key-terminating colon", raw)
          key = substr(line, 1, i - 1)
          val = substr(line, i + 1)
        }
        key = unquote(trim(key))
        val = trim(strip_comment(trim(val)))
        vq = substr(val, 1, 1)
        quoted = (length(val) >= 2 && (vq == "\"" || vq == "\047") && substr(val, length(val), 1) == vq)
        val = unquote(val)
        if (key == "") refuse("an empty key", raw)
        if (val == "") refuse("a key with no version", raw)
        # An UNQUOTED version carrying whitespace is the one shape left that
        # this reader cannot tell apart from a comment it failed to strip, so it
        # refuses instead of choosing. A quoted one is unambiguous and is taken
        # as written, which is how a range that genuinely needs a space is
        # spelled.
        if (!quoted && val ~ /[[:space:]]/) refuse("an unquoted version carrying whitespace", raw)
        print key "\t" val
      }
    ' "$1"
  )" || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sort
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
  #
  # The assignment is guarded rather than written as `[ -d ... ] && root=$(cd
  # ...)`, because `cd` fails on a directory that exists and cannot be entered,
  # and the command substitution then assigns the empty string. That turns an
  # unenterable root into a report that the root is missing, naming no path at
  # all, which is both the wrong cause and the loss of the one argument the
  # caller supplied.
  if [ -d "$root" ]; then
    local resolved
    resolved="$(cd "$root" 2>/dev/null && pwd)"
    [ -n "$resolved" ] && root="$resolved"
  fi

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

  # -f is not enough, because a subject that exists and cannot be READ makes
  # every reader below fail open in the same direction at once. awk yields no
  # entries for it, and the declared-block guard cannot fire either: its own
  # grep also cannot read the file, and grep exit 2 is indistinguishable from
  # exit 1 inside `if grep -q`. Both parses come back empty, empty agrees with
  # empty, and the run prints the clean line over a workspace whose floors it
  # never managed to look at. Refusing at 2 puts an unreadable subject in the
  # same class as an unenterable root, which is where it belongs: the reader
  # cannot answer the question rather than having answered it clean.
  local unreadable=""
  [ -r "$ws_file" ] || unreadable="pnpm-workspace.yaml"
  [ -n "$unreadable" ] || [ -r "$lock_file" ] || unreadable="pnpm-lock.yaml"
  if [ -n "$unreadable" ]; then
    printf 'check-cli-workspace-floors: %s exists under %s but cannot be read\n' \
      "$unreadable" "$root" >&2
    return 2
  fi

  printf 'workspace root: %s\n' "$root"

  local configured locked rc=0
  # The status is checked, never discarded. gaia_cwf_overrides returns 2 when it
  # meets a shape it does not recognize, and a bare command substitution would
  # throw that away and hand an empty map to a comparison that then agrees with
  # itself. It has already printed which file and line it refused on.
  configured="$(gaia_cwf_overrides "$ws_file")" || return 2
  locked="$(gaia_cwf_overrides "$lock_file")" || return 2

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
    # One pass over both lists. The sibling suite pins these wordings
    # byte-identical, each by a presence assertion rather than only by an
    # absence: `FLOOR NOT APPLIED:`, `floor applied:`, `absent from the
    # lockfile`, `and locked at`, and `UNDECLARED OVERRIDE`.
    local report flag line
    report="$(awk -F'\t' '
      # LOAD-BEARING, despite looking like a redundant guard against something
      # the parser already refuses. Each list arrives through `printf %s\n` on a
      # shell variable, so an EMPTY list arrives as ONE BLANK LINE rather than as
      # no input at all, and this is the term that drops it. Delete it and a
      # workspace or lockfile declaring no overrides emits a phantom row naming
      # a package that does not exist, at an unchanged exit status, which is how
      # a suite watching only the status stays green over it. Pinned by fixture.
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
    # `type == "object"` and `has("advisories")` are declared defence rather
    # than load-bearing terms, and no fixture can pin them: every payload they
    # would reject already makes `jq` exit non-zero on `has` itself, so the
    # gate closes either way. They are kept so the rule reads as the rule, and
    # so a future `jq` that stops erroring on those inputs does not open the
    # gate. `(has("error") | not)` IS load-bearing and test 24 pins it.
    if ! printf '%s' "$audit_json" \
      | jq -e 'type == "object" and has("advisories") and (has("error") | not)' >/dev/null 2>&1; then
      printf 'advisory arm: pnpm audit could not be read; this closure was NOT audited\n'
      return "$rc"
    fi
    # Every entry must carry all three fields the extraction below reads, not
    # only the two it selects on: an entry missing `title` passes a two-field
    # gate and then interpolates the literal `null` into the advisory line. An
    # entry schema this reader does not know filters to nothing and would
    # otherwise print the clean line, which is the container-level false clean
    # repeated one level down. An empty `advisories` object passes and is
    # correct: that is a scan that ran and found nothing.
    # As above, `(.advisories | type) == "object"` and the per-entry
    # `type == "object"` are declared defence that no payload can falsify,
    # because `to_entries` errors first. The three `has(...)` terms beside them
    # are load-bearing and each has its own isolating fixture.
    if ! printf '%s' "$audit_json" | jq -e '
      (.advisories | type) == "object"
      and (.advisories | to_entries | all(.value
        | (type == "object")
          and has("severity") and has("module_name") and has("title")))' >/dev/null 2>&1; then
      printf 'advisory arm: pnpm audit named advisories in a shape this reader cannot read; this closure was NOT audited\n'
      return "$rc"
    fi
    advisories="$(printf '%s' "$audit_json" | jq -r '
      .advisories | to_entries[]
      | select(.value.severity == "high" or .value.severity == "critical")
      | "\(.value.severity)\t\(.value.module_name)\t\(.value.title)"' 2>/dev/null)"
    if [ -z "$advisories" ]; then
      # Cross-check the report's own second statement of the same fact before
      # printing the most reassuring line this file can print. A count above
      # zero with nothing parsed means the report names findings this reader
      # did not see, which is what a future shape that moves them out of
      # `advisories` while leaving the empty key behind looks like from here.
      # Only a report that ITSELF states zero earns the clean line. The counts
      # are read without a `// 0` default on purpose: a default supplies the
      # very zero the report was supposed to state, so an absent `metadata`, an
      # absent count, or a `false` (which `//` also replaces) would buy the
      # clean line by saying nothing. Everything else is one fact from here --
      # a count above zero, a count in a type this reader does not know, a
      # `metadata` shape `jq` cannot index, or `jq` failing outright -- namely
      # that the report said something this reader did not read.
      declared="$(printf '%s' "$audit_json" | jq -r '
        [(.metadata?.vulnerabilities?.high), (.metadata?.vulnerabilities?.critical)]
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
