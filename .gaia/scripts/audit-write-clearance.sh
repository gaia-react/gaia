#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact. Replaces the byte-identical inline `printf` each of the
# three agent definitions used to carry.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|refused \
#                            [--base <sha>] \
#                            [--supersede-refusal <reason>] \
#                            [--help|-h]
#
#   --root         REQUIRED. The audited working root. The member's content
#                  digest is derived from it (never from the caller's CWD)
#                  via the digest engine (.claude/hooks/lib/audit-digest.sh),
#                  which bounds a worktree run from stamping a marker keyed to
#                  another worktree's content.
#   --member       REQUIRED. The Code Audit Team member writing the clearance.
#   --provenance   REQUIRED. earned | refused.
#   --supersede-refusal <reason>
#                  OPTIONAL, valid ONLY with --provenance earned (a usage error
#                  with refused, or with an empty/whitespace reason). A member's
#                  explicit, reasoned reversal of its OWN prior same-digest
#                  refusal: when set and a sibling <digest>[.<member>].refused
#                  exists, the earned body records a `supersedes` block naming
#                  the reason, and the writer removes that sibling refusal AFTER
#                  the earned .ok is atomically published. This is the only
#                  legitimate refused->earned path on identical content (an
#                  operator acknowledges an unaddressed Important with a stated
#                  reason, so the digest does not move). Absent the flag, an
#                  earned write NEVER touches a sibling refusal, that strict
#                  precedence is the anti-gaming control (a bare re-run must not
#                  clear a refusal; only an authored, reasoned supersede may).
#   --base <sha>   OPTIONAL. The incremental audit base sha. When given, the
#                  write also maintains the re-run CARRY-FORWARD LEDGER
#                  (.gaia/local/audit/<audit-key>.rerun.json, keyed by
#                  gaia_audit_key: this base plus the acting tree's branch).
#                  This is what makes a refusal self-describing. A refusal
#                  blocks a merge, and a refusal is retired only by its own
#                  author, so an operator who cannot learn WHAT was refused can
#                  neither repair it nor legitimately supersede it. The ledger
#                  is that briefing, derived from the member's own findings
#                  sidecar (see "Ledger" below), so it costs the member nothing
#                  beyond the report it already wrote.
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Every write lands unconditionally: it overwrites a stale body at the
#     same path. There is no create-only guard and no carried family to
#     dominate; provenance is earned or refused only.
#   - Exit 0 on write; stdout is the marker path. Exit 2 on a usage error, when
#     the member's content digest cannot be derived, or when the body cannot be
#     built (message on stderr) -- never a marker written keyed to an empty or
#     partial digest, and never an empty or partial body published.
#   - The body is schema 4. `schema` is informational: no reader validates it,
#     and clearance_acceptable ignores it entirely, so a schema-3 body on disk
#     still validates exactly as before. The bump records that `sidecar`'s
#     meaning changed and that `dispositions_sidecar` joined it (see the two
#     flags' derivation below), so someone diffing two markers can tell which
#     contract each was written under.
#   - jq is REQUIRED: it builds the body, so every value is escaped by
#     construction. Absent jq the writer fails closed rather than emitting a
#     hand-assembled body. The gate's reader requires jq for the same reason.
#
# Ledger (only with --base; NON-GATING, best-effort)
#   Path: <root>/.gaia/local/audit/<base-sha>.<branch-slug>.rerun.json
#   Shape: schema 1, as the frontend member's "Re-run carry-forward ledger"
#   defines it, plus a `member` field on each entry. One ledger serves the whole
#   dispatched set (its key is the base, not a digest), so without that field a
#   second member's write would silently clobber the first's remaining work.
#
#   refused: this member's `remaining[]` entries are rebuilt from its findings
#     sidecar (.gaia/local/audit/<audit-key>.<member>.findings.json), which
#     already carries each finding's path, line, title, failure_mode and
#     suggested_fix. Severity is mapped onto the ledger's own scale
#     (error -> critical, warning -> important, suggestion -> suggestion).
#     Other members' entries are preserved untouched. `round` increments from a
#     valid same-branch same-base ledger, else starts at 1, and
#     `first_seen_round` carries forward per (member, finding_class, path, line)
#     so a finding that survives rounds keeps its original round.
#   earned: the loop ended for this member, so its `remaining[]` entries are
#     retired: each moves to `fixed_last_round[]` stamped with the current HEAD
#     sha. The FILE is removed only when no member has anything left, matching
#     the documented clean-pass cleanup without discarding a co-dispatched
#     member's still-open work.
#   No sidecar, or an unresolvable key, or a `jq` failure: no ledger work, and
#   the marker write is unaffected. The ledger never gates a merge, no hook
#   reads it, and a failure here never fails the write, so a ledger problem can
#   never hold a merge shut or open one.
#
#   LEDGER_TAG, not the conventional name, holds gaia_audit_key's output: the
#   secret-write guard (.claude/hooks/block-secrets-write.sh) denies an
#   assignment to a `*_KEY` name whose value is a command substitution, so the
#   conventional spelling cannot be written to a tracked file at all.
#
# This writer is NOT evidence-gated: it takes no --report, calls no detector,
# and its body carries no evidence block. It raises the forgery bar (a forged
# marker must now be writer-shaped) but does not close the pool's
# write-integrity weakness; that remains its own separate concern.
#
# Bash 3.2 compatible (macOS-default bash). Never `cd`.

