#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted printf format strings where any
# $ or backtick is literal output text, not a shell expansion.
# shellcheck disable=SC2016
# verify-audit-roster.sh: the Code Audit Team roster's deterministic check.
#
# The roster is meant to grow, by adopters and by the maintainer, as a project
# adds languages and surfaces. Its silent failure modes, each made loud here:
#
#   * A forgotten machinery registration. Only files the machinery lists carry
#     land in every member's content digest, so an unlisted agent file rotates
#     no member's key and a change to it merges unaudited by the members it
#     should force.
#   * A glob overlap between two claimant members. Ownership is first-match-wins
#     over roster order, so an overlap hands a path to whichever member the
#     roster happens to list first, and stays invisible until someone adds a
#     file that lands in it.
#   * A member's own definition disagreeing with the roster about what it owns.
#     Claiming less makes a dispatched member self-skip work it was sent to do;
#     claiming more makes a file read as covered while dispatching nobody, so
#     the diff clears the merge gate having been reviewed by no one.
#
# Reads live state, never writes: no API write, no file write, no git mutation.
# One finding block per violation on stdout; exit 1 if any fired. `--emit-roster`
# is a read-only output mode the remit writer (write-audit-remits.sh) consumes
# to obtain the roster's raw globs.
#
# The invariants:
#
#   1. Pairwise claimant disjointness, as GLOB LANGUAGES, whether or not any
#      such file is tracked. An overlap names the pair and cites a witness path
#      that matches both globs, synthesized by construction from the two
#      patterns rather than searched for in a file list: the file need not
#      exist, which is the whole point of the invariant.
#   2. The default member is excluded from that comparison entirely. Its tier is
#      reached only after every claimant has failed to match, so an overlap
#      between the default and a claimant is what the precedence tier means, not
#      a defect.
#   3. A glob pair the bounded dialect cannot decide FAILS, naming the pair,
#      rather than passing. The check never fails open on the assertion it
#      exists to make.
#   4. Every roster member has an agent file on disk, registered in BOTH
#      machinery lists; exactly one member carries `default: true`.
#   5. Every roster member's name carries the `code-audit-` prefix. The local
#      self-heal hook (block-selfheal-paths.sh) binds a dispatched member to its
#      repair boundary by that prefix, not a roster lookup, so a member named
#      off-convention escapes the boundary silently. The prefix is already
#      load-bearing in the roster glob, the machinery lists, and the release
#      scrub's leak-check; this asserts it rather than assuming it.
#   6. Remit region parity. Every member's agent definition carries exactly one
#      balanced remit region, and the globs inside it are that member's roster
#      globs, complete and in roster order. A region that is absent, duplicated,
#      unbalanced, or reversed (its end marker appearing before its start
#      marker) fails; so does a roster glob the region omits, a region glob
#      the roster does not grant, and the same set in a different order, because
#      ownership is first-match-wins over roster order and a reordered region is
#      a different reading order. Every glob inside a region is classified by the
#      same bounded dialect as (3), which is why the default member's globs and a
#      lone claimant's are dialect-checked at all: the pairwise comparison in (1)
#      reaches neither position. The region's SENTENCE text is deliberately not
#      compared here; the writer (write-audit-remits.sh) owns the region's exact
#      form, and re-running it is the repair for every finding in this group.
#
# THE BOUNDED DIALECT, and why intersection is decidable over it at all. The
# classifier compiles three constructs (glob_to_regex, in the roster module
# sourced below):
#
#   literal  -> escaped literal   itself
#   *        -> [^/]*             any run within one segment, never crossing /
#   **       -> .*                anything, including /
#   **/      -> (.*/)?            any depth, INCLUDING zero segments
#
# Over that dialect a glob is a sequence of path segments, where each segment
# either matches exactly one path segment (a pattern of literals and single
# `*`s) or is a whole-segment `**` matching a run of segments: zero or more when
# a segment follows it, one or more when it ends the glob. Two such sequences
# intersect iff a product-automaton walk over segment positions reaches both
# ends, and the walk's own trace spells the witness. That is a bounded
# structural comparison, not general regex intersection.
#
# THE FRAGMENT THIS CHECK DECIDES, stated exactly, because a maintainer who
# teaches the classifier a new construct must teach it here too:
#
#   ACCEPTED: a glob whose `/`-separated segments are each either the whole
#   segment `**`, or a non-empty pattern of literal characters and single `*`s.
#   Every accepted pair is decided; there is no accepted-but-undecided case.
#
#   REJECTED as undecidable, never passed: an empty glob or an empty segment
#   (`a//b`, a leading or trailing `/`); any of ? [ ] { } or \, which a reader may
#   intend as wildcards and which the classifier silently escapes into literals;
#   `**` inside a segment rather than as a whole one (`app/**.ts`), whose
#   compiled form the segment model cannot represent; a run of three or more
#   `*`; whitespace, which the classifier's record contract cannot carry.
#
# Do not extend the dialect here, and do not make this checker cleverer than the
# classifier. The undecidable-pair failure is what makes a dialect drift loud
# instead of silent.
#
# DO NOT add `set -e` (matches verify-required-checks.sh): the loops below rely
# on grep and comparison exit status without aborting the script.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no
# `${var^^}`. Never `cd` outside the source-time lib resolution.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-audit-roster.sh [--root <dir>] [--config <file>] [--emit-roster]
  --root <dir>     repo root. Default: the repo holding this script.
                   Injection point for the machinery lists and the agent files.
  --config <file>  roster to verify. Default: <root>/.gaia/audit-ci.yml.
                   Injection point for the roster.
  --emit-roster    print the roster's raw member/glob/default records and
                   exit; read-only, runs no invariant.
  --help | -h      this text.

