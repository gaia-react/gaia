#!/usr/bin/env bash
# check-debt-issue-metadata.sh: validate the label set and dedup key a tech-debt
# filing carries, against the rules `.claude/skills/file-tech-debt/SKILL.md`
# states. Exit 0 when clean, 1 on any finding, 2 on a usage or environment
# error. Run it from the repository root.
#
# Three modes, two of them offline:
#
#   --pre-file --labels <csv> --body-file <path>
#       The blocking mode. Validates a filing that has NOT happened yet, from
#       the label set about to reach `gh issue create` argv and the body file
#       step 4 of the recipe already builds. Reads no network and needs no
#       `gh`, so the gate in front of every filing is hermetic.
#
#   --issue <N>
#       Advisory. Validates one already-filed issue, read through `gh`.
#
#   --sweep
#       Advisory. Validates every open `tech-debt` issue. This is the mode that
#       answers "what is already wrong", and it relabels nothing: the repair for
#       an existing issue is a human decision per issue, not a sweep.
#
# Why a script and not another paragraph. Every rule enforced below was already
# stated in prose in SKILL.md before this gate existed, and every one of them
# was violated anyway, because prose that nothing reads back is a convention
# rather than a check. The filing routes are models; the label set they emit is
# the one artifact of a filing that no later step re-reads, so a mistake there
# is silent until a drainer trips over it weeks later. This is the read-back.
# gaia:maintainer-only:start
#
# The `surface:` namespace is the one rule here that SKILL.md did not previously
# state. The two labels existed in the tracker and were applied by hand often
# enough to look like a convention, while being documented nowhere and emitted
# by no filing route. Step 6 of the recipe now defines them; this gate is what
# makes that definition checkable.
# gaia:maintainer-only:end

set -euo pipefail

readonly PROG="check-debt-issue-metadata"

# The permitted value sets, byte-for-byte, from steps 6 and 7 of the recipe in
# `.claude/skills/file-tech-debt/SKILL.md`. That file owns the vocabulary and
# the rubric for choosing within it; this one owns nothing but the read-back, so
# a value outside a set is reported as a finding rather than tolerated as a
# variant. The recipe's lockstep note lists this script as a consumer for
# exactly that reason: a spelling changed there and not here fails a filing
# immediately, which is the loud direction to fail in.
readonly SEVERITY_VALUES="critical important suggestion"
# gaia:maintainer-only:start
readonly SURFACE_VALUES="adopter maintainer"
# gaia:maintainer-only:end
readonly DIFFICULTY_VALUES="easy medium hard"
readonly HANDLER_VALUES="prompt plan spec"
# One permitted value today. A single-valued namespace is still a namespace
# rather than a bare label, because the axis it opens ("what does this repair's
# cost depend on") admits more answers than the one case that motivated it, and
# a bare `fold-required` label would have to be renamed to grow a second.
readonly FOLD_VALUES="required"

usage() {
  cat >&2 <<'EOF'
usage:
  check-debt-issue-metadata.sh --pre-file --labels <csv> --body-file <path>
  check-debt-issue-metadata.sh --issue <N>
  check-debt-issue-metadata.sh --sweep
EOF
  exit 2
}

fatal() {
  echo "$PROG: ERROR: $*" >&2
  exit 2
}

# Findings accumulate here rather than printing as they are found, so one
# subject's findings stay contiguous in the output and the exit status is
# decided once, at the end.
FINDING_COUNT=0