set -uo pipefail

# The default member owns the infix-free filename family.
DEFAULT_MEMBER="code-audit-frontend"

usage() {
  cat <<'EOF' >&2
usage: audit-write-clearance.sh --root <path> --member <name>
                                --provenance earned|refused
                                [--base <sha>]
                                [--supersede-refusal <reason>]
                                [--help|-h]

  --base <sha>                  the incremental audit base sha; maintains the
                                re-run carry-forward ledger so a refusal briefs
                                its own repair. Non-gating, best-effort.
  --supersede-refusal <reason>  valid only with --provenance earned; records a
                                reasoned reversal of this member's own prior
                                same-digest refusal and removes it.
EOF
}

err() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

# Resolve the digest engine from THIS file's own on-disk location, never cwd,
# never $ROOT: .gaia/scripts -> ../../.claude/hooks/lib.
_write_clearance_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_write_clearance_lib_dir:-}" ] && [ -f "$_write_clearance_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_lib_dir/audit-digest.sh"
fi

# The ledger's key rule, shared with every other worktree-partitioned artifact.
# Sourced defensively, exactly as the digest engine above is: the marker write
# is this script's job and the ledger is a rider, so a missing key lib must
# degrade to "no ledger", never to a failed or noisy clearance write.
_write_clearance_script_dir="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_write_clearance_script_dir}/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_write_clearance_script_dir}/audit-key-lib.sh"
fi

ROOT=""
MEMBER=""
PROVENANCE=""
BASE=""
# SUPERSEDE_SEEN records that the flag was passed at all, kept separate from
# SUPERSEDE_REASON so that an empty reason (flag present, value blank) is a
# usage error while an absent flag is the ordinary no-supersede path.
SUPERSEDE_SEEN=0
SUPERSEDE_REASON=""

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
    --provenance)
      PROVENANCE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --base)
      BASE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --supersede-refusal)
      SUPERSEDE_SEEN=1
      SUPERSEDE_REASON="${2:-}"
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

if [ -z "$ROOT" ]; then
  err "--root is required"
  usage
  exit 2
fi
if [ -z "$MEMBER" ]; then
  err "--member is required"
  usage
  exit 2
fi
case "$PROVENANCE" in
  earned|refused) ;;
  "")
    err "--provenance is required"
    usage
    exit 2
    ;;
  *)
    err "invalid --provenance '$PROVENANCE' (want earned|refused)"
    usage
    exit 2
    ;;
esac