Exit codes:
  0  every invariant holds. With --emit-roster: always, once the roster parses.
  1  at least one invariant is violated (one finding block per violation).
  2  usage error.
USAGE
}

root=""
config=""
root_given=0
config_given=0
emit_roster=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --emit-roster)
      emit_roster=1
      shift
      ;;
    --root|--config)
      if [ $# -lt 2 ]; then
        printf 'verify-audit-roster: %s needs a value\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --root)   root="$2"; root_given=1 ;;
        --config) config="$2"; config_given=1 ;;
      esac
      shift 2
      ;;
    *)
      printf 'verify-audit-roster: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$root" ]; then
  printf 'verify-audit-roster: could not resolve the repo root (pass --root)\n' >&2
  exit 2
fi
[ -n "$config" ] || config="${root}/.gaia/audit-ci.yml"
if [ ! -f "$config" ]; then
  printf 'verify-audit-roster: roster not found: %s\n' "$config" >&2
  exit 2
fi

# Source the roster-parsing module from THIS script's own on-disk location,
# never cwd and never $root: it is code, and there is one copy of it.
# .gaia/scripts -> ../../.claude/hooks/lib. Note the asymmetry with the
# machinery lists below, which resolve under --root because they are data a
# fixture must be able to inject.
_self_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_lib_dir:-}" ] && [ -f "$_self_lib_dir/audit-scope.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_lib_dir/audit-scope.sh"
fi

if ! command -v _audit_scope_parse_auditors >/dev/null 2>&1; then
  printf 'verify-audit-roster: roster-parsing library unavailable\n' >&2
  exit 1
fi

findings=0

# --- The raw-glob reader -----------------------------------------------------
#
# The classifier emits COMPILED regexes; the disjointness decision and the
# witness both need the RAW globs, and a raw-glob record would be a field no
# router reads, carried by every consumer, to serve this one caller. So this
# reads the glob strings itself. It is a YAML list-item scrape, not a second
# classifier: it never compiles, never matches a path, and never decides an
# owner. The one question with a real answer, which member is the default,
# still comes from the module. The two readers are held in lockstep by the
# per-member glob-count comparison below, and drift between them fails loudly
# rather than producing a verdict neither reader stands behind.
#
# Emits, tab-separated so a glob may legally contain a space:
#   MEMBER <name>
#   RAW <name> <glob>

