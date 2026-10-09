#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-fix-verify.sh: deterministic check of one audit fix round. The main
# thread records a working-tree baseline after the audit members return, a
# fresh fixer sub-agent edits the tree, and this script judges the fixer's
# delta from that baseline. The main thread never trusts the fixer's own
# account of what it did: it commits and runs the Quality Gate only on a pass.
# Members only report, so the baseline refuses a tree the member wave left
# dirty and only the fixer's delta is ever judged.
#
# The verifier judges the fixer from a pinned copy of itself. The baseline
# subcommand copies this script and the libraries it sources into
# <run-folder>/verifier-bin-<r>/ (beside the baseline file) and records their
# digest in the baseline; the main thread runs check, round-check and drift from
# that copy by its run-folder path, never from the working tree the fixer edits.
# Each of those subcommands refuses (bad-input, or exit 1 for drift and
# round-check) when the files beside it no longer hash to the recorded digest.
# An edit to the working-tree verifier therefore takes effect from the next
# round's baseline, not within the round that made it.
#
# Usage:
#   audit-fix-verify.sh baseline    --root <R> --round <r> --out <baseline-file>
#                                   (also writes verifier-bin-<r>/ beside it)
#   audit-fix-verify.sh check       --root <R> --round <r> --attempt <k>
#                                   --dispositions <f> --dispositions-sha <hex>
#                                   --baseline <f> --baseline-sha <hex>
#                                   --result <fixer-file> --out <verifier-file>
#                                   [--extra-declared <paths-file>]...
#   audit-fix-verify.sh drift       --root <R> --baseline <f>
#   audit-fix-verify.sh round-check --run-folder <dir> --round <r>
#
# Exit codes: 0 pass, 1 findings (each printed to stderr on its own line as
# `kind: detail`), 2 usage or missing jq, 3 baseline refusal (index differs
# from HEAD; no output file is written), 4 baseline refusal because the member
# wave left the tree dirty (a modified tracked file or an untracked, non-ignored
# file; stdout is `member-wave-dirty` then one `dirty <path>` line per path, no
# output file is written, and the caller stops without committing). Git-ignored
# paths never trip it. `check` writes its verifier file on every outcome,
# failures included.
#
# Attempt rule: k starts at 1 for the fixer's first write in a round and
# increases by 1 on every SendMessage continuation (verifier retry or gate
# repair alike). The fixer rewrites fixer-<r>-audit.json with "attempt": k and
# --attempt must equal it. verifier-<r>-<k>.json, gate-<r>-<k>.log and
# gate-<r>-<k>.paths use the same k.
#
# The main thread records the sha256 of the dispositions and baseline files
# before the fixer dispatch and passes them as --dispositions-sha and
# --baseline-sha, so the fixer cannot widen enforcement_paths_allowed or the
# baseline's dirty set (both would be bad-input).
#
# --extra-declared names a newline-separated paths file the main thread
# recorded as changed by the Quality Gate's autofix (gate-<r>-<k>.paths), so a
# re-verification after a gate repair does not fail on edits the fixer did not
# make.
#
# Run-folder file shapes (this header is their single owner), all under
# <MAIN>/.gaia/local/runs/<B>/:
#
#   dispositions-<r>.json (the round's orchestrator: the unit):
#     {"schema":1,"round":r,"tree":"<hex>","root":"<abs resolved root>",
#      "enforcement_paths_allowed":["<path>"],
#      "entries":[{"member","finding_class","path","line","severity","title",
#        "failure_mode","suggested_fix",
#        "disposition":"fix|accept-residual|waive-out-of-scope|file|divert","reason",
#        "basis":"triage-threshold|cross-remit"}]}
#     enforcement_paths_allowed lists an enforcement path only when an entry
#     marked fix names that path. basis is required on waive-out-of-scope
#     entries; this verifier does not read it, the dispositions check does.
#
#   vetoes.json (the main thread, written with Bash at the main-checkout path):
#     {"version":1,"keys":[{"member","finding_class","path","line","vetoed_at",
#       "unit","effective_from_round"}]}
#     effective_from_round is the <s> that audit-loop-eval.sh next-unit prints
#     when the veto is written (the first round the next unit opens), so a
#     veto never re-fails the dispositions file that held the original waiver.
#
#   unit-<u>.json (the unit; absent while the unit runs, so its appearance
#   marks the unit returned):
#     {"version":1,"unit":u,"start_round":s,"through_round":t,"k":K,
#      "rounds":[{"round":r,"opened":true|false,...}],
#      "marker_state":{"<member>":"cleared|pending|declined"},
#      "stop_reason":"clean|window-end|checkpoint-deny|dispositions-check-failed|needs-human|member-wave-dirty|failure",
#      "stop_detail":"...","dispositions_files":["<path>"],
#      "waiver_table":"<markdown, informational>","residual_path":"...",
#      "diverted_count":<int>,"diverted_records":["<path>"],
#      "filing_outcomes":["<path>"],"filing_pending":<int>}
#     A unit that opened no round writes one element
#     {"round":<start>,"opened":false,"reason":"<stop_reason>"}.
#
#   baseline-<r>.json (the baseline subcommand):
#     {"schema":1,"round":r,"root":"...","head":"<commit>",
#      "index_digest":"<sha256 of git ls-files -s -z output>",
#      "verifier_files":["<file name in verifier-bin-<r>/>"],
#      "verifier_digest":"<sha256 over each pinned file's sha256 and name>",
#      "dirty":{"<path>":"<blob hash of working content, or deleted>"},
#      "untracked":["<path>"]}
#
#   fixer-<r>-audit.json (the fixer):
#     {"schema":1,"round":r,"attempt":k,
#      "results":[{"member","finding_class","path","line",
#        "disposition":"fixed|disputed|cannot_fix","reason","changed_paths":[]}],
#      "changed_paths":[],"reverted_paths":[]}
#
#   verifier-<r>-<k>.json (the check subcommand):
#     {"schema":1,"round":r,"attempt":k,"pass":true|false,
#      "errors":[{"kind","detail"}]}
#     kinds: missing-disposition, undeclared-path, undeclared-revert,
#     forbidden-path, enforcement-path, head-moved, index-changed,
#     audit-artifact-written, bad-input.
#     audit-artifact-written fires on a file under the shared audit directory
#     newer than the baseline unless it provably belongs to another branch.
#     A sidecar, ledger or scope file is skipped when its name lacks this
#     branch's slug. A marker or refusal is skipped only when its body's tree is
#     a well-formed object id that differs from this root's HEAD tree and from
#     the tree of its working content, its sha differs from HEAD, and the digest
#     in its file name is none of this branch's branch-own digests (at HEAD and
#     for the working content). A body with no tree, a malformed tree, or a
#     digest this branch's members own counts, as does every marker when the
#     branch-own digests cannot be resolved. Another branch's concurrent
#     audit never fails this branch's round.
#
# Known limits: an untracked path is judged on presence only, never content,
# and a mode-only change on a baseline-dirty path is invisible because the
# comparison is on content hashes. Both fail toward missing a delta the
# fixer's own declaration would have to name; the Quality Gate and the audit
# re-run still read the tree.

