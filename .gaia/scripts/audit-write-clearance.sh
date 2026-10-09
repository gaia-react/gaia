#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact, replacing a byte-identical inline `printf` duplicated
# across the agent definitions.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|refused \
#                            [--base <sha>] \
#                            [--scope-digest <64-hex>] \
#                            [--supersede-refusal <reason>] \
#                            [--review full|light] \
#                            [--route-record <path>] \
#                            [--help|-h]
#
#   --root         REQUIRED, and validated: it must be a checkout ROOT, not a
#                  subdirectory of one and not a path a worktree used to
#                  occupy. The member's branch-own digest is derived from it
#                  (never from the caller's CWD) via the digest engine
#                  (.claude/hooks/lib/audit-digest.sh), which bounds a worktree
#                  run from stamping a marker keyed to another worktree's
#                  branch.
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
#                  (.gaia/local/audit/<audit-key>.rerun.json, at the derived
#                  key described under "Audit key" below; this value is the
#                  key's fallback, and its presence is what arms the ledger
#                  write). The open-finding accounting read does not need it.
#                  This is what makes a refusal self-describing. A refusal
#                  blocks a merge, and a refusal is retired only by its own
#                  author, so an operator who cannot learn WHAT was refused can
#                  neither repair it nor legitimately supersede it. The ledger
#                  is that briefing, derived from the member's own findings
#                  sidecar (see "Ledger" below), so it costs the member nothing
#                  beyond the report it already wrote.
#   --scope-digest <64-hex>
#                  OPTIONAL, gated on a PLAIN earned write only: never
#                  --provenance refused; an earned write carrying
#                  --supersede-refusal is conditionally exempt, see the
#                  staleness gate's own header comment further down for the
#                  exact condition. A member resolves its review scope at one
#                  HEAD, then finishes and writes at a later one; this
#                  carries the digest captured at scope resolution
#                  (.gaia/scripts/audit-scope-digest.sh --capture) for
#                  comparison against the digest this script derives fresh,
#                  right here, from the CURRENT --root. A difference means the
#                  member's review scope no longer describes what the marker
#                  would attest to, so the write refuses rather than
#                  publishing a marker keyed to unread content. A malformed
#                  value (not exactly 64 lowercase hex) is a usage error, not a
#                  staleness refusal.
#   --review full|light
#                  OPTIONAL, valid ONLY with --provenance earned. Earned bodies
#                  always carry `review`; absent the flag it is `full`, so every
#                  existing call site is unchanged. A refused body carries no
#                  `review` key. `light` is the cheap clearance a fresh router
#                  decision licenses, and it is never an incremental-scope anchor.
#                  It requires --route-record and refuses (exit 2, nothing
#                  written, no sibling touched) unless the record parses, says
#                  route light for this member, and names the digest and HEAD tree
#                  this script derives fresh from --root. It is a usage error
#                  with --supersede-refusal, and it refuses when a same-digest
#                  refusal sibling exists: a light clearance never supersedes or
#                  retires a refusal. It still passes the --scope-digest gate.
#   --route-record <path>
#                  Required with --review light, a usage error otherwise: the
#                  router's decision record.
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Every write lands unconditionally: it overwrites a stale body at the
#     same path. There is no create-only guard and no carried family to
#     dominate; provenance is earned or refused only.
#   - On a REFUSAL, and outside CI, also calls .claude/hooks/post-audit-status.sh
#     with the refusal it just wrote, so the required GAIA-Audit status falls to
#     `failure` and the merge paths that never run the local hook (GitHub's
#     auto-merge) cannot complete over a live refusal. Best-effort: its output
#     goes to stderr and any failure is absorbed, so stdout stays the marker
#     path and a refusal that cannot post one is still durably on disk.
#   - Exit 0 on write; stdout is the marker path. Exit 2 on a usage error, when
#     the member's branch-own digest cannot be derived, or when the body cannot be
#     built (message on stderr) -- never a marker written keyed to an empty or
#     partial digest, and never an empty or partial body published. A base tip
#     missing locally and a merge base that is not unique are exit 2 with their
#     one next step named (`git fetch origin`; the merge that makes the merge base
#     unique). Exit 3 when the open-finding accounting below fails: nothing is
#     published, no ledger byte changes, no status is posted, and the scope
#     capture is kept.
#   - The body is schema 4. `schema` is informational: no reader validates it,
#     and clearance_acceptable ignores it entirely, so a schema-3 body on disk
#     still validates exactly as before. A refused body carries
#     `review_coverage: {scope_digest}` when this member's scope capture at the
#     derived key recorded the write-time digest and was not taken on a
#     caller-overridden review base: the proof that the refusal's review covered
#     the content it is keyed to, which the incremental-scope resolver requires
#     before it anchors a member on its own refusal. Otherwise the key is absent.
#
# Branch-own digest
#   The member's digest covers the branch's own patch against the local base
#   reference (`audit_branch_digests_local`), bound to the branch. Content the
#   base brought in, by a clean catch-up merge, is not in it, so a catch-up
#   rotates no marker (barring a base edit within three lines of a branch
#   hunk) and leaves a scope capture equal to the write-time digest;
#   a change to the branch's own patch on the member's paths (including one made
#   inside a merge commit) rotates it.
#
# Audit key (the ledger, the findings sidecar, and the scope capture)
#   <key> = gaia_audit_key "$(git merge-base <KEY_REF> HEAD)" <root>, where
#   <KEY_REF> is the single line of the argument-less .github/audit/resolve-audit-base.sh,
#   run from the checkout root and resolved from this script's own location: the
#   branch's fork point, which a catch-up merge of the base never moves. The
#   merge-base it was built from is the KEY BASE. When that cannot be derived the
#   key falls back to the --base key (key base = the --base value); with neither,
#   nothing is located. The ledger records the key base as `.base_sha`, and both
#   staleness tests (the accounting read's and the ledger write's prior-ledger
#   test) compare against the key base, never against a differing --base: the
#   resolver links a refusal to the ledger only when `.base_sha` equals that
#   merge-base.
#
# Open-finding accounting (every write; GATING; before publish)
#   Each write, refused or earned (with or without --supersede-refusal), for a
#   member with open ledger entries must account for every one of them by
#   `entry_id`: the member's findings sidecar at the derived key either
#   re-reports it (a finding carrying that `entry_id`) or resolves it (a
#   `resolutions[]` record for that `entry_id` whose rationale is non-empty
#   after trimming). The check runs before anything publishes and fails closed:
#   an unaccounted entry, or open entries with an absent or unparseable
#   sidecar, exits 3 naming each unaccounted entry and the recovery step. It
#   applies regardless of --base, --scope-digest, or any sidecar flag, so
#   omitting a flag never skips it. On the supersede path it runs before the
#   refusal is removed, so an exit 3 leaves the `.refused` record in place.
#   The open set is the ledger's `remaining[]` entries for this member that
#   carry an `entry_id`; a ledger that does not parse, or whose branch or
#   `.base_sha` is not this tree's branch and key base, yields an empty open
#   set, EXCEPT when this member's scope capture recorded `base_reason`
#   `member-refusal`: the round then reviewed only the delta since the refusal,
#   so an unreadable or stale ledger is itself an exit 3 rather than an empty
#   set. A second exception covers a ledger written under an earlier key
#   derivation: with no ledger at the key, any ledger of this branch that holds
#   an open entry for this member under a base that is neither the key base nor
#   on HEAD's first-parent history is an exit 3 that lists each such ledger,
#   newest first, and prints the `jq` command re-keying the newest. No severity gate: re-reporting an open Critical or Important on an
#   earned write counts as accounted, exactly as on a refused write; whether an
#   earned marker is warranted stays the member protocol's precondition.
#   - jq is REQUIRED: it builds the body, so every value is escaped by
#     construction. Absent jq the writer fails closed rather than emitting a
#     hand-assembled body. The gate's reader requires jq for the same reason.
#
# Ledger write (armed by --base; best-effort, after publish)
#   Path: <root>/.gaia/local/audit/<key>.rerun.json, at the derived key above.
#   Shape: schema 1, as the frontend member's "Re-run carry-forward ledger"
#   defines it, plus a `member` field and a writer-assigned `entry_id` on each
#   entry, and a top-level `member_provenance` object. One ledger serves the
#   whole dispatched set (its key is the base, not a digest), so without the
#   `member` field a second member's write would silently clobber the first's
#   remaining work.
#
#   refused: this member's `remaining[]` entries are rebuilt from its findings
#     sidecar (.gaia/local/audit/<key>.<member>.findings.json), which already
#     carries each finding's path, line, title, failure_mode and suggested_fix.
#     Severity is mapped onto the ledger's own scale (error -> critical,
#     warning -> important, suggestion -> suggestion). A finding that echoes an
#     open `entry_id` keeps that id and its `first_seen_round` (its line may
#     move); every other finding gets a new id `r<round>-<n>`, unique within the
#     ledger. An open entry the sidecar resolves moves to `fixed_last_round[]`
#     carrying its `entry_id` and the rationale as `resolution`. The accounting
#     check has already refused any open entry that is neither. `round`
#     increments from a valid same-branch same-key-base ledger, else starts at
#     1. `member_provenance[<member>]` records this refusal's digest, tree, sha,
#     and version, the link the resolver checks before anchoring the member on
#     it. Other members' entries and provenance pass through untouched.
#   earned: the loop ended for this member, so its `remaining[]` entries are
#     retired: each moves to `fixed_last_round[]` stamped with the current HEAD
#     sha, its `entry_id`, and its resolution rationale when the sidecar
#     resolved it, and `member_provenance[<member>]` is removed. The FILE is
#     removed only when no member has anything left, matching the documented
#     clean-pass cleanup without discarding a co-dispatched member's still-open
#     work.
#   The accounting READ above gates and fails closed; this WRITE does not. No
#   sidecar, an unresolvable key, or a `jq` failure here means no ledger work,
#   and a failure here never fails a record that already published.
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
                                [--scope-digest <64-hex>]
                                [--supersede-refusal <reason>]
                                [--review full|light]
                                [--route-record <path>]
                                [--help|-h]

  --base <sha>                  the incremental audit base sha; arms the re-run
                                carry-forward ledger write so a refusal briefs
                                its own repair. The ledger write is best-effort;
                                the open-finding accounting read gates every
                                write and does not need --base.
  --scope-digest <64-hex>       gated on a plain earned write; refuses when it
                                differs from the write-time digest. See the
                                header comment above.
  --supersede-refusal <reason>  valid only with --provenance earned; records a
                                reasoned reversal of this member's own prior
                                same-digest refusal and removes it.
  --review full|light           valid only with --provenance earned; default
                                full. light also needs --route-record.
  --route-record <path>         the router decision record a light review
                                requires; a usage error otherwise.