_verify_roster_read_globs() {
  awk '
    function unq(s) {
      if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
      if (s ~ /^'\''.*'\''$/) return substr(s, 2, length(s) - 2)
      return s
    }
    BEGIN { OFS = "\t"; in_auditors = 0; in_globs = 0; member = "" }
    {
      raw = $0
      if (raw ~ /^auditors[[:space:]]*:/) { in_auditors = 1; next }
      if (!in_auditors) next
      # Any other top-level key closes the block.
      if (raw ~ /^[A-Za-z_]/) { in_auditors = 0; in_globs = 0; next }
      # Blank lines and comments (the maintainer-only markers included) never
      # end a member or the block.
      if (raw ~ /^[[:space:]]*$/) next
      if (raw ~ /^[[:space:]]*#/) next
      if (raw ~ /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/) {
        in_globs = 0
        v = raw
        sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        member = unq(v)
        print "MEMBER", member
        next
      }
      if (raw ~ /^[[:space:]]+globs[[:space:]]*:/) { in_globs = 1; next }
      # Any other member-level scalar key ends the glob sublist.
      if (raw ~ /^[[:space:]]+[A-Za-z_]+[[:space:]]*:/) { in_globs = 0; next }
      if (in_globs && raw ~ /^[[:space:]]*-[[:space:]]+/) {
        g = raw
        sub(/^[[:space:]]*-[[:space:]]+/, "", g)
        sub(/[[:space:]]+#.*$/, "", g)
        sub(/^[[:space:]]+/, "", g); sub(/[[:space:]]+$/, "", g)
        g = unq(g)
        if (g != "") print "RAW", member, g
        next
      }
    }
  '
}

# --- The remit-region reader -------------------------------------------------
#
# Each member's agent definition carries one marker-delimited remit region, and
# the globs bulleted inside it are what the dispatched member filters its
# changed-file list against. This reads that region back so the parity invariant
# can compare it to the roster. Shape only: it never interprets a glob and never
# reads the region's sentence, which is the writer's to own.
#
# Emits, tab-separated so a glob may legally contain a space:
#   REGIONMISSING <name> <agent-rel>
#   REGIONDUP <name> <agent-rel> <nstart> <nend>
#   REGIONUNBALANCED <name> <agent-rel> <nstart> <nend>
#   REGIONREVERSED <name> <agent-rel> <start-line> <end-line>
#   REGIONOK <name>
#   REGION <name> <glob>

REMIT_START='<!-- gaia:audit-remit:start -->'
REMIT_END='<!-- gaia:audit-remit:end -->'

_verify_roster_read_regions() {
  # <root> <raw-records>
  local rr="$1" recs="$2" kind name agent_rel agent nstart nend start_line end_line
  while IFS=$'\t' read -r kind name; do
    [ "$kind" = "MEMBER" ] || continue
    [ -n "$name" ] || continue
    agent_rel=".claude/agents/${name}.md"
    agent="${rr}/${agent_rel}"
    # A member with no definition at all is already reported by the
    # missing-agent-file invariant above; a region finding piled on top of that
    # is noise, and every fixture that deletes an agent file depends on this.
    [ -f "$agent" ] || continue
    # grep -c prints 0 and exits 1 on no match, and this script carries no
    # `set -e`; the `|| true` says so rather than leaving it to be inferred.
    nstart="$(grep -cxF -- "$REMIT_START" "$agent" || true)"
    nend="$(grep -cxF -- "$REMIT_END" "$agent" || true)"
    if [ "$nstart" -eq 0 ] && [ "$nend" -eq 0 ]; then
      printf 'REGIONMISSING\t%s\t%s\n' "$name" "$agent_rel"
    elif [ "$nstart" -gt 1 ] || [ "$nend" -gt 1 ]; then
      printf 'REGIONDUP\t%s\t%s\t%s\t%s\n' "$name" "$agent_rel" "$nstart" "$nend"
    elif [ "$nstart" -ne "$nend" ]; then
      printf 'REGIONUNBALANCED\t%s\t%s\t%s\t%s\n' "$name" "$agent_rel" "$nstart" "$nend"
    else
      start_line="$(grep -nxF -- "$REMIT_START" "$agent" | cut -d: -f1)"
      end_line="$(grep -nxF -- "$REMIT_END" "$agent" | cut -d: -f1)"
      if [ "$start_line" -gt "$end_line" ]; then
        printf 'REGIONREVERSED\t%s\t%s\t%s\t%s\n' "$name" "$agent_rel" "$start_line" "$end_line"
      else
        printf 'REGIONOK\t%s\n' "$name"
        # A marker state machine over the file, capturing every `- ` + backtick
        # bullet strictly between the pair, in file order. A line between the
        # markers that is not a bullet (the blank line, the canonical sentence)
        # contributes nothing.
        awk -v s="$REMIT_START" -v e="$REMIT_END" -v m="$name" '
          BEGIN { OFS = "\t" }
          $0 == s { infl = 1; next }
          $0 == e { infl = 0; next }
          infl && match($0, /^- `.*`$/) { print "REGION", m, substr($0, 4, length($0) - 4) }
        ' "$agent"
      fi
    fi
  done < <(printf '%s\n' "$recs")
}

class_records="$(_audit_scope_parse_auditors < "$config")"
raw_records="$(_verify_roster_read_globs < "$config")"

# --- Read-only roster emit ---------------------------------------------------
#
# The writer (.gaia/scripts/write-audit-remits.sh) needs the roster's RAW globs
# to generate each member's remit region. This mode is how it gets them: the
# scrape above is deliberately a second, independent reader of the same YAML, and
# the roster-reader-drift invariant is exactly the comparison between it and the
# classifier, so the writer reuses this reader rather than adding a third. Still
# read-only: it prints and exits before any invariant runs, and writes nothing.
if [ "$emit_roster" -eq 1 ]; then
  printf '%s\n' "$raw_records"
  printf '%s\n' "$class_records" |
    awk '$1 == "DEFAULT" { printf "DEFAULT\t%s\n", $2 }'
  exit 0
fi

region_records="$(_verify_roster_read_regions "$root" "$raw_records")"

# --- Invariant: exactly one default member -----------------------------------

default_count="$(printf '%s\n' "$class_records" | awk '$1 == "DEFAULT" { n++ } END { print n + 0 }')"
if [ "$default_count" -ne 1 ]; then
  findings=$((findings + 1))
  printf 'verify-audit-roster: FAIL default-member-count\n'
  printf '  roster: %s\n' "$config"
  printf '  members carrying `default: true`: %s (expected exactly 1)\n' "$default_count"
  printf '  Ownership resolves in two tiers: every claimant first, then the one\n'
  printf '  default member. Zero defaults leaves every unclaimed path ownerless;\n'
  printf '  more than one makes the second tier ambiguous.\n'
  printf '\n'
fi

# --- Invariant: agent file present and registered in BOTH machinery lists ----
#
# Read both lists as TEXT under --root: that is what makes the invariant
# testable at all, since a fixture can then inject a missing entry without
# mutating the repo's real lists. This is LITERAL LIST MEMBERSHIP, deliberately
# not audit_path_is_machinery: the matcher answers "is this path machinery"
# (including via a `/**` prefix), while the invariant is "is this member's agent
# file registered". An unregistered agent file is the silent fail-open, and a
# prefix match would hide it.
#
# Extra entries in either list are fine. This walks the roster and asks whether
# each member is registered, never the reverse: an adopter's lists still name
# the agents the roster scrub removed, and that must not fail.

machinery_lib="${root}/.claude/hooks/lib/audit-machinery.sh"
gate_script="${root}/.gaia/scripts/audit-machinery-complete.sh"

_roster_list_lines() {
  # <file> <shell-variable-name>: the heredoc list assigned to that variable.
  [ -f "$1" ] || return 0
  awk -v v="$2" '
    index($0, v "=") == 1 { inlist = 1; next }
    inlist && $0 == "EOF" { inlist = 0; next }
    inlist { print }
  ' "$1"
}

machinery_list="$(_roster_list_lines "$machinery_lib" AUDIT_MACHINERY_PATHS)"
gate_list="$(_roster_list_lines "$gate_script" GATE_MACHINERY_FILES)"

_report_unreadable_list() {
  # <file> <variable-name>
  findings=$((findings + 1))
  printf 'verify-audit-roster: FAIL unreadable-machinery-list\n'
  printf '  list: %s\n' "$2"
  printf '  file: %s\n' "$1"
  printf '  The list is empty, or the file does not carry it, so no member can be\n'
  printf '  confirmed as registered. Failing rather than passing every member.\n'
  printf '\n'
}

[ -n "$machinery_list" ] || _report_unreadable_list "$machinery_lib" AUDIT_MACHINERY_PATHS
[ -n "$gate_list" ] || _report_unreadable_list "$gate_script" GATE_MACHINERY_FILES

_report_unregistered() {
  # <member> <agent-rel-path> <list-name> <list-file>
  findings=$((findings + 1))
  printf 'verify-audit-roster: FAIL unregistered-agent-file\n'
  printf '  member:       %s\n' "$1"
  printf '  agent file:   %s\n' "$2"
  printf '  missing from: %s (%s)\n' "$3" "$4"
  printf '  A member whose agent file is absent from a machinery list is a\n'
  printf '  fail-open: a change to that file rotates no digest, so it merges\n'
  printf '  unaudited by the members it should force. Add the path to the list.\n'
  printf '\n'
}

while IFS=$'\t' read -r kind name; do
  [ "$kind" = "MEMBER" ] || continue
  [ -n "$name" ] || continue
  case "$name" in
    code-audit-*) ;;
    *)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL member-name-convention\n'
      printf '  member:   %s\n' "$name"
      printf '  expected: a name beginning `code-audit-`\n'
      printf '  The local self-heal hook (.claude/hooks/block-selfheal-paths.sh)\n'
      printf '  binds a dispatched member to its repair boundary by the\n'
      printf '  `code-audit-` name prefix, not a roster lookup, so a member named\n'
      printf '  off-convention escapes the boundary silently. The prefix is\n'
      printf '  load-bearing here and in the machinery lists and the release\n'
      printf '  scrub; this makes it checked rather than assumed.\n'
      printf '\n'
      ;;
  esac
  agent_rel=".claude/agents/${name}.md"
  if [ ! -f "${root}/${agent_rel}" ]; then
    findings=$((findings + 1))
    printf 'verify-audit-roster: FAIL missing-agent-file\n'
    printf '  member:   %s\n' "$name"
    printf '  expected: %s\n' "${root}/${agent_rel}"
    printf '  The roster dispatches this member and the gate demands its\n'
    printf '  clearance, but its definition does not exist.\n'
    printf '\n'
  fi
  if [ -n "$machinery_list" ] && ! printf '%s\n' "$machinery_list" | grep -qxF -- "$agent_rel"; then
    _report_unregistered "$name" "$agent_rel" AUDIT_MACHINERY_PATHS "$machinery_lib"
  fi
  if [ -n "$gate_list" ] && ! printf '%s\n' "$gate_list" | grep -qxF -- "$agent_rel"; then
    _report_unregistered "$name" "$agent_rel" GATE_MACHINERY_FILES "$gate_script"
  fi
