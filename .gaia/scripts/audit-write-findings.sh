#!/usr/bin/env bash
# audit-write-findings.sh: the ONE shared writer for a Code Audit Team member's
# findings sidecar, the artifact the PR Merge Workflow calls "the report of
# record". Replaces the hand-authored `printf` each of the five agent
# definitions used to describe in prose.
#
# Why a writer and not prose
#   The sidecar is the only durable channel a member's findings travel through:
#   a member's returned text does not reliably reach the orchestrator, and a
#   refusal that carries no findings blocks a merge without briefing the repair
#   that would clear it. Prose alone produced sidecar entries holding a
#   finding_class, a severity, and a directory tag -- no file, no line, no
#   defect, no repair -- which cannot brief a fix. This writer makes the
#   actionable fields a precondition of the write: a finding missing any of
#   them is a hard usage error naming the offending index, not a silently
#   thinner record.
#
# Usage
#   audit-write-findings.sh --root <path> --member <name> --base <sha>
#                           --findings <file>|-  [--help|-h]
#
#     --root      REQUIRED. The audited working root. The sidecar lands under
#                 <root>/.gaia/local/audit/, and the audit key's branch half is
#                 read from THIS tree (never the caller's CWD).
#     --member    REQUIRED. The Code Audit Team member writing the sidecar.
#     --base      REQUIRED. The incremental audit base sha. Combined with the
#                 acting tree's own branch into the key
#                 (gaia_audit_key, .gaia/scripts/audit-key-lib.sh).
#     --findings  REQUIRED. Path to a JSON array of finding objects, or `-` to
#                 read that array from stdin. `[]` is valid and meaningful: the
#                 member ran and found nothing countable.
#     --help | -h Usage, exit 0.
#
# Path (frozen; the key gaia_audit_key computes)
#   <root>/.gaia/local/audit/<base-sha>.<branch-slug>.<member>.findings.json
#   A base sha alone collides between two worktrees cut from the same main tip,
#   so the acting tree's own branch is the discriminator.
#
# Per-finding shape (every field REQUIRED unless noted)
#   finding_class  non-empty string. The closed holistic vocabulary
#                  (.gaia/cli/src/schemas/finding-class.ts), or
#                  `holistic/unclassified` when no seeded class fits.
#   severity       one of error | warning | suggestion (Critical -> error,
#                  Important -> warning, Suggestion -> suggestion).
#   path           repo-relative POSIX path of the defect.
#   line           integer >= 1.
#   title          one-line statement of the defect.
#   failure_mode   the defect itself: input + state + wrong outcome.
#   verified_by    how the finding was verified. The executed evidence, not the
#                  reasoning that suggested looking (e.g. "fed the hook the
#                  braced-expansion fixture: base denies, HEAD allows").
#   suggested_fix  the recommended repair, concrete enough to act on.
#   area_tags      OPTIONAL array of strings. Defaults to the `path`'s
#                  directory, which is what the recurrence tally reads; supply
#                  it only to say something the dirname does not.
#
# Written shape (schema 1; the shape post-findings-block.sh merges)
#   {"schema":1,"member":"<name>","findings":[ {<finding>}, ... ]}
#
# Output contract
#   Exit 0 and the written path on stdout, OR exit 0 and one decline line when
#   the audit key does not resolve:
#     findings-sidecar: declined: audit key unresolved
#   That decline is the documented fail-open: an undeterminable base or branch
#   (detached HEAD, not a git repository) writes no sidecar rather than
#   inventing a fallback key that a reader would never look under.
#   Exit 2 on a usage error, unreadable/unparseable input, or a finding missing
#   a required field (message on stderr, offending index named).
#
# Deliberately NOT CI-gated. Every member's own remit skips the sidecar in CI;
# that gate lives in the prose that decides whether to call this at all. A
# GITHUB_ACTIONS/CI check here would make the writer's own test suite decline
# on CI and pass locally, which is the wrong place to put an environment rule.
#
# AUDIT_TAG, not AUDIT_KEY, holds gaia_audit_key's output, matching
# post-findings-block.sh: the secret-write guard
# (.claude/hooks/block-secrets-write.sh) denies an assignment to a `*_KEY` name
# whose value is a command substitution, so the conventional name cannot be
# written to a tracked file at all.
#
# Bash 3.2 compatible (macOS default). Never `cd`s. jq required (fails closed,
# matching every other audit artifact writer in this directory).

set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/audit-key-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: audit-write-findings.sh --root <path> --member <name> --base <sha>
                               --findings <file>|- [--help|-h]

  --root      the audited working root (the sidecar lands under it).
  --member    the Code Audit Team member writing the sidecar.
  --base      the incremental audit base sha (keyed with this tree's branch).
  --findings  a JSON array of finding objects, or `-` for stdin. `[]` is valid.

Each finding requires finding_class, severity (error|warning|suggestion), path,
line, title, failure_mode, verified_by, and suggested_fix. area_tags is
optional and defaults to the path's directory.

exit 0 = written (path on stdout) or declined; 2 = usage/validation error.
EOF
}

err() {
  printf 'audit-write-findings: %s\n' "$1" >&2
}

ROOT=""
MEMBER=""
BASE=""
FINDINGS_INPUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --member)
      MEMBER="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --base)
      BASE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --findings)
      FINDINGS_INPUT="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      err "unrecognized argument: $1"
      usage
      exit 2
      ;;
  esac
done