exit 0 = written (marker path on stdout); 2 = usage, digest, or build error;
3 = open-finding accounting failure (nothing published).
EOF
}

error() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

# Resolve the digest engine and the version normalizer from THIS file's own
# on-disk location, never cwd, never $ROOT: .gaia/scripts -> ../../.claude/hooks/lib.
_write_clearance_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-branch-patch.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-branch-patch.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-base-provenance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-base-provenance.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-digest.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/gaia-version.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/gaia-version.sh"
fi

# The ledger's key rule, shared with every other worktree-partitioned artifact.
# Sourced defensively, exactly as the digest engine above is: the marker write
# is this script's job and the ledger is a rider, so a missing key lib must
# degrade to "no ledger", never to a failed or noisy clearance write.
_write_clearance_script_directory="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_write_clearance_script_directory}/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_write_clearance_script_directory}/audit-key-lib.sh"
fi

# The shared base resolver whose line 1 the audit key is derived from, located
# the same way: .gaia/scripts -> ../../.github/audit. Absent, the key falls
# back to the --base key.
_write_clearance_resolver_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.github/audit" 2>/dev/null && pwd)" || true
_write_clearance_resolver=""
if [ -n "${_write_clearance_resolver_directory:-}" ] && [ -f "${_write_clearance_resolver_directory}/resolve-audit-base.sh" ]; then
  _write_clearance_resolver="${_write_clearance_resolver_directory}/resolve-audit-base.sh"
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
# SCOPE_DIGEST_SEEN mirrors SUPERSEDE_SEEN above: a member that passes an
# empty value must hit the format-validation usage error, not read as "flag
# absent" and slip past the staleness gate silently.
SCOPE_DIGEST_SEEN=0
SCOPE_DIGEST=""
# REVIEW_SEEN mirrors SUPERSEDE_SEEN: an empty value must fail validation
# rather than read as an absent flag.
REVIEW_SEEN=0
REVIEW="full"
ROUTE_RECORD_SEEN=0
ROUTE_RECORD=""

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
    --scope-digest)
      SCOPE_DIGEST_SEEN=1
      SCOPE_DIGEST="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --supersede-refusal)
      SUPERSEDE_SEEN=1
      SUPERSEDE_REASON="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --review)
      REVIEW_SEEN=1
      REVIEW="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --route-record)
      ROUTE_RECORD_SEEN=1
      ROUTE_RECORD="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error "unrecognized argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "$ROOT" ]; then
  error "--root is required"
  usage
  exit 2
fi

# --root must BE a checkout root, not a subdirectory of one and not a path a
# worktree used to occupy. The branch-own digest, the HEAD tree and the marker
# store below are all derived from it, so a path that merely SITS INSIDE a
# checkout mints a marker attesting to content the caller never named. Compare
# physically resolved paths, via `cd <path> && pwd -P` rather than `realpath`
# (not guaranteed present on macOS -- see .gaia/scripts/main-root-lib.sh's
# header), so a symlinked checkout path passes a comparison it should pass.
_root_toplevel="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$_root_toplevel" ]; then
  error "--root '$ROOT' is not a git checkout"
  exit 2