# Paths a fixer may touch only when the dispositions file lists them in
# enforcement_paths_allowed (and a fix entry names them): the code that bounds
# the loop must not be editable by the actor the loop bounds. That holds for
# this verifier through its pinned copy (see the header): the working-tree file
# is protected here, and the copy that judges the round is out of the tree.
ENFORCEMENT_PATHS=(
  '.claude/hooks/audit-loop-bound.sh'         # denies a dispatch past the allowance
  '.claude/hooks/audit-loop-grant.sh'         # records the human's grant or accept line
  '.claude/hooks/block-audit-loop-write.sh'   # keeps Claude off the branch state files
  '.claude/hooks/lib/jq-availability.sh'      # every hook's fail-closed jq check
  '.gaia/scripts/audit-loop-state-lib.sh'     # state schema, locking and line parsing
  '.gaia/scripts/audit-loop-eval.sh'          # verdict and allowance formulas
  '.gaia/scripts/audit-fix-verify.sh'         # this verifier
  '.gaia/scripts/branch-name-lib.sh'          # branch key every state path derives from
  '.gaia/scripts/main-root-lib.sh'            # main-checkout resolution for every state path
  '.claude/settings.json'                     # hook registrations and env knobs
  '.claude/settings.local.json'               # machine-local overrides of the same
  '.claude/hooks/audit-loop-ask-grant.sh'     # records the human's AskUserQuestion answer
  '.gaia/scripts/context-checkpoint-lib.sh'   # shared context threshold and bands
  '.gaia/scripts/audit-dispositions-check.sh' # deterministic dispositions check
  '.gaia/scripts/audit-loop-signals-lib.sh'   # rubric signals and unit/member decisions
  '.claude/agents/audit-loop-unit.md'         # the unit orchestrator's definition
  '.gaia/statusline/gaia-statusline.sh'       # writes the context reading the gate trusts
  '.gaia/statusline/context-reading.sh'       # the context reading writer
  '.gaia/statusline/left-side.sh'             # statusline left side, same writer chain
)

# Files the baseline pins into the run folder: this script and every library it
# sources from its own directory.
PIN_FILES=(
  audit-fix-verify.sh
  main-root-lib.sh
  audit-key-lib.sh
)

