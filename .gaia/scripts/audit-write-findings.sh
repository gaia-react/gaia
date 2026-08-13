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
#                           --findings <file>|-
#                           [--review-base <sha> --base-reason <token>]
#                           [--anchor-tree <tree>] [--help|-h]
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
#     --review-base OPTIONAL. The PER-MEMBER review base sha
#                 (.github/audit/resolve-audit-base.sh --member), distinct from
#                 --base above (the SHARED artifact key). Must be paired with
#                 --base-reason: exactly one present is a usage error.
#     --base-reason OPTIONAL. The reason token the resolver emitted for
#                 --review-base. Paired with it as above.
#     --anchor-tree OPTIONAL. The recorded tree of the clearance that anchored
#                 the per-member base, or an empty value on every path where no
#                 clearance anchored it. Independent of the pairing rule: valid
#                 present or absent regardless of --review-base/--base-reason.
#     --help | -h Usage, exit 0.
#
#   The pairing rule for --review-base/--base-reason is on flag PRESENCE, not
#   value emptiness: exactly one present is exit 2 naming the missing flag;
#   both present with an empty value is not an error, it just omits the
#   resulting review_base key (an empty BASE_SHA is a documented, reachable
#   state the agent fences already warn about, and keying the error to
#   emptiness would make that state skip the report of record entirely).
#
# Path (frozen; the key gaia_audit_key computes)
#   <root>/.gaia/local/audit/<base-sha>.<branch-slug>.<member>.findings.json
#   A base sha alone collides between two worktrees cut from the same main tip,
#   so the acting tree's own branch is the discriminator.
#
# Per-finding shape (every field REQUIRED unless noted)
#   finding_class  non-empty string. The closed holistic vocabulary the
#                  Code Audit Team members enumerate (see
#                  .claude/agents/code-audit-frontend.md, "Per-bucket
#                  finding_class convention"), or `holistic/unclassified`
#                  when no seeded class fits.
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
#   With --review-base and --base-reason both present and non-empty, one
#   additive key:
#   {"schema":1,"member":"<name>","findings":[...],
#    "review_base":{"sha":"<review-base>","reason":"<base-reason>",
#                   "anchor_tree":"<anchor-tree>"}}
#   `anchor_tree` is present only when --anchor-tree was itself present with a
#   non-empty value. `review_base` carries the per-member decision this
#   member's fence made (SPEC lifecycle step 8: the base, the reason, and the
#   clearance that anchored it) -- schema stays 1 because `.findings`, the
#   only shape any reader depends on, is unchanged and this key is optional.
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
# Bash 3.2 compatible (macOS default). Never `cd`s. jq required (fails closed,
# matching every other audit artifact writer in this directory).

set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/audit-key-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: audit-write-findings.sh --root <path> --member <name> --base <sha>
                               --findings <file>|-
                               [--review-base <sha> --base-reason <token>]
                               [--anchor-tree <tree>] [--help|-h]

  --root        the audited working root (the sidecar lands under it).
  --member      the Code Audit Team member writing the sidecar.
  --base        the incremental audit base sha (keyed with this tree's branch).
  --findings    a JSON array of finding objects, or `-` for stdin. `[]` is valid.
  --review-base the per-member review base sha. Must be paired with
                --base-reason: exactly one present is a usage error.
  --base-reason the resolver's reason token for --review-base.
  --anchor-tree the clearance tree that anchored --review-base. Independently
                optional; never part of the pairing rule.

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
REVIEW_BASE=""
REVIEW_BASE_SET=0
BASE_REASON=""
BASE_REASON_SET=0
ANCHOR_TREE=""
ANCHOR_TREE_SET=0

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
    --review-base)
      REVIEW_BASE="${2:-}"
      REVIEW_BASE_SET=1
      shift 2 2>/dev/null || shift
      ;;
    --base-reason)
      BASE_REASON="${2:-}"
      BASE_REASON_SET=1
      shift 2 2>/dev/null || shift
      ;;
    --anchor-tree)
      ANCHOR_TREE="${2:-}"
      ANCHOR_TREE_SET=1
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

# The pairing rule is on flag PRESENCE, never on value emptiness (see the
# header's Usage section): exactly one of --review-base/--base-reason present
# is a usage error naming the missing flag. Both present, even with an empty
# value, is not an error here -- the render step below decides whether an
# empty value omits the review_base key.
if [ "$REVIEW_BASE_SET" -ne "$BASE_REASON_SET" ]; then
  if [ "$REVIEW_BASE_SET" -eq 1 ]; then
    err "--base-reason is required when --review-base is present"
  else
    err "--review-base is required when --base-reason is present"
  fi
  usage
  exit 2
fi

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

AUDIT_KEY="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
if [ -z "$AUDIT_KEY" ]; then
  printf 'findings-sidecar: declined: audit key unresolved\n'
  exit 0
fi

audit_dir="${ROOT}/.gaia/local/audit"
target="${audit_dir}/${AUDIT_KEY}.${MEMBER}.findings.json"

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

# HAS_REVIEW_BASE gates the whole additive object: the pair must be present
# (already enforced above) AND both values non-empty. HAS_ANCHOR_TREE is
# independent, matching the header's rule that --anchor-tree never enters the
# pairing predicate.
HAS_REVIEW_BASE=false
if [ "$REVIEW_BASE_SET" -eq 1 ] && [ -n "$REVIEW_BASE" ] && [ -n "$BASE_REASON" ]; then
  HAS_REVIEW_BASE=true
fi
HAS_ANCHOR_TREE=false
if [ "$ANCHOR_TREE_SET" -eq 1 ] && [ -n "$ANCHOR_TREE" ]; then
  HAS_ANCHOR_TREE=true
fi

tmp="$(mktemp "${audit_dir}/.audit-write-findings.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 2
fi

# review_base is appended the same way audit-write-clearance.sh appends its
# optional supersedes block (audit-write-clearance.sh:354-375): a conditional
# `+ (if ... then {...} else {} end)` on the same object literal, every value
# passed through --arg so it stays escaped by construction.
if ! printf '%s' "$raw" | jq -c \
  --arg member "$MEMBER" \
  --argjson has_review_base "$HAS_REVIEW_BASE" \
  --argjson has_anchor_tree "$HAS_ANCHOR_TREE" \
  --arg review_base "$REVIEW_BASE" \
  --arg base_reason "$BASE_REASON" \
  --arg anchor_tree "$ANCHOR_TREE" \
  '{schema: 1, member: $member,
    findings: [.[]
      | . + {area_tags: (.area_tags
             // [(if (.path | test("/")) then (.path | sub("/[^/]*$"; "")) else "." end)])}]}
   + (if $has_review_base
      then {review_base: ({sha: $review_base, reason: $base_reason}
            + (if $has_anchor_tree then {anchor_tree: $anchor_tree} else {} end))}
      else {} end)' \
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