fi
_root_physical_path="$(cd "$ROOT" 2>/dev/null && pwd -P)" || _root_physical_path=""
_toplevel_physical_path="$(cd "$_root_toplevel" 2>/dev/null && pwd -P)" || _toplevel_physical_path=""
if [ -z "$_root_physical_path" ] || [ "$_root_physical_path" != "$_toplevel_physical_path" ]; then
  error "--root '$ROOT' is not a checkout root (its checkout root is '$_root_toplevel')"
  exit 2
fi

if [ -z "$MEMBER" ]; then
  error "--member is required"
  usage
  exit 2
fi
case "$PROVENANCE" in
  earned|refused) ;;
  "")
    error "--provenance is required"
    usage
    exit 2
    ;;
  *)
    error "invalid --provenance '$PROVENANCE' (want earned|refused)"
    usage
    exit 2
    ;;
esac

if [ "$REVIEW_SEEN" -eq 1 ]; then
  case "$REVIEW" in
    full|light) ;;
    *)
      error "invalid --review '$REVIEW' (want full|light)"
      usage
      exit 2
      ;;
  esac
  if [ "$PROVENANCE" != "earned" ]; then
    error "--review is valid only with --provenance earned"
    usage
    exit 2
  fi
fi
if [ "$REVIEW" = "light" ]; then
  if [ "$ROUTE_RECORD_SEEN" -ne 1 ] || [ -z "$ROUTE_RECORD" ]; then
    error "--review light requires --route-record"
    usage
    exit 2
  fi
  if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
    error "--review light cannot be combined with --supersede-refusal"
    usage
    exit 2
  fi
elif [ "$ROUTE_RECORD_SEEN" -eq 1 ]; then
  error "--route-record is valid only with --review light"
  usage
  exit 2
fi

# --supersede-refusal is a reasoned reversal of an EARNED write only. Reject it
# on a refusal (a refusal supersedes nothing) and reject an empty/whitespace
# reason (supersession must be auditable, so it must carry a stated reason).
if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
  if [ "$PROVENANCE" != "earned" ]; then
    error "--supersede-refusal is valid only with --provenance earned"
    usage
    exit 2
  fi
  _supersede_trimmed="${SUPERSEDE_REASON#"${SUPERSEDE_REASON%%[![:space:]]*}"}"
  _supersede_trimmed="${_supersede_trimmed%"${_supersede_trimmed##*[![:space:]]}"}"
  if [ -z "$_supersede_trimmed" ]; then
    error "--supersede-refusal requires a non-empty reason"
    usage
    exit 2
  fi
fi

# --scope-digest, when present, must be exactly 64 lowercase hex: the shape
# the digest engine emits. This is a usage error, not a staleness refusal, so
# a caller passing a malformed value gets a distinct diagnostic from a caller
# whose digest genuinely rotated. Bash-3.2-safe `case`, not `[[ =~ ]]`.
_scope_digest_malformed=0
if [ "$SCOPE_DIGEST_SEEN" -eq 1 ]; then
  case "$SCOPE_DIGEST" in
    *[!0-9a-f]* | '') _scope_digest_malformed=1 ;;
  esac
  if [ "${#SCOPE_DIGEST}" -ne 64 ]; then
    _scope_digest_malformed=1
  fi
fi
if [ "$_scope_digest_malformed" -eq 1 ]; then
  error "--scope-digest must be a 64-hex digest"
  usage
  exit 2
fi

# The member's branch-own digest is the marker's validity key. Fail closed: never
# write a marker keyed to an empty or partial digest.
command -v audit_branch_digests_local >/dev/null 2>&1 || {
  error "cannot load the digest engine (.claude/hooks/lib/audit-digest.sh)"
  exit 2
}
digest=""
digest_status=0
digests_all="$(audit_branch_digests_local "$ROOT" 2>/dev/null)" || digest_status=$?
# The base tip not being present locally and the merge base not being unique each
# have one next step the operator can take; every other failure is "cannot derive".
case "$digest_status" in
  0) ;;
  4)
    error "cannot derive a branch-own digest for member '$MEMBER': the base branch tip is not present locally. Run: git fetch origin"
    exit 2
    ;;
  3)
    _merge_remedy_reference="$(audit_local_base_reference "$ROOT" 2>/dev/null || true)"
    error "cannot derive a branch-own digest for member '$MEMBER': this branch has more than one merge base with the base branch. Run: git merge --no-edit ${_merge_remedy_reference:-refs/remotes/origin/main}"
    exit 2
    ;;
esac
while IFS= read -r _digest_line; do
  if [ "${_digest_line%%$'\t'*}" = "$MEMBER" ]; then
    digest="${_digest_line#*$'\t'}"
    break
  fi
done <<EOF
$digests_all
EOF
if [ "$digest_status" -ne 0 ] || [ -z "$digest" ]; then
  error "cannot derive a branch-own digest for member '$MEMBER' at --root '$ROOT'"
  exit 2
fi

# _release_forfeited_capture: drop this member's stored capture as the
# superseded refusal below exits 2.
#
# Why the refusal cannot just exit. `audit-scope-digest.sh` spends a stored
# capture when a conclusion KEYED TO IT is on disk, which is the discriminator
# that tells a finished round from a running one. A round that ends without
# publishing anything is invisible to that test: it looks exactly like a running
# review, so its capture survives, and because the digest rotated while the
# round was ending, the NEXT round's earned write refuses `review scope
# superseded` and writes no artifact -- which spends nothing either. Every round
# after it refuses identically, forever, and the AND-aggregator holds
# GAIA-Audit shut with no in-band recovery. Three routes end a round that way:
# the dirty-tree withhold (the member definitions order a withhold with no
# `.refused` artifact, then ask for a re-dispatch once the operator commits,
# which is the rotation), a superseded forfeiture itself, and a crash or a
# no-op-detected round.
#
# Publishing a `.refused` here instead would spend the capture, but at the
# WRITE-TIME digest, which is not the one the spent test looks for; keyed to the
# CAPTURED digest it would spend correctly and then sit on disk as a live
# refusal blocking the very marker the next clean round earns, which is the
# hazard the withhold prose exists to avoid. Releasing the capture is what
# actually matches the situation: the round is over and produced nothing, so the
# next dispatch should start from a fresh capture.
#
# This costs the forfeited round and nothing after it. What it deliberately does
# NOT do is let the SAME round recover: a member that re-runs its scope fence
# after this refusal gets a fresh capture and could then earn a marker for
# content it reviewed at the old digest. Nothing in-band distinguishes a
# same-round re-run from the next dispatch -- that is why the refusal message
# says the round is forfeited in as many words, and why the member definitions
# say the fence re-run is safe EXCEPT after this refusal.
# Each outcome carries its own status, because the caller's diagnostic differs
# for each and a message that asserts one of them for all of them is read as a
# description of what happened. Saying "the capture is released" on a run
# that released nothing points the operator at a deadlock they have been told
# is already cleared.
#
#   0  released: a stored capture existed and is gone.
#   1  nothing to release: no capture is stored, so none can strand a later
#      round. Not a failure.
#   2  could not resolve the scope file at all -- no key lib, no --base (the CI
#      clearance call passes none), an unresolvable key, or the capture was
#      located but could not be removed. A capture may or may not still be
#      sitting there; this arm cannot always tell, and must not claim either.
_release_forfeited_capture() {
  local key="" scope_file
  command -v gaia_audit_key >/dev/null 2>&1 || return 2
  [ -n "$BASE" ] || return 2
  key="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  [ -n "$key" ] || return 2
  scope_file="${ROOT}/.gaia/local/audit/${key}.${MEMBER}.scope.json"
  [ -f "$scope_file" ] || return 1
  rm -f "$scope_file" || {
    error "warning: could not release the forfeited capture at '$scope_file'; the next round will refuse identically until it is removed"
    return 2
  }
  return 0
}

