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
#                            [--help|-h]
#
#   --root         REQUIRED, and validated: it must be a checkout ROOT, not a
#                  subdirectory of one and not a path a worktree used to
#                  occupy. The member's content digest is derived from it
#                  (never from the caller's CWD) via the digest engine
#                  (.claude/hooks/lib/audit-digest.sh), which bounds a worktree
#                  run from stamping a marker keyed to another worktree's
#                  content.
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
#   --scope-digest <64-hex>
#                  OPTIONAL, gated on a PLAIN earned write only: never
#                  --provenance refused, never an earned write carrying
#                  --supersede-refusal (both write paths proceed unchanged),
#                  and advisory-only for the one contractually never-blocking
#                  member (mirroring its own dirty-scope exemption). A member
#                  resolves its review scope at one HEAD, then finishes and
#                  writes at a later one; this carries the
#                  digest captured at scope resolution
#                  (.gaia/scripts/audit-scope-digest.sh --capture) for
#                  comparison against the digest this script derives fresh,
#                  right here, from the CURRENT --root. A difference means the
#                  member's review scope no longer describes what the marker
#                  would attest to, so the write refuses rather than
#                  publishing a marker keyed to unread content. A malformed
#                  value (not exactly 64 lowercase hex) is a usage error, not a
#                  staleness refusal.
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
                                [--help|-h]

  --base <sha>                  the incremental audit base sha; maintains the
                                re-run carry-forward ledger so a refusal briefs
                                its own repair. Non-gating, best-effort.
  --scope-digest <64-hex>       gated on a plain earned write; refuses when it
                                differs from the write-time digest. See the
                                header comment above.
  --supersede-refusal <reason>  valid only with --provenance earned; records a
                                reasoned reversal of this member's own prior
                                same-digest refusal and removes it.
EOF
}

err() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

# Resolve the digest engine and the version normalizer from THIS file's own
# on-disk location, never cwd, never $ROOT: .gaia/scripts -> ../../.claude/hooks/lib.
_write_clearance_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_write_clearance_lib_dir:-}" ] && [ -f "$_write_clearance_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_lib_dir/audit-digest.sh"
fi
if [ -n "${_write_clearance_lib_dir:-}" ] && [ -f "$_write_clearance_lib_dir/gaia-version.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_lib_dir/gaia-version.sh"
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
# SCOPE_DIGEST_SEEN mirrors SUPERSEDE_SEEN above: a member that passes an
# empty value must hit the format-validation usage error, not read as "flag
# absent" and slip past the staleness gate silently.
SCOPE_DIGEST_SEEN=0
SCOPE_DIGEST=""

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

# --root must BE a checkout root, not a subdirectory of one and not a path a
# worktree used to occupy. The content digest, the HEAD tree and the marker
# store below are all derived from it, so a path that merely SITS INSIDE a
# checkout mints a marker attesting to content the caller never named. Compare
# physically resolved paths, via `cd <path> && pwd -P` rather than `realpath`
# (not guaranteed present on macOS -- see .gaia/scripts/main-root-lib.sh's
# header), so a symlinked checkout path passes a comparison it should pass.
_root_toplevel="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$_root_toplevel" ]; then
  err "--root '$ROOT' is not a git checkout"
  exit 2
fi
_root_phys="$(cd "$ROOT" 2>/dev/null && pwd -P)" || _root_phys=""
_toplevel_phys="$(cd "$_root_toplevel" 2>/dev/null && pwd -P)" || _toplevel_phys=""
if [ -z "$_root_phys" ] || [ "$_root_phys" != "$_toplevel_phys" ]; then
  err "--root '$ROOT' is not a checkout root (its checkout root is '$_root_toplevel')"
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

# scope_advisory names the one contractually never-blocking member so the
# gate below can key on a plain variable rather than a member-name literal.
# On the adopter build the naming block just below is stripped, so this stays
# 0 unconditionally: the member cannot exist on an adopter clone, and every
# member that DOES exist there gets the full fail-closed refusal.
scope_advisory=0
# gaia:maintainer-only:start
# This member is exempt in both failing arms below, exactly as it is already
# exempt from the dirty-scope withhold -- that exemption is member-side
# prose, not a writer branch; this is the writer's FIRST member-name
# conditional beyond DEFAULT_MEMBER. It exists because that member is
# contractually never-blocking, so keep the naming on the next read of this
# file rather than deleting it as a stray inconsistency.
if [ "$MEMBER" = "code-audit-maintainer-prose" ]; then
  scope_advisory=1
