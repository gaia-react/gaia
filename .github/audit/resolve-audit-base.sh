#!/usr/bin/env bash
# resolve-audit-base.sh: resolve the incremental review base for the
# code-review-audit agent.
#
# Purpose
#   The audit reviews the diff from a "base" commit to HEAD. The base is
#   the most recent ancestor of HEAD that previously passed a CLEAN audit
#   under the CURRENT agent version, proven by either a GAIA-Audit commit
#   trailer (locally-stamped) or a GAIA-Audit commit status (CI-stamped).
#   Everything up to that commit was already cleared, so reviewing only
#   <base>..HEAD is correct and far cheaper than re-reviewing the whole
#   origin/main..HEAD diff on every push to an open PR.
#
#   That whole-team signal is stamped only when NO dispatched Code Audit
#   Team member is still pending, which is what makes it trustworthy and
#   also what caps it: a member that cleared in a round where a sibling was
#   pending cannot anchor on its own clearance. Naming a member with
#   `--member` adds a second anchor arm over the same walk, reading that
#   member's own earned clearances out of the local audit store. The
#   whole-team signal stays the FLOOR; the per-member arm only ever improves
#   on it, never replaces it.
#
#   When no usable ancestor exists, first audit of a PR, every prior run
#   cancelled or failed (those stamp nothing), a .gaia/VERSION bump
#   invalidated older audits, or the version file is missing; the helper
#   emits the main ref so the caller falls back to a full-scope review. It
#   can never skip uncleared code: an uncleared commit carries no signal to
#   anchor on.
#
# Invocation
#   .github/audit/resolve-audit-base.sh [--member <name>]
#
#   The argument-less form is what every non-agent caller uses (the audit
#   workflow, the workflow templates, the merge-time findings hook), and its
#   resolution is unchanged on every input except the inverted degraded arm
#   below. `--member <name>` is the per-member form; the Code Audit Team's
#   agent definitions are the only call sites that can name a member.
#
#   Reads .gaia/VERSION, HEAD's ancestry, commit trailers, the local audit
#   store's clearance records, and (when GH_TOKEN + gh are available) the
#   GitHub Commit Status API.
#
# Output (stdout), argument-less form
#   Exactly ONE line, suitable for a `base...HEAD` diff:
#     <40-hex-sha>: resolved incremental base (an audited PR ancestor)
#     origin/<base-ref>: fallback: review the full PR diff, scoped to the
#       branch the PR merges into (GITHUB_BASE_REF, read under Actions only,
#       which sets it on every pull_request event)
#     origin/main: the same fallback outside Actions, or when no base ref is
#       declared
#     (or main when neither remote-tracking ref resolves)
#
# Output (stdout), --member form
#   Exactly FOUR newline-terminated lines:
#     1. the per-member review base ref, which SCOPES that member's review
#     2. the reason token (closed set, below)
#     3. the shared pull-request-wide base ref, which KEYS every artifact
#     4. the recorded tree of the clearance that anchored line 1, or EMPTY
#        on every path where no clearance anchored it
#
#   Line 3 comes from the same code path the argument-less form prints, so
#   review-time and merge-time key agreement is structural rather than
#   incidental: the merge-time findings producer calls the argument-less
#   form and receives byte-identically what line 3 carries. Lines 1 and 3
#   legitimately differ, e.g. when a merely-shared machinery path changed
#   after the anchor: line 3 resets and line 1 does not. That divergence is
#   what the two-base split is for.
#
#   Line 4 lets a caller record WHICH clearance anchored the answer without
#   a second invocation and without parsing stderr. An empty line 4 is the
#   normal case for every reason other than member-clearance, and an empty
#   line is still a line.
#
# Output (stderr)
#   Exactly one decision line on every path:
#     resolve-audit-base: member=<name|-> base=<sha|ref> reason=<token> anchor_tree=<tree|->
#   plus one FURTHER explanatory line when a reset or a degradation fired,
#   naming the path or the library that forced it. Closed reason set:
#     member-clearance    anchored on this member's own earned clearance
#     team-signal         anchored on the whole-team trailer/status floor
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
#   resolve the diff's left side to HEAD and return nothing at status 0, and
#   it makes the merge-time findings hook post nothing at all. Reviewing
#   nothing is worse than reviewing everything. This script runs under
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
# Base reset on machinery change (RT-006)
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
#   clearance whose recorded TREE equals the candidate's tree and whose
#   recorded version equals the current one. The tree rather than the commit
#   sha is the matching field because the clean-round stamp amends HEAD,
#   rewriting the sha a moments-old clearance recorded while preserving the
#   tree; matching on the sha would lose the anchor on exactly the rounds
#   that earned it. No member digest is ever recomputed at a candidate: the
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
# Refusal precedence, and why the floor still runs past a refusal
#   If any candidate in range carries a tree the member REFUSED, the
#   per-member arm is disabled for the whole run, not merely at that
#   candidate: the member must be able neither to anchor on content it
#   refused nor to anchor past it, and the walk meets a newer earned
#   clearance first. The whole-team floor is deliberately NOT disabled by a
#   refusal. The trailer and the status are each stamped only when no
#   dispatched member is pending, and a member holding a live refusal IS
#   pending, so a whole-team signal at or newer than the refused commit is
#   evidence that the refusal was already resolved (superseded by its author
#   or retired by a digest rotation). That reasoning inherits the stamping
#   hook's member-pending check, which sits inside a guard with no else arm
#   and stamps anyway in a degraded environment; the floor is therefore
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
#   between runs. There the floor is sound and both tiers stay evaluable, so
#   resolution falls back to the whole-team signal rather than degrading.
#   Widening to full scope on that input would punish the normal CI path for
#   a broken-checkout symptom. Do not "fix" this into uniformity.
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
#   - Mirrors the frozen trailer regex + status-parse logic in
#     .github/audit/check-trailer.sh.