audit_directory="${ROOT}/.gaia/local/audit"

# Filename family for this member/provenance: keyed to the member's content
# digest, not the tree.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  infix=""
else
  infix=".${MEMBER}"
fi
earned_path="${audit_directory}/${digest}${infix}.ok"
refused_path="${audit_directory}/${digest}${infix}.refused"

# Whether a --supersede-refusal write actually has something to supersede.
# The flag alone is not enough: the gate below and do_supersede further down
# both need to agree on this, so it is derived once here rather than each
# re-deriving its own copy that could drift from the other's.
supersede_retires_refusal=0
if [ "$SUPERSEDE_SEEN" -eq 1 ] && [ -f "$refused_path" ]; then
  supersede_retires_refusal=1
fi

# A light clearance is licensed by a fresh router decision and by nothing else.
# Every check refuses before anything is written or touched, so a refused light
# attempt leaves the audit directory exactly as it found it.
if [ "$REVIEW" = "light" ]; then
  command -v jq >/dev/null 2>&1 || {
    error "jq is required to write a clearance marker"
    exit 2
  }
  if [ ! -r "$ROUTE_RECORD" ] || ! jq -e 'type == "object"' "$ROUTE_RECORD" >/dev/null 2>&1; then
    error "route record '$ROUTE_RECORD' is unreadable or not a JSON object"
    exit 2
  fi
  _light_head_tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
  if [ -z "$_light_head_tree" ]; then
    error "cannot resolve HEAD tree for --root '$ROOT'"
    exit 2
  fi
  _light_refusal="$(jq -r --arg member "$MEMBER" --arg digest "$digest" --arg tree "$_light_head_tree" '
    if .route != "light" then "route is not light"
    elif .member != $member then "route record names a different member"
    elif .digest != $digest then "route record digest is stale"
    elif .tree != $tree then "route record tree is stale"
    else "" end' "$ROUTE_RECORD" 2>/dev/null || echo "route record cannot be evaluated")"
  if [ -n "$_light_refusal" ]; then
    error "--review light refused: $_light_refusal"
    exit 2
  fi
  if [ -f "$refused_path" ]; then
    error "--review light refused: a same-digest refusal exists; a light clearance never supersedes a refusal"
    exit 2
  fi
fi

# Scope-digest staleness gate. Gated on a PLAIN earned write, a category
# that includes a --supersede-refusal write with no sibling refusal on disk:
# the flag exists so a member can retire its OWN prior same-digest refusal,
# and that act requires the refusal to actually be there. A write carrying the
# flag with nothing to retire is, by this writer's own filename family, an
# ordinary earned write, so it takes the ordinary earned write's gate rather
# than skipping it. A --provenance refused write is exempt throughout: a
# refusal is a claim that content should not merge, and suppressing THAT is
# the one genuinely fail-open outcome available here. Each arm below is its
# own explicit refusal rather than a `[ -n "$SCOPE_DIGEST" ] && …` guard, so
# an absent value refuses instead of silently skipping the comparison (the
# fail-open shape the inert `AUDIT_TREE_SHA` in the four specialists already
# shows the cost of).
#
# This gate does not make a stale-scope marker unreachable. A --provenance
# refused write is itself exempt and needs no digest, so the same outcome
# reaches an .ok marker in two calls: write a refusal, then supersede it with
# a mismatched --scope-digest. What this gate removes is the one-call form
# that left nothing behind; for a blocking member the surviving two-call
# route leaves a `.refused` artifact on disk on the way and publishes a body
# carrying a `supersedes` block with a stated reason and a timestamp, so it
# cannot be taken silently.
if [ "$PROVENANCE" = "earned" ] && [ "$supersede_retires_refusal" -ne 1 ]; then
  if [ "$SCOPE_DIGEST_SEEN" -ne 1 ]; then
    error "scope digest not supplied"
    # A member dispatched into a worktree loads the agent definition the
    # session resolved from the MAIN checkout, not from the worktree under
    # review. On a branch that edits that member's own definition the prompt it
    # is running therefore predates the edit, and a prompt predating this
    # handshake never learned to capture or pass a scope digest -- so its
    # earned write lands here. This refusal is the only channel that reaches
    # such a member, and without naming the cause it reads as the member's own
    # mistake: it retries identically, and if every dispatched member is in
    # that state the AND-aggregator holds the merge gate shut with nothing left
    # that can clear it. Naming the cause is what makes the stall self-clearing.
    error "If you were dispatched into a worktree whose branch edits your own agent definition, the definition you are running was resolved from the main checkout and predates that edit. Re-read your own definition from --root ('$ROOT'), follow it, and retry."
    exit 2
  elif [ "$SCOPE_DIGEST" != "$digest" ]; then
    error "review scope superseded: scope=$SCOPE_DIGEST write=$digest"
    _release_forfeited_capture
    case "$?" in
      0) error "this round is forfeited and its capture is released; the next dispatch captures fresh." ;;
      1) error "this round is forfeited; no stored capture was found to release, so nothing carries into the next dispatch." ;;
      *) error "this round is forfeited, but the stored capture could not be located or removed (no --base, an unresolvable audit key, the key library not being loaded, or the removal itself failed). If one is present, the next dispatch inherits it and refuses identically; clear it with audit-scope-digest.sh --capture --recapture." ;;
    esac
    error "Do NOT re-run the scope fence to obtain a new capture in this round: you reviewed the superseded content, and a marker earned on a fresh capture would attest content you never read."
    exit 2
  fi
fi

# jq builds the body. Fail closed here rather than at the write, so a missing
# jq never leaves a half-provisioned audit dir behind.
command -v jq >/dev/null 2>&1 || {
  error "jq is required to write a clearance marker"
  exit 2
}