# --supersede-refusal is a reasoned reversal of an EARNED write only. Reject it
# on a refusal (a refusal supersedes nothing) and reject an empty/whitespace
# reason (supersession must be auditable, so it must carry a stated reason).
if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
  if [ "$PROVENANCE" != "earned" ]; then
    err "--supersede-refusal is valid only with --provenance earned"
    usage
    exit 2
  fi
  _supersede_trimmed="${SUPERSEDE_REASON#"${SUPERSEDE_REASON%%[![:space:]]*}"}"
  _supersede_trimmed="${_supersede_trimmed%"${_supersede_trimmed##*[![:space:]]}"}"
  if [ -z "$_supersede_trimmed" ]; then
    err "--supersede-refusal requires a non-empty reason"
    usage
    exit 2
  fi
fi

# The member's content digest is the marker's validity key. Fail closed: never
# write a marker keyed to an empty or partial digest.
command -v audit_member_digest >/dev/null 2>&1 || {
  err "cannot load the digest engine (.claude/hooks/lib/audit-digest.sh)"
  exit 2
}
digest="$(audit_member_digest "$ROOT" "$MEMBER" 2>/dev/null || true)"
if [ -z "$digest" ]; then
  err "cannot derive a content digest for member '$MEMBER' at --root '$ROOT'"
  exit 2
fi

# jq builds the body. Fail closed here rather than at the write, so a missing
# jq never leaves a half-provisioned audit dir behind.
command -v jq >/dev/null 2>&1 || {
  err "jq is required to write a clearance marker"
  exit 2
}

# Resolve the real HEAD tree and commit sha from the root, never from CWD.
# Plain data fields on the body now, not the filename key.
tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
if [ -z "$tree" ]; then
  err "cannot resolve HEAD tree for --root '$ROOT'"
  exit 2
fi
sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

# Version is the .gaia/VERSION literal under the root. Advisory data, never a
# merge-gate contract.
version=""
version_file="${ROOT}/.gaia/VERSION"
if [ -f "$version_file" ]; then
  version="$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')"
  version="${version#"${version%%[![:space:]]*}"}"
  version="${version%"${version##*[![:space:]]}"}"
fi

# Two sidecar flags, because there are two sidecars and one field cannot answer
# for both. Derived from the member name; no CLI flag for either.
#
#   sidecar               does this member file a FINDINGS sidecar, its report
#                         of record? Every member does, so this is always true.
#                         It used to be true only for the default member, which
#                         was contradicted by the store itself: most of the
#                         findings sidecars on disk belong to specialized
#                         members. Anything reasoning from this field about
#                         whether a report exists was therefore wrong for four
#                         of the five members, and a wrong answer here reads as
#                         "this refusal has no report", which is the state that
#                         makes a refusal look unrepairable.
#   dispositions_sidecar  does this member file the out-of-scope DISPOSITION
#                         sidecar the merge gate's backstop reads? Only the
#                         default member does. This is the distinction the old
#                         single field was actually carrying.
sidecar="true"
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  dispositions_sidecar="true"
else
  dispositions_sidecar="false"
fi

audited_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

audit_dir="${ROOT}/.gaia/local/audit"

# Filename family for this member/provenance: keyed to the member's content
# digest, not the tree.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  infix=""
else
  infix=".${MEMBER}"
fi
earned_path="${audit_dir}/${digest}${infix}.ok"
refused_path="${audit_dir}/${digest}${infix}.refused"

case "$PROVENANCE" in
  earned)  target="$earned_path" ;;
  refused) target="$refused_path" ;;
esac

# Supersession is an EARNED-only, explicit act. It records the reversal in the
# body and removes the sibling refusal only when the flag was passed AND a
# same-digest refusal is actually on disk. Absent the flag, do_supersede stays
# false and the sibling refusal is never touched: an earned write can only clear
# a refusal that its author explicitly, reasonedly reverses, never a bare re-run
# (the anti-gaming invariant). With the flag but no sibling refusal, the earned
# write is a plain idempotent write, no supersedes block, no error.
do_supersede=false
if [ "$PROVENANCE" = "earned" ] && [ "$SUPERSEDE_SEEN" -eq 1 ] && [ -f "$refused_path" ]; then
  do_supersede=true
fi

mkdir -p "$audit_dir" || {
  err "cannot create audit directory '$audit_dir'"
  exit 2
}

# Atomic write: temp file in the SAME directory as the target, then mv. A torn
# marker would clear the existence-testing merge gate while failing the
# reader's stricter body check, so the publish must be a single rename.
tmp="$(mktemp "${audit_dir}/.audit-write-clearance.XXXXXX" 2>/dev/null || true)"
if [ -z "$tmp" ]; then
  err "cannot create temp file in '$audit_dir'"
  exit 2
fi