done < <(printf '%s\n' "$raw_records")

# --- Invariant: the remit region's SHAPE -------------------------------------
#
# Rendered here rather than in the awk pass below because these four say the
# region could not be read at all, so there is nothing for the parity comparison
# to compare. The writer refuses to repair a malformed pair, by design: it never
# deletes bytes outside a pair it can identify, so a human deletes the extra,
# unbalanced, or reversed markers first and re-runs it.

while IFS=$'\t' read -r kind name agent_rel nstart nend; do
  case "$kind" in
    REGIONMISSING)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL missing-remit-region\n'
      printf '  member:     %s\n' "$name"
      printf '  agent file: %s\n' "$agent_rel"
      printf '  This definition carries no remit region, so nothing states which\n'
      printf '  files it owns in a form the roster can be compared against. The\n'
      printf '  region is never optional and deleting the markers is never an\n'
      printf '  escape from the parity it enforces.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONDUP)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL duplicate-remit-region\n'
      printf '  member:        %s\n' "$name"
      printf '  agent file:    %s\n' "$agent_rel"
      printf '  start markers: %s\n' "$nstart"
      printf '  end markers:   %s\n' "$nend"
      printf '  More than one remit region appears in this definition, so which\n'
      printf '  pair states the member remit is ambiguous: a reader and the\n'
      printf '  dispatched member could take different ones as authoritative.\n'
      printf '  The writer will not repair this, because collapsing the pairs\n'
      printf '  would delete bytes outside a region it can identify. Delete the\n'
      printf '  extra pair by hand, leaving exactly one, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONUNBALANCED)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL unbalanced-remit-region\n'
      printf '  member:        %s\n' "$name"
      printf '  agent file:    %s\n' "$agent_rel"
      printf '  start markers: %s\n' "$nstart"
      printf '  end markers:   %s\n' "$nend"
      printf '  The remit markers do not pair up, so where the region ends is\n'
      printf '  ambiguous: everything from the unclosed marker to the end of the\n'
      printf '  file reads as remit, or no region opens at all. The writer will\n'
      printf '  not repair this, because it never deletes bytes outside a pair it\n'
      printf '  can identify. Restore the missing marker by hand, leaving exactly\n'
      printf '  one balanced pair, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REGIONREVERSED)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL reversed-remit-region\n'
      printf '  member:      %s\n' "$name"
      printf '  agent file:  %s\n' "$agent_rel"
      printf '  start line:  %s\n' "$nstart"
      printf '  end line:    %s\n' "$nend"
      printf '  The end marker appears before the start marker, so nothing marks\n'
      printf '  where the region actually begins and ends in file order. The\n'
      printf '  writer will not repair this, because it never deletes bytes\n'
      printf '  outside a pair it can identify. Fix the marker order by hand,\n'
      printf '  leaving the start marker first, then re-run the repair.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
  esac
done < <(printf '%s\n' "$region_records")

