#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-fix-verify.sh: deterministic check of one audit fix round. The main
# thread records a working-tree baseline after the audit members return, a
# fresh fixer sub-agent edits the tree, and this script judges the fixer's
# delta from that baseline. The main thread never trusts the fixer's own
# account of what it did: it commits and runs the Quality Gate only on a pass.
# A member's self-heal edits sit in the baseline, so only the fixer's delta is
# judged.
#
# Usage:
#   audit-fix-verify.sh baseline    --root <R> --round <r> --out <baseline-file>
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
# from HEAD; no output file is written). `check` writes its verifier file on
# every outcome, failures included.
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
#   dispositions-<r>.json (main thread):
#     {"schema":1,"round":r,"tree":"<hex>","root":"<abs resolved root>",
#      "enforcement_paths_allowed":["<path>"],
#      "entries":[{"member","finding_class","path","line","severity","title",
#        "failure_mode","suggested_fix",
#        "disposition":"fix|accept-residual|waive-out-of-scope|file","reason"}]}
#     enforcement_paths_allowed lists an enforcement path only when an entry
#     marked fix names that path.
#
#   baseline-<r>.json (the baseline subcommand):
#     {"schema":1,"round":r,"root":"...","head":"<commit>",
#      "index_digest":"<sha256 of git ls-files -s -z output>",
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
#     newer than the baseline that belongs to this branch only: its name
#     carries this branch's slug, or (a marker or refusal) its body names this
#     root's HEAD tree or commit. Another branch's concurrent audit never fails
#     this branch's round.
#
# Known limits: an untracked path is judged on presence only, never content,
# and a mode-only change on a baseline-dirty path is invisible because the
# comparison is on content hashes. Both fail toward missing a delta the
# fixer's own declaration would have to name; the Quality Gate and the audit
# re-run still read the tree.

# Paths a fixer may touch only when the dispositions file lists them in
# enforcement_paths_allowed (and a fix entry names them): the code that bounds
# the loop must not be editable by the actor the loop bounds.
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
OUT=''
DISP=''
DSHA=''
BASE=''
BSHA=''
RESULT=''
RUNFOLDER=''
EXTRAS=''

T=''
# shellcheck disable=SC2329 # invoked through the EXIT trap
cleanup() { if [ -n "$T" ]; then rm -rf "$T"; fi; }
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

# Atomic write: stdin to a temp file beside the destination, then mv.
_atomic_write() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  if cat >"$tmp" && mv "$tmp" "$dest"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Snapshot the current repo state into directory $1: head, index digest, a
# dirty map (path to working-content blob hash, or "deleted") and the
# untracked list.
snapshot_state() {
  local d="$1" p h
  mkdir -p "$d" || return 1
  _git rev-parse HEAD >"$d/head" 2>/dev/null || return 1
  _git ls-files -s -z >"$d/index.raw" 2>/dev/null || return 1
  _sha256 <"$d/index.raw" >"$d/index_digest" || return 1
  # --no-renames: a rename would otherwise list only the new name and hide
  # the deleted old path.
  _git diff --no-ext-diff --no-renames --name-only -z HEAD -- >"$d/dirty.raw" 2>/dev/null || return 1
  : >"$d/dirty.tsv"
  while IFS= read -r -d '' p; do
    case "$p" in
      *$'\n'*) return 1 ;;
    esac
    if [ -e "$ROOT/$p" ] || [ -L "$ROOT/$p" ]; then
      h="$(_git hash-object -- "$p" 2>/dev/null)" || h='unreadable'
    else
      h='deleted'
    fi
    printf '%s\t%s\n' "$h" "$p" >>"$d/dirty.tsv"
  done <"$d/dirty.raw"
  jq -Rn '[inputs | capture("^(?<h>[^\t]*)\t(?<p>.*)$")] | map({key: .p, value: .h}) | from_entries' \
    <"$d/dirty.tsv" >"$d/dirty.json" || return 1
  _git ls-files --others --exclude-standard -z >"$d/untracked.raw" 2>/dev/null || return 1
  : >"$d/untracked.txt"
  while IFS= read -r -d '' p; do
    case "$p" in
      *$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$p" >>"$d/untracked.txt"
  done <"$d/untracked.raw"
  LC_ALL=C sort -u "$d/untracked.txt" -o "$d/untracked.txt"
  return 0
}