# Paths a fixer may never touch, declared or not.
FORBIDDEN_PATHS=(
  'CHANGELOG.md'                              # the main thread decides the entry at merge time
)

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage:
  audit-fix-verify.sh baseline    --root <R> --round <r> --out <baseline-file>
  audit-fix-verify.sh check       --root <R> --round <r> --attempt <k> --dispositions <f> --dispositions-sha <hex> --baseline <f> --baseline-sha <hex> --result <f> --out <f> [--extra-declared <paths-file>]...
  audit-fix-verify.sh drift       --root <R> --baseline <f>
  audit-fix-verify.sh round-check --run-folder <dir> --round <r>
EOF
  exit 2
}

die_usage() {
  printf 'audit-fix-verify: %s\n' "$1" >&2
  usage
}

command -v jq >/dev/null 2>&1 || {
  printf 'audit-fix-verify: jq is required and was not found on PATH\n' >&2
  exit 2
}

ROOT=''
ROUND=''
ATTEMPT=''
OUTPUT_FILE=''
DISPOSITIONS_FILE=''
DISPOSITIONS_SHA=''
BASELINE_FILE=''
BASELINE_SHA=''
RESULT=''
RUNFOLDER=''
EXTRA_DECLARED_FILES=''

TEMPORARY_DIRECTORY=''
# shellcheck disable=SC2329 # invoked through the EXIT trap
cleanup() { if [ -n "$TEMPORARY_DIRECTORY" ]; then rm -rf "$TEMPORARY_DIRECTORY"; fi; }
trap cleanup EXIT

_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$ROOT" "$@"; }

# Prints the sha256 of stdin. `shasum` is on macOS and most Linux, `sha256sum`
# is the coreutils fallback.
_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    return 1
  fi
}

# Prints the pin digest of the named files in directory $1: the sha256 of one
# `<file sha256>  <name>` line per file, in the order given.
_pin_digest() {
  local directory="$1" file_name file_digest
  shift
  for file_name in "$@"; do
    file_digest="$(_sha256 <"$directory/$file_name")" || return 1
    printf '%s  %s\n' "$file_digest" "$file_name"
  done | _sha256
}

