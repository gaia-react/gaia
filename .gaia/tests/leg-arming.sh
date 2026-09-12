#!/usr/bin/env bash
# leg-arming.sh: whether one leg of .github/workflows/audit-ci-tests.yml's
# `shards` matrix should run its `code:`-gated steps for this pull request's
# changed files. Prints exactly `true` or `false`.
#
# That job's arming step calls this once per leg and copies the literal into
# $GITHUB_OUTPUT; each per-leg `code:`-gated step then carries the answer as an
# ADDITIONAL conjunct beside its paths-filter conjunct, never instead of it. The
# workflow's guard suite (.gaia/tests/lib/audit-ci-shards.bats) drives this file
# offline, per leg and per narrowable page, and compares the answers against a
# recomputation of its own, so this file is the declared side of that
# comparison.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
#
# Usage:
#   bash .gaia/tests/leg-arming.sh            # the arming answer, `true` or `false`
#   bash .gaia/tests/leg-arming.sh class      # the narrowable class, one path per line
#   bash .gaia/tests/leg-arming.sh -h | --help
#
# Inputs, all through the environment; no argument carries data:
#   GITHUB_EVENT_NAME   `workflow_dispatch` arms unconditionally.
#   CHANGED_FILES_JSON  the JSON array the paths-filter step exposes as
#                       `code_files` under `list-files: json`. A contributor
#                       picks those names, so the list is hostile input. The
#                       workflow withholds an oversized list, so it arrives
#                       here as the empty string and arms through the
#                       empty-list rule below.
#   LEG_ID              the matrix leg being decided.
#   PR_CHANGED_FILES    github.event.pull_request.changed_files, a decimal.
#
# Seams, each independently overridable. A value beginning with `/` is used
# as-is; anything else resolves against the root, never against $PWD:
#   LEG_ARMING_ROOT             default: the checkout holding this file
#   LEG_ARMING_SHARDER          default: .gaia/tests/bats-shards.sh
#   LEG_ARMING_WORKFLOW         default: .github/workflows/audit-ci-tests.yml
#   LEG_ARMING_CONCURRENCY_DIR  default: .gaia/tests/concurrency
#   LEG_ARMING_CONCURRENCY_LEG  default: see its declaration below
# The sharder's own directory seams pass straight through the environment to
# it. A path it prints repo-relative is resolved against LEG_ARMING_ROOT, so a
# test tree either keeps the two roots equal or points every sharder seam at an
# absolute path. That tree also needs a stand-in at
# <root>/.gaia/tests/lib/audit-ci-shards.bats, listed through the sharder's lib
# seam, and a concurrency seam holding at least one suite: without either, the
# script cannot place a leg and every leg arms, so no answer in that tree could
# ever be `false`.
#
# Exit status: 0 on every path of the arming answer, degraded ones included.
# `class` exits 2, with nothing on stdout, when it cannot derive a non-empty
# class. Diagnostics go to stderr, and none carries a changed filename: they
# name a reason and a count.
#
# THE DIRECTION OF FAILURE IS THE DESIGN. Every `code:` entry exists because a
# suite's source was edited, the filter said false, and the job greened having
# run that suite zero times; a narrowing manufactures exactly that hazard. So
# anything this script cannot resolve arms the leg, and the answer is decided
# OUTSIDE the derivation: `decide` carries every rule and prints its answer, and
# the code at the bottom of this file replaces anything but the two literals
# with `true` before printing. No failure inside `decide` reaches the exit
# without passing that check.
#
# errexit is deliberately not relied on inside `decide`. Under
# `out="$(decide)" || ...` bash 3.2 honors a `set -e` the function sets and
# bash 5 ignores it, so the same failure would abort on one runner and run on
# into a wrong answer on the other. Every failure is an explicit status check.
#
# The rules run cheapest first, and classification runs before any sharder call
# or scan. The common case, a pull request touching code, therefore costs one
# pass over the list, and no changed filename ever reaches grep: every scan is
# keyed on the class member a changed path equals, and that string came from
# this repository's own workflow.
#
# The class is DERIVED, never checked in: the `wiki/` paths the `code:` filter
# names, read from the workflow text at run time with awk. Not with a YAML
# parser, because this runs before the step that installs PyYAML. The reader
# takes the paths-filter step in the order the workflow writes it, `uses:`
# before `with:`, and any shape it does not recognize is a derivation failure,
# which arms. The guard suite compares its answer against a real YAML parser's.
#
# The scan is a superset of the files that name a page literally: every suite
# the sharder discovers, the `helpers/`, `lib/` and `fixtures/` subtrees beside
# them, and the concurrency seam, matched by full path or bare basename, with no
# filter on the matched line. A `case` arm or a docblock line naming a page arms
# like a real read, because no rule telling them apart fails in a safe
# direction.
#
# One exception narrows it: A NAMER OF ALL IS A NAMER OF NONE. A file naming
# every member of the class tells no page from another, so it is excluded from
# every page's namer set. The exclusion is derived from the class at run time,
# with no threshold and no file named. With a single-member class every namer
# would be a namer of all, so the rule is inert there. THE ACCEPTED RISK: a
# suite that genuinely reads the content of every class member is excluded and
# does not arm. That is real under-arming. It is accepted because no such suite
# exists today, because the leg holding the derived check arms unconditionally
# regardless, and because every other rule here fails open. A related, smaller
# gap: a suite that drives a page-reading script without naming the page
# itself, in its own source, sits on a leg the gate may decline to arm.
#
# The rule also costs something in the safe direction, and that cost is
# accepted too. A path inventory written once into a fixtures/ subtree and
# never regenerated names the class pages that existed when it was written. It
# is a namer of all only until the class gains a page it does not name. After
# that it is a namer of every page it does name, and arms every shard holding a
# suite beside it for each of them, though it reads none. Every rule that would
# drop such a file tells one namer from another by a guess: a threshold, a
# classification of fixtures by shape, or a file named here. Each guess
# under-arms when it is wrong, and the scan takes an exception in that
# direction only where the class itself derives it, as it derives the
# namer-of-all rule. The over-arming is bounded by what the frozen inventory
# names: a page added later arms through it only when its full path or bare
# basename already occurs in one of its lines, the match every namer gets.
#
# It writes nothing to $GITHUB_OUTPUT, $GITHUB_ENV or $GITHUB_STEP_SUMMARY.
# Those files are line-oriented, a filename may carry a newline, and one echoed
# diagnostic would let a crafted name append its own record and disarm every
# leg on a green required check. The workflow step writes the literal this
# prints and nothing else.
#
# Portability: bash 3.2 safe, the contract bats-shards.sh states. No mapfile, no
# declare -A, no ${var^^}, no wait -n, no eval. Every array expansion is written
# ${arr[@]+"${arr[@]}"}, because on bash 3.2 an empty array expanded bare under
# `set -u` aborts, and here that would abort the derivation on exactly the
# input the fallback exists for. Every sort and grep runs under LC_ALL=C.