# Delta of the current snapshot ($2) from a baseline file ($1), as sorted path
# lists in $2/d_mod (content differs from the baseline value), $2/d_rev (a
# baseline-dirty path now equal to HEAD) and $2/d_unt (an untracked path added
# or removed).
compute_delta() {
  local base="$1" cur="$2"
  jq -r --slurpfile c "$cur/dirty.json" \
    '.dirty as $b | $c[0] | to_entries[] | select($b[.key] != .value) | .key' "$base" |
    LC_ALL=C sort -u >"$cur/d_mod" || return 1
  jq -r --slurpfile c "$cur/dirty.json" \
    '.dirty | keys[] as $k | select(($c[0] | has($k)) | not) | $k' "$base" |
    LC_ALL=C sort -u >"$cur/d_rev" || return 1
  jq -r '.untracked[]' "$base" | LC_ALL=C sort -u >"$cur/base_untracked.txt" || return 1
  {
    LC_ALL=C comm -13 "$cur/base_untracked.txt" "$cur/untracked.txt"
    LC_ALL=C comm -23 "$cur/base_untracked.txt" "$cur/untracked.txt"
  } | LC_ALL=C sort -u >"$cur/d_unt"
  return 0
}

ERRS=''
add_err() {
  local d="$2"
  d=${d//$'\t'/ }
  d=${d//$'\n'/ }
  printf '%s\t%s\n' "$1" "$d" >>"$ERRS"
  printf '%s: %s\n' "$1" "$d" >&2
}

has_err() { [ -s "$ERRS" ]; }

# Reads paths on stdin and reports each one that is empty, absolute, starts
# with a dash, or carries a `..` segment.
validate_paths() {
  local label="$1" p
  while IFS= read -r p; do
    case "$p" in
      '' | /* | -*)
        add_err bad-input "path in $label is empty, absolute or starts with a dash: $p"
        continue
        ;;
    esac
    case "/$p/" in
      */../*) add_err bad-input "path in $label has a .. segment: $p" ;;
    esac
  done
}

finish_check() {
  jq -Rn --argjson r "$ROUND" --argjson k "$ATTEMPT" \
    '[inputs | split("\t") | {kind: .[0], detail: (.[1:] | join("\t"))}] as $e
     | {schema: 1, round: $r, attempt: $k, pass: ($e | length == 0), errors: $e}' \
    <"$ERRS" | _atomic_write "$OUT" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUT" >&2
    exit 1
  }
  if has_err; then exit 1; fi
  exit 0
}

cmd_baseline() {
  if [ -z "$ROOT" ] || [ -z "$OUT" ] || ! _is_uint "$ROUND"; then
    die_usage 'baseline needs --root, --round <int> and --out'
  fi
  T="$(mktemp -d)" || exit 1
  if ! _git diff --cached --quiet 2>/dev/null; then
    printf 'audit-fix-verify: baseline refused: the index differs from HEAD (staged change or unreadable repo) in %s\n' "$ROOT" >&2
    exit 3
  fi
  if ! snapshot_state "$T/cur"; then
    printf 'audit-fix-verify: baseline refused: cannot read repo state (or a path contains a newline) in %s\n' "$ROOT" >&2
    exit 3
  fi
  jq -n --argjson r "$ROUND" --arg root "$ROOT" \
    --arg head "$(cat "$T/cur/head")" --arg idx "$(cat "$T/cur/index_digest")" \
    --slurpfile d "$T/cur/dirty.json" \
    --rawfile u "$T/cur/untracked.txt" \
    '{schema: 1, round: $r, root: $root, head: $head, index_digest: $idx,
      dirty: $d[0], untracked: ($u | split("\n") | map(select(. != "")))}' |
    _atomic_write "$OUT" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUT" >&2
    exit 1
  }
  exit 0
}

cmd_drift() {
  local rc=0 p
  if [ -z "$ROOT" ] || [ -z "$BASE" ]; then
    die_usage 'drift needs --root and --baseline'
  fi
  T="$(mktemp -d)" || exit 1
  jq -e '.schema == 1 and (.dirty | type == "object") and (.untracked | type == "array")' "$BASE" >/dev/null 2>&1 || {
    printf 'bad-input: baseline does not parse: %s\n' "$BASE" >&2
    exit 1
  }
  snapshot_state "$T/cur" || {
    printf 'bad-input: cannot read repo state in %s\n' "$ROOT" >&2
    exit 1
  }
  compute_delta "$BASE" "$T/cur" || exit 1
  if [ "$(cat "$T/cur/head")" != "$(jq -r '.head' "$BASE")" ]; then
    printf 'head-moved\n' >&2
    rc=1
  fi
  if [ "$(cat "$T/cur/index_digest")" != "$(jq -r '.index_digest' "$BASE")" ]; then
    printf 'index-changed\n' >&2
    rc=1
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf 'drift: %s\n' "$p" >&2
    rc=1
  done < <(cat "$T/cur/d_mod" "$T/cur/d_rev" "$T/cur/d_unt")
  exit "$rc"
}

cmd_round_check() {
  local rc=0 f k
  if [ -z "$RUNFOLDER" ] || ! _is_uint "$ROUND"; then
    die_usage 'round-check needs --run-folder and --round <int>'
  fi
  for f in "$RUNFOLDER"/gate-"$ROUND"-*.log; do
    [ -e "$f" ] || continue
    k="${f##*/gate-"$ROUND"-}"
    k="${k%.log}"
    _is_uint "$k" || continue
    if ! jq -e '.pass == true' "$RUNFOLDER/verifier-$ROUND-$k.json" >/dev/null 2>&1; then
      printf 'gate-%s-%s.log exists without a passing verifier-%s-%s.json\n' "$ROUND" "$k" "$ROUND" "$k" >&2
      rc=1
    fi
  done
  exit "$rc"
}

cmd_check() {
  local p dok=1 rok=1 bok=1 f main sha
  if [ -z "$ROOT" ] || [ -z "$OUT" ] || [ -z "$DISP" ] || [ -z "$DSHA" ] || [ -z "$BASE" ] ||
    [ -z "$BSHA" ] || [ -z "$RESULT" ] || ! _is_uint "$ROUND" || ! _is_uint "$ATTEMPT"; then
    die_usage 'check is missing a required option (or --round/--attempt is not an integer)'
  fi
  T="$(mktemp -d)" || exit 1
  ERRS="$T/errs"
  : >"$ERRS"

  # Input validation. Anything wrong here ends the check before the delta is
  # computed: a file the fixer could have altered is never analysed.
  for f in "$DISP:dispositions:$DSHA" "$BASE:baseline:$BSHA"; do
    sha="${f##*:}"
    f="${f%:*}"
    p="${f##*:}"
    f="${f%:*}"
    if [ ! -r "$f" ]; then
      add_err bad-input "$p file unreadable: $f"
    elif [ "$(_sha256 <"$f")" != "$sha" ]; then
      add_err bad-input "$p file digest differs from the recorded digest: $f"
      [ "$p" = dispositions ] && dok=0 || bok=0
    fi
  done
  if [ ! -r "$RESULT" ]; then
    add_err bad-input "result file unreadable: $RESULT"
    rok=0
  fi
  [ -r "$DISP" ] || dok=0
  [ -r "$BASE" ] || bok=0

  if [ "$dok" = 1 ]; then
    if ! jq -e 'type == "object"' "$DISP" >/dev/null 2>&1; then
      add_err bad-input "dispositions file does not parse as a JSON object: $DISP"
      dok=0
    elif ! jq -e --argjson r "$ROUND" '.round == $r' "$DISP" >/dev/null 2>&1; then
      add_err bad-input "dispositions file carries the wrong round (want $ROUND)"
      dok=0
    elif ! jq -e '(.entries | type == "array") and all(.entries[]; type == "object" and (.path | type == "string"))
        and ((.enforcement_paths_allowed // []) | type == "array")
        and all((.enforcement_paths_allowed // [])[]; type == "string")' "$DISP" >/dev/null 2>&1; then
      add_err bad-input "dispositions file has the wrong shape: $DISP"
      dok=0
    fi
  fi
  if [ "$rok" = 1 ]; then
    if ! jq -e 'type == "object"' "$RESULT" >/dev/null 2>&1; then
      add_err bad-input "result file does not parse as a JSON object: $RESULT"
      rok=0
    elif ! jq -e --argjson r "$ROUND" '.round == $r' "$RESULT" >/dev/null 2>&1; then
      add_err bad-input "result file carries the wrong round (want $ROUND)"
      rok=0
    elif ! jq -e --argjson k "$ATTEMPT" '.attempt == $k' "$RESULT" >/dev/null 2>&1; then
      add_err bad-input "result attempt differs from --attempt $ATTEMPT"
      rok=0
    elif ! jq -e '(.results | type == "array")
        and all(.results[]; type == "object" and ((.changed_paths // []) | type == "array")
          and all((.changed_paths // [])[]; type == "string"))
        and ((.changed_paths // []) | type == "array") and all((.changed_paths // [])[]; type == "string")
        and ((.reverted_paths // []) | type == "array") and all((.reverted_paths // [])[]; type == "string")' \
      "$RESULT" >/dev/null 2>&1; then
      add_err bad-input "result file has the wrong shape: $RESULT"
      rok=0
    fi
  fi
  if [ "$bok" = 1 ]; then
    if ! jq -e 'type == "object"' "$BASE" >/dev/null 2>&1; then
      add_err bad-input "baseline file does not parse as a JSON object: $BASE"
      bok=0
    elif ! jq -e --argjson r "$ROUND" '.round == $r' "$BASE" >/dev/null 2>&1; then
      add_err bad-input "baseline file carries the wrong round (want $ROUND)"
      bok=0
    elif ! jq -e '(.head | type == "string") and (.index_digest | type == "string")
        and (.dirty | type == "object") and (.untracked | type == "array")
        and all(.untracked[]; type == "string")' "$BASE" >/dev/null 2>&1; then
      add_err bad-input "baseline file has the wrong shape: $BASE"
      bok=0
    fi
  fi

  if [ "$dok" = 1 ]; then
    jq -r '.entries[].path, (.enforcement_paths_allowed // [])[]' "$DISP" | validate_paths dispositions
    jq -r '(.enforcement_paths_allowed // [])[]' "$DISP" >"$T/allowed"
    while IFS= read -r p; do
      jq -e --arg p "$p" '[.entries[] | select(.disposition == "fix" and .path == $p)] | length > 0' "$DISP" >/dev/null 2>&1 ||
        add_err bad-input "enforcement_paths_allowed names a path no fix entry names: $p"
    done <"$T/allowed"
  fi
  if [ "$rok" = 1 ]; then
    jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[]), (.reverted_paths // [])[], (.results[].path | select(type == "string"))' \
      "$RESULT" | validate_paths result
  fi
  if [ "$bok" = 1 ]; then
    jq -r '(.dirty | keys[]), .untracked[]' "$BASE" | validate_paths baseline
  fi
  : >"$T/extra"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -r "$f" ]; then
      add_err bad-input "extra-declared file unreadable: $f"
      continue
    fi
    grep -v '^$' "$f" | validate_paths extra-declared
    grep -v '^$' "$f" >>"$T/extra"
  done <<EOF
$EXTRAS
EOF

  if has_err; then finish_check; fi

  if ! snapshot_state "$T/cur"; then
    add_err bad-input "cannot read repo state in $ROOT (or a path contains a newline)"
    finish_check
  fi
  compute_delta "$BASE" "$T/cur" || {
    add_err bad-input "cannot compute the delta from $BASE"
    finish_check
  }

  [ "$(cat "$T/cur/head")" = "$(jq -r '.head' "$BASE")" ] ||
    add_err head-moved "HEAD is $(cat "$T/cur/head"), baseline recorded $(jq -r '.head' "$BASE")"
  [ "$(cat "$T/cur/index_digest")" = "$(jq -r '.index_digest' "$BASE")" ] ||
    add_err index-changed 'the index differs from the baseline index digest'

  while IFS= read -r p; do
    [ -n "$p" ] && add_err missing-disposition "$p"
  done < <(jq -r --slurpfile res "$RESULT" '
    ($res[0].results) as $R
    | .entries[] | select(.disposition == "fix") as $e
    | select([$R[] | select(.member == $e.member and .finding_class == $e.finding_class
        and .path == $e.path and .line == $e.line
        and (.disposition == "fixed" or .disposition == "disputed" or .disposition == "cannot_fix"))] | length == 0)
    | "\($e.member) \($e.finding_class) \($e.path) \($e.line)"' "$DISP")

  jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[])' "$RESULT" |
    cat - "$T/extra" | LC_ALL=C sort -u >"$T/declared"
  jq -r '(.reverted_paths // [])[]' "$RESULT" | LC_ALL=C sort -u >"$T/reverted"

  cat "$T/cur/d_mod" "$T/cur/d_unt" | LC_ALL=C sort -u >"$T/d_au"
  LC_ALL=C comm -23 "$T/d_au" "$T/declared" >"$T/undeclared"
  while IFS= read -r p; do
    [ -n "$p" ] && add_err undeclared-path "$p"
  done <"$T/undeclared"
  LC_ALL=C comm -23 "$T/cur/d_rev" "$T/reverted" >"$T/unrev"
  while IFS= read -r p; do
    [ -n "$p" ] && add_err undeclared-revert "$p"
  done <"$T/unrev"

  cat "$T/cur/d_mod" "$T/cur/d_rev" "$T/cur/d_unt" | LC_ALL=C sort -u >"$T/d_all"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for f in "${FORBIDDEN_PATHS[@]}"; do
      [ "$p" = "$f" ] && add_err forbidden-path "$p"
    done
    for f in "${ENFORCEMENT_PATHS[@]}"; do
      if [ "$p" = "$f" ] && ! grep -Fxq -- "$p" "$T/allowed" 2>/dev/null; then
        add_err enforcement-path "$p"
      fi
    done
  done <"$T/d_all"

  # shellcheck source=main-root-lib.sh
  . "$_here/main-root-lib.sh"
  if main="$(gaia_resolve_main_root "$ROOT" 2>/dev/null)" && [ -n "$main" ]; then
    if [ -d "$main/.gaia/local/audit" ]; then
      # The audit directory is shared by every linked worktree, so a file
      # newer than the baseline counts only when it belongs to this branch: a
      # sidecar, ledger or scope file carries this branch's slug in its name,
      # and a marker or refusal (named by digest only) carries this root's
      # HEAD tree or commit in its body. A slug that cannot be resolved, or a
      # marker body that does not parse, counts the file, so the check never
      # narrows silently.
      slug=''
      # shellcheck source=audit-key-lib.sh
      . "$_here/audit-key-lib.sh"
      slug="$(gaia_branch_slug "$ROOT" 2>/dev/null)" || slug=''
      head_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=''
      head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || head_sha=''
      find "$main/.gaia/local/audit" -type f -newer "$BASE" >"$T/audit-new" 2>/dev/null
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
          *.ok | *.refused)
            if [ -n "$head_tree" ] && jq -e --arg t "$head_tree" --arg s "$head_sha" \
              '(type == "object") and (((.tree // "") != $t) and ((.sha // "") != $s))' "$p" >/dev/null 2>&1; then
              continue
            fi
            ;;
          *)
            if [ -n "$slug" ]; then
              case "${p##*/}" in
                *".$slug."*) ;;
                *) continue ;;
              esac
            fi
            ;;
        esac
        add_err audit-artifact-written "$p"
      done <"$T/audit-new"
    fi
  else
    add_err bad-input "cannot resolve the main checkout root from $ROOT"
  fi

  finish_check
}

[ $# -ge 1 ] || usage
SUB="$1"
shift
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die_usage "option $1 needs a value"
  case "$1" in
    --root) ROOT="$2" ;;
    --round) ROUND="$2" ;;
    --attempt) ATTEMPT="$2" ;;
    --out) OUT="$2" ;;
    --dispositions) DISP="$2" ;;
    --dispositions-sha) DSHA="$2" ;;
    --baseline) BASE="$2" ;;
    --baseline-sha) BSHA="$2" ;;
    --result) RESULT="$2" ;;
    --run-folder) RUNFOLDER="$2" ;;
    --extra-declared) EXTRAS="$EXTRAS$2"$'\n' ;;
    *) die_usage "unknown option $1" ;;
  esac
  shift 2
done

case "$SUB" in
  baseline) cmd_baseline ;;
  check) cmd_check ;;
  drift) cmd_drift ;;
  round-check) cmd_round_check ;;
  *) die_usage "unknown subcommand $SUB" ;;
esac