# --- Invariants: pairwise claimant disjointness, and undecidable pairs -------
#
# The decision and the witness synthesis live in one awk pass, which is where
# the classifier's own glob compiler lives too. It reads both record streams,
# tab-normalized, and emits one machine-readable line per violation for the
# shell to verify and render.

pair_records="$(
  {
    printf '%s\n' "$class_records" |
      awk '{ k = $1; m = $2; r = $0; sub(/^[^ ]+[ ]+[^ ]+[ ]*/, "", r); printf "%s\t%s\t%s\n", k, m, r }'
    printf '%s\n' "$raw_records"
    printf '%s\n' "$region_records"
  } | awk -F'\t' '
    # --- The segment-pattern layer -------------------------------------------
    #
    # A segment pattern is literals and single `*`s, and matches exactly one
    # path segment. pat_matches is the classic two-pointer wildcard match.

    function pat_matches(p, s,   i, j, star, mark, lp, ls, c) {
      lp = length(p); ls = length(s)
      i = 1; j = 1; star = 0; mark = 0
      while (j <= ls) {
        c = (i <= lp) ? substr(p, i, 1) : ""
        if (c != "" && c != "*" && c == substr(s, j, 1)) { i++; j++ }
        else if (c == "*") { star = i; mark = j; i++ }
        else if (star) { i = star + 1; mark++; j = mark }
        else return 0
      }
      while (i <= lp && substr(p, i, 1) == "*") i++
      return (i > lp)
    }

    function cpush(ni, nj, pi, pj, c) {
      if ((ni, nj) in CR) return
      CR[ni, nj] = 1; CPI[ni, nj] = pi; CPJ[ni, nj] = pj; CPC[ni, nj] = c
    }

    # Decides two segment patterns and returns a NON-EMPTY string both match, or
    # "" for none. A path segment is never empty, so "" is an unambiguous
    # sentinel. Product-automaton reachability over character positions: `*`
    # contributes an epsilon (it may match zero chars) plus a self-loop on any
    # char; a literal contributes one edge. The (any, any) combination is
    # skipped because it returns to the same state, so dropping it loses no
    # reachable state, only witness padding. Every remaining edge advances
    # i + j, so one forward pass suffices and the walk cannot cycle.
    function seg_witness(p, q,   key, kp, kq, i, j, pc, qc, k, np, w, cand) {
      key = p SUBSEP q
      if (key in SWC) return SWC[key]
      kp = length(p); kq = length(q)
      split("", CR); split("", CPI); split("", CPJ); split("", CPC)
      CR[0, 0] = 1
      for (i = 0; i <= kp; i++) {
        for (j = 0; j <= kq; j++) {
          if (!((i, j) in CR)) continue
          pc = (i < kp) ? substr(p, i + 1, 1) : ""
          qc = (j < kq) ? substr(q, j + 1, 1) : ""
          if (pc == "*") cpush(i + 1, j, i, j, "")
          if (qc == "*") cpush(i, j + 1, i, j, "")
          if (pc == "" || qc == "") continue
          if (pc != "*" && qc != "*") { if (pc == qc) cpush(i + 1, j + 1, i, j, pc) }
          else if (pc == "*" && qc != "*") cpush(i, j + 1, i, j, qc)
          else if (qc == "*" && pc != "*") cpush(i + 1, j, i, j, pc)
        }
      }
      if (!((kp, kq) in CR)) { SWC[key] = ""; return "" }
      split("", CWP)
      i = kp; j = kq; np = 0
      while (i != 0 || j != 0) {
        if (CPC[i, j] != "") { np++; CWP[np] = CPC[i, j] }
        k = CPI[i, j]; j = CPJ[i, j]; i = k
      }
      w = ""
      for (k = np; k >= 1; k--) w = w CWP[k]
      # Reaching the end on epsilons alone means both patterns match "", which
      # only the all-star pattern `*` does. A path segment is never empty, so
      # take the one-character witness instead.
      if (w == "") w = "x"
      # Cosmetic, and verified rather than assumed: a leading `*` that collapsed
      # to nothing reads as a dotfile ("witness: .sh"), sending a human looking
      # for a file that was never the point. Pad it when both patterns still
      # match the padded form.
      if (substr(w, 1, 1) == "." && (substr(p, 1, 1) == "*" || substr(q, 1, 1) == "*")) {
        cand = "x" w
        if (pat_matches(p, cand) && pat_matches(q, cand)) w = cand
      }
      SWC[key] = w
      return w
    }

    # --- The glob layer ------------------------------------------------------
    #
    # Splits a glob into items: "**" (a whole-segment globstar) or a segment
    # pattern. Returns the item count, or -1 with REJ naming why the pair is
    # undecidable. Everything rejected here is either a construct the classifier
    # silently escapes into a literal or a shape the segment model cannot
    # represent; deciding either would be the fail-open this check exists to
    # delete.
    function glob_items(g, arr,   n, i, s) {
      REJ = ""
      if (g == "") { REJ = "the glob is empty"; return -1 }
      if (index(g, " ") || index(g, "\t")) { REJ = "the glob contains whitespace, which the classifier record contract cannot carry"; return -1 }
      if (index(g, "?")) { REJ = "the glob contains `?`, which the classifier escapes into a literal"; return -1 }
      if (index(g, "[") || index(g, "]")) { REJ = "the glob contains a bracket, which the classifier escapes into a literal"; return -1 }
      if (index(g, "{") || index(g, "}")) { REJ = "the glob contains a brace, which the classifier escapes into a literal"; return -1 }
      if (index(g, "\\")) { REJ = "the glob contains a backslash, which the classifier escapes into a literal"; return -1 }
      if (index(g, "***")) { REJ = "the glob contains a run of three or more `*`"; return -1 }
      n = split(g, arr, "/")
      for (i = 1; i <= n; i++) {
        s = arr[i]
        if (s == "") { REJ = "the glob has an empty path segment"; return -1 }
        if (s == "**") continue
        if (index(s, "**")) { REJ = "`**` appears inside the segment \"" s "\" rather than as a whole segment"; return -1 }
      }
      return n
    }

    function spush(ni, nj, pi, pj, w) {
      if ((ni, nj) in R) return
      R[ni, nj] = 1; PI[ni, nj] = pi; PJ[ni, nj] = pj; PW[ni, nj] = w
    }

    # One state of the segment-level product walk. A non-terminal globstar is
    # zero-or-more segments (an epsilon plus a self-loop); a terminal one is
    # one-or-more (a self-loop plus an exit edge), because `**/` compiles to
    # (.*/)? while a trailing `**` compiles to `.*` behind a literal `/`. A
    # plain segment is exactly one segment. As one level down, the two-globstar
    # self-loop is the only combination that returns to (i, j) and is skipped.
    function relax(i, j, na, nb,   ka, kb, ni, nj, w, nao, nbo) {
      if (i < na && IA[i + 1] == "**" && (i + 1) < na) spush(i + 1, j, i, j, "")
      if (j < nb && IB[j + 1] == "**" && (j + 1) < nb) spush(i, j + 1, i, j, "")
      nao = 0
      if (i < na) {
        if (IA[i + 1] == "**") {
          nao++; AOT[nao] = i; AOP[nao] = "*"
          if ((i + 1) == na) { nao++; AOT[nao] = i + 1; AOP[nao] = "*" }
        } else { nao++; AOT[nao] = i + 1; AOP[nao] = IA[i + 1] }
      }
      nbo = 0
      if (j < nb) {
        if (IB[j + 1] == "**") {
          nbo++; BOT[nbo] = j; BOP[nbo] = "*"
          if ((j + 1) == nb) { nbo++; BOT[nbo] = j + 1; BOP[nbo] = "*" }
        } else { nbo++; BOT[nbo] = j + 1; BOP[nbo] = IB[j + 1] }
      }
      for (ka = 1; ka <= nao; ka++) {
        for (kb = 1; kb <= nbo; kb++) {
          ni = AOT[ka]; nj = BOT[kb]
          if (ni == i && nj == j) continue
          w = seg_witness(AOP[ka], BOP[kb])
          if (w != "") spush(ni, nj, i, j, w)
        }
      }
    }

    # 1 iff the two item sequences share a path, with WITNESS spelling one.
    function seg_dp(na, nb,   i, j, k, np) {
      split("", R); split("", PI); split("", PJ); split("", PW)
      R[0, 0] = 1
      for (i = 0; i <= na; i++) {
        for (j = 0; j <= nb; j++) {
          if ((i, j) in R) relax(i, j, na, nb)
        }
      }
      if (!((na, nb) in R)) return 0
      split("", WP)
      i = na; j = nb; np = 0
      while (i != 0 || j != 0) {
        if (PW[i, j] != "") { np++; WP[np] = PW[i, j] }
        k = PI[i, j]; j = PJ[i, j]; i = k
      }
      WITNESS = ""
      for (k = np; k >= 1; k--) {
        if (WITNESS == "") WITNESS = WP[k]
        else WITNESS = WITNESS "/" WP[k]
      }
      return 1
    }

    # Sets DEC to OVERLAP / DISJOINT / UNDECIDABLE; WITNESS on OVERLAP, DREASON
    # on UNDECIDABLE.
    function decide(g, h,   na, nb) {
      DEC = ""; WITNESS = ""; DREASON = ""
      na = glob_items(g, IA)
      if (na < 0) { DEC = "UNDECIDABLE"; DREASON = REJ " (glob: " g ")"; return }
      nb = glob_items(h, IB)
      if (nb < 0) { DEC = "UNDECIDABLE"; DREASON = REJ " (glob: " h ")"; return }
      DEC = seg_dp(na, nb) ? "OVERLAP" : "DISJOINT"
    }

    $1 == "DEFAULT" { isdef[$2] = 1; next }
    $1 == "GLOB" || $1 == "DEFAULTGLOB" { nrx[$2]++; rx[$2, nrx[$2]] = $3; next }
    $1 == "MEMBER" { nm++; mem[nm] = $2; next }
    $1 == "RAW" { nraw[$2]++; raw[$2, nraw[$2]] = $3; next }
    # An exact field compare, so REGIONOK / REGIONMISSING / REGIONDUP /
    # REGIONUNBALANCED / REGIONREVERSED never match the REGION handler. These
    # four shape records fall through every handler here and are ignored,
    # which is right: they are rendered shell-side, and a member whose region
    # could not be read carries no hasreg entry, so the parity section below
    # skips it.
    $1 == "REGIONOK" { hasreg[$2] = 1; next }
    $1 == "REGION" { nreg[$2]++; reg[$2, nreg[$2]] = $3; next }

    END {
      # The scrape and the classifier agree about how many globs each member
      # declares, or neither the regexes nor the raw globs below line up and no
      # verdict is produced at all.
      drift = 0
      for (i = 1; i <= nm; i++) {
        m = mem[i]
        if (m in seenmm) continue
        seenmm[m] = 1
        if ((nraw[m] + 0) != (nrx[m] + 0)) {
          printf "MISMATCH\t%s\t%d\t%d\n", m, nraw[m] + 0, nrx[m] + 0
          drift = 1
        }
      }
      if (drift) exit 0
      nc = 0
      for (i = 1; i <= nm; i++) {
        m = mem[i]
        if (m in isdef) continue
        if (m in seencl) continue
        seencl[m] = 1
        nc++; cl[nc] = m
      }
      for (a = 1; a <= nc; a++) {
        for (b = a + 1; b <= nc; b++) {
          pa = cl[a]; pb = cl[b]
          repov = 0; repun = 0
          for (x = 1; x <= (nraw[pa] + 0) && !(repov && repun); x++) {
            for (y = 1; y <= (nraw[pb] + 0) && !(repov && repun); y++) {
              decide(raw[pa, x], raw[pb, y])
              if (DEC == "UNDECIDABLE" && !repun) {
                printf "UNDECIDABLE\t%s\t%s\t%s\t%s\t%s\n", pa, raw[pa, x], pb, raw[pb, y], DREASON
                repun = 1
              } else if (DEC == "OVERLAP" && !repov) {
                printf "OVERLAP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pa, raw[pa, x], rx[pa, x], pb, raw[pb, y], rx[pb, y], WITNESS
                repov = 1
              }
            }
          }
        }
      }

      # --- Remit region parity, and the region-glob dialect -------------------
      #
      # Parity is an ORDERED string comparison between a member remit region and
      # its roster entry; it needs no glob-language decision and never touches
      # the pairwise walk above. The dialect classification does need one, and it
      # reuses glob_items() rather than a second copy of it. That reuse is also
      # why every region glob of the DEFAULT member and of a lone claimant is
      # classified here: both are positions the pairwise invariant never reaches,
      # and a lone claimant plus a default is the whole adopter roster shape.
      #
      # Membership is a nested string comparison over lists of at most a dozen
      # globs. A hash keyed on the glob string would have to handle SUBSEP
      # collisions to be correct; the nested loop is clearer and fast enough.
      split("", seenrm)
      for (i = 1; i <= nm; i++) {
        m = mem[i]
        if (m in seenrm) continue
        seenrm[m] = 1
        if (!(m in hasreg)) continue
        for (k = 1; k <= (nreg[m] + 0); k++) {
          if (glob_items(reg[m, k], IR) < 0)
            printf "REMITUNDECIDABLE\t%s\t%s\t%s\n", m, reg[m, k], REJ
        }
        nmiss = 0; nextra = 0
        for (x = 1; x <= (nraw[m] + 0); x++) {
          hit = 0
          for (y = 1; y <= (nreg[m] + 0); y++) if (raw[m, x] == reg[m, y]) { hit = 1; break }
          if (!hit) { printf "REMITMISSING\t%s\t%s\n", m, raw[m, x]; nmiss++ }
        }
        for (y = 1; y <= (nreg[m] + 0); y++) {
          hit = 0
          for (x = 1; x <= (nraw[m] + 0); x++) if (reg[m, y] == raw[m, x]) { hit = 1; break }
          if (!hit) { printf "REMITEXTRA\t%s\t%s\n", m, reg[m, y]; nextra++ }
        }
        # Order is only meaningful once the two lists hold the same globs; a
        # set comparison must never pass a permuted region, so the first
        # differing position is reported.
        if (nmiss == 0 && nextra == 0 && (nreg[m] + 0) == (nraw[m] + 0)) {
          for (p = 1; p <= (nraw[m] + 0); p++) {
            if (raw[m, p] != reg[m, p]) {
              printf "REMITORDER\t%s\t%d\t%s\t%s\n", m, p, raw[m, p], reg[m, p]
              break
            }
          }
        }
      }
    }
  '
)"

while IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7; do
  case "$kind" in
    MISMATCH)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL roster-reader-drift\n'
      printf '  member: %s\n' "$f1"
      printf '  globs scraped by this check: %s; globs compiled by the classifier: %s\n' "$f2" "$f3"
      printf '  This check scrapes the raw globs while the classifier compiles\n'
      printf '  them, and the two disagree, so no disjointness verdict was\n'
      printf '  produced: one of the two readers has drifted from the roster\n'
      printf '  format. Fix that before trusting this check.\n'
      printf '\n'
      ;;
    UNDECIDABLE)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL undecidable-glob-pair\n'
      printf '  members: %s, %s\n' "$f1" "$f3"
      printf '  globs:   "%s" (%s)  vs  "%s" (%s)\n' "$f2" "$f1" "$f4" "$f3"
      printf '  reason:  %s\n' "$f5"
      printf '  This check decides the classifier three-construct dialect only:\n'
      printf '  literals, `*` within one segment, and a whole-segment `**`. It\n'
      printf '  fails an undecidable pair rather than passing it, because a pair\n'
      printf '  silently called disjoint is the fail-open it exists to catch.\n'
      printf '  Express the glob in the dialect, or teach the classifier and this\n'
      printf '  check the new construct together.\n'
      printf '\n'
      ;;
    OVERLAP)
      if [ -n "$f3" ] && [ -n "$f6" ] && [[ "$f7" =~ $f3 ]] && [[ "$f7" =~ $f6 ]]; then
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL claimant-glob-overlap\n'
        printf '  members: %s, %s\n' "$f1" "$f4"
        printf '  globs:   "%s" (%s)  vs  "%s" (%s)\n' "$f2" "$f1" "$f5" "$f4"
        printf '  witness: %s\n' "$f7"
        printf '  Two claimant members must not claim the same path. The witness\n'
        printf '  is synthesized from the two globs and matches both; no such file\n'
        printf '  need exist, which is exactly why the overlap stays invisible\n'
        printf '  until one does. Ownership is first-match-wins over roster order,\n'
        printf '  so the witness silently belongs to whichever member is listed\n'
        printf '  first. Narrow one of the two globs.\n'
        printf '\n'
      else
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL unverifiable-witness\n'
        printf '  members: %s, %s\n' "$f1" "$f4"
        printf '  globs:   "%s" (%s)  vs  "%s" (%s)\n' "$f2" "$f1" "$f5" "$f4"
        printf '  synthesized witness: %s\n' "$f7"
        printf '  The pair decides as overlapping, but the witness does not match\n'
        printf '  both compiled globs, so the decision procedure and the compiler\n'
        printf '  disagree. That is a defect in this check; the pair is cleared by\n'
        printf '  neither verdict.\n'
        printf '\n'
      fi
      ;;
    REMITMISSING)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-missing\n'
      printf '  member:     %s\n' "$f1"
      printf '  glob:       %s\n' "$f2"
      printf '  roster:     %s\n' "$config"
      printf '  agent file: .claude/agents/%s.md\n' "$f1"
      printf '  The roster grants this member the glob above and its remit region\n'
      printf '  omits it, so the dispatched member filters the changed-file list\n'
      printf '  against a narrower remit than the one it was dispatched for and\n'
      printf '  self-skips work the gate sent it to do. The roster is the\n'
      printf '  authority; regenerate the region rather than editing the roster\n'
      printf '  down to fit it.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITEXTRA)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-ungranted\n'
      printf '  member:     %s\n' "$f1"
      printf '  glob:       %s\n' "$f2"
      printf '  roster:     %s\n' "$config"
      printf '  agent file: .claude/agents/%s.md\n' "$f1"
      printf '  This remit region claims a glob the roster does not grant this\n'
      printf '  member, so a file matching it reads as covered while dispatching\n'
      printf '  nobody: no clearance is ever demanded for it and the diff clears\n'
      printf '  the merge gate having been reviewed by no one. Regenerate the\n'
      printf '  region, or grant the glob in the roster if the claim is the\n'
      printf '  intended one.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITORDER)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-order\n'
      printf '  member:   %s\n' "$f1"
      printf '  position: %s\n' "$f2"
      printf '  roster:   %s\n' "$f3"
      printf '  region:   %s\n' "$f4"
      printf '  The region holds exactly the globs the roster grants, in a\n'
      printf '  different order. Ownership is first-match-wins over roster order,\n'
      printf '  so a reordered region is a different reading order and a path two\n'
      printf '  of its globs both match resolves differently than dispatch does.\n'
      printf '  Parity is ordered; it is never a set comparison.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITUNDECIDABLE)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL undecidable-remit-glob\n'
      printf '  member:  %s\n' "$f1"
      printf '  glob:    %s\n' "$f2"
      printf '  reason:  %s\n' "$f3"
      printf '  This check decides the classifier three-construct dialect only:\n'
      printf '  literals, `*` within one segment, and a whole-segment `**`. It\n'
      printf '  fails an undecidable glob rather than passing it, because a glob\n'
      printf '  silently called harmless is the fail-open it exists to catch.\n'
      printf '  Every glob inside a region is classified, the default member and\n'
      printf '  a lone claimant included, and neither is a position the pairwise\n'
      printf '  comparison ever reaches. Express the glob in the dialect, or\n'
      printf '  teach the classifier and this check the new construct together.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
  esac