# The derived both-ways check lives in this suite, so the leg holding it always
# arms: a rename or deletion of a narrowable page whose namers sit elsewhere
# must not skip the check that pins the map the edit invalidates. The shard
# holding it is asked of the sharder, never named here.
CHECK_SUITE_REL='.gaia/tests/lib/audit-ci-shards.bats'

# GitHub's pulls.listFiles endpoint stops listing at this many files, and the
# pinned paths-filter action paginates it without reconciling the total, so at
# or above this count the matched list may be short.
PAGINATION_CAP=3000

SHARDER_DEFAULT='.gaia/tests/bats-shards.sh'
WORKFLOW_DEFAULT='.github/workflows/audit-ci-tests.yml'
CONCURRENCY_DIR_DEFAULT='.gaia/tests/concurrency'

# The leg id the concurrency seam's suites resolve to. The sharder refuses this
# leg outright, so nothing else could turn a hit under that seam into a leg id
# to compare against LEG_ID. This default is a declared seam default, not a
# shard id used as a decision value, and it is the one declared exemption from
# the no-literal-shard-id check over this file.
CONCURRENCY_LEG_DEFAULT='concurrency'

NL='
'

note() {
  printf 'leg-arming: %s\n' "$*" >&2
}

usage() {
  printf 'Usage: bash .gaia/tests/leg-arming.sh\n'
  printf '       bash .gaia/tests/leg-arming.sh class\n'
  printf '       bash .gaia/tests/leg-arming.sh -h | --help\n'
  printf 'Inputs arrive through the environment; see the header of this file.\n'
}

# Only ever called inside `decide`, whose stdout is the answer.
arm() {
  note "arm: $1"
  printf 'true\n'
}

decline() {
  note "narrow: $1"
  printf 'false\n'
}

# The checkout holding this file, the bats-shards.sh idiom: derived from the
# script's own location, never from $PWD.
script_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  [ -n "$here" ] || return 1
  git -C "$here" rev-parse --show-toplevel 2>/dev/null
}