for _pair in "root:$ROOT" "member:$MEMBER" "base:$BASE" "findings:$FINDINGS_INPUT"; do
  if [ -z "${_pair#*:}" ]; then
    err "--${_pair%%:*} is required"
    usage
    exit 2
  fi
done

command -v jq >/dev/null 2>&1 || {
  err "jq is required to write a findings sidecar"
  exit 2
}

# -----------------------------------------------------------------------------
# 1. Read the input array. `-` is stdin so a caller can pipe a heredoc without
#    staging a temp file it then has to clean up.
# -----------------------------------------------------------------------------

if [ "$FINDINGS_INPUT" = "-" ]; then
  raw="$(cat)"
else
  if [ ! -f "$FINDINGS_INPUT" ]; then
    err "--findings file does not exist: $FINDINGS_INPUT"
    exit 2
  fi
  raw="$(cat "$FINDINGS_INPUT")"
fi

if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
  err "--findings must hold a JSON array of finding objects"
  exit 2
fi

# -----------------------------------------------------------------------------
# 2. Validate every entry BEFORE resolving a path or touching the filesystem, so
#    a rejected write leaves nothing half-written and nothing to clean up.
#
#    Validation is one jq pass that returns the FIRST offending entry as
#    "<index><tab><reason>", or nothing when every entry is complete. Doing it
#    in jq rather than a bash loop keeps the field rules in one readable place
#    and avoids re-parsing the array once per finding.
# -----------------------------------------------------------------------------

#    The finding is bound to $f before any field is read. Without the binding,
#    a `.severity` inside a `["error",...] | index(...)` pipe resolves against
#    the LITERAL ARRAY rather than the finding, which is a jq runtime error, and
#    an error swallowed by `2>/dev/null` would silently accept every finding.
#    So the jq status is checked and a validator that cannot run FAILS CLOSED.
if ! violation="$(printf '%s' "$raw" | jq -r '
  def nonempty_string: type == "string" and (length > 0);
  def reason:
    . as $f
    | if ($f | type) != "object" then "not a JSON object"
      elif ($f.finding_class | nonempty_string | not) then "finding_class must be a non-empty string"
      elif (($f.severity | type) != "string")
        or ((["error","warning","suggestion"] | index($f.severity)) == null)
        then "severity must be one of error|warning|suggestion"
      elif ($f.path | nonempty_string | not) then "path must be a non-empty repo-relative path"
      elif (($f.line | type) != "number") or ($f.line != ($f.line | floor)) or ($f.line < 1)
        then "line must be an integer >= 1"
      elif ($f.title | nonempty_string | not) then "title must be a non-empty string"
      elif ($f.failure_mode | nonempty_string | not) then "failure_mode must be a non-empty string"
      elif ($f.verified_by | nonempty_string | not) then "verified_by must be a non-empty string (how the finding was verified)"
      elif ($f.suggested_fix | nonempty_string | not) then "suggested_fix must be a non-empty string"
      elif (($f | has("area_tags"))
            and ((($f.area_tags | type) != "array")
                 or (any($f.area_tags[]; type != "string"))))
        then "area_tags, when present, must be an array of strings"
      else empty
      end;
  first(to_entries[] | select((.value | [reason] | length) > 0) | "\(.key)\t\(.value | reason)") // empty
' 2>&1)"; then
  err "cannot validate the findings input: $violation"
  exit 2
fi

if [ -n "$violation" ]; then
  _bad_index="${violation%%$'\t'*}"
  _bad_reason="${violation#*$'\t'}"
  err "findings[${_bad_index}]: ${_bad_reason}"
  err "a finding that cannot name its file, line, defect, verification, and repair cannot brief the fix that would clear it"
  exit 2
fi

# -----------------------------------------------------------------------------
# 3. Resolve the audit key. An undeterminable base or branch is the documented
#    fail-open skip, not an error: no reader looks under a fallback key.
# -----------------------------------------------------------------------------

AUDIT_TAG="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
if [ -z "$AUDIT_TAG" ]; then
  printf 'findings-sidecar: declined: audit key unresolved\n'
  exit 0
fi

audit_dir="${ROOT}/.gaia/local/audit"
target="${audit_dir}/${AUDIT_TAG}.${MEMBER}.findings.json"

mkdir -p "$audit_dir" || {
  err "cannot create audit directory '$audit_dir'"
  exit 2
}

# -----------------------------------------------------------------------------
# 4. Render and publish. area_tags defaults to the finding's own directory, so
#    the recurrence tally always has the field it reads without every member
#    restating what the path already says. Atomic (temp in the target dir, then
#    mv): a torn sidecar reads as a malformed report rather than an absent one,
#    and the merge-gate-adjacent readers treat those differently.
# -----------------------------------------------------------------------------

tmp="$(mktemp "${audit_dir}/.audit-write-findings.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 2
fi

if ! printf '%s' "$raw" | jq -c \
  --arg member "$MEMBER" \
  '{schema: 1, member: $member,
    findings: [.[]
      | . + {area_tags: (.area_tags
             // [(if (.path | test("/")) then (.path | sub("/[^/]*$"; "")) else "." end)])}]}' \
  > "$tmp"; then
  rm -f "$tmp"
  err "cannot render the findings sidecar"
  exit 2
fi

mv -f "$tmp" "$target" || {
  rm -f "$tmp"
  err "cannot publish the findings sidecar to '$target'"
  exit 2
}

printf '%s\n' "$target"
exit 0