# Body built by `jq -n`, never a hand-assembled template: every value is
# escaped by construction, so a field carrying a `"` or `\` can never emit
# malformed JSON. `-c` keeps the compact single-line shape the marker's
# consumers read. A jq failure must not publish an empty or partial marker.
jq -cn \
  --arg version "$version" \
  --argjson schema 4 \
  --arg member "$MEMBER" \
  --arg provenance "$PROVENANCE" \
  --arg digest "$digest" \
  --arg tree "$tree" \
  --arg sha "$sha" \
  --arg audited_at "$audited_at" \
  --argjson sidecar "$sidecar" \
  --argjson dispositions_sidecar "$dispositions_sidecar" \
  --argjson do_supersede "$do_supersede" \
  --arg supersede_reason "$SUPERSEDE_REASON" \
  '{version: $version, schema: $schema, member: $member,
    provenance: $provenance, digest: $digest, tree: $tree, sha: $sha,
    audited_at: $audited_at, sidecar: $sidecar,
    dispositions_sidecar: $dispositions_sidecar}
   + (if $do_supersede
      then {supersedes: {provenance: "refused", reason: $supersede_reason,
                         superseded_at: $audited_at}}
      else {} end)' \
  > "$tmp" || {
  rm -f "$tmp"
  err "cannot build the marker body"
  exit 2
}

mv -f "$tmp" "$target" || {
  rm -f "$tmp"
  err "cannot publish marker to '$target'"
  exit 2
}

# Order is load-bearing: the earned .ok is published above FIRST, the sibling
# refusal is removed here SECOND. A crash between the two leaves BOTH markers on
# disk, and the merge gate checks the refusal family first, so it stays shut
# (fail-safe). Removing the refusal first would open a window where neither an
# earned nor a refused marker exists. If the removal itself fails, the earned
# marker is already durably published, so warn and still exit 0 rather than
# reporting a false failure; the stale refusal keeps the gate shut until the
# next supersede attempt, never falsely opens it. This runs inside the writer
# subprocess, not as a Claude Bash tool call, so the destructive-command guard
# does not intercept it.
if [ "$do_supersede" = "true" ]; then
  rm -f "$refused_path" || err "warning: superseded but could not remove '$refused_path'"
fi

# -----------------------------------------------------------------------------
# Re-run carry-forward ledger (only with --base).
#
# Runs AFTER the marker is durably published, and every failure path below is a
# warning that still exits 0. The ordering and the fail-open are both
# deliberate: the marker is the gate artifact and the ledger is a briefing, so a
# ledger problem must never fail a write that already landed, and must never be
# able to hold a merge shut or open one.
#
# This is the step that makes a refusal self-describing. Without it a refusal is
# an opaque blocking artifact: it cannot be repaired by an operator who does not
# know what it found, and it cannot be superseded either, since supersession
# requires stating a reason the operator is not in a position to state.
# -----------------------------------------------------------------------------