fi
# gaia:maintainer-only:end

# --scope-digest, when present, must be exactly 64 lowercase hex: the shape
# the digest engine emits. This is a usage error, not a staleness refusal, so
# a caller passing a malformed value gets a distinct diagnostic from a caller
# whose digest genuinely rotated. Bash-3.2-safe `case`, not `[[ =~ ]]`.
#
# The never-blocking member is exempt here too, not only in the staleness arms
# below. Its definition always passes --scope-digest "$D_SCOPE", and --read
# prints nothing whenever the capture never ran, the audit key moved between two
# of the member's Bash calls, or the janitor reaped the scope file -- so the
# value it passes is EMPTY on exactly the paths the exemption exists to cover.
# Exiting 2 here would make the one member that can never block a merge the one
# that blocks it permanently, with no marker for the AND-aggregator to wait on.
# A malformed value from that member therefore degrades to the not-supplied
# state and falls through to the advisory arm, which reports and clears.
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
  if [ "$scope_advisory" -eq 1 ]; then
    err "--scope-digest is not a 64-hex digest (advisory): treating as not supplied"
    SCOPE_DIGEST_SEEN=0
    SCOPE_DIGEST=""
  else
    err "--scope-digest must be a 64-hex digest"
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
# description of what happened (`.claude/rules/partial-cause-reporting.md`). Saying "the
# capture is released" on a run that released nothing points the operator at a
# deadlock they have been told is already cleared.
#
#   0  released: a stored capture existed and is gone.
#   1  nothing to release: no capture is stored, so none can strand a later
#      round. Not a failure.
#   2  could not resolve the scope file at all -- no key lib, no --base (the CI
#      clearance call passes none), or an unresolvable key. A capture may or may
#      not be sitting there; this arm cannot tell, and must not claim either.
#   3  located, but not removed: the capture is exactly where it should be and
#      the rm failed. Distinct from 2 precisely because the location IS known --
#      the helper has already printed a diagnostic naming the path, so a caller
#      that folded this into 2 would follow that diagnostic with a second
#      message guessing at location causes, none of which is what happened.
_release_forfeited_capture() {
  local key="" scope_file
  command -v gaia_audit_key >/dev/null 2>&1 || return 2
  [ -n "$BASE" ] || return 2
  key="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  [ -n "$key" ] || return 2
  scope_file="${ROOT}/.gaia/local/audit/${key}.${MEMBER}.scope.json"
  [ -f "$scope_file" ] || return 1
  rm -f "$scope_file" || {
    err "warning: could not release the forfeited capture at '$scope_file'; the next round will refuse identically until it is removed"
    return 3
  }
  return 0
}

# Scope-digest staleness gate. Gated only on a PLAIN earned write: a refusal
# is a claim that content should not merge, and suppressing THAT is the one
# genuinely fail-open outcome available here, and a
# --supersede-refusal write is the member's own reasoned reversal of its prior
# refusal, orthogonal to whether the tree moved under it since scope
# resolution. Each arm is its own explicit refusal rather than a
# `[ -n "$SCOPE_DIGEST" ] && …` guard, so an absent value refuses instead of
# silently skipping the comparison (the fail-open shape the inert
# `AUDIT_TREE_SHA` in the four specialists already shows the cost of).
#
if [ "$PROVENANCE" = "earned" ] && [ "$SUPERSEDE_SEEN" -ne 1 ]; then
  if [ "$scope_advisory" -eq 1 ]; then
    if [ "$SCOPE_DIGEST_SEEN" -ne 1 ]; then
      err "review scope superseded (advisory)"
    elif [ "$SCOPE_DIGEST" != "$digest" ]; then
      err "review scope superseded (advisory): scope=$SCOPE_DIGEST write=$digest"
      # This arm warns and falls through to publish, and the marker it
      # publishes is keyed to the WRITE-TIME digest, never to the captured one
      # the spent test looks for. So without this release the capture is never
      # spent by the very round that ends on it: it survives for the life of
      # the audit key, and every later round re-reads it and re-emits the
      # warning above, which the never-blocking member is instructed to record
      # as a finding. The signal is stuck on, and the findings it produces are
      # false. Only the mismatch arm releases; the not-supplied arm above says
      # nothing about whether this round ended, exactly as on the blocking path.
      _release_forfeited_capture || true
    fi
  elif [ "$SCOPE_DIGEST_SEEN" -ne 1 ]; then
    err "scope digest not supplied"
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
    err "If you were dispatched into a worktree whose branch edits your own agent definition, the definition you are running was resolved from the main checkout and predates that edit. Re-read your own definition from --root ('$ROOT'), follow it, and retry."
    exit 2
  elif [ "$SCOPE_DIGEST" != "$digest" ]; then
    err "review scope superseded: scope=$SCOPE_DIGEST write=$digest"
    _release_forfeited_capture
    case "$?" in
      0) err "this round is forfeited and its capture is released; the next dispatch captures fresh." ;;
      1) err "this round is forfeited; no stored capture was found to release, so nothing carries into the next dispatch." ;;
      3) err "this round is forfeited; the stored capture was located but could not be removed, so the next dispatch inherits it and refuses identically until the path named above is cleared." ;;
      *) err "this round is forfeited, but the stored capture could not be located to release it (no --base, an unresolvable audit key, or the key library not being loaded). If one is present, the next dispatch inherits it and refuses identically; clear it with audit-scope-digest.sh --capture --recapture." ;;
    esac
    err "Do NOT re-run the scope fence to obtain a new capture in this round: you reviewed the superseded content, and a marker earned on a fresh capture would attest content you never read."
    exit 2
  fi
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
if command -v gaia_read_version >/dev/null 2>&1; then
  version="$(gaia_read_version "${ROOT}/.gaia/VERSION")"