resolve_root() {
  local base=''
  case "${LEG_ARMING_ROOT:-}" in
    /*)
      printf '%s\n' "$LEG_ARMING_ROOT"
      return 0
      ;;
  esac
  base="$(script_root)" || return 1
  [ -n "$base" ] || return 1
  if [ -n "${LEG_ARMING_ROOT:-}" ]; then
    printf '%s\n' "$base/$LEG_ARMING_ROOT"
  else
    printf '%s\n' "$base"
  fi
}

# resolve_seam <root> <value>
resolve_seam() {
  case "$2" in
    /*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1/$2" ;;
  esac
}

# derive_class <workflow>
#
# The `wiki/` paths the one paths-filter step's `code:` list names, LC_ALL=C
# sorted and deduplicated, one per line. Returns non-zero, having said why on
# stderr, when the workflow is unreadable, holds other than exactly one
# paths-filter step, has no `code:` list inside that step's `filters:` block
# string, carries an entry this reader does not parse, or names no `wiki/`
# path at all.
#
# The `code:` list is a YAML document nested inside a block string, so its
# entries are read the way YAML reads them: a comment line never ends the list
# whatever its indent, a line indented at or below the `filters:` key ends the
# block string, and a non-comment line at or below the `code:` key's indent
# ends the list unless it is itself a `- ` entry, which is YAML's compact
# sequence form. Only a `- ` at the first entry's indent opens an entry: one
# indented deeper is either a continuation YAML folds into a plain entry above
# or a malformed list, never an entry of its own. An entry is a quoted
# or plain string, or a change-type mapping (`deleted: 'x'`) whose one inline
# value is the path. A multi-line entry, a `- ` line off the list's own indent,
# a flow collection, or an escape this reader does not decode is a failure
# rather than a guess.
derive_class() {
  local wf="$1" out rc=0
  if [ ! -f "$wf" ] || [ ! -r "$wf" ]; then
    note 'class: the workflow seam names no readable file'
    return 1
  fi
  out="$(LC_ALL=C awk '
    function ind(s) {
      match(s, /^ */)
      return RLENGTH
    }
    function bail(msg) {
      printf "leg-arming: class: %s (workflow line %d)\n", msg, NR > "/dev/stderr"
      failed = 1
      exit 3
    }
    function scalar(s,    q, i, n, c, v) {
      q = substr(s, 1, 1)
      n = length(s)
      if (q == sq || q == dq) {
        v = ""
        i = 2
        closed = 0
        while (i <= n) {
          c = substr(s, i, 1)
          if (q == sq && c == sq) {
            if (substr(s, i + 1, 1) == sq) {
              v = v sq
              i += 2
              continue
            }
            closed = 1
            break
          }
          if (q == dq && c == "\\") {
            c = substr(s, i + 1, 1)
            if (c != "\\" && c != dq) bail("a double-quoted code: entry carries an escape this reader does not decode")
            v = v c
            i += 2
            continue
          }
          if (q == dq && c == dq) {
            closed = 1
            break
          }
          v = v c
          i++
        }
        if (!closed) bail("an unterminated quoted code: entry")
        if (substr(s, i + 1) !~ /^[ \t]*(#.*)?$/) bail("text after the closing quote of a code: entry")
        return v
      }
      if (index(indicators, q) > 0 || s ~ /^[-?:]([ \t]|$)/) bail("a code: entry that is not a plain or quoted string")
      v = s
      sub(/[ \t]+#.*$/, "", v)
      sub(/[ \t]+$/, "", v)
      if (v == "" || v ~ /:([ \t]|$)/) bail("a code: entry that is not a plain or quoted string")
      return v
    }
    BEGIN {
      sq = sprintf("%c", 39)
      dq = "\""
      indicators = "*&!|>{}[]%@`#,"
      state = 0
      steps = 0
      failed = 0
      top = -1
      sind = -1
    }
    { sub(/\r$/, "") }
    /^[ \t]*(-[ \t]+)?uses:[ \t]*.?dorny\/paths-filter@/ { steps++ }
    state == 0 {
      if ($0 ~ /^[ \t]*(-[ \t]+)?uses:[ \t]*.?dorny\/paths-filter@/) {
        state = 1
        if (match($0, /^ *-[ \t]+/)) keyind = RLENGTH
        else keyind = ind($0)
      }
      next
    }
    state == 1 {
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      if (ind($0) < keyind) bail("the paths-filter step ends before a filters: block string")
      if ($0 ~ /^ *filters:[ \t]*[|][-+]?[ \t]*$/) {
        state = 2
        find = ind($0)
      }
      next
    }
    state == 2 {
      if ($0 ~ /^[ \t]*$/) next
      if (ind($0) <= find) bail("the filters: block string ends before a code: list")
      if ($0 ~ /^[ \t]*#/) next
      if (top < 0) top = ind($0)
      if (ind($0) == top && $0 ~ /^ *code:[ \t]*(#.*)?$/) {
        state = 3
        cind = top
      }
      next
    }
    state == 3 {
      if ($0 ~ /^[ \t]*$/) next
      if (ind($0) <= find) {
        state = 4
        next
      }
      if ($0 ~ /^[ \t]*#/) next
      if (ind($0) <= cind && $0 !~ /^ *-[ \t]/) {
        state = 4
        next
      }
      if ($0 !~ /^ *-([ \t]|$)/) bail("a line inside the code: list that is neither an entry nor a comment")
      if (sind < 0) sind = ind($0)
      else if (ind($0) != sind) bail("a - line off the entry indent of the code: list, which YAML reads as a multi-line entry or a malformed list, never as a new entry")
      s = $0
      sub(/^ *-[ \t]*/, "", s)
      if (s == "") bail("a code: entry with no inline value")
      c = substr(s, 1, 1)
      if (c != sq && c != dq) {
        kpos = 0
        if (match(s, /:([ \t]|$)/)) kpos = RSTART
        cpos = 0
        if (match(s, /[ \t]#/)) cpos = RSTART
        if (kpos > 0 && (cpos == 0 || kpos < cpos)) {
          key = substr(s, 1, kpos - 1)
          if (key !~ /^[A-Za-z|][A-Za-z| \t]*$/) bail("a code: mapping entry whose key is not a change-type list")
          s = substr(s, kpos + 1)
          sub(/^[ \t]+/, "", s)
          if (s == "" || s ~ /^#/) bail("a code: mapping entry with no inline value")
        }
      }
      v = scalar(s)
      if (index(v, "wiki/") == 1) print v
      next
    }
    END {
      if (failed) exit 3
      if (steps != 1) {
        printf "leg-arming: class: the workflow holds %d paths-filter steps, expected exactly one\n", steps > "/dev/stderr"
        exit 3
      }
      if (state < 3) {
        print "leg-arming: class: no code: list inside the paths-filter step" > "/dev/stderr"
        exit 3
      }
    }
  ' "$wf")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  if [ -z "$out" ]; then
    note 'class: the code: filter names no wiki/ path'
    return 1
  fi
  rc=0
  out="$(printf '%s\n' "$out" | LC_ALL=C sort -u)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    note "class: could not sort the derived class (exit $rc)"
    return 1
  fi
  printf '%s\n' "$out"
}

# line_in <needle> <newline-separated haystack>: exact whole-line membership,
# compared in the shell rather than handed to grep as a pattern.
line_in() {
  local needle="$1" l
  while IFS= read -r l || [ -n "$l" ]; do
    if [ "$l" = "$needle" ]; then
      return 0
    fi
  done <<EOF
$2
EOF
  return 1
}

is_sharder_id() {
  local s
  for s in ${shard_ids[@]+"${shard_ids[@]}"}; do
    if [ "$s" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

# grep_unit <files|tree> <target> <class-member>
#
# The files in one scan unit that name the member, by full path or bare
# basename, fixed-string. `files` takes a newline-separated list of suites;
# `tree` takes one directory, scanned recursively with no include filter.
# grep's exit 1 is a clean miss and prints nothing; any other non-zero exit is
# a hard error and returns 1, because an unreadable file must never read as
# "nothing here names the page".
grep_unit() {
  local kind="$1" target="$2" member="$3" base out f rc=0
  base="${member##*/}"
  if [ "$kind" = tree ]; then
    out="$(LC_ALL=C grep -rlF -e "$member" -e "$base" -- "$target")" || rc=$?
  else
    unit_files=()
    while IFS= read -r f || [ -n "$f" ]; do
      if [ -n "$f" ]; then
        unit_files+=("$f")
      fi
    done <<EOF
$target
EOF
    # grep handed no file operand reads stdin, which here is the empty
    # heredoc's end and would read as a clean miss.
    if [ "${#unit_files[@]}" -eq 0 ]; then
      note 'scan: a scan unit resolved no files'
      return 1
    fi
    out="$(LC_ALL=C grep -lF -e "$member" -e "$base" -- ${unit_files[@]+"${unit_files[@]}"})" || rc=$?
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    note "scan: grep failed (exit $rc)"
    return 1
  fi
  printf '%s' "$out"
}

# group_holds_leg <shard-id>: 0 when LEG_ID is in that id's exchange group, 1
# when it is not, 2 when the group cannot be resolved. The concurrency seam's
# leg is a group of one, because the sharder does not know it.
group_holds_leg() {
  local id="$1" grp g rc=0
  if [ "$id" = "$conc_leg" ] && ! is_sharder_id "$id"; then
    if [ "$id" = "$leg" ]; then
      return 0
    fi
    return 1
  fi
  grp="$(bash "$sharder" group "$id")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$grp" ]; then
    note "the sharder could not resolve shard $id's exchange group (exit $rc)"
    return 2
  fi
  while IFS= read -r g || [ -n "$g" ]; do
    if [ "$g" = "$leg" ]; then
      return 0
    fi
  done <<EOF
$grp
EOF
  return 1
}

# The whole decision. Runs in the command substitution at the bottom of this
# file, so the options it sets and the arrays it fills stay in that subshell.
# Prints exactly one literal on every path it controls; the caller treats any
# other outcome as `true`.
decide() {
  set -uo pipefail
  local rc token rec first complete path hit i j k u f id dir sub found any
  local excluded lst root sharder workflow conc_dir conc_leg leg class_out
  local shards_out listing abs abslist pcf zeros digits check_abs conc_bats
  local count

  # Rule 1, the dispatch lane: the self-heal lane, unconditional.
  if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
    arm 'workflow_dispatch is the self-heal lane, which runs every leg'
    return 0
  fi

  # A different condition from the dispatch lane above, and it says so
  # separately: there an empty list is the absence of the filter step, here it
  # means no list reached this step at all.
  if [ -z "${CHANGED_FILES_JSON:-}" ]; then
    arm 'CHANGED_FILES_JSON is empty off the dispatch lane: no changed-file list reached this step, so there is nothing to narrow against'
    return 0
  fi

  # Rule 2, parse. Python's json module, handed the list through its
  # environment, never through argv or a heredoc the shell would expand. It
  # emits a status token, then one NUL-terminated record per path, then an
  # empty record as the end marker. NUL is the one byte no path carries, so a
  # name holding a newline survives intact, and the end marker is what shows
  # the parser finished: a process substitution hides its exit status, so a
  # parser that died partway would otherwise read as a short list. Its stderr
  # is discarded because a traceback can quote the offending string; the token
  # carries the reason instead.
  changed=()
  token=''
  first=1
  complete=0
  while IFS= read -r -d '' rec; do
    if [ "$first" -eq 1 ]; then
      token="$rec"
      first=0
    elif [ -z "$rec" ]; then
      complete=1
      break
    else
      changed+=("$rec")
    fi
  done < <(CHANGED_FILES_JSON="$CHANGED_FILES_JSON" python3 -I -c '
import json
import os
import sys

out = sys.stdout.buffer


def finish(token, items=()):
    out.write(token.encode("ascii") + b"\0")
    for item in items:
        out.write(item + b"\0")
    out.write(b"\0")
    out.flush()
    sys.exit(0)


try:
    data = json.loads(os.environ.get("CHANGED_FILES_JSON", ""))
except Exception:
    finish("not-json")
if not isinstance(data, list):
    finish("not-an-array")
if not data:
    finish("empty-array")
encoded = []
for item in data:
    if not isinstance(item, str) or item == "" or "\0" in item:
        finish("non-string-member")
    try:
        encoded.append(item.encode("utf-8"))
    except UnicodeEncodeError:
        finish("unencodable-member")
finish("ok", encoded)
' 2>/dev/null)

  if [ "$complete" -ne 1 ] || [ -z "$token" ]; then
    arm 'the JSON parser never reached its end marker: python3 is missing, or it died partway'
    return 0
  fi
  case "$token" in
    ok) ;;
    empty-array)
      arm 'CHANGED_FILES_JSON is an empty array: no matched file is no narrowable file'
      return 0
      ;;
    not-json | not-an-array | non-string-member | unencodable-member)
      arm "CHANGED_FILES_JSON is not a JSON array of path strings ($token)"
      return 0
      ;;
    *)
      arm 'the JSON parser reported a status this script does not know'
      return 0
      ;;
  esac
  if [ "${#changed[@]}" -eq 0 ]; then
    arm 'the JSON parser reported success over no paths'
    return 0
  fi

  # Rule 3, the pagination cap. A THRESHOLD, not a comparison, and the obvious
  # "fix" is a bug: CHANGED_FILES_JSON holds the files that MATCHED `code:`,
  # while PR_CHANGED_FILES counts every changed file, so the two agree only
  # when every changed file matched. A real wiki sync touches wiki/log.md and
  # other pages no filter lists, so an equality reconcile would arm every leg
  # on exactly the pull requests this narrowing exists for, and it would ship
  # inert with every check still green. An absent or non-decimal value does not
  # fire: it is absent on the dispatch lane, which rule 1 already answered, and
  # arming on it would arm every leg for no real reason.
  pcf="${PR_CHANGED_FILES:-}"
  case "$pcf" in
    '' | *[!0-9]*) ;;
    *)
      zeros="${pcf%%[!0]*}"
      digits="${pcf#"$zeros"}"
      # More digits than the cap is above it, and comparing it as an integer
      # could overflow `[`.
      if [ "${#digits}" -gt "${#PAGINATION_CAP}" ] ||
        { [ -n "$digits" ] && [ "$digits" -ge "$PAGINATION_CAP" ]; }; then
        arm "PR_CHANGED_FILES is at or above the pagination cap ($PAGINATION_CAP), so the matched list may be truncated"
        return 0
      fi
      ;;
  esac

  root="$(resolve_root)" || root=''
  if [ -z "$root" ]; then
    arm 'could not resolve the root: LEG_ARMING_ROOT is not absolute and git could not name the checkout holding this script'
    return 0
  fi
  sharder="$(resolve_seam "$root" "${LEG_ARMING_SHARDER:-$SHARDER_DEFAULT}")"
  workflow="$(resolve_seam "$root" "${LEG_ARMING_WORKFLOW:-$WORKFLOW_DEFAULT}")"
  conc_dir="$(resolve_seam "$root" "${LEG_ARMING_CONCURRENCY_DIR:-$CONCURRENCY_DIR_DEFAULT}")"
  conc_leg="${LEG_ARMING_CONCURRENCY_LEG:-$CONCURRENCY_LEG_DEFAULT}"
  leg="${LEG_ID:-}"

  # Rule 4, classify, before any sharder call or scan.
  rc=0
  class_out="$(derive_class "$workflow")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    arm 'could not derive the narrowable class from the workflow'
    return 0
  fi
  class=()
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    case "$path" in
      */)
        arm 'a narrowable class member has no basename to match on'
        return 0
        ;;
    esac
    class+=("$path")
  done <<EOF
$class_out
EOF
  if [ "${#class[@]}" -eq 0 ]; then
    arm 'the derived narrowable class is empty'
    return 0
  fi

  # Exact string equality, never a substring or pattern test: a class member's
  # dots are not wildcards, and a path merely containing a member is not one.
  # `named` holds class INDICES, so from here on every scan is keyed on the
  # class member's own string rather than on the contributor's.
  named=()
  for path in ${changed[@]+"${changed[@]}"}; do
    hit=-1
    i=0
    while [ "$i" -lt "${#class[@]}" ]; do
      if [ "$path" = "${class[$i]}" ]; then
        hit=$i
        break
      fi
      i=$((i + 1))
    done
    if [ "$hit" -lt 0 ]; then
      arm "a changed path is outside the narrowable class (${#changed[@]} changed, ${#class[@]} narrowable)"
      return 0
    fi
    found=0
    for k in ${named[@]+"${named[@]}"}; do
      if [ "$k" -eq "$hit" ]; then
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      named+=("$hit")
    fi
  done
  count="${#changed[@]}"
  changed=()

  # Every shard's listing, captured and status-checked rather than read from a
  # process substitution: the sharder exits 2 on a shard it cannot resolve or
  # that resolves zero files, and through `< <(...)` that status is lost, so
  # the shard would report "no namer" and the fail-open would be defeated in
  # the one direction that matters. Each path is absolutized once, here.
  rc=0
  shards_out="$(bash "$sharder" shards)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$shards_out" ]; then
    arm "the sharder could not list its shard ids (exit $rc)"
    return 0
  fi
  shard_ids=()
  shard_lists=()
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    rc=0
    listing="$(bash "$sharder" files "$id")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
      arm "the sharder could not list shard $id (exit $rc)"
      return 0
    fi
    abslist=''
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      case "$f" in
        /*) abs="$f" ;;
        *) abs="$root/$f" ;;
      esac
      abslist="$abslist$abs$NL"
    done <<EOF
$listing
EOF
    shard_ids+=("$id")
    shard_lists+=("$abslist")
  done <<EOF
$shards_out
EOF

  if [ -z "$leg" ]; then
    arm 'LEG_ID is empty'
    return 0
  fi
  if ! is_sharder_id "$leg" && [ "$leg" != "$conc_leg" ]; then
    arm "LEG_ID $leg is neither a shard the sharder knows nor the concurrency seam's leg"
    return 0
  fi

  # Rule 5, the leg holding the derived check always arms.
  check_abs="$root/$CHECK_SUITE_REL"
  found=0
  i=0
  while [ "$i" -lt "${#shard_ids[@]}" ]; do
    if line_in "$check_abs" "${shard_lists[$i]}"; then
      found=1
      rc=0
      group_holds_leg "${shard_ids[$i]}" || rc=$?
      if [ "$rc" -eq 0 ]; then
        arm "this leg's exchange group holds the derived both-ways check, which always runs"
        return 0
      elif [ "$rc" -ne 1 ]; then
        arm 'could not resolve the exchange group holding the derived check'
        return 0
      fi
    fi
    i=$((i + 1))
  done
  if [ "$found" -eq 0 ]; then
    arm 'no shard lists the derived-check suite, so the leg holding it cannot be told apart'
    return 0
  fi

  # Rule 6, the scan. A unit is a set of files sharing one attribution: a
  # shard's own suites (that shard), a suite directory's helpers/, lib/ or
  # fixtures/ subtree (every shard holding a suite in that directory, the way
  # a sourced helper is shared), or the concurrency seam (its leg).
  unit_kind=()
  unit_target=()
  unit_attr=()
  dir_path=()
  dir_attr=()
  i=0
  while [ "$i" -lt "${#shard_ids[@]}" ]; do
    id="${shard_ids[$i]}"
    unit_kind+=(files)
    unit_target+=("${shard_lists[$i]}")
    unit_attr+=("$id")
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      dir="${f%/*}"
      found=-1
      j=0
      while [ "$j" -lt "${#dir_path[@]}" ]; do
        if [ "${dir_path[$j]}" = "$dir" ]; then
          found=$j
          break
        fi
        j=$((j + 1))
      done
      if [ "$found" -lt 0 ]; then
        dir_path+=("$dir")
        dir_attr+=("$id")
      else
        case " ${dir_attr[$found]} " in
          *" $id "*) ;;
          *) dir_attr[found]="${dir_attr[$found]} $id" ;;
        esac
      fi
    done <<EOF
${shard_lists[$i]}
EOF
    i=$((i + 1))
  done
  j=0
  while [ "$j" -lt "${#dir_path[@]}" ]; do
    for sub in helpers lib fixtures; do
      if [ -d "${dir_path[$j]}/$sub" ]; then
        unit_kind+=(tree)
        unit_target+=("${dir_path[$j]}/$sub")
        unit_attr+=("${dir_attr[$j]}")
      fi
    done
    j=$((j + 1))
  done

  # The concurrency seam, which the sharder does not discover. A missing
  # directory or one holding no suite is a discovery failure, the same
  # zero-files rule the sharder applies to its own shards.
  if [ ! -d "$conc_dir" ]; then
    arm 'the concurrency seam directory does not exist'
    return 0
  fi
  conc_bats=''
  for f in "$conc_dir"/*.bats; do
    if [ -e "$f" ]; then
      conc_bats="$conc_bats$f$NL"
    fi
  done
  if [ -z "$conc_bats" ]; then
    arm 'the concurrency seam holds no suite'
    return 0
  fi
  unit_kind+=(files)
  unit_target+=("$conc_bats")
  unit_attr+=("$conc_leg")
  if [ -d "$conc_dir/lib" ]; then
    unit_kind+=(tree)
    unit_target+=("$conc_dir/lib")
    unit_attr+=("$conc_leg")
  fi

  # Per unit: grep for each changed member first, and only when one of them
  # hits, for every other member too, which is what the namer-of-all test
  # needs. A hit file naming every member is excluded; any other hit
  # contributes the unit's attribution. `raw` and `post` count hits per
  # changed member before and after that exclusion, so an empty namer set can
  # say which of the two emptied it.
  raw=()
  post=()
  for k in ${named[@]+"${named[@]}"}; do
    raw[k]=0
    post[k]=0
  done
  contrib=()
  u=0
  while [ "$u" -lt "${#unit_kind[@]}" ]; do
    lists=()
    have=()
    any=0
    for k in ${named[@]+"${named[@]}"}; do
      rc=0
      lst="$(grep_unit "${unit_kind[$u]}" "${unit_target[$u]}" "${class[$k]}")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        arm 'a scan grep failed, and a failed read must never read as no namer'
        return 0
      fi
      lists[k]="$lst"
      have[k]=1
      if [ -n "$lst" ]; then
        any=1
      fi
    done
    if [ "$any" -eq 0 ]; then
      u=$((u + 1))
      continue
    fi
    if [ "${#class[@]}" -gt 1 ]; then
      k=0
      while [ "$k" -lt "${#class[@]}" ]; do
        if [ -z "${have[$k]:-}" ]; then
          rc=0
          lst="$(grep_unit "${unit_kind[$u]}" "${unit_target[$u]}" "${class[$k]}")" || rc=$?
          if [ "$rc" -ne 0 ]; then
            arm 'a scan grep failed, and a failed read must never read as no namer'
            return 0
          fi
          lists[k]="$lst"
          have[k]=1
        fi
        k=$((k + 1))
      done
    fi
    for k in ${named[@]+"${named[@]}"}; do
      while IFS= read -r f || [ -n "$f" ]; do
        [ -n "$f" ] || continue
        raw[k]=$((raw[k] + 1))
        excluded=0
        if [ "${#class[@]}" -gt 1 ]; then
          excluded=1
          j=0
          while [ "$j" -lt "${#class[@]}" ]; do
            if ! line_in "$f" "${lists[$j]:-}"; then
              excluded=0
              break
            fi
            j=$((j + 1))
          done
        fi
        if [ "$excluded" -eq 1 ]; then
          continue
        fi
        post[k]=$((post[k] + 1))
        for id in ${unit_attr[$u]}; do
          found=0
          for sub in ${contrib[@]+"${contrib[@]}"}; do
            if [ "$sub" = "$id" ]; then
              found=1
            fi
          done
          if [ "$found" -eq 0 ]; then
            contrib+=("$id")
          fi
        done
      done <<EOF
${lists[$k]:-}
EOF
    done
    u=$((u + 1))
  done

  # A globally empty namer set is a discovery failure, not a correct
  # narrowing to no leg. Checked per changed member, so a pull request naming
  # one read page and one unread page still arms.
  for k in ${named[@]+"${named[@]}"}; do
    if [ "${raw[$k]}" -eq 0 ]; then
      arm 'no suite, helper or fixture names a changed page, which is a discovery failure rather than a leg with nothing to run'
      return 0
    fi
    if [ "${post[$k]}" -eq 0 ]; then
      arm 'every file naming a changed page names every narrowable page, so the namer-of-all rule left it no namer, and an empty namer set arms'
      return 0
    fi
  done

  for id in ${contrib[@]+"${contrib[@]}"}; do
    rc=0
    group_holds_leg "$id" || rc=$?
    if [ "$rc" -eq 0 ]; then
      arm "a file naming a changed page is attributed to this leg's exchange group"
      return 0
    elif [ "$rc" -ne 1 ]; then
      arm 'could not resolve the exchange group of a shard holding a namer'
      return 0
    fi
  done

  # HONEST LIMIT of this narrowing, accepted rather than overlooked.
  #
  # Widening the workflow's `code:` filter cannot reach this decision. Class
  # membership is exact string equality, so an added entry only grows the class:
  # a changed path equal to a class member never reaches the out-of-class arm
  # above and is still decided here, per leg. A `wiki/**` entry in that filter
  # therefore arms the JOB for pages outside the class. For a page inside the
  # class, the rules below still decide, and an added member can move that
  # decision in either direction, because the class also feeds the
  # namer-of-all exclusion.
  #
  # The cost, and it is real. Some suites assert a property of every tracked
  # file rather than of a page they name, so a wiki page can violate one without
  # appearing anywhere in it, which leaves the scan above no way to attribute
  # them to it. For a class page whose namers sit outside a leg's exchange
  # group, this declines that leg, and those assertions do not run for an edit
  # to that page alone. That is accepted: telling a whole-tree suite from a
  # page-reading one needs a rule that guesses, and a wrong guess under-arms,
  # the one direction this file refuses to fail in.
  #
  # A whole-tree suite escapes the gap when it shares an exchange group with
  # CHECK_SUITE_REL, which rule 5 arms unconditionally. That is a property of
  # where the sharder currently places it rather than a protection whole-tree
  # suites hold as a class, so a reshuffle moving it out of that group takes the
  # exemption with it and this gap widens silently.
  decline "no file naming a changed page is attributed to this leg's exchange group (changed: $count, narrowable pages named: ${#named[@]} of ${#class[@]})"
}

run_class() {
  local root workflow out rc=0
  root="$(resolve_root)" || root=''
  if [ -z "$root" ]; then
    note 'class: could not resolve the root: LEG_ARMING_ROOT is not absolute and git could not name the checkout holding this script'
    exit 2
  fi
  workflow="$(resolve_seam "$root" "${LEG_ARMING_WORKFLOW:-$WORKFLOW_DEFAULT}")"
  out="$(derive_class "$workflow")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  class)
    if [ "$#" -gt 1 ]; then
      note 'class takes no further argument'
      usage >&2
      exit 2
    fi
    run_class
    ;;
  '') ;;
  *)
    # No argument carries data, and the arming answer is printed on every
    # path, so an unknown one arms rather than exiting without an answer.
    note 'arm: unknown argument; the arming answer takes none'
    printf 'true\n'
    exit 0
    ;;
esac

answer=''
status=0
answer="$(decide)" || status=$?
if [ "$status" -ne 0 ]; then
  note "arm: the derivation exited $status before answering"
  answer=true
fi
case "$answer" in
  true | false) ;;
  *)
    note 'arm: the derivation printed neither literal'
    answer=true
    ;;
esac
printf '%s\n' "$answer"
exit 0