# Succeeds when the files beside this script hash to the digest the baseline
# file $1 recorded. Fails closed on a baseline with no pin record or a pinned
# name that is not a plain file name.
_verify_pin() {
  local baseline_file="$1" want got file_name files=()
  want="$(jq -r '.verifier_digest // empty' "$baseline_file" 2>/dev/null)" || return 1
  [ -n "$want" ] || return 1
  while IFS= read -r file_name; do
    case "$file_name" in
      '' | */* | .*) return 1 ;;
    esac
    files+=("$file_name")
  done < <(jq -r '(.verifier_files // [])[]' "$baseline_file" 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 1
  got="$(_pin_digest "$_here" "${files[@]}")" || return 1
  [ "$got" = "$want" ]
}

# Atomic write: stdin to a temp file beside the destination, then mv.
_atomic_write() {
  local destination="$1" temporary_file
  mkdir -p "$(dirname "$destination")" || return 1
  temporary_file="$(mktemp "$destination.XXXXXX")" || return 1
  if cat >"$temporary_file" && mv "$temporary_file" "$destination"; then
    return 0
  fi
  rm -f "$temporary_file"
  return 1
}

_is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Prints the tree id of the root's working content (tracked files as they are
# on disk plus untracked, unignored ones), built in a throwaway index so the
# real index is untouched.
_working_tree_id() {
  local index_file="$TEMPORARY_DIRECTORY/wt-index"
  rm -f "$index_file"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" read-tree HEAD >/dev/null 2>&1 || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" add -A >/dev/null 2>&1 || return 1
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR GIT_INDEX_FILE="$index_file" git -C "$ROOT" write-tree 2>/dev/null
}

# Snapshot the current repo state into directory $1: head, index digest, a
# dirty map (path to working-content blob hash, or "deleted") and the
# untracked list.
snapshot_state() {
  local snapshot_directory="$1" file_path content_hash
  mkdir -p "$snapshot_directory" || return 1
  _git rev-parse HEAD >"$snapshot_directory/head" 2>/dev/null || return 1
  _git ls-files -s -z >"$snapshot_directory/index.raw" 2>/dev/null || return 1
  _sha256 <"$snapshot_directory/index.raw" >"$snapshot_directory/index_digest" || return 1
  # --no-renames: a rename would otherwise list only the new name and hide
  # the deleted old path.
  _git diff --no-ext-diff --no-renames --name-only -z HEAD -- >"$snapshot_directory/dirty.raw" 2>/dev/null || return 1
  : >"$snapshot_directory/dirty.tsv"
  while IFS= read -r -d '' file_path; do
    case "$file_path" in
      *$'\n'*) return 1 ;;
    esac
    if [ -e "$ROOT/$file_path" ] || [ -L "$ROOT/$file_path" ]; then
      content_hash="$(_git hash-object -- "$file_path" 2>/dev/null)" || content_hash='unreadable'
    else
      content_hash='deleted'
    fi
    printf '%s\t%s\n' "$content_hash" "$file_path" >>"$snapshot_directory/dirty.tsv"
  done <"$snapshot_directory/dirty.raw"
  jq -Rn '[inputs | capture("^(?<content_hash>[^\t]*)\t(?<file_path>.*)$")] | map({key: .file_path, value: .content_hash}) | from_entries' \
    <"$snapshot_directory/dirty.tsv" >"$snapshot_directory/dirty.json" || return 1
  _git ls-files --others --exclude-standard -z >"$snapshot_directory/untracked.raw" 2>/dev/null || return 1
  : >"$snapshot_directory/untracked.txt"
  while IFS= read -r -d '' file_path; do
    case "$file_path" in
      *$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$file_path" >>"$snapshot_directory/untracked.txt"
  done <"$snapshot_directory/untracked.raw"
  LC_ALL=C sort -u "$snapshot_directory/untracked.txt" -o "$snapshot_directory/untracked.txt"
  return 0
}

# Delta of the current snapshot ($2) from a baseline file ($1), as sorted path
# lists in $2/d_mod (content differs from the baseline value), $2/d_rev (a
# baseline-dirty path now equal to HEAD) and $2/d_unt (an untracked path added
# or removed).
compute_delta() {
  local baseline_file="$1" current_directory="$2"
  jq -r --slurpfile current_dirty "$current_directory/dirty.json" \
    '.dirty as $baseline_dirty | $current_dirty[0] | to_entries[] | select($baseline_dirty[.key] != .value) | .key' "$baseline_file" |
    LC_ALL=C sort -u >"$current_directory/d_mod" || return 1
  jq -r --slurpfile current_dirty "$current_directory/dirty.json" \
    '.dirty | keys[] as $dirty_path | select(($current_dirty[0] | has($dirty_path)) | not) | $dirty_path' "$baseline_file" |
    LC_ALL=C sort -u >"$current_directory/d_rev" || return 1
  jq -r '.untracked[]' "$baseline_file" | LC_ALL=C sort -u >"$current_directory/base_untracked.txt" || return 1
  {
    LC_ALL=C comm -13 "$current_directory/base_untracked.txt" "$current_directory/untracked.txt"
    LC_ALL=C comm -23 "$current_directory/base_untracked.txt" "$current_directory/untracked.txt"
  } | LC_ALL=C sort -u >"$current_directory/d_unt"
  return 0
}

ERRORS_FILE=''
add_error() {
  local detail="$2"
  detail=${detail//$'\t'/ }
  detail=${detail//$'\n'/ }
  printf '%s\t%s\n' "$1" "$detail" >>"$ERRORS_FILE"
  printf '%s: %s\n' "$1" "$detail" >&2
}

has_errors() { [ -s "$ERRORS_FILE" ]; }

# Reads paths on stdin and reports each one that is empty, absolute, starts
# with a dash, or carries a `..` segment.
validate_paths() {
  local label="$1" file_path
  while IFS= read -r file_path; do
    case "$file_path" in
      '' | /* | -*)
        add_error bad-input "path in $label is empty, absolute or starts with a dash: $file_path"
        continue
        ;;
    esac
    case "/$file_path/" in
      */../*) add_error bad-input "path in $label has a .. segment: $file_path" ;;
    esac
  done
}

finish_check() {
  jq -Rn --argjson round "$ROUND" --argjson attempt "$ATTEMPT" \
    '[inputs | split("\t") | {kind: .[0], detail: (.[1:] | join("\t"))}] as $errors
     | {schema: 1, round: $round, attempt: $attempt, pass: ($errors | length == 0), errors: $errors}' \
    <"$ERRORS_FILE" | _atomic_write "$OUTPUT_FILE" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUTPUT_FILE" >&2
    exit 1
  }
  if has_errors; then exit 1; fi
  exit 0
}

command_baseline() {
  local pin_directory pin_digest file_name
  if [ -z "$ROOT" ] || [ -z "$OUTPUT_FILE" ] || ! _is_uint "$ROUND"; then
    die_usage 'baseline needs --root, --round <int> and --out'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  if ! _git diff --cached --quiet 2>/dev/null; then
    printf 'audit-fix-verify: baseline refused: the index differs from HEAD (staged change or unreadable repo) in %s\n' "$ROOT" >&2
    exit 3
  fi
  if ! snapshot_state "$TEMPORARY_DIRECTORY/cur"; then
    printf 'audit-fix-verify: baseline refused: cannot read repo state (or a path contains a newline) in %s\n' "$ROOT" >&2
    exit 3
  fi
  # Members run in parallel on one tree and only report, so no edit is
  # attributable to one of them: any dirt after the wave stops the unit.
  {
    jq -r 'keys[]' "$TEMPORARY_DIRECTORY/cur/dirty.json"
    cat "$TEMPORARY_DIRECTORY/cur/untracked.txt"
  } | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/wave-dirty.txt"
  if [ -s "$TEMPORARY_DIRECTORY/wave-dirty.txt" ]; then
    printf 'member-wave-dirty\n'
    while IFS= read -r file_name; do
      printf 'dirty %s\n' "$file_name"
    done <"$TEMPORARY_DIRECTORY/wave-dirty.txt"
    printf 'audit-fix-verify: baseline refused: the member wave left the tree dirty in %s\n' "$ROOT" >&2
    exit 4
  fi
  pin_directory="$(dirname "$OUTPUT_FILE")/verifier-bin-$ROUND"
  rm -rf "$pin_directory"
  mkdir -p "$pin_directory" || exit 1
  for file_name in "${PIN_FILES[@]}"; do
    cp "$_here/$file_name" "$pin_directory/$file_name" || {
      printf 'audit-fix-verify: cannot pin %s into %s\n' "$file_name" "$pin_directory" >&2
      exit 1
    }
  done
  pin_digest="$(_pin_digest "$pin_directory" "${PIN_FILES[@]}")" || {
    printf 'audit-fix-verify: cannot hash the pinned verifier in %s\n' "$pin_directory" >&2
    exit 1
  }
  jq -n --argjson round "$ROUND" --arg root "$ROOT" \
    --arg head "$(cat "$TEMPORARY_DIRECTORY/cur/head")" --arg index_digest "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" \
    --slurpfile dirty "$TEMPORARY_DIRECTORY/cur/dirty.json" \
    --rawfile untracked "$TEMPORARY_DIRECTORY/cur/untracked.txt" \
    --arg pin_digest "$pin_digest" \
    '{schema: 1, round: $round, root: $root, head: $head, index_digest: $index_digest,
      verifier_files: $ARGS.positional, verifier_digest: $pin_digest,
      dirty: $dirty[0], untracked: ($untracked | split("\n") | map(select(. != "")))}' \
    --args "${PIN_FILES[@]}" |
    _atomic_write "$OUTPUT_FILE" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUTPUT_FILE" >&2
    exit 1
  }
  exit 0
}

command_drift() {
  local exit_status=0 file_path
  if [ -z "$ROOT" ] || [ -z "$BASELINE_FILE" ]; then
    die_usage 'drift needs --root and --baseline'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  jq -e '.schema == 1 and (.dirty | type == "object") and (.untracked | type == "array")' "$BASELINE_FILE" >/dev/null 2>&1 || {
    printf 'bad-input: baseline does not parse: %s\n' "$BASELINE_FILE" >&2
    exit 1
  }
  _verify_pin "$BASELINE_FILE" || {
    printf 'bad-input: the verifier files beside this script differ from the digest pinned in %s\n' "$BASELINE_FILE" >&2
    exit 1
  }
  snapshot_state "$TEMPORARY_DIRECTORY/cur" || {
    printf 'bad-input: cannot read repo state in %s\n' "$ROOT" >&2
    exit 1
  }
  compute_delta "$BASELINE_FILE" "$TEMPORARY_DIRECTORY/cur" || exit 1
  if [ "$(cat "$TEMPORARY_DIRECTORY/cur/head")" != "$(jq -r '.head' "$BASELINE_FILE")" ]; then
    printf 'head-moved\n' >&2
    exit_status=1
  fi
  if [ "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" != "$(jq -r '.index_digest' "$BASELINE_FILE")" ]; then
    printf 'index-changed\n' >&2
    exit_status=1
  fi
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    printf 'drift: %s\n' "$file_path" >&2
    exit_status=1
  done < <(cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/cur/d_unt")
  exit "$exit_status"
}

command_round_check() {
  local exit_status=0 log_file attempt_number
  if [ -z "$RUNFOLDER" ] || ! _is_uint "$ROUND"; then
    die_usage 'round-check needs --run-folder and --round <int>'
  fi
  if [ -e "$RUNFOLDER/baseline-$ROUND.json" ] && ! _verify_pin "$RUNFOLDER/baseline-$ROUND.json"; then
    printf 'bad-input: the verifier files beside this script differ from the digest pinned in baseline-%s.json\n' "$ROUND" >&2
    exit 1
  fi
  for log_file in "$RUNFOLDER"/gate-"$ROUND"-*.log; do
    [ -e "$log_file" ] || continue
    attempt_number="${log_file##*/gate-"$ROUND"-}"
    attempt_number="${attempt_number%.log}"
    _is_uint "$attempt_number" || continue
    if ! jq -e '.pass == true' "$RUNFOLDER/verifier-$ROUND-$attempt_number.json" >/dev/null 2>&1; then
      printf 'gate-%s-%s.log exists without a passing verifier-%s-%s.json\n' "$ROUND" "$attempt_number" "$ROUND" "$attempt_number" >&2
      exit_status=1
    fi
  done
  exit "$exit_status"
}

