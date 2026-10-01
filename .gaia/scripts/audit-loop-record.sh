#!/usr/bin/env bash
# audit-loop-record.sh: publish the PR body's `## Audit rounds` section.
#
#   audit-loop-record.sh --pr <N> [--repo <owner/name>]
#       --values-json <file|->
#       [--body-in <file> --body-out <file>]
#
# The one deterministic writer of the marker-delimited section below, used by
# the main thread after each round.
# Branch state is local and gitignored; the PR body is the published,
# cross-machine record of how many audit rounds a PR took. Publication only:
# nothing reads the section back to grant a round or set a count, so a
# hand-edited section is simply replaced by the computed one on the next write.
#
# The section (members sorted by name, each count the number of distinct
# audited trees the member was dispatched on):
#
#   <!-- gaia:audit-rounds:start -->
#   ## Audit rounds
#
#   Total rounds: <int>; per member: <member> <int>, <member> <int>; human grants: <int>.
#   <!-- gaia:audit-rounds:end -->
#
# The block is rewritten in place between the markers and appended after one
# blank line when absent; every byte outside the markers is preserved. With no
# member counts the per-member list reads `none`.
#
# Values: `--values-json` takes {"total":n,"members":{"code-audit-x":n},
# "grants":g} (the shape `audit-loop-eval.sh record-values` prints; `-` reads
# stdin). Integers must be non-negative, member names `code-audit-[a-z0-9-]+`,
# no extra keys.
#
# The body is read with `gh pr view` and written with
# `gh pr edit --body-file <temp>`; it never travels on a command line. The
# offline pair `--body-in`/`--body-out` (both or neither) replaces both gh
# calls, which is what the tests use.
#
# Refuses (exit 1, nothing written) on more than one start or end marker, one
# without the other, the end before the start, a marker not alone on its line,
# or a marker inside a fenced code block (a fence opens on a line starting with
# three backticks or three tildes, up to three leading spaces allowed).
#
# Exit: 0 written, 1 refusal / gh or jq failure, 2 usage or invalid input.
# bash 3.2 and BWK awk safe; never changes directory.
set -eu

START_MARKER='<!-- gaia:audit-rounds:start -->'
END_MARKER='<!-- gaia:audit-rounds:end -->'

die_usage() {
  printf 'audit-loop-record: %s\n' "$1" >&2
  exit 2
}

die_fail() {
  printf 'audit-loop-record: %s\n' "$1" >&2
  exit 1
}

PR=""
REPO=""
VALUES_SRC=""
BODY_IN=""
BODY_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pr|--repo|--values-json|--body-in|--body-out)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --pr) PR="$2" ;;
        --repo) REPO="$2" ;;
        --values-json) VALUES_SRC="$2" ;;
        --body-in) BODY_IN="$2" ;;
        --body-out) BODY_OUT="$2" ;;
      esac
      shift 2
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

printf '%s' "$PR" | grep -Eq '^[1-9][0-9]{0,9}$' || die_usage "--pr must be a positive integer"
if [ -n "$REPO" ]; then
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die_usage "--repo must be <owner>/<name>"
fi

if [ -z "$VALUES_SRC" ]; then
  die_usage "--values-json is required"
fi
if { [ -n "$BODY_IN" ] && [ -z "$BODY_OUT" ]; } || { [ -z "$BODY_IN" ] && [ -n "$BODY_OUT" ]; }; then
  die_usage "--body-in and --body-out go together"
fi

command -v jq >/dev/null 2>&1 || die_fail "jq is required"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

require_gh() {
  command -v gh >/dev/null 2>&1 || die_fail "gh is required"
}

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

if [ "$VALUES_SRC" = "-" ]; then
  cat > "$WORK/values.json"
else
  [ -f "$VALUES_SRC" ] || die_usage "--values-json file not found: $VALUES_SRC"
  cp "$VALUES_SRC" "$WORK/values.json"
fi

# \A and \z, not ^ and $: jq's regex engine reads ^ and $ as line anchors, so a
# name with an embedded newline would pass the anchored form.
if ! jq -e '
    def uint: type == "number" and . >= 0 and . == floor and . < 1000000000;
    type == "object"
    and ((keys - ["total", "members", "grants"]) | length) == 0
    and (.total | uint)
    and (.grants | uint)
    and (.members | type) == "object"
    and (.members | to_entries | all(.key | test("\\Acode-audit-[a-z0-9-]+\\z")))
    and (.members | to_entries | all(.value | uint))
  ' "$WORK/values.json" >/dev/null 2>&1; then
  die_usage "values JSON is invalid: need {total, members, grants} with non-negative integers and code-audit-* member names"
fi

TOTAL="$(jq -r '.total' "$WORK/values.json")"
GRANTS="$(jq -r '.grants' "$WORK/values.json")"
MEMBERS="$(jq -r '.members | to_entries | sort_by(.key) | map("\(.key) \(.value)") | join(", ")' "$WORK/values.json")"
[ -n "$MEMBERS" ] || MEMBERS="none"