# Resolve the real HEAD tree and commit sha from the root, never from CWD.
# Plain data fields on the body now, not the filename key.
tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
if [ -z "$tree" ]; then
  error "cannot resolve HEAD tree for --root '$ROOT'"
  exit 2
fi
sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

# Version is the .gaia/VERSION literal under the root. Advisory data, never a
# merge-gate contract.
version=""
if command -v gaia_read_version >/dev/null 2>&1; then
  version="$(gaia_read_version "${ROOT}/.gaia/VERSION")"
else
  # Degrade exactly as an absent VERSION file does rather than failing the
  # write: the marker's validity key is the digest above, not this field.
  error "version normalizer unavailable (.claude/hooks/lib/gaia-version.sh); recording an empty version"
fi

# -----------------------------------------------------------------------------
# Audit key derivation and open-finding accounting (before anything publishes).
#
# The key is derived here rather than taken from --base because the resolver
# links a refusal to the ledger by the merge-base it computes itself, and a
# member that dropped the flag passes no --base at all: a check keyed to
# the flag would be skippable by omitting it.
# -----------------------------------------------------------------------------

branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"

key_base=""
audit_key=""
if [ -n "$_write_clearance_resolver" ] \
   && command -v gaia_audit_key >/dev/null 2>&1; then
  # The resolver reads its repository from the working directory, so it runs
  # from the checkout root; its stderr is a decision trace, not ours to print.
  _key_resolver_output="$( (cd "$_root_toplevel" && bash "$_write_clearance_resolver") 2>/dev/null || true)"
  _key_reference="${_key_resolver_output%%$'\n'*}"
  case "$_key_reference" in
    '' | -*) _key_reference="" ;;
  esac
  if [ -n "$_key_reference" ]; then
    key_base="$(git -C "$ROOT" merge-base "$_key_reference" HEAD 2>/dev/null || true)"
    if [ -n "$key_base" ]; then
      audit_key="$(gaia_audit_key "$key_base" "$ROOT" 2>/dev/null || true)"
    fi
  fi
  [ -n "$audit_key" ] || key_base=""
fi
if [ -z "$audit_key" ] && [ -n "$BASE" ] && command -v gaia_audit_key >/dev/null 2>&1; then
  audit_key="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  if [ -n "$audit_key" ]; then
    key_base="$BASE"
  fi
fi

# _current_ledger <path>: the ledger as compact JSON when it parses as one
# schema-1 object for this branch and key base, else `null`. The accounting
# read and the ledger write's prior-ledger test share it, so the two can never
# disagree about which ledger is live.
_current_ledger() {
  local ledger_path="$1" current
  [ -f "$ledger_path" ] || {
    printf 'null\n'
    return 0
  }
  current="$(jq -cs --arg branch "$branch" --arg base "$key_base" '
    if (length == 1) and ((.[0] | type) == "object") and (.[0].schema == 1)
       and (.[0].branch == $branch) and (.[0].base_sha == $base)
    then .[0] else null end' "$ledger_path" 2>/dev/null)" || current='null'
  [ -n "$current" ] || current='null'
  printf '%s\n' "$current"
}

# _orphaned_ledger_candidates: prints, newest first, the path of every re-run
# ledger of this branch that holds an open entry for this member under a base
# that is neither the current key base nor on HEAD's first-parent history.
#
# Why that test cannot misfire on an earlier round's ledger: the key base is the
# branch's fork point, and an incremental round keys on a past HEAD of this
# branch. The fork point and every past HEAD sit on HEAD's first-parent chain,
# and a catch-up merge adds to that chain without ever removing from it. A base
# off the chain is therefore a base tip a merge brought in (the key derivation
# before it was stable across catch-ups) or a commit a rebase or amend removed.
#
# Newest is by the committer date of the ledger's base; a base git cannot
# resolve sorts last.
_orphaned_ledger_candidates() {
  local branch_slug candidate candidate_base chain="" chain_loaded=0
  local committer_date rows="" newline=$'\n'
  branch_slug="$(gaia_branch_slug "$ROOT" 2>/dev/null)" || return 0
  [ -n "$branch_slug" ] || return 0
  for candidate in "${audit_directory}/"*".${branch_slug}.rerun.json"; do
    [ -f "$candidate" ] || continue
    [ "$candidate" != "$ledger" ] || continue
    candidate_base="$(jq -rs --arg branch "$branch" --arg member "$MEMBER" '
      if (length == 1) and ((.[0] | type) == "object") and (.[0].schema == 1)
         and (.[0].branch == $branch)
         and ((.[0].base_sha | type) == "string") and ((.[0].base_sha | length) > 0)
         and ((.[0].remaining | type) == "array")
         and any(.[0].remaining[]; type == "object" and .member == $member)
      then .[0].base_sha else empty end' "$candidate" 2>/dev/null)" || continue
    [ -n "$candidate_base" ] || continue
    [ "$candidate_base" != "$key_base" ] || continue
    if [ "$chain_loaded" -eq 0 ]; then
      chain="$(git -C "$ROOT" rev-list --first-parent HEAD 2>/dev/null)" || return 0
      chain="${newline}${chain}${newline}"
      chain_loaded=1
    fi
    case "$chain" in
      *"${newline}${candidate_base}${newline}"*) continue ;;
    esac
    committer_date=""
    case "$candidate_base" in
      *[!0-9a-f]*) ;;
      *) committer_date="$(git -C "$ROOT" log -1 --format=%ct "${candidate_base}^{commit}" 2>/dev/null || true)" ;;
    esac
    case "$committer_date" in
      '' | *[!0-9]*) rows="${rows}0000000000000"$'\t'"${candidate}"$'\n' ;;
      *) rows="${rows}$(printf '1%012d' "$committer_date")"$'\t'"${candidate}"$'\n' ;;
    esac
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | LC_ALL=C sort -r | while IFS= read -r candidate; do
    printf '%s\n' "${candidate#*$'\t'}"
  done
}

# _findings_report <path>: the findings sidecar as compact JSON when it parses
# as one object, else `null`.
_findings_report() {
  local sidecar_path="$1" report
  [ -f "$sidecar_path" ] || {
    printf 'null\n'
    return 0
  }
  report="$(jq -cs 'if (length == 1) and ((.[0] | type) == "object") then .[0] else null end' \
    "$sidecar_path" 2>/dev/null)" || report='null'
  [ -n "$report" ] || report='null'
  printf '%s\n' "$report"
}

ledger=""
findings_sidecar=""
if [ -n "$audit_key" ]; then
  ledger="${audit_directory}/${audit_key}.rerun.json"
  findings_sidecar="${audit_directory}/${audit_key}.${MEMBER}.findings.json"
fi