command_check() {
  local file_path input_label dispositions_ok=1 result_ok=1 baseline_ok=1 input_spec extra_declared_file protected_path main_checkout_root sha
  if [ -z "$ROOT" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$DISPOSITIONS_FILE" ] || [ -z "$DISPOSITIONS_SHA" ] || [ -z "$BASELINE_FILE" ] ||
    [ -z "$BASELINE_SHA" ] || [ -z "$RESULT" ] || ! _is_uint "$ROUND" || ! _is_uint "$ATTEMPT"; then
    die_usage 'check is missing a required option (or --round/--attempt is not an integer)'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  ERRORS_FILE="$TEMPORARY_DIRECTORY/errs"
  : >"$ERRORS_FILE"

  # Input validation. Anything wrong here ends the check before the delta is
  # computed: a file the fixer could have altered is never analysed.
  for input_spec in "$DISPOSITIONS_FILE:dispositions:$DISPOSITIONS_SHA" "$BASELINE_FILE:baseline:$BASELINE_SHA"; do
    sha="${input_spec##*:}"
    input_spec="${input_spec%:*}"
    input_label="${input_spec##*:}"
    input_spec="${input_spec%:*}"
    if [ ! -r "$input_spec" ]; then
      add_error bad-input "$input_label file unreadable: $input_spec"
    elif [ "$(_sha256 <"$input_spec")" != "$sha" ]; then
      add_error bad-input "$input_label file digest differs from the recorded digest: $input_spec"
      [ "$input_label" = dispositions ] && dispositions_ok=0 || baseline_ok=0
    fi
  done
  if [ ! -r "$RESULT" ]; then
    add_error bad-input "result file unreadable: $RESULT"
    result_ok=0
  fi
  [ -r "$DISPOSITIONS_FILE" ] || dispositions_ok=0
  [ -r "$BASELINE_FILE" ] || baseline_ok=0

  if [ "$dispositions_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file does not parse as a JSON object: $DISPOSITIONS_FILE"
      dispositions_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file carries the wrong round (want $ROUND)"
      dispositions_ok=0
    elif ! jq -e '(.entries | type == "array") and all(.entries[]; type == "object" and (.path | type == "string"))
        and ((.enforcement_paths_allowed // []) | type == "array")
        and all((.enforcement_paths_allowed // [])[]; type == "string")' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file has the wrong shape: $DISPOSITIONS_FILE"
      dispositions_ok=0
    fi
  fi
  if [ "$result_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file does not parse as a JSON object: $RESULT"
      result_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file carries the wrong round (want $ROUND)"
      result_ok=0
    elif ! jq -e --argjson attempt "$ATTEMPT" '.attempt == $attempt' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result attempt differs from --attempt $ATTEMPT"
      result_ok=0
    elif ! jq -e '(.results | type == "array")
        and all(.results[]; type == "object" and ((.changed_paths // []) | type == "array")
          and all((.changed_paths // [])[]; type == "string"))
        and ((.changed_paths // []) | type == "array") and all((.changed_paths // [])[]; type == "string")
        and ((.reverted_paths // []) | type == "array") and all((.reverted_paths // [])[]; type == "string")' \
      "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file has the wrong shape: $RESULT"
      result_ok=0
    fi
  fi
  if [ "$baseline_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file does not parse as a JSON object: $BASELINE_FILE"
      baseline_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file carries the wrong round (want $ROUND)"
      baseline_ok=0
    elif ! jq -e '(.head | type == "string") and (.index_digest | type == "string")
        and (.dirty | type == "object") and (.untracked | type == "array")
        and all(.untracked[]; type == "string")' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file has the wrong shape: $BASELINE_FILE"
      baseline_ok=0
    elif ! _verify_pin "$BASELINE_FILE"; then
      add_error bad-input "the verifier files beside this script differ from the digest pinned in the baseline (or it records none): $BASELINE_FILE"
      baseline_ok=0
    fi
  fi

  if [ "$dispositions_ok" = 1 ]; then
    jq -r '.entries[].path, (.enforcement_paths_allowed // [])[]' "$DISPOSITIONS_FILE" | validate_paths dispositions
    jq -r '(.enforcement_paths_allowed // [])[]' "$DISPOSITIONS_FILE" >"$TEMPORARY_DIRECTORY/allowed"
    while IFS= read -r file_path; do
      jq -e --arg file_path "$file_path" '[.entries[] | select(.disposition == "fix" and .path == $file_path)] | length > 0' "$DISPOSITIONS_FILE" >/dev/null 2>&1 ||
        add_error bad-input "enforcement_paths_allowed names a path no fix entry names: $file_path"
    done <"$TEMPORARY_DIRECTORY/allowed"
  fi
  if [ "$result_ok" = 1 ]; then
    jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[]), (.reverted_paths // [])[], (.results[].path | select(type == "string"))' \
      "$RESULT" | validate_paths result
  fi
  if [ "$baseline_ok" = 1 ]; then
    jq -r '(.dirty | keys[]), .untracked[]' "$BASELINE_FILE" | validate_paths baseline
  fi
  : >"$TEMPORARY_DIRECTORY/extra"
  while IFS= read -r extra_declared_file; do
    [ -n "$extra_declared_file" ] || continue
    if [ ! -r "$extra_declared_file" ]; then
      add_error bad-input "extra-declared file unreadable: $extra_declared_file"
      continue
    fi
    grep -v '^$' "$extra_declared_file" | validate_paths extra-declared
    grep -v '^$' "$extra_declared_file" >>"$TEMPORARY_DIRECTORY/extra"
  done <<EOF
$EXTRA_DECLARED_FILES
EOF

  if has_errors; then finish_check; fi

  if ! snapshot_state "$TEMPORARY_DIRECTORY/cur"; then
    add_error bad-input "cannot read repo state in $ROOT (or a path contains a newline)"
    finish_check
  fi
  compute_delta "$BASELINE_FILE" "$TEMPORARY_DIRECTORY/cur" || {
    add_error bad-input "cannot compute the delta from $BASELINE_FILE"
    finish_check
  }

  [ "$(cat "$TEMPORARY_DIRECTORY/cur/head")" = "$(jq -r '.head' "$BASELINE_FILE")" ] ||
    add_error head-moved "HEAD is $(cat "$TEMPORARY_DIRECTORY/cur/head"), baseline recorded $(jq -r '.head' "$BASELINE_FILE")"
  [ "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" = "$(jq -r '.index_digest' "$BASELINE_FILE")" ] ||
    add_error index-changed 'the index differs from the baseline index digest'

  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error missing-disposition "$file_path"
  done < <(jq -r --slurpfile result "$RESULT" '
    ($result[0].results) as $results
    | .entries[] | select(.disposition == "fix") as $fix_entry
    | select([$results[] | select(.member == $fix_entry.member and .finding_class == $fix_entry.finding_class
        and .path == $fix_entry.path and .line == $fix_entry.line
        and (.disposition == "fixed" or .disposition == "disputed" or .disposition == "cannot_fix"))] | length == 0)
    | "\($fix_entry.member) \($fix_entry.finding_class) \($fix_entry.path) \($fix_entry.line)"' "$DISPOSITIONS_FILE")

  jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[])' "$RESULT" |
    cat - "$TEMPORARY_DIRECTORY/extra" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/declared"
  jq -r '(.reverted_paths // [])[]' "$RESULT" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/reverted"

  cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_unt" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/d_au"
  LC_ALL=C comm -23 "$TEMPORARY_DIRECTORY/d_au" "$TEMPORARY_DIRECTORY/declared" >"$TEMPORARY_DIRECTORY/undeclared"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error undeclared-path "$file_path"
  done <"$TEMPORARY_DIRECTORY/undeclared"
  LC_ALL=C comm -23 "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/reverted" >"$TEMPORARY_DIRECTORY/unrev"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error undeclared-revert "$file_path"
  done <"$TEMPORARY_DIRECTORY/unrev"

  cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/cur/d_unt" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/d_all"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    for protected_path in "${FORBIDDEN_PATHS[@]}"; do
      [ "$file_path" = "$protected_path" ] && add_error forbidden-path "$file_path"
    done
    for protected_path in "${ENFORCEMENT_PATHS[@]}"; do
      if [ "$file_path" = "$protected_path" ] && ! grep -Fxq -- "$file_path" "$TEMPORARY_DIRECTORY/allowed" 2>/dev/null; then
        add_error enforcement-path "$file_path"
      fi
    done
  done <"$TEMPORARY_DIRECTORY/d_all"

  # shellcheck source=main-root-lib.sh
  . "$_here/main-root-lib.sh"
  if main_checkout_root="$(gaia_resolve_main_root "$ROOT" 2>/dev/null)" && [ -n "$main_checkout_root" ]; then
    if [ -d "$main_checkout_root/.gaia/local/audit" ]; then
      # The audit directory is shared by every linked worktree, so a file
      # newer than the baseline is skipped only when it provably belongs to
      # another branch. A sidecar, ledger or scope file is skipped when its
      # name lacks this branch's slug. A marker or refusal (named by digest
      # only) is skipped when its body carries a well-formed tree that is
      # neither this root's HEAD tree nor its working-content tree, a sha other
      # than HEAD, and its name's digest is none of this branch's branch-own
      # digests: the merge gate reads a marker by that name and never reads
      # the body's tree, so a body that merely differs from HEAD proves
      # nothing. Anything that cannot be proven foreign counts, so the check
      # never narrows silently.
      slug=''
      # shellcheck source=audit-key-lib.sh
      . "$_here/audit-key-lib.sh"
      slug="$(gaia_branch_slug "$ROOT" 2>/dev/null)" || slug=''
      head_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=''
      head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || head_sha=''
      worktree_tree="$(_working_tree_id)" || worktree_tree=''
      : >"$TEMPORARY_DIRECTORY/member-digests"
      digests_ok=0
      if [ -n "$worktree_tree" ] && [ -f "$ROOT/.claude/hooks/lib/audit-digest.sh" ]; then
        digests_ok=1
        for tree_reference in HEAD "$worktree_tree"; do
          # The batch form prints `<member><TAB><digest>` lines and nothing at
          # all when it cannot resolve the roster or the base. The merge base
          # comes from HEAD in both calls: a bare tree id has no history.
          # shellcheck source=/dev/null
          if ! member_digest_lines="$( (. "$ROOT/.claude/hooks/lib/audit-digest.sh" && audit_branch_digests_local "$ROOT" "$tree_reference") 2>/dev/null)" ||
            [ -z "$member_digest_lines" ]; then
            digests_ok=0
            break
          fi
          printf '%s\n' "$member_digest_lines" | cut -f2 >>"$TEMPORARY_DIRECTORY/member-digests"
        done
      fi
      find "$main_checkout_root/.gaia/local/audit" -type f -newer "$BASELINE_FILE" >"$TEMPORARY_DIRECTORY/audit-new" 2>/dev/null
      while IFS= read -r file_path; do
        [ -n "$file_path" ] || continue
        case "$file_path" in
          *.ok | *.refused)
            key="${file_path##*/}"
            key="${key%%.*}"
            if [ "$digests_ok" = 1 ] && [ -n "$head_tree" ] && [ -n "$worktree_tree" ] &&
              ! grep -Fxq -- "$key" "$TEMPORARY_DIRECTORY/member-digests" &&
              jq -e --arg head_tree "$head_tree" --arg worktree_tree "$worktree_tree" --arg head_sha "$head_sha" \
                '(type == "object") and ((.tree | type) == "string")
                  and (.tree | test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
                  and (.tree != $head_tree) and (.tree != $worktree_tree) and ((.sha // "") != $head_sha)' "$file_path" >/dev/null 2>&1; then
              continue
            fi
            ;;
          *)
            if [ -n "$slug" ]; then
              case "${file_path##*/}" in
                *".$slug."*) ;;
                *) continue ;;
              esac
            fi
            ;;
        esac
        add_error audit-artifact-written "$file_path"
      done <"$TEMPORARY_DIRECTORY/audit-new"
    fi
  else
    add_error bad-input "cannot resolve the main checkout root from $ROOT"
  fi

  finish_check
}

[ $# -ge 1 ] || usage
SUBCOMMAND="$1"
shift
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die_usage "option $1 needs a value"
  case "$1" in
    --root) ROOT="$2" ;;
    --round) ROUND="$2" ;;
    --attempt) ATTEMPT="$2" ;;
    --out) OUTPUT_FILE="$2" ;;
    --dispositions) DISPOSITIONS_FILE="$2" ;;
    --dispositions-sha) DISPOSITIONS_SHA="$2" ;;
    --baseline) BASELINE_FILE="$2" ;;
    --baseline-sha) BASELINE_SHA="$2" ;;
    --result) RESULT="$2" ;;
    --run-folder) RUNFOLDER="$2" ;;
    --extra-declared) EXTRA_DECLARED_FILES="$EXTRA_DECLARED_FILES$2"$'\n' ;;
    *) die_usage "unknown option $1" ;;
  esac
  shift 2
done

case "$SUBCOMMAND" in
  baseline) command_baseline ;;
  check) command_check ;;
  drift) command_drift ;;
  round-check) command_round_check ;;
  *) die_usage "unknown subcommand $SUBCOMMAND" ;;
esac
