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
#   <key><TAB><value> lines, sorted. Prints nothing when the file declares no
#   overrides block. Returns 2, having said why, when the file cannot be read.
#
#   THIS READS WITH js-yaml, THE LIBRARY THAT WROTE THE FILE, and that is the
#   whole point rather than a convenience. pnpm serializes pnpm-lock.yaml with
#   js-yaml, which is verifiable: dumping an overrides map through the copy in
#   .gaia/cli/node_modules reproduces the live lockfile block byte-identically,
#   quoting included. Reading it back with the same library makes the question
#   "does this reader know that YAML shape" disappear rather than moving it.
#
#   It replaced a hand-rolled awk recognizer, and the reason is measured, not
#   stylistic: six consecutive audit rounds each found the recognizer reading a
#   different legal shape wrong, and every one of them printed a verdict rather
#   than refusing. Key termination, a comment tail folded into a version, the
#   line between plain and quoted scalars, an annotated block header, and then
#   three more spellings of that same header, each of which js-yaml reads
#   correctly and the recognizer reported clean over an unapplied floor. Fixing
#   a spelling produced the next spelling; that is what says the instrument was
#   wrong rather than any one of its readings.
#
#   FAILSAFE_SCHEMA, not the default. Under the default schema `1.10` loads as
#   the number 1.1, and the report would then print a version the file does not
#   contain. The failsafe schema resolves every scalar as a string, which is
#   what a version specifier is.
#
#   NO SILENT DEGRADATION. If node or js-yaml is missing this returns 2 and says
#   so; it never falls back to a weaker reader, because a weaker reader is
#   exactly what the six rounds above were about.
gaia_cwf_overrides() {
  local file="$1" out

  [ -n "$GAIA_CWF_NODE" ] || return 3
  out="$(
    "$GAIA_CWF_NODE" -e '
      const path = process.argv[1];
      const yamlDir = process.argv[2];
      const fs = require("fs");
      const yaml = require(yamlDir);
      let doc;
      try {
        doc = yaml.load(fs.readFileSync(path, "utf8"), { schema: yaml.FAILSAFE_SCHEMA });
      } catch (e) {
        process.stderr.write("check-cli-workspace-floors: " + path + " is not readable as YAML: " + e.message + "\n");
        process.exit(2);
      }
      if (doc === null || doc === undefined) process.exit(0);
      if (typeof doc !== "object" || Array.isArray(doc)) {
        process.stderr.write("check-cli-workspace-floors: " + path + " is not a YAML mapping\n");
        process.exit(2);
      }
      if (!Object.prototype.hasOwnProperty.call(doc, "overrides")) process.exit(0);
      const ov = doc.overrides;
      // A declared block that is empty, or that is not a mapping of scalars, is
      // refused rather than reported as no floors. Empty compared against empty
      // agrees, and that agreement is the false clean this check exists to
      // prevent.
      if (ov === null) {
        process.stderr.write("check-cli-workspace-floors: " + path + " declares an overrides block yielding no entries\n");
        process.exit(2);
      }
      if (typeof ov !== "object" || Array.isArray(ov)) {
        process.stderr.write("check-cli-workspace-floors: " + path + " declares an overrides block that is not a mapping\n");
        process.exit(2);
      }
      const keys = Object.keys(ov);
      if (keys.length === 0) {
        process.stderr.write("check-cli-workspace-floors: " + path + " declares an overrides block yielding no entries\n");
        process.exit(2);
      }
      const lines = [];
      for (const k of keys) {
        const v = ov[k];
        if (typeof v !== "string") {
          process.stderr.write("check-cli-workspace-floors: " + path + " maps " + k + " to a value that is not a scalar\n");
          process.exit(2);
        }
        if (k.indexOf("\t") !== -1 || v.indexOf("\t") !== -1) {
          process.stderr.write("check-cli-workspace-floors: " + path + " has a tab inside an override key or value\n");
          process.exit(2);
        }
        lines.push(k + "\t" + v);
      }
      process.stdout.write(lines.join("\n") + "\n");
    ' "$file" "$GAIA_CWF_JSYAML"
  )" || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sort
}

# gaia_cwf_resolve_reader
#   Set GAIA_CWF_NODE and GAIA_CWF_JSYAML, or return 2 saying what is missing.
#   js-yaml is resolved from THIS REPOSITORY's own .gaia/cli workspace rather
#   than from the root under check, because the root under check is an argument
#   and may legitimately be a fixture with no node_modules of its own.
gaia_cwf_resolve_reader() {
  GAIA_CWF_NODE=""
  GAIA_CWF_JSYAML=""
  command -v node >/dev/null 2>&1 || {
    printf 'check-cli-workspace-floors: node is required to read these files and was not found on PATH\n' >&2
    return 2
  }
  local candidate="$SELF_DIR/../cli/node_modules/js-yaml"
  [ -d "$candidate" ] || {
    printf 'check-cli-workspace-floors: js-yaml was not found at %s; run pnpm -C .gaia/cli install first\n' \
      "$candidate" >&2
    return 2
  }
  GAIA_CWF_NODE="$(command -v node)"
  GAIA_CWF_JSYAML="$(cd "$candidate" && pwd)"
  return 0
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
  # Resolved once, before either file is read, so a missing reader is reported
  # as a missing reader rather than twice as an unreadable file.
  gaia_cwf_resolve_reader || return 2

  # THE STATUS IS LOAD-BEARING, and it is the only path a refusal takes. Every
  # refusal, an unparseable file, a declared block that is not a mapping, a
  # declared block yielding no entries, is raised inside gaia_cwf_overrides, so
  # a bare command substitution here would discard all of them and hand an empty
  # map to a comparison that agrees with itself. The reader has already named
  # the file and said what it could not read.
  configured="$(gaia_cwf_overrides "$ws_file")" || return 2
  locked="$(gaia_cwf_overrides "$lock_file")" || return 2

  # An empty map here means one thing only: the file declared no overrides block
  # at all. A block that IS declared and yields no entries never reaches this
  # point, because the reader refuses it rather than returning an empty map that
  # empty would agree with. That refusal used to live out here as a separate
  # `grep -q` over the same files, which is two readers of one fact, and they
  # disagreed: a UTF-8 BOM defeated the parse and the grep differently on macOS
  # and on the GNU grep the runner uses, so the gate reported clean in CI over a
  # workspace it had never read. One reader cannot disagree with itself.
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