set -euo pipefail

# Defensive cap on the ancestry walk (PRs rarely exceed this many commits;
# the merge-base bound usually keeps the list far shorter).
MAX_WALK=50

TAB="$(printf '\t')"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

member=""
member_form="false"
arg_error=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --member)
      if [ "$#" -lt 2 ]; then
        arg_error="--member requires a value"
        break
      fi
      if [ -z "$2" ]; then
        arg_error="--member requires a non-empty value"
        break
      fi
      member="$2"
      member_form="true"
      shift 2
      ;;
    *)
      arg_error="unknown argument '$1'"
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
  main_ref="origin/main"
  shared_base="$main_ref"
  echo "resolve-audit-base: not inside a git checkout; resetting to full scope (${main_ref})." >&2
  emit "$main_ref" degraded ""
fi

# -----------------------------------------------------------------------------
# Resolve a "main ref": used both for the fallback output and to bound the
# ancestry walk via merge-base.
# -----------------------------------------------------------------------------

resolve_main_ref() {
  # The declared base ref comes first because it names the branch THIS pull
  # request merges into, which the repository default does not whenever the
  # pull request is stacked on another branch. Preferring the default there
  # hands every consumer the base branch's entire divergence as if this pull
  # request had introduced it, and a finding raised against that history is
  # indistinguishable, in a member's output, from one against the pull
  # request's own code (gaia-react/gaia#1057).
  #
  # Read only under Actions, which is what makes the value trustworthy: there
  # the event sets it, not whoever invoked the script. This resolver SCOPES a
  # review, so a value resolving at or near HEAD empties the reviewed delta and
  # a member then earns a clearance marker having read nothing, a false green
  # no downstream check can catch because the gate trusts the marker rather
  # than the scope. A check that can only WIDEN on a bad input may take the
  # environment; one that decides how much gets read may not. The merge gate's
  # bypasses reach the opposite conclusion from the same principle and read the
  # pull request record instead, so neither posture transfers to the other.
  #
  # No `gh` fallback for the local case either: this resolver runs from hooks
  # and agent bootstraps where gh may be absent or unauthenticated, and a base
  # that resolves only sometimes is worse than one that is always the
  # repository default, which is what a local run keeps.
  if [ "${GITHUB_ACTIONS:-}" = "true" ] \
    && [ -n "${GITHUB_BASE_REF:-}" ] \
    && git -C "$repo_root" rev-parse --verify --quiet "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
    printf 'origin/%s' "$GITHUB_BASE_REF"
    return 0
  fi
  if git -C "$repo_root" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    printf 'origin/main'
    return 0
  fi
  if git -C "$repo_root" rev-parse --verify --quiet main >/dev/null 2>&1; then
    printf 'main'
    return 0
  fi
  # Last resort: emit origin/main anyway (matches the existing workflow's
  # assumption; the caller's diff errors loudly if it truly can't resolve).
  printf 'origin/main'
}
main_ref="$(resolve_main_ref)"
shared_base="$main_ref"