accounting_protocol_pointer="The accounting step is documented in your own definition under '${_root_toplevel}/.claude/agents/'."
# gaia:maintainer-only:start
accounting_protocol_pointer="The accounting step is documented in '${_root_toplevel}/.claude/hooks/lib/audit-member-protocol.md' and in your own definition under '${_root_toplevel}/.claude/agents/'."
# gaia:maintainer-only:end

review_coverage_digest=""
if [ -n "$audit_key" ]; then
  capture_file="${audit_directory}/${audit_key}.${MEMBER}.scope.json"
  capture_reason=""
  capture_digest=""
  capture_overridden="false"
  if [ -f "$capture_file" ]; then
    capture_reason="$(jq -r '.base_reason // "" | tostring' "$capture_file" 2>/dev/null || true)"
    capture_digest="$(jq -r '.scope_digest // "" | tostring' "$capture_file" 2>/dev/null || true)"
    capture_overridden="$(jq -r '.base_overridden == true' "$capture_file" 2>/dev/null || echo unreadable)"
  fi

  # The review-coverage proof: the refusal's own round reviewed the content
  # the refusal is keyed to, on the base the resolver chose.
  if [ "$PROVENANCE" = "refused" ] && [ -n "$capture_digest" ] \
     && [ "$capture_digest" = "$digest" ] && [ "$capture_overridden" = "false" ]; then
    review_coverage_digest="$digest"
  fi

  current_ledger="$(_current_ledger "$ledger")"

  # No ledger at the key is not yet "nothing open": a branch that caught up with
  # its base before the key stopped moving on a catch-up wrote its ledger under
  # the base tip it merged. Publishing now would read an empty open set and drop
  # that ledger's open entries for this member.
  if [ ! -f "$ledger" ]; then
    orphaned_ledgers="$(_orphaned_ledger_candidates)"
    if [ -n "$orphaned_ledgers" ]; then
      newest_orphaned_ledger="${orphaned_ledgers%%$'\n'*}"
      error "open-finding accounting failed: there is no re-run ledger at '$ledger', but this branch has ledger(s) with open entries for member '$MEMBER' keyed to a base that is not on this branch's history. The branch caught up with its base before the audit key stopped moving on a catch-up, or its history was rewritten; writing now would drop those open findings silently."
      error "Ledger(s), newest first:"
      while IFS= read -r orphaned_ledger_path; do
        printf 'audit-write-clearance:   %s\n' "$orphaned_ledger_path" >&2
      done <<EOF