if [ -n "$BASE" ]; then
  LEDGER_TAG=""
  if command -v gaia_audit_key >/dev/null 2>&1; then
    LEDGER_TAG="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  fi
  if [ -z "$LEDGER_TAG" ]; then
    err "warning: --base given but the audit key does not resolve; no ledger written"
  else
    ledger="${audit_dir}/${LEDGER_TAG}.rerun.json"
    # Deliberately NOT named `sidecar`: that name already holds the marker body's
    # boolean flag built above, and reusing it here would shadow the flag for any
    # future edit that moves a body build below this block.
    findings_sidecar="${audit_dir}/${LEDGER_TAG}.${MEMBER}.findings.json"
    branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"

    # A prior ledger counts only when it is for THIS branch and base; anything
    # else is stale and is replaced rather than extended (the reader contract's
    # own staleness rule, applied at the writer so a stale file never briefs).
    prior='null'
    if [ -f "$ledger" ]; then
      prior="$(jq -c --arg b "$branch" --arg base "$BASE" \
        'if (.schema == 1) and (.branch == $b) and (.base_sha == $base) then . else null end' \
        "$ledger" 2>/dev/null || echo null)"
      [ -n "$prior" ] || prior='null'
    fi

    ledger_body=""
    if [ "$PROVENANCE" = "refused" ]; then
      if [ ! -f "$findings_sidecar" ]; then
        err "warning: refusal recorded with no findings sidecar at '$findings_sidecar'; the ledger cannot brief the repair"
      else
        # remaining[] for THIS member is rebuilt from its sidecar every round:
        # the sidecar is the current report, so a finding it no longer names is
        # closed and must not linger. Other members' entries pass through
        # untouched, and first_seen_round is carried per finding identity.
        # Every `as` binding is fully parenthesized: jq's `as` binds looser than
        # `+` and `//`, so `a + 1 as $r | body` parses as `a + (1 as $r | body)`
        # and errors at runtime. jq's stderr is captured rather than discarded --
        # a silently-swallowed program error here would look exactly like "there
        # was nothing to write".
        if ! ledger_body="$(jq -n \
          --argjson prior "$prior" \
          --slurpfile sc "$findings_sidecar" \
          --arg member "$MEMBER" \
          --arg base "$BASE" \
          --arg branch "$branch" \
          --arg head "$sha" \
          --arg now "$audited_at" \
          '
          def ledger_severity:
            {"error":"critical","warning":"important","suggestion":"suggestion"}[.] // "important";
          ((($prior.round // 0) + 1)                            as $round
          | (($prior.remaining // []))                          as $prev
          | ([$prev[] | select(.member != $member)])            as $others
          | (($sc[0].findings // []))                           as $found
          | ([ $found[]
              | . as $f
              | ((first($prev[] | select(.member == $member
                                        and .finding_class == $f.finding_class
                                        and .path == $f.path
                                        and .line == $f.line)) // null) as $was
                | {member: $member,
                   finding_class: $f.finding_class,
                   severity: ($f.severity | ledger_severity),
                   path: $f.path,
                   line: $f.line,
                   title: $f.title,
                   failure_mode: $f.failure_mode,
                   verified_by: $f.verified_by,
                   suggested_fix: $f.suggested_fix,
                   first_seen_round: ($was.first_seen_round // $round),
                   escalated: false})
            ])                                                  as $mine
          | {schema: 1,
             base_sha: $base,
             branch: $branch,
             round: $round,
             head_sha: $head,
             updated_at: $now,
             remaining: ($others + $mine),
             fixed_last_round: [($prior.fixed_last_round // [])[]
                                | select(.member != $member)],
             notes: ($prior.notes // "")})
          ' 2>&1)"; then
          err "warning: cannot build the carry-forward ledger: $ledger_body"
          ledger_body=""
        fi
      fi
    else
      # An earned write ends this member's loop, so its open entries are retired
      # rather than left to misbrief the next round: each moves into
      # fixed_last_round stamped with the sha that closed it.
      #
      # Gated on this member's own refusal being gone. A plain earned write never
      # clears a live refusal (that is the anti-gaming rule: only --supersede-refusal
      # retires one, and it removes the file above at line 390, before this block).
      # So a refusal surviving here means the merge is still blocked on findings
      # that are still open, and retiring them would stamp fixed_in_sha on a repair
      # no commit made, then delete the very briefing needed to clear the block.
      # Skipping leaves ledger_body empty, which writes nothing and removes
      # nothing, so the briefing survives intact.
      if [ "$prior" != "null" ] && [ ! -f "$refused_path" ]; then
        if ! ledger_body="$(jq -n \
          --argjson prior "$prior" \
          --arg member "$MEMBER" \
          --arg head "$sha" \
          --arg now "$audited_at" \
          '
          ((($prior.remaining // []))                            as $prev
          | ([$prev[] | select(.member == $member)])             as $closed
          | $prior
            + {updated_at: $now,
               head_sha: $head,
               remaining: [$prev[] | select(.member != $member)],
               fixed_last_round:
                 ([($prior.fixed_last_round // [])[] | select(.member != $member)]
                  + [$closed[] | {member, finding_class, path, line, title,
                                  fixed_in_sha: $head}])})
          ' 2>&1)"; then
          err "warning: cannot update the carry-forward ledger: $ledger_body"
          ledger_body=""
        fi
      fi
    fi

    if [ -n "$ledger_body" ]; then
      # Clean-pass cleanup: the file goes away only when NO member has anything
      # left, so a co-dispatched member's still-open work is never discarded by
      # another member's clean pass.
      if [ "$PROVENANCE" = "earned" ] \
         && [ "$(printf '%s' "$ledger_body" | jq -r '(.remaining | length) == 0' 2>/dev/null)" = "true" ]; then
        rm -f "$ledger" || err "warning: could not remove the spent ledger '$ledger'"
      else
        ledger_tmp="$(mktemp "${audit_dir}/.audit-rerun-ledger.XXXXXX" 2>/dev/null || true)"
        if [ -z "$ledger_tmp" ]; then
          err "warning: cannot create a temp file for the ledger in '$audit_dir'"
        elif ! printf '%s\n' "$ledger_body" > "$ledger_tmp"; then
          rm -f "$ledger_tmp"
          err "warning: cannot stage the ledger"
        elif ! mv -f "$ledger_tmp" "$ledger"; then
          rm -f "$ledger_tmp"
          err "warning: cannot publish the ledger to '$ledger'"
        fi
      fi
    fi
  fi
fi

printf '%s\n' "$target"
exit 0
