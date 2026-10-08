#!/usr/bin/env bash
# resolve-audit-base.sh: resolve the incremental review base for the
# code-review-audit agent.
#
# Purpose
#   The audit reviews the diff from a "base" commit to HEAD. The base is the
#   most recent ancestor of HEAD whose content is accounted for under the
#   CURRENT agent version, in one of two ways:
#     cleared  it passed a CLEAN audit, proven by a GAIA-Audit commit status
#              or, in the --member form, that member's own earned clearance.
#     refused  --member form only: that member's own newest refusal, linked
#              to the open-finding record it left in the re-run ledger. The
#              content up to it was reviewed, and what the review found is
#              carried as open entries that the member's next clearance
#              write must account for one by one (re-reported or resolved
#              with a rationale), so nothing found there is dropped by not
#              being read again.
#   Reviewing only <base>..HEAD is then far cheaper than re-reviewing the
#   whole origin/main..HEAD diff on every push to an open PR.
#
#   That whole-team signal is posted only when NO dispatched Code Audit
#   Team member is still pending, which is what makes it trustworthy and
#   also what caps it: a member that cleared in a round where a sibling was
#   pending cannot anchor on its own clearance. Naming a member with
#   `--member` adds a second anchor arm over the same walk, reading that
#   member's own clearances and refusals out of the local audit store. The
#   whole-team signal stays the FLOOR; the per-member arm only ever improves
#   on it, never replaces it.
#
#   When no usable ancestor exists, first audit of a PR, every prior run
#   cancelled or failed (those post nothing), a .gaia/VERSION bump
#   invalidated older audits, or the version file is missing; the helper
#   emits the main ref so the caller falls back to a full-scope review. A
#   commit nobody reviewed carries no signal to anchor on, and a refusal
#   anchors only while its open findings are on record, so neither shortcut
#   leaves content unread with nothing owed on it.
#
# Invocation
#   .github/audit/resolve-audit-base.sh [--member <name>]
#
#   The argument-less form resolves the shared pull-request-wide base, and its
#   resolution is unchanged on every input except the inverted degraded arm
#   below. The merge-time
#   findings hook is not one of them and no longer calls this script at all:
#   the block it posts selects its sidecars on the branch, across every base. `--member <name>` is the per-member form; the Code Audit Team's
#   agent definitions are the only call sites that can name a member.
#
#   Reads .gaia/VERSION, HEAD's ancestry, the local audit store's clearance
#   and refusal records and (--member form) its re-run ledger, and (when
#   GH_TOKEN + gh are available) the GitHub Commit Status API. A commit-message
#   trailer on any commit is ignored.
#
# Output (stdout), argument-less form
#   Exactly ONE line, suitable for a `base...HEAD` diff:
#     <40-hex-sha>: resolved incremental base (an audited PR ancestor)
#     origin/main: the fallback: review the full PR diff
#     (or main when neither remote-tracking ref resolves)
#
# Output (stdout), --member form
#   Exactly FOUR newline-terminated lines:
#     1. the per-member review base ref, which SCOPES that member's review
#     2. the reason token (closed set, below)
#     3. the shared pull-request-wide base ref, which KEYS every artifact
#     4. the recorded tree of the clearance or refusal that anchored line 1,
#        or EMPTY on every path where neither anchored it
#
#   Line 3 comes from the same code path the argument-less form prints, so
#   co-dispatched members agree on the key structurally rather than
#   incidentally: each receives byte-identically what the argument-less form
#   carries, which is what makes the shared re-run ledger one file per round.
#   The findings block used to be the second beneficiary of that agreement and
#   is no longer a beneficiary at all; the ledger is the whole reason line 3
#   exists. Lines 1 and 3
#   legitimately differ, e.g. when a merely-shared machinery path changed
#   after the anchor: line 3 resets and line 1 does not. That divergence is
#   what the two-base split is for.
#
#   Line 4 lets a caller record WHICH record anchored the answer without a
#   second invocation and without parsing stderr. An empty line 4 is the
#   normal case for every reason other than member-clearance and
#   member-refusal, and an empty line is still a line.
#
# Output (stderr)
#   Exactly one decision line on every path:
#     resolve-audit-base: member=<name|-> base=<sha|ref> reason=<token> anchor_tree=<tree|->
#   plus one FURTHER explanatory line when a reset or a degradation fired,
#   naming the path or the library that forced it. Closed reason set:
#     member-clearance    anchored on this member's own earned clearance
#     member-refusal      anchored on this member's own refusal, linked to
#                         the open-finding record it left in the ledger
#     team-signal        anchored on the whole-team status floor
#     no-anchor           no usable anchor in range; full scope
#     rules-reset-global  a global-rules path changed between anchor and HEAD
#     rules-reset-member  this member's own agent definition changed
#     machinery-reset     the argument-less flat machinery reset fired
#     degraded            classifier, machinery, rules, or version lib not
#                         sourceable
#     no-version          .gaia/VERSION missing or empty
#
# Exit code
#   0 always, on every path, a usage error included. A non-zero exit does
#   NOT degrade the callers uniformly to full scope: it degrades the agent
#   call sites to an EMPTY review scope, because an empty base makes git
#   resolve the diff's left side to HEAD and return nothing at status 0.
#   Reviewing nothing is worse than reviewing everything. The merge-time
#   findings hook is no longer among the degraded callers: it does not call
#   this script, so a non-zero exit here costs it nothing and it still posts. This script runs under
#   `set -euo pipefail`, so every library function is probed with
#   `command -v` before it is called: an unguarded call into a library that
#   did not load is a command-not-found, which is exactly that non-zero
#   exit.
#
# Why version-match (not digest-match) gates a base
#   A commit is a usable base when its audit signal's <version> equals the
#   current .gaia/VERSION. A version mismatch means the ruleset changed
#   since that audit, so code cleared under the old version may now have
#   findings; that commit is NOT a safe base, and the walk continues,
#   ultimately falling back to a full re-audit under the new ruleset. The
#   signal's frontend-digest and tree fields are not compared here; they
#   describe content the audit already reviewed, not whether the ruleset
#   that reviewed it is still current. The per-member arm is gated the same
#   way, on the clearance body's own recorded version.
#
# Base reset on machinery change
#   A version-matching candidate is not automatically safe: if any
#   gate-machinery file (the ownership classifier, the machinery matcher,
#   the digest recipe itself) changed between that candidate and HEAD, the
#   candidate's audit ran under different membership/scoping rules than
#   HEAD's, even though the version string didn't move. Reviewing only
#   <candidate>..HEAD would then leave the candidate's own pre-base content
#   unreviewed under the new rules. The argument-less form keeps that one
#   flat test over the whole machinery set (via the batch machinery matcher,
#   sourced from the checkout), so its resolution stays what it has always
#   been.
#
# The two-tier reset, --member form only
#   The flat test is far broader than the question a single member is
#   asking. A repair to one member's own lens file, or an edit to a hook
#   that only posts a status, resets every member. So the per-member form
#   tests the same delta in two tiers (audit-rules-changed.sh):
#     global tier  the files deciding what a member owns, what counts as
#                  machinery, how a digest is computed, whether a clearance
#                  is believed, which members are dispatched, or under which
#                  version any of that was decided. Resets EVERY member.
#     member tier  a member's own agent definition. Resets only that member.
#   Machinery that is merely shared resets nobody. It still rotates digests,
#   so a fresh clearance is still required before the merge gate opens, but
#   the review earning it stays incremental. The tier predicate is a
#   carve-out of the machinery set and never edits it.
#
# Per-member anchor: what a clearance proves, and what it does not
#   A candidate is a per-member anchor when the member holds an earned
#   clearance carrying `review: full` whose recorded TREE equals the
#   candidate's tree and which the merge gate itself would accept: its
#   recorded version equals the current one, and no live refusal of this
#   member exists for that clearance's own digest (a re-run-until-pass
#   clearance beside its own refusal never anchors). A
#   `review: light` marker, and a marker whose body lacks the field, is never
#   an anchor: it was written from a delta or before the field existed, and a
#   later full review must start from the last full clearance. The tree rather than the commit
#   sha is the matching field because an amend or a rebase rewrites the sha a
#   moments-old clearance recorded while preserving the tree; matching on the
#   sha would lose the anchor on exactly the rounds that earned it. No member digest is ever recomputed at a candidate: the
#   ownership classifier reads the working tree's roster rather than the
#   candidate commit's, so a recomputed digest can name a value that never
#   existed at that commit.
#
#   CHAINED TRUST, a documented assumption rather than a proof. A clearance
#   body records the member, the digest, the version, the write-time HEAD
#   commit, and the tree, but never the RANGE the member reviewed. So a
#   clearance at commit C attests a content digest over that member's owned
#   files at C; that it covers everything up to C holds only by chaining,
#   each clearance inheriting the coverage of the ones before it. A single
#   vacuous clearance would therefore propagate forward invisibly. The
#   clearance validity predicate this arm leans on is likewise a
#   well-formedness and change-detection key, NOT an anti-forgery defence:
#   anyone who can write the store can already write the working tree.
#   Repairing either property is a human's decision, not this file's.
#
# Team-signal arm and review depth, --member form only
#   The status is light-blind by design: it attests that no
#   dispatched member is pending, not how deep any review was. So the --member
#   form anchors on a whole-team signal S only when the local marker store
#   shows no non-full marker among the in-range candidate trees, scanned
#   across the whole roster and not only the resolving member: (a) no
#   candidate in range may carry a tree holding any member's non-full earned
#   marker (light, or a body without the field, at any version), and (b) some
#   member's earned `review: full` marker must record S's tree. Check (a)
#   matches a marker by the tree it recorded, so a non-full marker whose tree
#   left the range (a content amend or a rebase rewrites the commit trees
#   while the marker stays valid by content digest) is not found and does not
#   disable the arm; the reviewed delta of that member can then fall before
#   the anchor. Either failing check disables the
#   arm for the run and logs why; the walk still continues, so the per-member
#   arm can win on an older full clearance of the resolving member, and with
#   none in range the answer is no-anchor, the full-branch base.
#   Documented boundary and its cost: the store is gitignored, so CI and a
#   fresh clone have no markers, (b) is never met, and the arm refuses there.
#   A --member resolution from such a run scopes the whole branch rather than
#   the delta since the last team signal: wider (more tokens), never narrower.
#   CI-side marker validation is out of scope. Line 3 and the argument-less
#   form are unaffected: they still carry the whole-team floor and only KEY
#   artifacts, so none of them scopes a member's review.
#
# Refusals, --member form: the newest member signal wins
#   The walk goes newest first, and the member arm stops at the first of the
#   member's own signals it meets. Per candidate tree a refusal is tested
#   before an earned clearance, so a refusal and a clearance recorded at the
#   same tree resolve as the refusal. A refusal of ANY recorded version is a
#   signal: it stops the member arm there, so the member never anchors on an
#   earned clearance older than its own refusal. A refusal recorded at HEAD's
#   own tree is the newest signal of all and cannot be an anchor (the diff
#   from it is empty), so it disables the member arm for the run.
#
#   The refusal the walk stops at becomes the anchor, reason member-refusal
#   with line 4 carrying the refusal's recorded tree, only when every link
#   below holds; any failure falls back to the whole-team anchor the walk
#   found, else to no-anchor, never to the degraded reason, and logs the
#   cause on a line naming the refused content:
#     version   the refusal was recorded under the current version. The
#               version match applies only to anchoring AT a refusal; an
#               older-version refusal still stops the arm.
#     coverage  the refusal record carries a review-coverage proof: its
#               review_coverage.scope_digest equals its own digest, which the
#               clearance writer records only when the member's captured
#               review scope matched the write-time digest without an
#               override, so the refusal really reviewed the tree it records.
#     ledger    the re-run ledger at this branch's audit key (built from the
#               merge-base of line 3 and HEAD, through audit-key-lib.sh)
#               parses, is schema 1, and names this branch and that
#               merge-base; its per-member provenance for this member names
#               this refusal's digest, its tree, and the current version; and
#               it holds at least one open entry for this member.
#   The ledger is read only through `jq --arg`, for presence and the
#   provenance fields. Without jq or
#   the key library the link fails rather than degrading. Every reset below
#   applies to a refusal anchor exactly as to a clearance anchor.
#
#   Trust boundary. The link is a completeness tripwire, not an anti-forgery
#   defence: it proves the store holds a writer-shaped record of this
#   refusal's open findings, which the member's next clearance write must
#   account for, and anyone who can write the store can write the ledger too.
#
#   An earned clearance NEWER than a refusal still anchors. That rests on the
#   chained-trust assumption above, not on a proof: the clearance attests the
#   content at its own tree, and the clearance writer made it account for
#   every open entry the refusal left. The whole-team floor likewise still
#   runs past a refusal: the status is posted only
#   when no dispatched member is pending, and a member holding a live refusal
#   IS pending, so a whole-team signal newer than the refused commit is
#   evidence that the refusal was already resolved (superseded by its author
#   or retired by a digest rotation). That reasoning inherits the posting
#   hook's member-pending check, which sits inside a guard with no else arm
#   and posts anyway in a degraded environment; the floor is therefore
#   sound in the normal case and fail-open in a degraded one.
#
# Fail direction: an unloadable library resets to full scope
#   With the classifier, the machinery matcher, or the rules-tier predicate
#   unsourceable, NEITHER tier can be evaluated, so the anchor's soundness
#   for the resolving member cannot be established at all and the narrowing
#   it would permit is member-specific and invisible. Both forms therefore
#   emit the full-scope main ref and log the degradation; on no path is a
#   candidate emitted. The merge gate already denies outright on the same
#   input, so this agrees with the gate rather than adding a new denial. The
#   accepted cost is that a checkout missing those libraries always reviews
#   full scope.
#
#   audit-clearance.sh is the deliberate exception. Its absence is the same
#   condition as an empty clearance store, which is every
#   continuous-integration run: the store is gitignored and never uploaded
#   between runs. Both tiers stay evaluable there, so it does not take the
#   degraded arm (which would emit a reason of its own). In the argument-less
#   form the whole-team signal still anchors; in the --member form the
#   team-signal arm refuses for want of verifiable review depth and the answer
#   is no-anchor (see the team-signal section above). Do not "fix" this into
#   uniformity. audit-key-lib.sh is outside the degraded set for the same
#   reason: without it only the refusal link fails, and the answer falls back
#   exactly as it does when no ledger exists.
#
# Why bound the walk to merge-base..HEAD
#   The base must be one of THIS PR's commits (or the divergence point as
#   the floor). Walking into main's own history could pick a deeper main
#   commit and pull already-merged, unrelated changes into this PR's review
#   scope. The merge-base bound prevents that; reaching the floor yields the
#   main ref, i.e. the same scope as origin/main...HEAD.
#
# Conventions
#   - Bash 3.2 compatible (macOS default). No associative arrays / mapfile.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Uses git -C "$repo_root".