$orphaned_ledgers
EOF
      if [ "$newest_orphaned_ledger" != "$orphaned_ledgers" ]; then
        error "The recovery below re-keys the newest of them; the others are older rounds of the same branch and stay where they are."
      fi
      error "Recovery: re-key the ledger to the current key base, then retry this write:"
      printf 'audit-write-clearance:   jq --arg base %q %s %q > %q\n' \
        "$key_base" "'.base_sha = \$base'" "$newest_orphaned_ledger" "$ledger" >&2
      error "$accounting_protocol_pointer"
      exit 3
    fi
  fi

  # A round resolved on member-refusal reviewed only the delta since the
  # refusal; its open findings live nowhere but the ledger, so a ledger that
  # cannot be read must refuse here, never read as "nothing open".
  if [ "$capture_reason" = "member-refusal" ] && [ "$current_ledger" = "null" ]; then
    error "open-finding accounting failed: this round's review scope was resolved on member-refusal, but the re-run ledger at '$ledger' is absent, unreadable, or stale, so the findings that refusal left open cannot be accounted for."
    error "Recovery: release the capture with audit-scope-digest.sh --release, re-run the scope resolver (it no longer anchors on the refusal, so it resolves an earlier base: the whole-team signal if one precedes the refusal, else full scope), review, and write again."
    error "$accounting_protocol_pointer"
    exit 3
  fi

  # No live ledger means an empty open set (the member-refusal case refused
  # above), so there is nothing to evaluate.
  unaccounted_entries=""
  findings_report="$(_findings_report "$findings_sidecar")"
  if [ "$current_ledger" != "null" ] && ! unaccounted_entries="$(jq -rn \
    --argjson ledger "$current_ledger" \
    --argjson report "$findings_report" \
    --arg member "$MEMBER" '
    def nonempty_string: type == "string" and length > 0;
    def array_or_empty: if type == "array" then . else [] end;
    ([($ledger.remaining // null | array_or_empty)[] | objects
      | select(.member == $member and (.entry_id | nonempty_string))])   as $open
    | ([($report.findings // null | array_or_empty)[] | objects
        | .entry_id | select(nonempty_string)]
       + [($report.resolutions // null | array_or_empty)[] | objects
          | select((.rationale | type) == "string"
                   and ((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0)
          | .entry_id | select(nonempty_string)])                         as $accounted
    | $open[]
    | . as $entry
    | select(any($accounted[]; . == $entry.entry_id) | not)
    | [.entry_id, (.finding_class // "" | tostring), (.path // "" | tostring),
       (.line // "" | tostring)]
    | map(gsub("[\t\n\r\u001f]"; " "))
    | join("\u001f")
    ' 2>&1)"; then
    error "open-finding accounting failed: the ledger and sidecar could not be evaluated: $unaccounted_entries"
    error "$accounting_protocol_pointer"
    exit 3
  fi

  if [ -n "$unaccounted_entries" ]; then
    if [ "$findings_report" = "null" ]; then
      error "open-finding accounting failed: member '$MEMBER' has open re-run ledger entries and no readable findings sidecar at '$findings_sidecar'. Unaccounted entries:"
    else
      error "open-finding accounting failed: these open re-run ledger entries for member '$MEMBER' are neither re-reported nor resolved:"
    fi
    while IFS=$'\037' read -r entry_identifier entry_class entry_path entry_line; do
      [ -n "$entry_identifier" ] || continue
      printf 'audit-write-clearance:   %s  %s  %s:%s\n' \
        "$entry_identifier" "$entry_class" "$entry_path" "$entry_line" >&2
    done <<<"$unaccounted_entries"
    error "Recovery: re-check each entry at HEAD, then rewrite the findings sidecar with audit-write-findings.sh, re-reporting a still-present finding with its entry_id or passing --resolutions with {entry_id, rationale} for one that is fixed or acknowledged, and retry this write."
    error "$accounting_protocol_pointer"
    exit 3
  fi
fi

# Every member files a FINDINGS sidecar, its report of record, so this flag
# is always true. No CLI flag for it.
sidecar="true"

audited_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$PROVENANCE" in
  earned)  target="$earned_path" ;;
  refused) target="$refused_path" ;;
esac

# Supersession is an EARNED-only, explicit act. It records the reversal in the
# body and removes the sibling refusal only when the flag was passed AND a
# same-digest refusal is actually on disk. Absent the flag, do_supersede stays
# false and the sibling refusal is never touched: an earned write can only clear
# a refusal that its author explicitly, reasonedly reverses, never a bare re-run
# (the anti-gaming invariant). See the staleness gate's header comment above
# for what happens with the flag but no sibling refusal on disk.
do_supersede=false
if [ "$PROVENANCE" = "earned" ] && [ "$supersede_retires_refusal" -eq 1 ]; then
  do_supersede=true
fi

mkdir -p "$audit_directory" || {
  error "cannot create audit directory '$audit_directory'"
  exit 2
}

# Atomic write: temp file in the SAME directory as the target, then mv. A torn
# marker would clear the existence-testing merge gate while failing the
# reader's stricter body check, so the publish must be a single rename.
temporary_file="$(mktemp "${audit_directory}/.audit-write-clearance.XXXXXX" 2>/dev/null || true)"
if [ -z "$temporary_file" ]; then
  error "cannot create temp file in '$audit_directory'"
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
  --arg review "$REVIEW" \
  --argjson do_supersede "$do_supersede" \
  --arg supersede_reason "$SUPERSEDE_REASON" \
  --arg review_coverage "$review_coverage_digest" \
  '{version: $version, schema: $schema, member: $member,
    provenance: $provenance, digest: $digest, tree: $tree, sha: $sha,
    audited_at: $audited_at, sidecar: $sidecar}
   + (if $provenance == "earned" then {review: $review} else {} end)
   + (if $provenance == "refused" and $review_coverage != ""
      then {review_coverage: {scope_digest: $review_coverage}}
      else {} end)
   + (if $do_supersede
      then {supersedes: {provenance: "refused", reason: $supersede_reason,
                         superseded_at: $audited_at}}
      else {} end)' \
  > "$temporary_file" || {
  rm -f "$temporary_file"
  error "cannot build the marker body"
  exit 2
}

mv -f "$temporary_file" "$target" || {
  rm -f "$temporary_file"
  error "cannot publish marker to '$target'"
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
  rm -f "$refused_path" || error "warning: superseded but could not remove '$refused_path'"
fi

# -----------------------------------------------------------------------------
# Re-run carry-forward ledger (only with --base).
#
# Runs AFTER the marker is durably published, and every failure path below is a
# warning that still exits 0. The ordering and the fail-open are both
# deliberate: the marker is the gate artifact and the ledger is a briefing, so a
# problem WRITING the ledger must never fail a record that already landed. The
# gating read of the same ledger ran before publish, in the accounting block.
#
# This is the step that makes a refusal self-describing. Without it a refusal is
# an opaque blocking artifact: it cannot be repaired by an operator who does not
# know what it found, and it cannot be superseded either, since supersession
# requires stating a reason the operator is not in a position to state.
# -----------------------------------------------------------------------------

if [ -n "$BASE" ]; then
  if [ -z "$audit_key" ]; then
    error "warning: --base given but the audit key does not resolve; no ledger written"
  else
    # A prior ledger counts only when it is for THIS branch and key base;
    # anything else is stale and is replaced rather than extended (the reader
    # contract's own staleness rule, applied at the writer so a stale file
    # never briefs).
    prior="$(_current_ledger "$ledger")"
    # Deliberately NOT named `sidecar`: that name already holds the marker
    # body's boolean flag built above.
    sidecar_report="$(_findings_report "$findings_sidecar")"

    ledger_body=""
    if [ "$PROVENANCE" = "refused" ]; then
      if [ ! -f "$findings_sidecar" ]; then
        error "warning: refusal recorded with no findings sidecar at '$findings_sidecar'; the ledger cannot brief the repair"
      elif [ "$sidecar_report" = "null" ]; then
        error "warning: cannot build the carry-forward ledger: the findings sidecar at '$findings_sidecar' does not parse"
      else
        # remaining[] for THIS member is rebuilt from its sidecar every round.
        # The accounting check has already refused any open entry the sidecar
        # neither re-reports nor resolves, so each one is either carried by its
        # entry_id (keeping first_seen_round, taking the re-reported line) or
        # moved to fixed_last_round with its resolution. An id echoed twice is
        # claimed by its first finding only, so ids stay unique. Other members'
        # entries and provenance pass through untouched.
        # Every `as` binding is fully parenthesized: jq's `as` binds looser than
        # `+` and `//`, so `a + 1 as $r | body` parses as `a + (1 as $r | body)`
        # and errors at runtime. jq's stderr is captured rather than discarded --
        # a silently-swallowed program error here would look exactly like "there
        # was nothing to write".
        if ! ledger_body="$(jq -n \
          --argjson prior "$prior" \
          --argjson report "$sidecar_report" \
          --arg member "$MEMBER" \
          --arg base "$key_base" \
          --arg branch "$branch" \
          --arg head "$sha" \
          --arg now "$audited_at" \
          --arg digest "$digest" \
          --arg tree "$tree" \
          --arg version "$version" \
          '
          def ledger_severity:
            {"error":"critical","warning":"important","suggestion":"suggestion"}[.] // "important";
          def nonempty_string: type == "string" and length > 0;
          def array_or_empty: if type == "array" then . else [] end;
          ((($prior.round // 0) + 1)                                        as $round
          | (($prior.remaining // null | array_or_empty))                   as $previous_entries
          | ([$previous_entries[] | select(.member != $member)])            as $others
          | ([$previous_entries[] | objects
              | select(.member == $member and (.entry_id | nonempty_string))]) as $open
          | (($report.findings // null | array_or_empty))                   as $found
          | ([($report.resolutions // null | array_or_empty)[] | objects
              | select((.entry_id | nonempty_string)
                       and ((.rationale | type) == "string")
                       and (((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0))]) as $resolutions
          | (reduce $found[] as $finding ({claimed: [], pairs: []};
              ((if ($finding.entry_id | nonempty_string) then $finding.entry_id else null end) as $echo
               | ((if ($echo != null) and (any(.claimed[]; . == $echo) | not)
                   then (first($open[] | select(.entry_id == $echo)) // null)
                   else null end) as $was
                  | .claimed += (if $was != null then [$echo] else [] end)
                  | .pairs += [{finding: $finding, was: $was}]))))          as $matched
          | ((reduce $matched.pairs[] as $pair ({count: 0, entries: []};
              (if $pair.was == null then .count += 1 else . end)
              | ((if $pair.was != null then $pair.was.entry_id
                  else "r\($round)-\(.count)" end) as $entry_identifier
                 | ((if $pair.was != null then ($pair.was.first_seen_round // $round)
                     else $round end) as $first_seen
                    | ($pair.finding) as $finding
                    | .entries += [{member: $member,
                                    entry_id: $entry_identifier,
                                    finding_class: $finding.finding_class,
                                    severity: ($finding.severity | ledger_severity),
                                    path: $finding.path,
                                    line: $finding.line,
                                    title: $finding.title,
                                    failure_mode: $finding.failure_mode,
                                    verified_by: $finding.verified_by,
                                    suggested_fix: $finding.suggested_fix,
                                    first_seen_round: $first_seen,
                                    escalated: false}])))).entries)          as $mine
          | ($matched.claimed)                                              as $rereported
          | ([$open[]
              | . as $entry
              | select(any($rereported[]; . == $entry.entry_id) | not)
              | ((first($resolutions[] | select(.entry_id == $entry.entry_id)) // null) as $resolution
                 | select($resolution != null)
                 | {member, entry_id, finding_class, path, line, title,
                    fixed_in_sha: $head, resolution: $resolution.rationale})]) as $resolved
          | {schema: 1,
             base_sha: $base,
             branch: $branch,
             round: $round,
             head_sha: $head,
             updated_at: $now,
             remaining: ($others + $mine),
             fixed_last_round: ([($prior.fixed_last_round // null | array_or_empty)[]
                                 | select(.member != $member)] + $resolved),
             notes: ($prior.notes // ""),
             member_provenance:
               ((if ($prior.member_provenance | type) == "object"
                 then $prior.member_provenance else {} end)
                + {($member): {refusal_digest: $digest, refusal_tree: $tree,
                               refusal_sha: $head, version: $version}})})
          ' 2>&1)"; then
          error "warning: cannot build the carry-forward ledger: $ledger_body"
          ledger_body=""
        fi
      fi
    else
      # An earned write ends this member's loop, so its open entries are retired
      # rather than left to misbrief the next round: each moves into
      # fixed_last_round stamped with the sha that closed it, its entry_id, and
      # the rationale of the resolution that accounted for it, if any. The
      # member's provenance goes with them: nothing of its refusal is left to
      # anchor on.
      #
      # Gated on this member's own refusal being gone. A plain earned write never
      # clears a live refusal (that is the anti-gaming rule: only --supersede-refusal
      # retires one, and it removes the file above, before this block).
      # So a refusal surviving here means the merge is still blocked on findings
      # that are still open, and retiring them would stamp fixed_in_sha on a repair
      # no commit made, then delete the very briefing needed to clear the block.
      # Skipping leaves ledger_body empty, which writes nothing and removes
      # nothing, so the briefing survives intact.
      if [ "$prior" != "null" ] && [ ! -f "$refused_path" ]; then
        if ! ledger_body="$(jq -n \
          --argjson prior "$prior" \
          --argjson report "$sidecar_report" \
          --arg member "$MEMBER" \
          --arg head "$sha" \
          --arg now "$audited_at" \
          '
          def nonempty_string: type == "string" and length > 0;
          def array_or_empty: if type == "array" then . else [] end;
          ((($prior.remaining // null | array_or_empty))                   as $previous_entries
          | ([$previous_entries[] | select(.member == $member)])             as $closed
          | ([($report.resolutions // null | array_or_empty)[] | objects
              | select((.entry_id | nonempty_string)
                       and ((.rationale | type) == "string")
                       and (((.rationale | gsub("^\\s+|\\s+$"; "")) | length) > 0))]) as $resolutions
          | $prior
            + {updated_at: $now,
               head_sha: $head,
               remaining: [$previous_entries[] | select(.member != $member)],
               fixed_last_round:
                 ([($prior.fixed_last_round // null | array_or_empty)[]
                   | select(.member != $member)]
                  + [$closed[]
                     | . as $entry
                     | ((first($resolutions[] | select(.entry_id == $entry.entry_id)) // null) as $resolution
                        | {member, finding_class, path, line, title, fixed_in_sha: $head}
                          + (if ($entry.entry_id | nonempty_string)
                             then {entry_id: $entry.entry_id} else {} end)
                          + (if $resolution != null
                             then {resolution: $resolution.rationale} else {} end))])}
          | (if (.member_provenance | type) == "object"
             then .member_provenance |= del(.[$member]) else . end))
          ' 2>&1)"; then
          error "warning: cannot update the carry-forward ledger: $ledger_body"
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
        rm -f "$ledger" || error "warning: could not remove the spent ledger '$ledger'"
      else
        ledger_temporary_file="$(mktemp "${audit_directory}/.audit-rerun-ledger.XXXXXX" 2>/dev/null || true)"
        if [ -z "$ledger_temporary_file" ]; then
          error "warning: cannot create a temp file for the ledger in '$audit_directory'"
        elif ! printf '%s\n' "$ledger_body" > "$ledger_temporary_file"; then
          rm -f "$ledger_temporary_file"
          error "warning: cannot stage the ledger"
        elif ! mv -f "$ledger_temporary_file" "$ledger"; then
          rm -f "$ledger_temporary_file"
          error "warning: cannot publish the ledger to '$ledger'"
        fi
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Compensating server-side signal on a refusal (LOCAL path only).
#
# A refusal blocks the merge path that runs .claude/hooks/pr-merge-audit-check.sh
# and only that one. GitHub's auto-merge fires on the required GAIA-Audit status
# alone, so a refusal written after a sibling member's clean pass already posted
# `success` leaves that success standing and the pull request merges over a live
# refusal, with the artifact on disk and no diagnostic anywhere. Posting
# `failure` for the same head retracts it, which is why this call belongs to the
# writer rather than to an agent's instructions: the one moment a refusal is
# guaranteed to be recorded is the moment it is written.
#
# Runs LAST, after both the refusal and the ledger are durably on disk. This is
# the only step here that touches the network, and `gh` has no bound of its own,
# so a hung call must not sit in front of the briefing a refusal exists to
# produce. It never affects either write: `|| true` absorbs every failure, and
# the hook's own output goes to stderr so stdout stays the marker path this
# script contracts to print. A post that cannot happen (no gh, an un-pushed
# head) leaves the refusal on disk, where the local gate still denies the merge.
#
# Anchored on $_root_toplevel, the absolute checkout root already derived and
# validated above, rather than on $ROOT: the subshell `cd` re-bases every
# relative path inside it, so a caller passing a relative --root from a
# subdirectory would resolve the hook one way for the `[ -x ]` test and another
# way for the run. $target has the same exposure, since audit_directory is built from
# $ROOT, so the marker is re-derived here against the absolute root. Both paths
# name the same files either way: the validation above proves $ROOT and
# $_root_toplevel are one physical directory.
#
# The `cd` itself is load-bearing and cannot be dropped: the hook derives its
# repo root, and `gh` its repository and branch, from the ambient working
# directory, so the call has to be anchored on the audited tree.
#
# The window this closes: a wave posts once, so a later wave's refusal can
# arrive behind an earlier wave's success, and the refusal must flip the status
# to failure whatever the environment.
# -----------------------------------------------------------------------------
if [ "$PROVENANCE" = "refused" ]; then
  status_hook="${_root_toplevel}/.claude/hooks/post-audit-status.sh"
  status_marker="${_root_toplevel}/.gaia/local/audit/${target##*/}"
  if [ -x "$status_hook" ]; then
    ( cd "$_root_toplevel" && bash "$status_hook" "$status_marker" ) >&2 || true
  fi
fi

printf '%s\n' "$target"
exit 0