done < <(printf '%s\n' "$pair_records")

# gaia:maintainer-only:start
# --- The built-in fallback lockstep ------------------------------------------
#
# Structurally separate from the invariants above -- pairwise disjointness, the
# default member's exclusion from it, the undecidable-pair failure, machinery
# registration and the single default, the member-name convention, and remit
# region parity -- and maintainer-only: the classifier's built-in roster is
# consulted only when the config yields no records, which on an adopter machine
# does not happen, so the assertion is dead code there.
#
# It compares the fallback to THE SHIPPED ROSTER, so it runs only on a run that
# resolves both inputs by default. Every fixture roster differs from the
# fallback by construction, which is what makes it a fixture; without this gate
# the lockstep would fire on every injected run and every other invariant's test
# would fail for a reason that has nothing to do with the invariant under test.
if [ "$config_given" -eq 0 ] && [ "$root_given" -eq 0 ]; then
  builtin_records="$(_audit_scope_builtin_roster | _audit_scope_parse_auditors)"
  if [ "$builtin_records" != "$class_records" ]; then
    findings=$((findings + 1))
    printf 'verify-audit-roster: FAIL builtin-fallback-lockstep\n'
    printf '  roster:   %s\n' "$config"
    printf '  fallback: _audit_scope_builtin_roster in %s\n' "${_self_lib_dir:-<unresolved>}/audit-scope.sh"
    printf '  The fallback roster does not compile to the same records as the\n'
    printf '  shipped one. A glob the config carries and the fallback misses\n'
    printf '  leaves that path ownerless whenever the config cannot be read, so\n'
    printf '  the gate dispatches nobody for a change to it. Records only the\n'
    printf '  fallback carries are prefixed `<`, records only the roster carries\n'
    printf '  are prefixed `>`:\n'
    diff <(printf '%s\n' "$builtin_records") <(printf '%s\n' "$class_records") |
      grep -E '^[<>]' | sed 's/^/    /'
    printf '\n'
  fi
fi
# gaia:maintainer-only:end

if [ "$findings" -gt 0 ]; then
  printf 'verify-audit-roster: %d invariant violation(s).\n' "$findings"
  exit 1
fi

printf 'verify-audit-roster: roster clean (%s).\n' "$config"
exit 0