# finding <subject> <code> <message>
finding() {
  echo "$1: $2: $3"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# in_set <needle> <space-separated set>: exit 0 when present.
in_set() {
  local needle="$1" set="$2" v
  for v in $set; do
    [ "$v" = "$needle" ] && return 0
  done
  return 1
}

# count_ns <labels-newline-list> <namespace-prefix>: how many labels carry it.
count_ns() {
  printf '%s\n' "$1" | grep -c "^$2" || true
}

# values_ns <labels-newline-list> <namespace-prefix>: the values, prefix stripped.
# A label that is the bare prefix yields an empty line rather than no line, so
# the count of lines out always equals the count of labels in.
values_ns() {
  printf '%s\n' "$1" | sed -n "s/^$2//p"
}

# check_ns_values <subject> <labels> <prefix> <permitted set> <namespace name>
#
# Report every value in one namespace that is not in its permitted set.
#
# Two properties here are load-bearing, and neither is style. The values are
# read a line at a time out of a process substitution rather than word-split out
# of an unquoted `$(...)` in a `for` list. An unquoted command substitution is
# split on IFS and then glob-expanded, which silently converts one bad label
# into something the checks accept: `severity:critical important` would be tested
# as two separate values that are each individually legal, and `severity:*` would
# expand against the working directory and report one finding per file in the
# repository root instead of one finding naming the label. And the loop is fed
# by a redirect rather than a pipe, because `finding` increments a counter in
# the caller's shell and a piped `while` runs in a subshell that discards every
# increment, which greens the gate while printing its own findings.
check_ns_values() {
  local subject="$1" labels="$2" prefix="$3" permitted="$4" ns="$5" v count
  count="$(count_ns "$labels" "$prefix")"
  # Nothing in this namespace: return before the loop, because an absent
  # namespace and a single empty-valued one both yield no text, and only the
  # second is a defect.
  [ "$count" -gt 0 ] || return 0
  while IFS= read -r v; do
    # An empty value is its own defect rather than an absence. `severity:` with
    # nothing after the colon still counts as one label, so the count check
    # above passes, and a vocabulary loop that skipped empties would see nothing
    # to reject: between them the two checks would let it through. This is the
    # most reachable bad shape, because the recipe substitutes placeholders into
    # this argv and an unfilled `difficulty:<grade>` arrives in exactly it.
    if [ -z "$v" ]; then
      finding "$subject" "$ns-value" "\`$prefix\` carries an empty value"
      continue
    fi
    if ! in_set "$v" "$permitted"; then
      finding "$subject" "$ns-value" "\`$prefix$v\` is outside the permitted set ($permitted)"
    fi
  done < <(values_ns "$labels" "$prefix")
  return 0
}

# ---------------------------------------------------------------------------
# The label checks. `labels` arrives as a newline-separated list, already
# normalized by whichever mode read it, so the checks below never care whether
# the source was argv or `gh --json labels`.
# ---------------------------------------------------------------------------

# check_labels <subject> <labels-newline-list>
check_labels() {
  local subject="$1" labels="$2" n v

  if ! printf '%s\n' "$labels" | grep -qx 'tech-debt'; then
    finding "$subject" "missing-tech-debt" "no \`tech-debt\` label"
  fi

  # Exactly one severity. Zero is the common defect (the ordering query's
  # `else` branch silently files it into the suggestion band, so it never
  # surfaces as an error at drain time); two is rarer and worse, because the
  # band an issue sorts into then depends on jq's index() order.
  n="$(count_ns "$labels" 'severity:')"
  if [ "$n" -ne 1 ]; then
    finding "$subject" "severity-count" "expected exactly one \`severity:\` label, found $n"
  fi
  check_ns_values "$subject" "$labels" 'severity:' "$SEVERITY_VALUES" "severity"
  # gaia:maintainer-only:start

  # Exactly one surface. Unlike severity there is no fallback band: an
  # unlabeled issue is simply unfiled against the adopter/maintainer split
  # that decides who the defect is visible to.
  n="$(count_ns "$labels" 'surface:')"
  if [ "$n" -ne 1 ]; then
    finding "$subject" "surface-count" "expected exactly one \`surface:\` label, found $n"
  fi
  check_ns_values "$subject" "$labels" 'surface:' "$SURFACE_VALUES" "surface"
  # gaia:maintainer-only:end

  # Difficulty is optional by design: a filing that did not read the cited code
  # omits the grade rather than guessing one. So zero is clean and two is not,
  # and a present grade must still be in the vocabulary.
  n="$(count_ns "$labels" 'difficulty:')"
  if [ "$n" -gt 1 ]; then
    finding "$subject" "difficulty-count" "expected at most one \`difficulty:\` label, found $n"
  fi
  check_ns_values "$subject" "$labels" 'difficulty:' "$DIFFICULTY_VALUES" "difficulty"

  # Handler is optional here for a different reason than difficulty is. Every
  # filing route this recipe governs emits one, but nothing downstream depends
  # on the value: the drain re-derives spec-versus-implement from the cited code
  # and grades prompt-versus-plan itself, so an absent class costs one line of
  # `why` output and never a misroute. Demanding presence would demand a value
  # no decision reads, and it would make every human-filed issue a finding.
  n="$(count_ns "$labels" 'handler:')"
  if [ "$n" -gt 1 ]; then
    finding "$subject" "handler-count" "expected at most one \`handler:\` label, found $n"
  fi
  check_ns_values "$subject" "$labels" 'handler:' "$HANDLER_VALUES" "handler"

  # Fold is optional in the strongest sense of the three: it marks a minority of
  # findings, so absence is the ordinary case rather than an omission, and
  # nothing gates on presence or absence. It is checked here for the same reason
  # the others are: the value reaches a display surface that reads it literally,
  # so a misspelling is silent until a drainer does not see the annotation the
  # filer thought they left.
  n="$(count_ns "$labels" 'fold:')"
  if [ "$n" -gt 1 ]; then
    finding "$subject" "fold-count" "expected at most one \`fold:\` label, found $n"
  fi
  check_ns_values "$subject" "$labels" 'fold:' "$FOLD_VALUES" "fold"

  return 0
}

# ---------------------------------------------------------------------------
# The body checks.
# ---------------------------------------------------------------------------

# The dedup key, matched as the whole line shape rather than a loose substring,
# so a key with a missing field or a non-integer line reads as malformed rather
# than as absent. `path` is required to be repo-relative POSIX: a leading slash
# or a backslash means an absolute or Windows path reached the key, and every
# consumer of the key compares it against repo-relative paths.
#
# `path` is a GREEDY `.+`, not `[^ ]+`, and that is load-bearing rather than
# lazy: repository paths legally contain spaces, and this repository has one
# under an existing key (`path=wiki/concepts/PR Merge Workflow.md`). A
# space-intolerant pattern reports every such key as malformed, which on the
# blocking `--pre-file` path would refuse a correct filing outright. The greedy
# form plus the anchored ` line=<int> -->` tail performs the same split
# `.claude/skills/gaia/references/debt.md`'s own capture performs.
#
# CRLF is handled by normalizing the body before it reaches these patterns (see
# `check_body`), never by an escape inside the pattern itself. `\r` in an ERE is
# BSD-only: GNU grep reads a backslash before an ordinary character as that
# character, so `-->\r?$` means "an optional literal r" on Linux. That spelling
# is worse than no tolerance at all, because it inverts by platform. It matches
# a CRLF key on macOS and not on Linux, matches a key ending in a stray literal
# `r` on Linux and not on macOS, and GNU sed accepts `\r` where GNU grep does
# not, so the shape test and the path extraction below would disagree with each
# other on the same body. Normalizing once removes the divergence instead of
# relocating it.
readonly KEY_RE='^<!-- gaia-debt-key: v1 class=[^ ]+ path=.+ line=[0-9]+ -->$'

# A key CANDIDATE is any line that opens with the key comment, well-formed or
# not. Counting candidates apart from well-formed keys is what lets a malformed
# key be reported while a valid one stands beside it. Testing only for the
# absence of a well-formed key cannot see that case, and the case is not
# harmless: `.gaia/scripts/debt-count-refresh.sh` collects covered paths with a
# looser `scan` than this file's shape test, so a malformed second key line
# contributes its bogus path to the set the statusline nudge suppression reads,
# even though dedup identity itself is unaffected (the drain's own capture takes
# the first well-formed match).
#
# Anchoring on the line start is also what preserves the deliberate tolerance
# for a key mentioned inside running prose, which a correction comment quoting
# the format legitimately does.
readonly KEY_CANDIDATE_RE='^<!-- gaia-debt-key:'

# check_body <subject> <body-text>
check_body() {
  local subject="$1" body="$2" wellformed candidates path

  # Strip carriage returns before anything reads the body. GitHub returns a body
  # with the line endings the client submitted, and a browser textarea submits
  # CRLF, so an issue created or edited in the web UI carries a trailing `\r` on
  # every line. The drain's own capture is an unanchored substring match and
  # accepts that; the end-anchored patterns below would not, so without this the
  # gate and the drain would disagree on exactly the bodies a human touched
  # last, and `--sweep` would report an exact key as malformed.
  #
  # Done here with `tr` rather than as a `\r?` in each pattern because that
  # escape is BSD-only and would make the gate's verdict depend on which platform
  # ran it. One normalization also keeps the shape test and the path extraction
  # reading the same bytes, which per-pattern escapes did not.
  body="$(printf '%s\n' "$body" | tr -d '\r')"

  wellformed="$(printf '%s\n' "$body" | grep -cE "$KEY_RE" || true)"
  candidates="$(printf '%s\n' "$body" | grep -cE "$KEY_CANDIDATE_RE" || true)"

  # Three independent verdicts, not a chain. Written as separate `if`s rather
  # than an `if/elif` ladder because a body can carry more than one of these
  # defects at once, and the ladder's later arms were unreachable whenever an
  # earlier one held: one valid key plus one malformed key line satisfied the
  # "a well-formed key exists" arm and reported nothing at all.
  if [ "$candidates" -eq 0 ] && [ "$wellformed" -eq 0 ]; then
    finding "$subject" "missing-dedup-key" "the body carries no \`gaia-debt-key\` line"
  fi
  if [ "$candidates" -gt "$wellformed" ]; then
    finding "$subject" "malformed-dedup-key" "$((candidates - wellformed)) \`gaia-debt-key\` line(s) do not match the v1 shape"
  fi
  if [ "$wellformed" -gt 1 ]; then
    finding "$subject" "duplicate-dedup-key" "expected exactly one \`gaia-debt-key\` line, found $wellformed"
  fi

  # Path shape, checked only on a key that already parsed. Reported separately
  # from the shape check above so a caller sees which half is wrong.
  #
  # Fed by a here-doc rather than a pipe on purpose: `finding` increments a
  # counter in the caller's shell, and a piped `while` runs in a subshell where
  # every increment is discarded when the loop ends. That failure is silent and
  # green, which is the one outcome a gate must never produce.
  local paths
  # No CRLF handling here: the body was normalized at the top of this function,
  # so this program and KEY_RE above read identical bytes. A per-pattern escape
  # would not have given that, since GNU sed accepts `\r` where GNU grep does
  # not, leaving the shape test and this extraction disagreeing on one body.
  paths="$(printf '%s\n' "$body" | sed -nE 's/^<!-- gaia-debt-key: v1 class=[^ ]+ path=(.+) line=[0-9]+ -->$/\1/p')"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      /* | *\\*)
        finding "$subject" "dedup-key-path" "\`path=$path\` is not a repo-relative POSIX path"
        ;;
    esac
  done <<EOF
$paths
EOF
  return 0
}

# ---------------------------------------------------------------------------
# Mode: --pre-file
# ---------------------------------------------------------------------------

run_pre_file() {
  local labels_csv="$1" body_file="$2" labels body

  [ -n "$labels_csv" ] || fatal "--pre-file requires --labels"
  [ -n "$body_file" ] || fatal "--pre-file requires --body-file"
  [ -f "$body_file" ] || fatal "body file not found: $body_file"

  # Accept the labels comma-separated, which is how a caller assembling
  # `--label a --label b` argv most naturally hands them over. Empty entries
  # are dropped rather than counted as a label named "".
  labels="$(printf '%s' "$labels_csv" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # `|| fatal` for the same reason the two gh reads below carry one: a bare
  # assignment under `set -e` propagates `cat`'s exit 1, which this script
  # documents as "findings were reported", so an unreadable file that passed the
  # `[ -f ]` test above would tell the caller to fix findings it never printed.
  body="$(cat "$body_file")" || fatal "could not read the body file: $body_file"

  check_labels "pre-file" "$labels"
  check_body "pre-file" "$body"

  # The claim and park labels belong to work that has started, not to the act
  # of filing. The recipe says so; nothing checked it.
  #
  # Written as an `if`, not `grep ... && finding ...`: an AND-list whose left
  # side fails carries a non-zero status, and under `set -e` that aborts the
  # script on the clean case. The same trap `.claude/rules/bats-assertions.md`
  # documents for test bodies applies to any `set -e` script.
  if printf '%s\n' "$labels" | grep -qE '^(in-progress|debt:spec-pending|debt:spec-active)$'; then
    finding "pre-file" "drain-label-on-new-filing" "\`in-progress\` / \`debt:spec-pending\` / \`debt:spec-active\` are applied once work starts, never by a filing"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Modes: --issue and --sweep. Both read through `gh`.
# ---------------------------------------------------------------------------

require_gh() {
  command -v gh >/dev/null 2>&1 || fatal "gh not found on PATH; --issue and --sweep need it (--pre-file does not)"
  command -v jq >/dev/null 2>&1 || fatal "jq not found on PATH; --issue and --sweep need it (--pre-file does not)"
}

# check_one_issue <json-object>: one issue's worth of checks, from the JSON
# shape both gh modes below produce.
check_one_issue() {
  local obj="$1" number labels body
  number="$(printf '%s' "$obj" | jq -r '.number')"
  labels="$(printf '%s' "$obj" | jq -r '.labels[].name')"
  body="$(printf '%s' "$obj" | jq -r '.body // ""')"

  check_labels "#$number" "$labels"
  check_body "#$number" "$body"
}

fetch_corpus() {
  gh issue list --label tech-debt --state open --limit 1000 \
    --json number,labels,body
}

run_issue() {
  local number="$1" obj
  require_gh
  case "$number" in
    '' | *[!0-9]*) fatal "--issue needs an issue number" ;;
  esac

  # `|| fatal` rather than a bare assignment: under `set -e` a failing `gh`
  # would propagate its own exit 1, which is this script's documented "findings
  # were reported" status, so an auth or network failure would read as a clean
  # run with an unlucky exit code. Routing it to 2 keeps the three-way contract
  # honest. The blocking `--pre-file` mode is unaffected, being hermetic.
  obj="$(gh issue view "$number" --json number,labels,body)" ||
    fatal "could not read issue #$number through gh"
  check_one_issue "$obj"
}

run_sweep() {
  local corpus count obj
  require_gh

  corpus="$(fetch_corpus)" || fatal "could not read the tech-debt backlog through gh"
  count="$(printf '%s' "$corpus" | jq 'length')"

  # An empty corpus is reported, never silently green. A `gh` that returned
  # nothing and a backlog that is genuinely empty look identical from the exit
  # status alone, and only one of them means "nothing to check".
  if [ "$count" -eq 0 ]; then
    echo "$PROG: the open tech-debt backlog is empty; nothing was checked" >&2
    return 0
  fi

  # One `jq` for the whole corpus, streamed a record per line, rather than one
  # `jq` per index. The indexed form re-parsed the entire document on every
  # iteration and, with the fetch capped at 1000 issues, spent up to four
  # thousand forks on a sweep.
  #
  # Fed by a redirect rather than a pipe, for the reason this file keeps
  # repeating: `check_one_issue` calls `finding`, which increments a counter in
  # the caller's shell, and a piped `while` runs in a subshell that discards it.
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    check_one_issue "$obj"
  done < <(printf '%s' "$corpus" | jq -c '.[]')

  echo "$PROG: checked $count open tech-debt issue(s)" >&2
}

# ---------------------------------------------------------------------------

main() {
  local mode="" labels="" body_file="" issue=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pre-file) mode="pre-file" ;;
      --sweep) mode="sweep" ;;
      --issue)
        mode="issue"
        shift
        issue="${1:-}"
        ;;
      --labels)
        shift
        labels="${1:-}"
        ;;
      --body-file)
        shift
        body_file="${1:-}"
        ;;
      -h | --help) usage ;;
      *) fatal "unknown argument: $1" ;;
    esac
    shift || true
  done

  case "$mode" in
    pre-file) run_pre_file "$labels" "$body_file" ;;
    issue) run_issue "$issue" ;;
    sweep) run_sweep ;;
    *) usage ;;
  esac

  if [ "$FINDING_COUNT" -gt 0 ]; then
    echo "$PROG: $FINDING_COUNT finding(s)" >&2
    exit 1
  fi
  echo "$PROG: clean" >&2
  exit 0
}

main "$@"