# A mis-invocation cannot be trusted to be a member call site, so it degrades
# to the argument-less full-scope shape rather than guessing a four-line one.
if [ -n "$arg_error" ]; then
  member=""
  member_form="false"
  echo "resolve-audit-base: ${arg_error}; resolving full scope (${main_ref})." >&2
  emit "$main_ref" no-anchor ""
fi

# -----------------------------------------------------------------------------
# Read .gaia/VERSION: missing/empty means no base can be validated, on either
# anchor arm.
# -----------------------------------------------------------------------------

# Sourced here rather than in the library block below, because that block sits
# after this read and the version gate has to answer before the walk starts.
version_lib="${repo_root}/.claude/hooks/lib/gaia-version.sh"
if [ -f "$version_lib" ]; then
  # shellcheck source=/dev/null
  . "$version_lib" 2>/dev/null || true
fi
if ! command -v gaia_read_version >/dev/null 2>&1; then
  echo "resolve-audit-base: version normalizer unavailable (gaia-version.sh); resetting to full scope (${main_ref})." >&2
  emit "$main_ref" degraded ""
fi

cur_version="$(gaia_read_version "${repo_root}/.gaia/VERSION")"
if [ -z "$cur_version" ]; then
  emit "$main_ref" no-version ""
fi

# -----------------------------------------------------------------------------
# Build the candidate list (PR commits, newest first).
# -----------------------------------------------------------------------------

head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
if [ -z "$head_sha" ]; then
  emit "$main_ref" no-anchor ""
fi

merge_base=$(git -C "$repo_root" merge-base "$main_ref" HEAD 2>/dev/null || true)
if [ -n "$merge_base" ]; then
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAX_WALK" "${merge_base}..HEAD" 2>/dev/null || true)
else
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAX_WALK" HEAD 2>/dev/null || true)
fi

# -----------------------------------------------------------------------------
# Signal extractors (frozen regex + status shape mirror check-trailer.sh).
# -----------------------------------------------------------------------------