printf '%s\n%s\n\n%s\n%s\n' \
  "$START_MARKER" \
  '## Audit rounds' \
  "Total rounds: ${TOTAL}; per member: ${MEMBERS}; human grants: ${GRANTS}." \
  "$END_MARKER" > "$WORK/section.md"

# ---------------------------------------------------------------------------
# Body in
# ---------------------------------------------------------------------------

if [ -n "$BODY_IN" ]; then
  [ -f "$BODY_IN" ] || die_usage "--body-in file not found: $BODY_IN"
  cp "$BODY_IN" "$WORK/body.md"
else
  require_gh
  if [ -n "$REPO" ]; then
    gh pr view "$PR" --repo "$REPO" --json body --jq '.body // ""' > "$WORK/body.md" 2>/dev/null \
      || die_fail "gh could not read the PR body"
  else
    gh pr view "$PR" --json body --jq '.body // ""' > "$WORK/body.md" 2>/dev/null \
      || die_fail "gh could not read the PR body"
  fi
  # gh prints the string and one newline; the body itself did not carry it.
  if [ -s "$WORK/body.md" ] \
    && [ "$(tail -c 1 "$WORK/body.md" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
    head -c "$(( $(wc -c < "$WORK/body.md") - 1 ))" "$WORK/body.md" > "$WORK/body.trim"
    mv "$WORK/body.trim" "$WORK/body.md"
  fi
fi

# ---------------------------------------------------------------------------
# Marker scan: one pass, six numbers.
#   starts ends start-line end-line fenced-marker-lines not-alone-lines
# ---------------------------------------------------------------------------

SCAN="$(LC_ALL=C awk -v S="$START_MARKER" -v E="$END_MARKER" '
  {
    line = $0
    t = line
    sub(/[ \t\r]+$/, "", t)
    hasS = index(line, S) > 0
    hasE = index(line, E) > 0
    if (hasS || hasE) {
      if (infence) fenced++
      if (hasS) { ns++; if (!sl) sl = NR; if (t != S) alone++ }
      if (hasE) { ne++; if (!el) el = NR; if (t != E) alone++ }
      next
    }
    p = line
    sub(/^ ? ? ?/, "", p)
    c = substr(p, 1, 1)
    if ((c == "`" || c == "~") && substr(p, 1, 3) == c c c) {
      if (!infence) { infence = 1; fc = c }
      else if (c == fc) { infence = 0 }
    }
  }
  END { printf "%d %d %d %d %d %d\n", ns, ne, sl, el, fenced, alone }
' "$WORK/body.md")"

# shellcheck disable=SC2034  # the fields are named for the reader
read -r N_START N_END L_START L_END N_FENCED N_ALONE <<SCANEOF
$SCAN
SCANEOF

if [ "$N_FENCED" -gt 0 ]; then
  die_fail "refusing: an audit-rounds marker sits inside a fenced code block"
fi
if [ "$N_ALONE" -gt 0 ]; then
  die_fail "refusing: an audit-rounds marker is not alone on its line"
fi
if [ "$N_START" -gt 1 ] || [ "$N_END" -gt 1 ]; then
  die_fail "refusing: duplicate audit-rounds markers"
fi
if [ "$N_START" -ne "$N_END" ]; then
  die_fail "refusing: unbalanced audit-rounds markers (one without the other)"
fi
if [ "$N_START" -eq 1 ] && [ "$L_END" -lt "$L_START" ]; then
  die_fail "refusing: the audit-rounds end marker comes before the start marker"
fi

# ---------------------------------------------------------------------------
# Splice. head -n and tail -n keep the outside bytes exactly, including a
# missing final newline.
# ---------------------------------------------------------------------------

if [ "$N_START" -eq 1 ]; then
  {
    head -n "$(( L_START - 1 ))" "$WORK/body.md"
    cat "$WORK/section.md"
    tail -n "+$(( L_END + 1 ))" "$WORK/body.md"
  } > "$WORK/body.new"
else
  {
    if [ -s "$WORK/body.md" ]; then
      cat "$WORK/body.md"
      if [ "$(tail -c 1 "$WORK/body.md" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
        printf '\n'
      else
        printf '\n\n'
      fi
    fi
    cat "$WORK/section.md"
  } > "$WORK/body.new"
fi

# ---------------------------------------------------------------------------
# Body out
# ---------------------------------------------------------------------------

if [ -n "$BODY_OUT" ]; then
  cat "$WORK/body.new" > "$BODY_OUT" || die_fail "could not write $BODY_OUT"
else
  if [ -n "$REPO" ]; then
    gh pr edit "$PR" --repo "$REPO" --body-file "$WORK/body.new" >/dev/null 2>&1 \
      || die_fail "gh could not write the PR body"
  else
    gh pr edit "$PR" --body-file "$WORK/body.new" >/dev/null 2>&1 \
      || die_fail "gh could not write the PR body"
  fi
fi