else
  # Degrade exactly as an absent VERSION file does rather than failing the
  # write: the marker's validity key is the digest above, not this field.
  err "version normalizer unavailable (.claude/hooks/lib/gaia-version.sh); recording an empty version"
fi

# Two sidecar flags, because there are two sidecars and one field cannot answer
# for both. Derived from the member name; no CLI flag for either.
#
#   sidecar               does this member file a FINDINGS sidecar, its report
#                         of record? Every member does, so this is always true.
#   dispositions_sidecar  does this member file the out-of-scope DISPOSITION
#                         sidecar the merge gate's backstop reads? Only the
#                         default member does.
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
  AUDIT_KEY=""
  if command -v gaia_audit_key >/dev/null 2>&1; then
    AUDIT_KEY="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  fi
  if [ -z "$AUDIT_KEY" ]; then
    err "warning: --base given but the audit key does not resolve; no ledger written"
  else
    ledger="${audit_dir}/${AUDIT_KEY}.rerun.json"
    # Deliberately NOT named `sidecar`: that name already holds the marker body's
    # boolean flag built above, and reusing it here would shadow the flag for any
    # future edit that moves a body build below this block.
    findings_sidecar="${audit_dir}/${AUDIT_KEY}.${MEMBER}.findings.json"
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
# way for the run. $target has the same exposure, since audit_dir is built from
# $ROOT, so the marker is re-derived here against the absolute root. Both paths
# name the same files either way: the validation above proves $ROOT and
# $_root_toplevel are one physical directory.
#
# The `cd` itself is load-bearing and cannot be dropped: the hook derives its
# repo root, and `gh` its repository and branch, from the ambient working
# directory, so the call has to be anchored on the audited tree.
#
# Skipped in CI because that workflow posts one terminal status per run and owns
# the context; a second writer racing it is a failure mode the local path does
# not have. The window this closes is local-specific in the same way: the local
# path posts once per dispatch wave, so a later wave's refusal can arrive behind
# an earlier wave's success, which a single terminal CI post cannot do.
# -----------------------------------------------------------------------------
if [ "$PROVENANCE" = "refused" ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then
    # Say so rather than skipping silently. A local shell that exports CI for
    # unrelated reasons takes this arm, and then the incident this block exists
    # to prevent arrives with no diagnostic at all: the refusal lands, no
    # status is posted, and nothing says why. The direction is still safe, the
    # local gate denies on the artifact alone.
    err "note: compensating GAIA-Audit failure status skipped (CI environment); the refusal is on disk and the local merge gate still denies"
  else
    status_hook="${_root_toplevel}/.claude/hooks/post-audit-status.sh"
    status_marker="${_root_toplevel}/.gaia/local/audit/${target##*/}"
    if [ -x "$status_hook" ]; then
      ( cd "$_root_toplevel" && bash "$status_hook" "$status_marker" ) >&2 || true
    fi
  fi
fi

printf '%s\n' "$target"
exit 0