# C3: version, frontend-digest (64-hex), tree (40-hex).
trailer_regex='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{64})[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# trailer_version_for <sha> → echoes the (last) GAIA-Audit trailer version on
# that commit's message, or empty. Reads from a temp file (not a pipe) so the
# matched value survives in this shell (Bash 3.2 has no lastpipe). Only $1
# (version) is read here; the base is gated by version match alone.
trailer_version_for() {
  local sha="$1" line ver="" tmp
  tmp=$(mktemp -t gaia-audit-base.XXXXXX) || return 0
  git -C "$repo_root" log -1 --format='%B' "$sha" 2>/dev/null \
    | git -C "$repo_root" interpret-trailers --parse > "$tmp" 2>/dev/null || true
  while IFS= read -r line; do
    case "$line" in
      GAIA-Audit:*) ;;
      *) continue ;;
    esac
    if [[ "$line" =~ $trailer_regex ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
  done < "$tmp"
  rm -f "$tmp"
  printf '%s' "$ver"
}

# status_version_for <sha> → echoes the GAIA-Audit commit status version, or
# empty. Only a state: success status counts; a non-success status (e.g. a
# local-mode stand-down's pending status on this SHA) is filtered out at the
# source, so such a commit is not a usable base from the status path. Needs
# gh + GH_TOKEN + repo slug; a missing token / absent gh / API failure / no
# success status all yield empty (the walk continues).
status_version_for() {
  local sha="$1" repo desc
  [ -n "${GH_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  repo="${GITHUB_REPOSITORY:-}"
  [ -n "$repo" ] || return 0
  desc=$(gh api "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit" and .state == "success")) | last | .description' \
    2>/dev/null || true)
  if [ -z "$desc" ] || [ "$desc" = "null" ]; then
    return 0
  fi
  printf '%s' "$desc" | awk '{print $1}'
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

lib_dir="${repo_root}/.claude/hooks/lib"
for lib_file in audit-scope.sh audit-machinery.sh audit-rules-changed.sh audit-clearance.sh; do
  if [ -f "${lib_dir}/${lib_file}" ]; then
    . "${lib_dir}/${lib_file}" 2>/dev/null || true
  fi
done

missing_lib=""
if ! command -v audit_owner_for_path >/dev/null 2>&1; then
  missing_lib="audit-scope.sh"
elif ! command -v audit_path_is_machinery >/dev/null 2>&1 \
  || ! command -v audit_delta_has_machinery >/dev/null 2>&1; then
  missing_lib="audit-machinery.sh"
elif ! command -v audit_rules_reset_for >/dev/null 2>&1; then
  missing_lib="audit-rules-changed.sh"
fi
if [ -n "$missing_lib" ]; then
  echo "resolve-audit-base: classifier/machinery/rules libs unavailable (${missing_lib}); resetting to full scope (${main_ref})." >&2
  emit "$main_ref" degraded ""
fi

# -----------------------------------------------------------------------------
# Per-member pre-scan: the trees this member has earned, and the trees it has
# refused. Only the --member form reads the store, and only when the clearance
# reader loaded.
# -----------------------------------------------------------------------------

member_arm="false"
earned_trees=""
refused_trees=""

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
    while IFS="$TAB" read -r rec_tree rec_version _; do
      [ -n "$rec_tree" ] || continue
      [ "$rec_version" = "$cur_version" ] || continue
      earned_trees="${earned_trees}${rec_tree}
"
    done <<EOF
$earned_scan
EOF
  fi

  # Version-independent, deliberately: a refusal carries no version qualifier,
  # and the conservative direction is to honour more refusals, not fewer.
  if [ -n "$refused_scan" ]; then
    while IFS="$TAB" read -r rec_tree _; do
      [ -n "$rec_tree" ] || continue
      refused_trees="${refused_trees}${rec_tree}
"
    done <<EOF
$refused_scan
EOF
  fi

  if [ -n "$earned_trees" ]; then
    member_arm="true"
  fi
fi

# Refusal precedence is a WHOLE-RANGE pre-scan, not a per-candidate test: the
# walk meets a newer earned clearance before the refused candidate, so testing
# per candidate would let the member anchor past its own refusal.
if [ "$member_arm" = "true" ] && [ -n "$refused_trees" ]; then
  for sha in $candidates; do
    cand_tree="$(git -C "$repo_root" rev-parse "${sha}^{tree}" 2>/dev/null || true)"
    [ -n "$cand_tree" ] || continue
    if grep -qxF -- "$cand_tree" <<<"$refused_trees"; then
      echo "resolve-audit-base: ${member} refused content at ${sha}; per-member anchoring disabled for this run." >&2
      member_arm="false"
      break
    fi
  done
fi

# -----------------------------------------------------------------------------
# One walk, two arms, newest wins. Per candidate the per-member arm is tested
# first, so a member clearance and a whole-team signal on the SAME commit
# resolve as the former; across candidates the newer of the two wins, which is
# why this is one walk and not two.
# -----------------------------------------------------------------------------

team_anchor=""
winner=""
winner_reason=""
winner_tree=""

for sha in $candidates; do
  # HEAD itself can't be the base (an empty diff), and never carries a
  # *matching* signal anyway, a match would have skipped the run upstream.
  [ "$sha" = "$head_sha" ] && continue

  if [ "$member_arm" = "true" ] && [ -z "$winner" ]; then
    cand_tree="$(git -C "$repo_root" rev-parse "${sha}^{tree}" 2>/dev/null || true)"
    if [ -n "$cand_tree" ] && grep -qxF -- "$cand_tree" <<<"$earned_trees"; then
      winner="$sha"
      winner_reason="member-clearance"
      winner_tree="$cand_tree"
    fi
  fi

  tv="$(trailer_version_for "$sha")"
  if [ -n "$tv" ] && [ "$tv" = "$cur_version" ]; then
    team_anchor="$sha"
  else
    sv="$(status_version_for "$sha")"
    if [ -n "$sv" ] && [ "$sv" = "$cur_version" ]; then
      team_anchor="$sha"
    fi
  fi

  # The team arm is the floor for BOTH forms, so the walk runs until it finds
  # one (or exhausts the range) even when the member arm already won.
  if [ -n "$team_anchor" ]; then
    if [ -z "$winner" ]; then
      winner="$sha"
      winner_reason="team-signal"
    fi
    break
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
    echo "resolve-audit-base: machinery changed between ${team_anchor} and HEAD; resetting to full scope (${main_ref})." >&2
  fi
  emit "$shared_base" "$shared_reason" ""
fi

# -----------------------------------------------------------------------------
# The per-member resolution: the walk's winner, then the two-tier reset.
# -----------------------------------------------------------------------------

if [ -z "$winner" ]; then
  emit "$main_ref" no-anchor ""
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
  # The member tier's trigger is the whole file: any change to
  # .claude/agents/<member>.md re-arms this reset, a reworded sentence as
  # readily as a rewritten remit, and the member then re-reviews the whole
  # pull request's diff against its remit instead of the delta since its
  # anchor. That breadth is chosen, and it is the expensive choice: a round of
  # prose repairs spanning several definitions pays that widened re-review for
  # every member it touches.
  #
  # It is chosen because a member definition is an instruction file, where the
  # prose IS the logic and no syntactic split separates a comment-only edit
  # from a behavior-changing one. "Prefer" becoming "always" inside a remit
  # rewrites what the member looks for, and only the surrounding sentence says
  # so. The narrowings that look attractive fail on their own terms. Resetting
  # only outside regions marked non-normative has no region to key on: the
  # gaia:maintainer-only markers mark AUDIENCE, a maintainer-only paragraph
  # still instructs, and most member definitions carry no marker at all, so a
  # new convention would rest the reset on whoever remembered to mark a
  # region. Exempting a member's own round-trip repair is backwards, because
  # the member reviewed under the OLD definition and its correction is what
  # changes the instructions it runs under next.
  #
  # The direction of the miss settles it. Resetting too often costs tokens and
  # wall-clock, and both are visible in the run that pays them. Resetting too
  # rarely lets a member earn a clearance marker over a surface narrower than
  # its changed instructions warrant, and the merge gate believes the marker
  # rather than re-deriving the scope behind it, so nothing downstream catches
  # that one.
  #
  # What stays open is the number of resets rather than the trigger: batching
  # a round's definition repairs into one commit pays one reset, not one per
  # commit.
  if [ "$reset_tier" = "member" ]; then
    echo "resolve-audit-base: ${member}'s own agent definition changed between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_ref})." >&2
    emit "$main_ref" rules-reset-member ""
  fi
  echo "resolve-audit-base: a global rules path changed between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_ref})." >&2
  emit "$main_ref" rules-reset-global ""
fi

emit "$winner" "$winner_reason" "$winner_tree"