set -euo pipefail

# Defensive cap on the ancestry walk (PRs rarely exceed this many commits;
# the merge-base bound usually keeps the list far shorter).
MAXIMUM_WALK_COMMIT_COUNT=50

TAB="$(printf '\t')"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

member=""
member_form="false"
argument_error=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --member)
      if [ "$#" -lt 2 ]; then
        argument_error="--member requires a value"
        break
      fi
      if [ -z "$2" ]; then
        argument_error="--member requires a non-empty value"
        break
      fi
      member="$2"
      member_form="true"
      shift 2
      ;;
    *)
      argument_error="unknown argument '$1'"
      break
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Emit: the one exit point. Writes the decision line to stderr and the
# invocation form's stdout shape. shared_base must already hold the
# argument-less resolution, since that is what line 3 carries.
# -----------------------------------------------------------------------------

emit() {
  local base="$1" reason="$2" anchor_tree="$3"
  printf 'resolve-audit-base: member=%s base=%s reason=%s anchor_tree=%s\n' \
    "${member:--}" "$base" "$reason" "${anchor_tree:--}" >&2
  if [ "$member_form" = "true" ]; then
    printf '%s\n%s\n%s\n%s\n' "$base" "$reason" "$shared_base" "$anchor_tree"
  else
    printf '%s\n' "$base"
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Resolve repo root
# -----------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  # Defensive: not in a git repo, so nothing can be sourced out of the
  # checkout either. Full scope; the caller's git will error loudly on the
  # broken environment.
  main_reference="origin/main"
  shared_base="$main_reference"
  echo "resolve-audit-base: not inside a git checkout; resetting to full scope (${main_reference})." >&2
  emit "$main_reference" degraded ""
fi

# -----------------------------------------------------------------------------
# Resolve a "main ref": used both for the fallback output and to bound the
# ancestry walk via merge-base.
# -----------------------------------------------------------------------------

resolve_main_reference() {
  # No declared-base-ref arm and no `gh` fallback: this resolver SCOPES a
  # review, so a base that resolves only sometimes, or one taken from the
  # environment, could land at or near HEAD, empty the reviewed delta, and let
  # a member earn a clearance marker having read nothing. It runs from hooks
  # and agent bootstraps where gh may be absent, and a base that is always the
  # repository default is the one every run can reproduce.
  if git -C "$repo_root" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    printf 'origin/main'
    return 0
  fi
  if git -C "$repo_root" rev-parse --verify --quiet main >/dev/null 2>&1; then
    printf 'main'
    return 0
  fi
  # Last resort: emit origin/main anyway; the caller's diff errors loudly if
  # it truly can't resolve.
  printf 'origin/main'
}
main_reference="$(resolve_main_reference)"
shared_base="$main_reference"

# A mis-invocation cannot be trusted to be a member call site, so it degrades
# to the argument-less full-scope shape rather than guessing a four-line one.
if [ -n "$argument_error" ]; then
  member=""
  member_form="false"
  echo "resolve-audit-base: ${argument_error}; resolving full scope (${main_reference})." >&2
  emit "$main_reference" no-anchor ""
fi

# -----------------------------------------------------------------------------
# Read .gaia/VERSION: missing/empty means no base can be validated, on either
# anchor arm.
# -----------------------------------------------------------------------------

# Sourced here rather than in the library block below, because that block sits
# after this read and the version gate has to answer before the walk starts.
# Bracketed rather than `if [ -f ]; then . X || true; fi`: the existence test
# admits a file that is present but UNPARSEABLE, and on bash 3.2.57 -- the
# /bin/bash stock macOS ships, and the floor this script's Conventions block
# claims -- errexit abandons the shell AT the load, so the `|| true` is never
# reached and the resolver exits emitting nothing instead of degrading to full
# scope. Dropping errexit across the load is what lets the failure reach the
# `command -v` degrade below. The flat `set -e` restore matches this file's own
# errexit arming above, rather than the state-preserving form a library uses.
version_library="${repo_root}/.claude/hooks/lib/gaia-version.sh"
set +e
# shellcheck source=/dev/null
[ -f "$version_library" ] && . "$version_library" 2>/dev/null
set -e
if ! command -v gaia_read_version >/dev/null 2>&1; then
  echo "resolve-audit-base: version normalizer unavailable (gaia-version.sh); resetting to full scope (${main_reference})." >&2
  emit "$main_reference" degraded ""
fi

current_version="$(gaia_read_version "${repo_root}/.gaia/VERSION")"
if [ -z "$current_version" ]; then
  emit "$main_reference" no-version ""
fi

# -----------------------------------------------------------------------------
# Build the candidate list (PR commits, newest first).
# -----------------------------------------------------------------------------

head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
if [ -z "$head_sha" ]; then
  emit "$main_reference" no-anchor ""
fi

merge_base=$(git -C "$repo_root" merge-base "$main_reference" HEAD 2>/dev/null || true)
if [ -n "$merge_base" ]; then
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAXIMUM_WALK_COMMIT_COUNT" "${merge_base}..HEAD" 2>/dev/null || true)
else
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAXIMUM_WALK_COMMIT_COUNT" HEAD 2>/dev/null || true)
fi

# -----------------------------------------------------------------------------
# Signal extractor (the GAIA-Audit commit status shape).
# -----------------------------------------------------------------------------

# status_version_for <sha> → echoes the GAIA-Audit commit status version, or
# empty. Only a state: success status counts; a non-success status (e.g. a
# local-mode stand-down's pending status on this SHA) is filtered out at the
# source, so such a commit is not a usable base from the status path. Needs
# gh + GH_TOKEN + repo slug; a missing token / absent gh / API failure / no
# success status all yield empty (the walk continues).
status_version_for() {
  local sha="$1" repo description
  [ -n "${GH_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  repo="${GITHUB_REPOSITORY:-}"
  [ -n "$repo" ] || return 0
  description=$(gh api "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit" and .state == "success")) | last | .description' \
    2>/dev/null || true)
  if [ -z "$description" ] || [ "$description" = "null" ]; then
    return 0
  fi
  printf '%s' "$description" | awk '{print $1}'
}

# delta_for <anchor> → the anchor..HEAD delta, one path per line.
#
# Fed to the batch matchers by here-string, never by pipe: they return on the
# first match without draining stdin, so a piped git-diff writing past the
# ~64KB pipe buffer takes SIGPIPE (141), and under `set -o pipefail` the
# pipeline status collapses to false -- silently skipping the reset.
#
# `-z` because the matchers compare their prefixes literally: under git's
# default core.quotePath a path carrying non-ASCII or control bytes comes back
# wrapped in literal double quotes, and a token starting with `"` prefix-matches
# nothing, so the reset silently does not fire. The `tr` puts back the newlines
# the here-string feed reads by.
delta_for() {
  git -C "$repo_root" diff --name-only -z "$1" "$head_sha" 2>/dev/null | tr '\0' '\n' || true
}

# -----------------------------------------------------------------------------
# Load the predicate libraries. This happens BEFORE the walk, not lazily on
# first need, because their availability now decides the answer rather than
# merely qualifying it.
# -----------------------------------------------------------------------------

library_directory="${repo_root}/.claude/hooks/lib"
for library_file in audit-scope.sh audit-machinery.sh audit-rules-changed.sh audit-clearance.sh; do
  # Bracketed for the reason given at the version-normalizer load above: an
  # existence test admits an unparseable lib, and under errexit bash 3.2.57
  # dies at the load rather than at the `||`. Same shape, same reason.
  set +e
  # shellcheck source=/dev/null
  [ -f "${library_directory}/${library_file}" ] && . "${library_directory}/${library_file}" 2>/dev/null
  set -e
done

# The key library builds the re-run ledger's path for the refusal link. Same
# bracketed load; its absence fails only that link and never sets
# missing_library below.
key_library="${repo_root}/.gaia/scripts/audit-key-lib.sh"
set +e
# shellcheck source=/dev/null
[ -f "$key_library" ] && . "$key_library" 2>/dev/null
set -e

missing_library=""
if ! command -v audit_owner_for_path >/dev/null 2>&1; then
  missing_library="audit-scope.sh"
elif ! command -v audit_path_is_machinery >/dev/null 2>&1 \
  || ! command -v audit_delta_has_machinery >/dev/null 2>&1; then
  missing_library="audit-machinery.sh"
elif ! command -v audit_rules_reset_for >/dev/null 2>&1; then
  missing_library="audit-rules-changed.sh"
fi
if [ -n "$missing_library" ]; then
  echo "resolve-audit-base: classifier/machinery/rules libs unavailable (${missing_library}); resetting to full scope (${main_reference})." >&2
  emit "$main_reference" degraded ""
fi

# -----------------------------------------------------------------------------
# Per-member pre-scan: the trees at which this member holds a gate-accepted
# earned clearance, and every refusal record it holds. Only the --member form
# reads the store, and only when the clearance reader loaded.
# -----------------------------------------------------------------------------

# scan_field <clearance_scan line> <n> prints the n-th tab-separated field.
# `cut` rather than `read` under a tab IFS: tab is IFS whitespace, so `read`
# collapses the empty version or sha an old body can record and shifts every
# later field, the review column included.
scan_field() {
  printf '%s\n' "$1" | cut -f"$2"
}

member_arm="false"
earned_trees=""
refused_trees=""
# One line per refusal record: <tree>\t<version>\t<digest>\t<path>.
refused_records=""
non_full_trees=""
non_full_owners=""
full_trees=""
team_arm_refusal=""

if [ "$member_form" = "true" ] && command -v clearance_scan >/dev/null 2>&1; then
  # An unreadable / empty store is not a degradation: it is the ordinary CI
  # condition, where the whole-team floor is sound and both tiers stay
  # evaluable. Fall back to the floor, never narrow on an absent record.
  earned_scan="$(clearance_scan "$repo_root" "$member" earned 2>/dev/null || true)"
  refused_scan="$(clearance_scan "$repo_root" "$member" refused 2>/dev/null || true)"

  # Empty fields are excluded explicitly: the clearance writer applies no
  # empty-guard to the fields it records, so an empty recorded value must
  # never match an empty candidate value.
  if [ -n "$earned_scan" ]; then
    while IFS= read -r scan_line; do
      [ -n "$scan_line" ] || continue
      recorded_tree="$(scan_field "$scan_line" 1)"
      recorded_version="$(scan_field "$scan_line" 2)"
      recorded_review="$(scan_field "$scan_line" 4)"
      [ -n "$recorded_tree" ] || continue
      [ "$recorded_version" = "$current_version" ] || continue
      # Only a `review: full` marker anchors. A light clearance was written by
      # a reviewer that read a delta, so a later full review must start from
      # the last full one; a body lacking the field (a legacy marker) is not
      # full either.
      [ "$recorded_review" = "full" ] || continue
      # The digest comes from the record body, never from the scan's sha
      # column; clearance_scan has already checked it equals the filename stem.
      recorded_digest="$(clearance_field "$(scan_field "$scan_line" 5)" digest)"
      [ -n "$recorded_digest" ] || continue
      # The merge gate refuses a clearance beside a live refusal for its own
      # digest, so such a clearance is no signal here either.
      if clearance_member_refused "$repo_root" "$recorded_digest" "$member"; then
        continue
      fi
      earned_trees="${earned_trees}${recorded_tree}
"
    done <<EOF
$earned_scan
EOF
  fi

  # Every version is kept: an older-version refusal cannot anchor, but it still
  # stops the member arm, so the member never anchors past it.
  if [ -n "$refused_scan" ]; then
    while IFS= read -r scan_line; do
      [ -n "$scan_line" ] || continue
      recorded_tree="$(scan_field "$scan_line" 1)"
      recorded_version="$(scan_field "$scan_line" 2)"
      recorded_path="$(scan_field "$scan_line" 5)"
      [ -n "$recorded_tree" ] || continue
      recorded_digest="$(clearance_field "$recorded_path" digest)"
      refused_trees="${refused_trees}${recorded_tree}
"
      refused_records="${refused_records}${recorded_tree}${TAB}${recorded_version}${TAB}${recorded_digest}${TAB}${recorded_path}
"
    done <<EOF
$refused_scan
EOF
  fi

  if [ -n "$earned_trees" ] || [ -n "$refused_trees" ]; then
    member_arm="true"
  fi
fi

# Without a working jq the store reads as empty, so a refusal it holds is
# invisible rather than linked; say so instead of resolving silently.
if [ "$member_form" = "true" ] && ! jq -n 'true' >/dev/null 2>&1; then
  echo "resolve-audit-base: jq is unavailable, so ${member}'s records cannot be read and no refused content can be linked to an open-finding record; per-member anchoring disabled for this run." >&2
fi

# A refusal at HEAD's own tree is the newest signal of all and cannot be an
# anchor (the diff from it is empty), so nothing older may anchor either. The
# walk still runs for the whole-team floor.
if [ "$member_arm" = "true" ] && [ -n "$refused_trees" ]; then
  head_tree="$(git -C "$repo_root" rev-parse "${head_sha}^{tree}" 2>/dev/null || true)"
  if [ -n "$head_tree" ] && grep -qxF -- "$head_tree" <<<"$refused_trees"; then
    echo "resolve-audit-base: ${member} refused content at HEAD ${head_sha}; a refusal at HEAD leaves an empty diff to anchor on, so per-member anchoring is disabled for this run." >&2
    member_arm="false"
  fi
fi

# -----------------------------------------------------------------------------
# Team-arm review-depth check, --member form only. The status
# is light-blind by design: it attests that every dispatched member holds a
# clearance, not how deep any review was, so only the local marker store can say
# whether a signal stands on full reviews. The scan therefore covers EVERY
# roster member's earned markers, not only the resolving member's.
#   (a) any candidate in range whose tree carries a non-full earned marker of
#       any member (light, or a body lacking the field, at any version)
#       disables the team arm for the run;
#   (b) at the signal commit itself, some member's earned `review: full` marker
#       must record that commit's tree (checked in the walk).
# An empty store (CI, a fresh clone), an absent clearance reader, an unreadable
# roster, and a marker the reader cannot parse all leave (b) unmet, so the arm
# refuses to anchor: it cannot verify, and the cost of refusing is scope width
# (the full-branch base), never narrower scope.
# -----------------------------------------------------------------------------

# record_roster_scan <roster member> <clearance_scan output>: sorts one member's
# earned markers into the full-tree and non-full-tree sets.
record_roster_scan() {
  local roster_member="$1" roster_scan="$2" scan_line recorded_tree
  [ -n "$roster_scan" ] || return 0
  while IFS= read -r scan_line; do
    [ -n "$scan_line" ] || continue
    recorded_tree="$(scan_field "$scan_line" 1)"
    [ -n "$recorded_tree" ] || continue
    if [ "$(scan_field "$scan_line" 4)" = "full" ]; then
      full_trees="${full_trees}${recorded_tree}
"
    else
      non_full_trees="${non_full_trees}${recorded_tree}
"
      non_full_owners="${non_full_owners}${recorded_tree}${TAB}${roster_member}
"
    fi
  done <<EOF
$roster_scan
EOF
}

# scan_roster_depth: the whole-roster scan and check (a). The walk calls it once,
# at the first whole-team signal, because nothing else reads its result and a
# store scan costs seconds per member; the resolving member's scan is the one
# already captured above, not repeated.
scan_roster_depth() {
  local roster_member roster_includes_member="false" candidate_tree non_full_owner candidate_sha
  while IFS= read -r roster_member; do
    [ -n "$roster_member" ] || continue
    if [ "$roster_member" = "$member" ]; then
      roster_includes_member="true"
      record_roster_scan "$roster_member" "$earned_scan"
    else
      record_roster_scan "$roster_member" "$(clearance_scan "$repo_root" "$roster_member" earned 2>/dev/null || true)"
    fi
  done <<EOF
$roster_members
EOF
  [ "$roster_includes_member" = "true" ] || record_roster_scan "$member" "$earned_scan"
  if [ -n "$non_full_trees" ]; then
    for candidate_sha in $candidates; do
      candidate_tree="$(git -C "$repo_root" rev-parse "${candidate_sha}^{tree}" 2>/dev/null || true)"
      [ -n "$candidate_tree" ] || continue
      if grep -qxF -- "$candidate_tree" <<<"$non_full_trees"; then
        non_full_owner="$(grep -F -- "${candidate_tree}${TAB}" <<<"$non_full_owners" | head -n 1 | cut -f2 || true)"
        team_arm_refusal="${non_full_owner:-a member} holds a non-full clearance at ${candidate_sha}, so the whole-team signal may stand on content no full review read"
        echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
        break
      fi
    done
  fi
}

roster_members=""
if [ "$member_form" = "true" ]; then
  if ! command -v clearance_scan >/dev/null 2>&1; then
    team_arm_refusal="the clearance reader is unavailable, so review depth at the whole-team signal cannot be verified"
  else
    roster_members="$(audit_roster_member_names "${repo_root}/.gaia/audit-ci.yml" 2>/dev/null || true)"
    if [ -z "$roster_members" ]; then
      team_arm_refusal="the audit roster is unreadable, so review depth at the whole-team signal cannot be verified"
    fi
  fi
  if [ -n "$team_arm_refusal" ]; then
    echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
  fi
fi

# -----------------------------------------------------------------------------
# One walk, two arms, newest wins. Per candidate the per-member arm is tested
# first, so a member signal and a whole-team signal on the SAME commit resolve
# as the former; across candidates the newer of the two wins, which is why this
# is one walk and not two. Within the member arm a refusal is tested before an
# earned clearance at the same tree, and the first member signal met settles
# the arm. A refusal settles it only as a CANDIDATE: whether it anchors is
# decided after the walk, once line 3 (which keys the ledger) is known.
# -----------------------------------------------------------------------------

team_anchor=""
team_winner=""
winner=""
winner_reason=""
winner_tree=""
refusal_candidate=""
refusal_candidate_tree=""

for sha in $candidates; do
  # HEAD itself can't be the base (an empty diff), and never carries a
  # *matching* signal anyway, a match would have skipped the run upstream.
  [ "$sha" = "$head_sha" ] && continue

  if [ "$member_arm" = "true" ] && [ -z "$winner" ] && [ -z "$refusal_candidate" ]; then
    candidate_tree="$(git -C "$repo_root" rev-parse "${sha}^{tree}" 2>/dev/null || true)"
    if [ -n "$candidate_tree" ]; then
      if grep -qxF -- "$candidate_tree" <<<"$refused_trees"; then
        refusal_candidate="$sha"
        refusal_candidate_tree="$candidate_tree"
      elif grep -qxF -- "$candidate_tree" <<<"$earned_trees"; then
        winner="$sha"
        winner_reason="member-clearance"
        winner_tree="$candidate_tree"
      fi
    fi
  fi

  # Only the first (newest) signal is the shared floor. Once it is found a
  # later signal is never read: the walk only continues for the member arm.
  if [ -z "$team_anchor" ]; then
    status_version="$(status_version_for "$sha")"
    if [ -n "$status_version" ] && [ "$status_version" = "$current_version" ]; then
      team_anchor="$sha"
    fi

    # Check (b): a member's earned full marker must record the signal's tree.
    # The shared floor keeps this signal either way, so line 3 of the member
    # form still equals the argument-less answer.
    if [ -n "$team_anchor" ] && [ "$member_form" = "true" ] && [ -z "$team_arm_refusal" ]; then
      scan_roster_depth
    fi
    if [ -n "$team_anchor" ] && [ "$member_form" = "true" ] && [ -z "$team_arm_refusal" ]; then
      signal_tree="$(git -C "$repo_root" rev-parse "${team_anchor}^{tree}" 2>/dev/null || true)"
      if [ -z "$signal_tree" ] || ! grep -qxF -- "$signal_tree" <<<"$full_trees"; then
        team_arm_refusal="no member holds a full-review clearance at the whole-team signal ${team_anchor}, so its review depth is unverifiable"
        echo "resolve-audit-base: ${team_arm_refusal}; whole-team anchoring disabled for ${member} this run." >&2
      fi
    fi
  fi

  # The team arm is the floor for BOTH forms, so the walk runs until it finds
  # one (or exhausts the range) even when the member arm already won. When the
  # member form refuses the team arm, only the member arm can still win, so
  # the walk goes on past the signal for an older full clearance of the member.
  # A refusal candidate met before the signal keeps the signal as its fallback.
  if [ -n "$team_anchor" ]; then
    if [ -z "$team_arm_refusal" ]; then
      if [ -z "$winner" ]; then
        team_winner="$sha"
      fi
      break
    fi
    if [ -n "$winner" ] || [ -n "$refusal_candidate" ] || [ "$member_arm" != "true" ]; then
      break
    fi
  fi
done

# -----------------------------------------------------------------------------
# The shared, pull-request-wide resolution: the whole-team arm plus the flat
# machinery reset. This is what the argument-less form prints and what the
# --member form carries on line 3; there is one code path so the two cannot
# drift.
# -----------------------------------------------------------------------------

shared_reason="no-anchor"
if [ -n "$team_anchor" ]; then
  shared_delta="$(delta_for "$team_anchor")"
  if [ -n "$shared_delta" ] && audit_delta_has_machinery >/dev/null <<<"$shared_delta"; then
    shared_reason="machinery-reset"
  else
    shared_base="$team_anchor"
    shared_reason="team-signal"
  fi
fi

if [ "$member_form" != "true" ]; then
  if [ "$shared_reason" = "machinery-reset" ]; then
    echo "resolve-audit-base: machinery changed between ${team_anchor} and HEAD; resetting to full scope (${main_reference})." >&2
  fi
  emit "$shared_base" "$shared_reason" ""
fi

# -----------------------------------------------------------------------------
# The refusal link. A refusal candidate anchors only when the store provably
# holds this member's open findings FROM THAT REFUSAL, and the refusal provably
# reviewed the tree it records. Evaluated here, after the shared resolution,
# because the ledger is keyed by the merge-base of line 3 and HEAD.
# -----------------------------------------------------------------------------

link_failure_cause=""

# refusal_link_holds: exit 0 iff the refusal at refusal_candidate_tree links;
# otherwise sets link_failure_cause and returns 1.
refusal_link_holds() {
  local record_line versioned_records="" proven_records="" coverage_digest
  local key_base ledger_key ledger_path current_branch provenance_line
  local provenance_digest provenance_tree provenance_version digest_matched="false"

  if ! jq -n 'true' >/dev/null 2>&1; then
    link_failure_cause="jq is unavailable, so the re-run ledger cannot be read"
    return 1
  fi
  if ! command -v gaia_audit_key >/dev/null 2>&1; then
    link_failure_cause="the audit key library (audit-key-lib.sh) is unavailable, so the re-run ledger cannot be located"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    [ "$(scan_field "$record_line" 1)" = "$refusal_candidate_tree" ] || continue
    [ "$(scan_field "$record_line" 2)" = "$current_version" ] || continue
    versioned_records="${versioned_records}${record_line}
"
  done <<EOF
$refused_records
EOF
  if [ -z "$versioned_records" ]; then
    link_failure_cause="version mismatch: no refusal at this tree was recorded under the current version ${current_version}"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    coverage_digest="$(jq -r '(.review_coverage | objects | .scope_digest | strings) // empty' \
      "$(scan_field "$record_line" 4)" 2>/dev/null || true)"
    [ -n "$coverage_digest" ] || continue
    [ "$coverage_digest" = "$(scan_field "$record_line" 3)" ] || continue
    proven_records="${proven_records}${record_line}
"
  done <<EOF
$versioned_records
EOF
  if [ -z "$proven_records" ]; then
    link_failure_cause="no review-coverage proof: the refusal record does not show its review covered the digest it records"
    return 1
  fi

  key_base="$(git -C "$repo_root" merge-base "$shared_base" HEAD 2>/dev/null || true)"
  ledger_key=""
  if [ -n "$key_base" ]; then
    ledger_key="$(gaia_audit_key "$key_base" "$repo_root" 2>/dev/null || true)"
  fi
  if [ -z "$ledger_key" ]; then
    link_failure_cause="the re-run ledger key is undeterminable"
    return 1
  fi
  ledger_path="${repo_root}/.gaia/local/audit/${ledger_key}.rerun.json"
  if [ ! -f "$ledger_path" ]; then
    link_failure_cause="no linked open-finding record: the re-run ledger is absent"
    return 1
  fi
  if ! jq -e 'type == "object"' "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger does not parse"
    return 1
  fi
  current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
  if ! jq -e --arg branch "$current_branch" --arg base "$key_base" \
    '(.schema == 1) and (.branch == $branch) and (.base_sha == $base)' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="stale re-run ledger: its schema, branch, or base does not match this checkout"
    return 1
  fi
  if ! jq -e --arg member "$member" \
    '[.remaining[]? | select(type == "object" and .member == $member)] | length > 0' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger holds no open entry for ${member}"
    return 1
  fi
  if ! jq -e --arg member "$member" \
    '(.member_provenance | type == "object") and (.member_provenance[$member] | type == "object")' \
    "$ledger_path" >/dev/null 2>&1; then
    link_failure_cause="no linked open-finding record: the re-run ledger holds no provenance for ${member}"
    return 1
  fi

  provenance_line="$(jq -r --arg member "$member" \
    '.member_provenance[$member] | [.refusal_digest, .refusal_tree, .version]
      | map(if type == "string" then . else "" end) | join("\t")' \
    "$ledger_path" 2>/dev/null || true)"
  provenance_digest="$(scan_field "$provenance_line" 1)"
  provenance_tree="$(scan_field "$provenance_line" 2)"
  provenance_version="$(scan_field "$provenance_line" 3)"
  if [ "$provenance_version" != "$current_version" ]; then
    link_failure_cause="version mismatch: the ledger provenance for ${member} was recorded under a different version"
    return 1
  fi

  while IFS= read -r record_line; do
    [ -n "$record_line" ] || continue
    [ -n "$provenance_digest" ] || continue
    [ "$(scan_field "$record_line" 3)" = "$provenance_digest" ] || continue
    digest_matched="true"
    if [ "$provenance_tree" = "$(scan_field "$record_line" 1)" ]; then
      return 0
    fi
  done <<EOF
$proven_records
EOF
  if [ "$digest_matched" = "true" ]; then
    link_failure_cause="no linked open-finding record: the ledger provenance records a different tree for this refusal"
  else
    link_failure_cause="no linked open-finding record: the ledger provenance names a different refusal of ${member}"
  fi
  return 1
}

# -----------------------------------------------------------------------------
# The per-member resolution: the walk's winner, then the two-tier reset.
# -----------------------------------------------------------------------------

if [ -n "$refusal_candidate" ]; then
  if refusal_link_holds; then
    winner="$refusal_candidate"
    winner_reason="member-refusal"
    winner_tree="$refusal_candidate_tree"
  else
    echo "resolve-audit-base: ${member} refused content at ${refusal_candidate} (${link_failure_cause}); per-member anchoring disabled for this run." >&2
  fi
fi

if [ -z "$winner" ] && [ -n "$team_winner" ]; then
  winner="$team_winner"
  winner_reason="team-signal"
  winner_tree=""
fi

if [ -z "$winner" ]; then
  emit "$main_reference" no-anchor ""
fi

member_delta="$(delta_for "$winner")"
reset_hit=""
if [ -n "$member_delta" ]; then
  reset_hit="$(audit_rules_reset_for "$member" <<<"$member_delta" || true)"
fi

if [ -n "$reset_hit" ]; then
  reset_tier=""
  reset_path=""
  IFS="$TAB" read -r reset_tier reset_path <<<"$reset_hit"
  if [ "$reset_tier" = "member" ]; then
    echo "resolve-audit-base: ${member}'s own agent definition changed between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_reference})." >&2
    emit "$main_reference" rules-reset-member ""
  fi
  echo "resolve-audit-base: a global rules path changed between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_reference})." >&2
  emit "$main_reference" rules-reset-global ""
fi

emit "$winner" "$winner_reason" "$winner_tree"
