#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until every dispatched Code Audit
# Team member has cleared HEAD. AND-aggregator: resolves the diff's dispatched
# member set (.gaia/scripts/resolve-audit-members.sh) and requires each
# member's own clearance, one cleared member can no longer satisfy the gate
# while a co-dispatched member withholds.
#
# Zero-match (the whole diff is out of audit scope) or the resolver script
# being absent both fall through to the LEGACY single-signal gate: the marker/
# trailer/status/bypass logic below, unchanged, evaluated for
# code-audit-frontend alone. A non-empty dispatched set instead runs the
# member-aware gate further down: code-audit-frontend by the same signals,
# each SPECIALIZED member <m> by its own marker
# .gaia/local/audit/<digest>.<m>.ok (the sole clearance signal for maintainer
# members, which are local/advisory-only with no CI/trailer equivalent).
#
# Markers are keyed to each member's own CONTENT DIGEST (a sha256 over exactly
# the files that member owns plus the shared gate machinery, folding in the
# in-scope-but-ownerless paths for the default member), not the whole tree and
# not the commit. A marker attests that a member audited the CONTENT its
# digest covers: an out-of-glob change (a CHANGELOG line, a wiki edit) rotates
# no member's digest, so every existing marker keeps validating with zero
# re-dispatch; a change to a file a member owns rotates only that member's
# digest; a change to any gate-machinery file rotates every member's digest.
# code-audit-frontend's GAIA-Audit trailer stamp lands as an empty commit,
# which advances HEAD while leaving every blob byte-identical, so it rotates
# no digest either.
#
# code-audit-frontend / legacy-gate signals:
#
#   1. Local marker file at .gaia/local/audit/<frontend-digest>.ok, written by
#      the audit agent at the end of a clean local review.
#
#   2. GAIA-Audit trailer on HEAD's commit message, when the trailer's
#      version and frontend-digest fields both match a recomputed frontend
#      digest. Written by a local audit run via
#      .claude/hooks/audit-stamp-trailer.sh.
#
#   3. GAIA-Audit GitHub commit status on HEAD with state: success, description
#      "<version> <frontend-digest> <tree>", when both version and digest
#      match (the tree field is data only, never compared). CI stamps this
#      status instead of pushing an empty marker commit (pushing it would
#      re-trigger CI and leave the PR HEAD without check runs). A non-success
#      status (e.g. a local-mode stand-down's pending status on the same
#      context and SHA) is not a cleared signal even when its description
#      matches. Queried via `gh api` using GH_TOKEN or the ambient gh auth
#      session.
#
#   4. chore(deps) PR bypass: PR title matches `^chore\(deps(-dev)?\):`. The
#      /update-deps wrapper runs the full quality gate locally before
#      pushing, so the audit signal is implicit for this PR class. Mirrors
#      the same narrowing applied to code-review-audit.yml, tests.yml, and
#      chromatic.yml, all four surfaces skip together on chore(deps) PRs.
#
#   5. Out-of-scope bypass (legacy gate only, a non-empty dispatched set means
#      an in-scope file exists so this never applies there): every file the PR
#      changes lives on a surface outside audit scope, wiki, instruction files
#      (.claude / .specify), .gaia metadata, prose docs, and root-level
#      markdown. These mirror the surfaces code-review-audit.yml treats as out
#      of scope via its `has_source` check. Evaluated fail-closed: any in-scope
#      path (app/, test/, configs, .github/workflows/) makes the marker
#      mandatory again. An in-scope-but-ownerless path (a root Makefile,
#      public/**) is folded into the frontend member's digest input set, so a
#      stale marker computed for a prior digest never matches such a change
#      either; this bypass and that digest fold close the same band from two
#      directions.
#
#   6. Self-mod-only GAIA-update bypass: the only in-scope path the PR changes
#      is .github/workflows/code-review-audit.yml AND its committed bytes are a
#      verbatim re-render of the bundled template
#      (.gaia/cli/templates/workflows/code-review-audit.yml.tmpl), with every
#      other changed path out of scope. This is the self-mod-only case
#      /update-gaia Step 12 produces: it refreshes a stale audit workflow by
#      copying the release template verbatim, which makes CI self-mod-skip (no
#      stamp) and trips the in-scope guard of signal 5. The changed bytes are
#      GAIA's own template, not adopter code, so there is nothing to audit.
#
# Signals 1-4 and 6 prove an audit ran against this content (or that none is
# needed); signal 5 proves there is nothing in audit scope to review at all. A
# refusal artifact (.gaia/local/audit/<digest>[.<member>].refused) for a
# member's current digest is checked BEFORE any earned signal and is
# absolute: it denies regardless of a same-digest earned marker, for both
# code-audit-frontend and every specialized member.
#
# Without every dispatched member's clearance, the hook denies the gh pr merge
# call. To unblock:
#   1. Spawn the pending member's agent (code-audit-frontend for the default
#      member; the specialized member named in the deny reason otherwise) on
#      the current branch, OR for code-audit-frontend, push to the PR branch
#      and wait for CI's audit to stamp the GitHub commit status (CI ships no
#      specialized members).
#   2. Address any findings; commit and push.
#   3. Re-spawn the pending member's agent on the new HEAD; let it write its marker.
#   4. Retry gh pr merge.
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Note: avoid naming this `command`, it would shadow bash's `command` builtin
# and make any later `command -v ...` calls in this script silently misbehave.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# gate_cmd_is_first_command_merge: does this tool call's FIRST command tokenize
# to `gh pr merge`? The text arms below cannot answer that, because every
# spelling that breaks the literal run of characters `gh pr merge` is invisible
# to them: `gh pr "merge" <n>`, `gh "pr" merge <n>`, and a line continuation
# inside the verb were each demonstrated against the running hook skipping the
# gate entirely, on a pull request carrying no marker at all
# (gaia-react/gaia#1541).
#
# Named at parent level because a `[[ =~ ]]` pattern holding a quote and a
# backslash is unreadable written inline, and quoting it there would match it
# literally instead of as a regex.
gate_gh_lead_re=$'^[[:space:]]*[g"\'\\\\]'

# It asks the shared scanner for WORDS rather than calling gaia_scan_gh_merge,
# and the difference is load-bearing rather than stylistic. That function also
# abstains on any flag shape it declines to model, which is the right answer for
# a relaxation deciding whether to permit and the wrong one here: arming must be
# strictly broader than clearing, or a merge carrying an unmodelled flag would
# skip the gate rather than meet it.
gate_cmd_is_first_command_merge() {
  local lib_dir
  # Cheap pre-filter first. This hook fires on EVERY Bash tool call, while the
  # scan below is a byte-at-a-time bash loop over the command and the library
  # holding it is several hundred lines to source. A call that cannot be a merge
  # must pay for neither, which is the same reason every other library load in
  # this file sits below the early exits.
  #
  # The filter tests the FIRST non-blank byte rather than searching for the verb,
  # and soundness is why. A word the shell assembles need not appear in the
  # command as a run of bytes at all: `gh pr me\<newline>rge 1` spells the verb
  # through a line continuation and holds no `merge` substring, so a search for
  # one would drop exactly the spelling this arm exists to catch. A command whose
  # first word tokenizes to `gh` can only begin with `g` or with a quoting
  # character, so this test admits every such command and nothing here can be
  # outrun by a spelling that is merely quoted more creatively.
  [[ "$cmd" =~ $gate_gh_lead_re ]] || return 1

  # From this hook's OWN on-disk location, never cwd: the bats suites run this
  # hook by absolute path from a sandbox cwd that has no .claude/, so a
  # cwd-relative source would leave this arm silently dead exactly where the
  # tests believe they are exercising it.
  if ! type gaia_scan_first_command >/dev/null 2>&1; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
    [ -n "$lib_dir" ] && [ -f "$lib_dir/repo-scope.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$lib_dir/repo-scope.sh" || return 1
    type gaia_scan_first_command >/dev/null 2>&1 || return 1
  fi

  gaia_scan_first_command "$cmd" || return 1
  [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -ge 3 ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[0]}" = "gh" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[1]}" = "pr" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[2]}" = "merge" ]
}

# Arm the gate when this tool call carries a `gh pr merge`. Two arms, unioned,
# because each reaches a spelling the other cannot and neither is a superset.
#
# TEXT: the literal run `gh pr merge` at the very start of the command or
# immediately after a shell separator (&&, ;, ||, |, newline). Use bash =~ for
# whole-string regex semantics; grep operates line-by-line. This is the only arm
# that can see a merge which is NOT the first command in the tool call, because
# the scanner stops at the first one, so dropping it in favour of the tokenizer
# would open a hole (`<anything> && gh pr merge <n>`) rather than close one.
#
# TOKENIZER: the first command really is the merge, whatever quoting spells it.
#
# WHAT THIS DOES NOT GUARANTEE. Stated because the comment that stood here
# claimed the opposite, and a guard advertising a property it does not have is
# worse than one that admits the gap. The text arm OVER-arms: its newline
# alternative means a heredoc body line, or a quoted prose string carrying a
# separator, that begins with the verb arms the gate and denies an unrelated
# tool call. Writing this repository's own merge documentation through a heredoc
# trips it. That direction is fail-closed, it costs an unrelated call rather
# than permitting an unaudited merge, and closing it needs a scanner that walks
# every command in the tool call and models heredoc bodies as data, which the
# shared one does not. Neither arm reads a prefix (`env gh pr merge`, an
# absolute path to gh) or a subshell, since those change which word is first.
# This gate targets accidental and inattentive merges; a PreToolUse hook
# matching a command is not a boundary against deliberate obfuscation.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
elif gate_cmd_is_first_command_merge; then
  : # the first command tokenizes to the merge, however it is quoted
else
  exit 0
fi

# Repo-scope: this gate enforces the home repo's audit contract only. A
# `gh pr merge` aimed at a different repo (e.g. a sibling project merged via
# `cd ../other && gh pr merge` or `gh pr merge -R owner/other`) has no bearing
# on this repo's audit markers, allow it.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Load the shared clearance reader from this hook's OWN on-disk location
# (never cwd, never $repo_root). The bats suites run this hook by absolute
# path from a sandbox cwd that has no .claude/, so a cwd-relative source would
# miss the lib and flip every clearance check. Loaded lazily here, after the
# early exits above, because this hook fires on every Bash tool call.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `root` derivation below.
_root_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [ -n "$_root_lib_dir" ] && [ -f "$_root_lib_dir/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_root_lib_dir/.gaia/scripts/main-root-lib.sh"
fi

# Load the shared ownership classifier + machinery list + digest engine + base
# provenance resolver from the same on-disk location. check_out_of_scope_pr()
# and check_self_mod_only_update_pr() below depend on the classifier to know
# what a changed path is and on the provenance resolver to know what base they
# are reading a change set against, and every marker check below is keyed to a
# member's content digest computed by the digest engine; an absent or
# unreadable module means this gate cannot know what it is gating, so it denies
# rather than fall through to a degraded, uninformed gate. This is a
# deliberate fail-closed path distinct from every other guard in this hook
# (which fail OPEN on an unusable lookup).
_scope_lib="$_lib_dir/audit-scope.sh"
_machinery_lib="$_lib_dir/audit-machinery.sh"
_digest_lib="$_lib_dir/audit-digest.sh"
_version_lib="$_lib_dir/gaia-version.sh"
_provenance_lib="$_lib_dir/audit-base-provenance.sh"
if [ -z "$_lib_dir" ] || [ ! -f "$_scope_lib" ] || [ ! -f "$_machinery_lib" ] || [ ! -f "$_digest_lib" ] || [ ! -f "$_version_lib" ] || [ ! -f "$_provenance_lib" ]; then
  jq -n --arg r "PR merge gate: cannot load the ownership classifier, the digest engine, the version normalizer, or the base provenance resolver (.claude/hooks/lib/audit-scope.sh, .claude/hooks/lib/audit-machinery.sh, .claude/hooks/lib/audit-digest.sh, .claude/hooks/lib/gaia-version.sh, and .claude/hooks/lib/audit-base-provenance.sh must all exist and be readable). Every marker check below is keyed to a member's content digest and to a version literal this gate compares for equality against the stamped one; this gate's out-of-scope and self-mod-only bypasses depend on the classifier to know what a changed path is, and on the provenance resolver to know what base their change set is read against, so it denies rather than guess. Restore all five files (they ship with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi
# shellcheck source=/dev/null
. "$_scope_lib"
# shellcheck source=/dev/null
. "$_machinery_lib"
# shellcheck source=/dev/null
. "$_digest_lib"
# shellcheck source=/dev/null
. "$_version_lib"
# shellcheck source=/dev/null
. "$_provenance_lib"

# The shared disposition-ledger logic (disposition_offenders). C4 re-verifies
# code-audit-frontend's dispositions whenever its own earned digest marker is
# valid, so a still-open receipt that seed-forward carried across a digest
# rotation without re-verifying it against the backend is still caught here.
# Loaded lazily here, after the early exits, resolved from this hook's own
# on-disk location. An absent lib is NOT fail-closed: the re-check below
# simply cannot run (every call site guards on `command -v
# disposition_offenders`), the gate still demands every dispatched member's
# own clearance regardless.
if [ -f "$_lib_dir/audit-dispositions.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-dispositions.sh"
fi

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

# Resolve HEAD's TREE. This is now a plain DATA field (surfaced in deny
# messages only), never a validity key: every marker check below is keyed to
# a member's own content digest, computed next.
tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)

# TWO roots, because this gate spans two different questions and one root
# cannot answer both.
#
#   root       WHERE a clearance lives. Resolved to the MAIN checkout: every
#              marker clearance_member_cleared builds a path for is
#              main-anchored shared state (.gaia/state-registry.json
#              scope=shared, the symlinked audit/ store), not a property of
#              whichever tree this hook happens to run in. Sourced from this
#              hook's own on-disk location, matching the sibling lib-loads
#              above.
#   tree_root  WHAT a clearance attests to. The ACTING tree: the content
#              being merged is this tree's HEAD, not main's. Every writer
#              agrees -- the five agent definitions pass
#              `--root "$(git rev-parse --show-toplevel)"` to
#              audit-write-clearance.sh, and resolve-audit-spawn.sh and
#              audit-stamp-trailer.sh derive the same way -- so digesting
#              main's HEAD here would compare a marker against content
#              nobody is merging. From a linked worktree the two trees
#              differ, no marker could ever match, and the gate's own remedy
#              text ("re-spawn the agents") would rewrite the same
#              non-matching marker forever.
#
# Both fall back to a bare toplevel query, then pwd, when the resolver is
# unavailable or fails -- the same fail-open direction the original
# CWD-anchored derivation had.
root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  root="$(gaia_resolve_main_root 2>/dev/null)" || root=""
fi
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Parse the roster ONCE per run (never once per path); the classifier module
# was sourced above. audit_digests_all below re-inits the same state
# internally (its own single-walk contract), so this call is redundant with
# it in effect but kept explicit: check_out_of_scope_pr() and
# check_self_mod_only_update_pr() run before any digest-dependent path in a
# future edit would still find the roster parsed.
audit_scope_init "$tree_root"

# Compute every roster member's content digest in ONE walk (directive
# PERF-001): audit_digests_all parses the roster, walks the tree once, and
# classifies every path once, emitting "<member>\t<digest>" per member. This
# is the sole validity-key derive point for every marker check below,
# replacing the single HEAD^{tree} marker key. Fail closed: a missing sha256
# tool, an unloadable classifier, or a git failure returns non-zero here (the
# same tool-degradation fail-closed posture already applied to an unloadable
# classifier above), and this gate must never proceed with a partial or empty
# digest set.
_digest_batch="$(audit_digests_all "$tree_root" 2>/dev/null)" || _digest_batch=""
if [ -z "$_digest_batch" ]; then
  jq -n --arg r "PR merge gate: cannot derive per-member content digests for HEAD ${sha:0:12} (audit_digests_all failed or returned nothing). This usually means a missing sha256 tool (sha256sum / shasum -a 256), a git failure, or a corrupted checkout. Every Code Audit Team marker is keyed to a member's content digest, so this gate denies rather than match against an empty or partial digest. Restore the missing tool/checkout and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

# Parse the batch into parallel arrays (bash 3.2 has no associative arrays,
# mirroring the digest engine's own convention).
_DIGEST_MEMBER=()
_DIGEST_VALUE=()
while IFS= read -r _digest_line; do
  [ -n "$_digest_line" ] || continue
  _DIGEST_MEMBER[${#_DIGEST_MEMBER[@]}]="${_digest_line%%$'\t'*}"
  _DIGEST_VALUE[${#_DIGEST_VALUE[@]}]="${_digest_line#*$'\t'}"
done <<EOF
$_digest_batch
EOF

# member_digest <member> -> that member's content digest on stdout, exit 0;
# exit 1 (empty stdout) when the member is absent from the batch above.
member_digest() {
  local want="$1" i=0
  while [ "$i" -lt "${#_DIGEST_MEMBER[@]}" ]; do
    if [ "${_DIGEST_MEMBER[$i]}" = "$want" ]; then
      printf '%s\n' "${_DIGEST_VALUE[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

frontend_digest="$(member_digest code-audit-frontend)" || frontend_digest=""

marker="$root/.gaia/local/audit/${frontend_digest}.ok"

# A refusal for the frontend's CURRENT digest is checked before any earned
# signal and is absolute (C6): denies regardless of a same-digest earned
# marker. Computed once so both the legacy and member-aware deny paths (and
# frontend_cleared() below) see the same value without re-querying per call.
frontend_refused=0
if [ -n "$frontend_digest" ] && clearance_member_refused "$root" "$frontend_digest" code-audit-frontend; then
  frontend_refused=1
fi
refusal_note=""
if [ "$frontend_refused" -eq 1 ]; then
  refusal_note="
A live refusal exists for this exact content: $(clearance_refused_path "$root" "$frontend_digest" code-audit-frontend). A refusal always takes precedence over any earned marker for the same content, and a bare re-spawn does NOT clear it: an ordinary earned write leaves the refusal in place, so re-running the agent against unchanged, still-unaddressed content refuses again. Clear it by resolving the finding (a content change rotates the digest, retiring this refusal), or, when the operator acknowledges an Important with a stated reason and the content does not move, by re-spawning code-audit-frontend so it writes its earned marker with --supersede-refusal \"<reason>\", which removes its own refusal as an explicit, recorded act.
"
fi

# Human-readable state of a local marker file for a deny message. The gate now
# accepts only a writer-produced clearance, so a file that exists but is not
# writer-shaped is neither "cleared" nor "missing": name that third state so an
# operator staring at a present marker while the gate says "missing" is not
# left guessing.
marker_state() {
  if [ -f "$1" ]; then
    printf '(present but not a valid clearance; re-run the member'\''s agent)'
  else
    printf '(missing)'
  fi
}

# --- code-audit-frontend clearance signals -----------------------------------
#
# Each check is a self-contained function so frontend_cleared() below can
# reuse it from both the legacy gate and the member-aware gate.

# The C3 shared trailer regex (POSIX ERE): version, 64-hex frontend digest,
# 40-hex tree, in that order after the colon. $1=version, $2=digest, $3=tree.
GAIA_AUDIT_TRAILER_RE='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{64})[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# _gate_current_version -> the trimmed .gaia/VERSION literal on stdout, or
# empty. Shared by check_trailer and check_github_status: both compare a
# stamped version field against the same literal.
_gate_current_version() {
  gaia_read_version ".gaia/VERSION"
}

# Trailer fallback: accept a GAIA-Audit trailer on HEAD when its version and
# frontend-digest fields both match. The trailer format (per
# audit-stamp-trailer.sh) is "GAIA-Audit: <version> <frontend-digest> <tree>",
# parsed via the C3 shared regex above; the tree field is data only and is
# never compared. Sets $trailer_status for the deny reason regardless of
# outcome.
check_trailer() {
  trailer_line=$(git log -1 --format='%B' HEAD 2>/dev/null \
    | git interpret-trailers --parse 2>/dev/null \
    | grep -E '^GAIA-Audit:' \
    | head -1)
  trailer_status="missing"
  if [ -n "$trailer_line" ]; then
    if [[ "$trailer_line" =~ $GAIA_AUDIT_TRAILER_RE ]]; then
      trailer_version="${BASH_REMATCH[1]}"
      trailer_digest="${BASH_REMATCH[2]}"
      cur_version="$(_gate_current_version)"
      if [ -n "$cur_version" ] && [ "$trailer_version" = "$cur_version" ] \
         && [ -n "$frontend_digest" ] && [ "$trailer_digest" = "$frontend_digest" ]; then
        return 0
      fi
      trailer_status="present but version/digest mismatch (audit was for different content)"
    else
      trailer_status="present but does not match the GAIA-Audit trailer format (version, 64-hex frontend digest, 40-hex tree)"
    fi
  fi
  return 1
}

# GitHub commit status fallback: CI stamps a GAIA-Audit commit status instead
# of pushing an empty marker commit (pushing it would re-trigger CI and leave
# the PR HEAD without check runs). Query the API for a matching status on HEAD.
# The status must be state: success; its description shape is
# "<version> <frontend-digest> <tree>" (C3), and version + digest must both
# match (the tree field is data only, never compared). A non-success status
# (e.g. a local-mode stand-down's pending status) is filtered out at the
# source, so a pending status carrying HEAD's version+digest is not treated as
# cleared. Falls through silently on any error (no gh, no token, no
# GITHUB_REPOSITORY, API failure), the deny path below fires as normal.
check_github_status() {
  command -v gh >/dev/null 2>&1 || return 1

  # Derive repo slug. GITHUB_REPOSITORY is set inside Actions; derive from
  # the current directory's git remote for local runs via `gh repo view`
  # (avoids BSD-vs-GNU sed portability issues with lazy quantifiers).
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$repo" ] || return 1
    case "$repo" in
      */*) ;;  # must contain exactly one slash (owner/name)
      *) return 1 ;;
    esac
  fi

  # Read .gaia/VERSION (same "no stamp without VERSION" invariant as CI).
  cur_version="$(_gate_current_version)"
  [ -n "$cur_version" ] || return 1

  [ -n "$frontend_digest" ] || return 1

  status_desc=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | select(.state == "success") | .description' \
    2>/dev/null || true)

  [ -n "$status_desc" ] && [ "$status_desc" != "null" ] || return 1

  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_digest=$(printf '%s' "$status_desc" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_digest" ] || return 1
  [ "$status_version" = "$cur_version" ] || return 1
  [ "$status_digest" = "$frontend_digest" ] || return 1

  return 0
}

# resolve_pr_record: read this pull request's record once into
# $pr_record_title, $pr_record_base, $pr_record_head and $pr_record_number.
# Memoized on $pr_record_read, which is what distinguishes "not read yet" from
# "read, and the answer was nothing".
#
# One read rather than one per field. Both consumers below sit on the same
# uncleared path, and `gh` carries no request timeout of its own, so a second
# round-trip is a second OS-length stall on a blackholed network. Every failure
# (no gh, no auth, no PR for this branch, network error) leaves all four fields
# empty and each consumer takes its own no-answer path.
#
# All five variables are initialized HERE, at parent level, and that placement
# is load-bearing rather than cosmetic. This script runs under `set -uo
# pipefail`, and this function returns early before reaching any jq assignment
# on its two most common paths: no `gh` on PATH, and a `gh` that answers with
# nothing. A reader that dereferences $pr_record_head after either of those
# returns would trip `set -u` and kill the hook outright, so the gate would emit
# no JSON at all exactly where it owes a deny. Initializing inside the function
# body would not fix that; the early returns sit above it.
pr_record_read=""
pr_record_title=""
pr_record_base=""
pr_record_head=""
pr_record_number=""
resolve_pr_record() {
  [ -z "$pr_record_read" ] || return 0
  pr_record_read=yes

  command -v gh >/dev/null 2>&1 || return 0
  pr_record=$(gh pr view --json title,baseRefName,headRefOid,number 2>/dev/null || true)
  [ -n "$pr_record" ] || return 0

  # `// ""` so a JSON null reaches the callers as the same empty string an
  # absent record does; both are "no answer" and neither is a branch name nor a
  # commit sha. A record carrying no head sha (an older stub, a trimmed
  # response) therefore reads as no answer, which FAILS the record-bound
  # conjunction below rather than passing it by default.
  pr_record_title=$(printf '%s' "$pr_record" | jq -r '.title // ""' 2>/dev/null || true)
  pr_record_base=$(printf '%s' "$pr_record" | jq -r '.baseRefName // ""' 2>/dev/null || true)
  pr_record_head=$(printf '%s' "$pr_record" | jq -r '.headRefOid // ""' 2>/dev/null || true)
  pr_record_number=$(printf '%s' "$pr_record" | jq -r '.number // ""' 2>/dev/null || true)
}

# chore(deps) bypass: PRs whose title matches `^chore\(deps(-dev)?\):` are
# pre-verified by the /update-deps wrapper's local quality gate (typecheck +
# lint + vitest + playwright + build), so the audit-marker requirement is
# waived for this PR class. The predicate itself lives in one place,
# .gaia/scripts/chore-deps-skip.sh, shared with the CI workflows
# (code-review-audit.yml, tests.yml, chromatic.yml).
#
# The title comes from the shared PR-record read above. On any failure (no gh,
# no auth, no PR for the current branch, network error, or an unresolved repo
# root) the bypass does not fire and the normal deny path runs, the bypass is
# opt-in proof, not a fallback.
check_chore_deps_pr() {
  resolve_pr_record
  [ -n "$pr_record_title" ] || return 1
  # Bind the bypass to the pull request the COMMAND names. The title above came
  # from `gh pr view` with no number, so on its own it proves a property of the
  # CURRENT BRANCH's pull request while the merge being gated names one this
  # function never parsed: from a checkout sitting on a dep-bump branch, a merge
  # naming an arbitrary unaudited number cleared with no marker at all
  # (gaia-react/gaia#1540). A command carrying no positional still permits,
  # since that is gh's current-branch default and therefore the very pull
  # request the title was read for, which is what leaves the turnkey
  # `gh pr merge --squash` dep-bump path unaffected.
  gate_cmd_names_the_record_pr || return 1
  # tree_root, not root: the predicate is executable code, so it comes from the
  # ACTING tree that carries it. root is the main checkout, which from a linked
  # worktree is a different branch entirely and need not have the script at all.
  [ -n "$tree_root" ] || return 1
  [ "$(bash "$tree_root/.gaia/scripts/chore-deps-skip.sh" "$pr_record_title")" = "true" ]
}

# gate_resolve_base: resolve, ONCE per run, the diff base that scopes this pull
# request's own changes, together with the provenance that says how much that
# base deserves to be trusted. Both bypasses below read $gate_trust,
# $gate_anchor and $gate_base and nothing else, so the two cannot drift.
#
# The resolution itself lives in the shared library
# (.claude/hooks/lib/audit-base-provenance.sh), the one place tree-wide that
# walks the supplied/record/default-branch ladder and the one definition of
# whether an empty range at a given trust level is decisive. This gate owns no
# copy of either, which is what keeps it from reaching a verdict the audit spawn
# oracle would contradict about the same base.
#
# Every git call runs against $tree_root, the ACTING tree resolved from cwd
# above. The derivation this replaced used a bare cwd-relative `git`; anchoring
# it makes explicit what was implicit, and matches the anchoring the member
# dispatch block below already uses.
#
# The supplied-base argument is ALWAYS the empty string, deliberately. No
# gate-side consumer accepts a base override and none may gain one: a
# caller-chosen base is a caller-chosen diff, and a fail-closed check whose diff
# the caller picks is not fail-closed. Do not add one here for symmetry with the
# spawn oracle, which is a dispatch-side consumer answering a different question.
#
# The answer comes from the pull request record, never from the environment. An
# exported base-ref variable would let a caller shrink a fail-closed check's
# diff until every remaining path looked out of scope; a PR's base ref is the
# branch it actually merges into, so scoping to it concedes nothing that merging
# the PR would not already concede. The shared resolver reads no environment
# variable naming a base branch on any path, so that refusal survives the move
# into it intact.
#
# Both checks below scope their diff to a merge base, and the branch that merge
# base is taken against decides what "this PR changes" means. The remote's
# advertised default is that branch only when the PR targets it: a PR stacked on
# another branch merges into THAT branch, and diffing against the default hands
# the check the base branch's own history instead, denying a bypass the PR had
# earned (gaia-react/gaia#1057).
#
# When the record's remote-tracking ref does not verify (no gh, no auth, no PR
# for this branch, network error, a base branch this checkout has never
# fetched), the resolver falls through to the advertised default and reports
# anchor `default-branch`. That is usually the wider diff but not always: a
# backport forked from current main and targeting an older maintenance branch
# merge-bases NEARER to HEAD against main than against its own base. It is the
# safe direction regardless, for a reason that does not rest on the geometry.
# Whatever the narrower answer drops sits on commits already merged to the
# default branch, which is where they were already audited.
#
# That fall-through describes the ref-does-not-verify case ONLY. A record ref
# that verifies but whose merge-base fails (unrelated histories, a shallow HEAD)
# does not fall through at all: the resolver answers `unresolvable` with an
# empty base, the guards below fire, and the gate denies. That is exactly the
# answer the derivation this replaced gave, and falling through there would hand
# this gate a resolved, wider base on a path where it previously refused
# outright.
#
# The memo is parent-level, and calling this function DIRECTLY (never inside a
# `$( )`) is what keeps it that way. The per-subshell memo it replaced existed
# only because both bypasses reached the base through a command substitution,
# which also made its two variables a coupled pair whose half-set state was the
# one combination that derivation existed to forbid. Both bypasses are invoked
# from the parent shell, so a direct call retires that hazard.
#
# Resolution stays LAZY: this reaches the network through resolve_pr_record, and
# a run whose every marker is already on disk decides the whole gate from local
# files. Call it only from inside the two bypasses and the legacy deny reason,
# never at the top level of this script.
gate_prov_read=""
gate_trust=""
gate_anchor=""
gate_base=""
gate_resolve_base() {
  [ -z "$gate_prov_read" ] || return 0
  gate_prov_read=yes

  resolve_pr_record

  local prov
  prov="$(audit_resolve_base_provenance "$tree_root" pr-record "" "$pr_record_base")" || prov=""
  # An empty $prov leaves all three fields empty, which every guard below reads
  # as unresolvable and fails closed on.
  IFS=$'\t' read -r gate_trust gate_anchor gate_base <<< "$prov" || true
}

# gate_cmd_names_the_record_pr: is the pull request the gated `gh pr merge`
# names the same one whose record the conjuncts around this were checked
# against? The record comes from `gh pr view` with no number, which describes
# the CURRENT BRANCH's pull request, so without this the record conjuncts prove
# only "this checkout is on a pull request", never "on the one being merged".
#
# Everything this reads about the command comes from the shared scanner in
# repo-scope.sh, never from a parser written here, and that is the whole design
# rather than a convenience. Two hand-rolled readings were tried and both were
# wrong in the permitting direction. Skipping options by their leading `-`
# alone reads a value-taking flag's SEPARATED value as the positional, so
# `gh pr merge --body <record-number> <other-number>` compared equal to the
# record and permitted a merge of <other-number>; `gh pr merge` has six such
# flags. Counting occurrences of the literal `gh pr merge` phrase to prove no
# second merge rides along missed every spelling that breaks the literal run of
# characters, `gh pr "merge" <n>` and a line continuation inside the verb among
# them. Both were demonstrated against this hook rather than argued.
#
# The scanner tokenizes the way the shell does, so it answers two of the three
# questions exactly: which reference the merge names, and whether a separator
# or a comment put another command beside it. The third, whether an EXPANSION
# smuggled one in, is not a question about words, so no word-level tokenizer
# answers it; this function rules it out lexically instead, by admitting only
# the characters a merge invocation needs and denying every other byte. Every
# abstention denies.
gate_cmd_names_the_record_pr() {
  # The scanner is normally already loaded, from the repo-scope source near the
  # top of this hook. That source is cwd-relative, so it can miss from a
  # non-root cwd; reload from this hook's OWN on-disk location and deny if the
  # scanner still cannot be had. A relaxation that cannot read the command it
  # is relaxing has nothing to relax on.
  if ! type gaia_scan_gh_merge >/dev/null 2>&1; then
    [ -n "$_lib_dir" ] && [ -f "$_lib_dir/repo-scope.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$_lib_dir/repo-scope.sh" || return 1
    type gaia_scan_gh_merge >/dev/null 2>&1 || return 1
  fi

  # Abstains unless the tool call's FIRST command is the merge and every flag
  # on it is a shape the scanner models.
  gaia_scan_gh_merge "$cmd" || return 1

  # And no SEPARATOR puts a second command beside it. The scanner sets this
  # while reading the same command the call above just read, so it is that
  # read's own answer rather than a second pass: 0 means no separator and no
  # comment closed the merge.
  #
  # The allowlist above subsumes this today, since every separator character is
  # outside its set, which means no mutation of this line alone can red a test
  # while that arm stands. It is kept anyway, and the reason is stated rather
  # than left to be rediscovered: the two conjuncts answer different questions,
  # one lexical and one structural, and a future widening of the character set
  # (to admit a quoted subject, say) must not silently take the separator
  # guarantee with it.
  [ "$GAIA_FIRST_COMMAND_CLOSED" -eq 0 ] || return 1

  # And no EXPANSION runs one either. That question is not about words, so the
  # flag above does not answer it: a substitution is ordinary word text to a
  # tokenizer that models words, which reaches the end of the string having
  # found no separator while the shell runs the payload first, before the
  # permitted merge.
  #
  # This is an ALLOWLIST rather than a list of substitution spellings, and the
  # difference is the whole point. Two attempts to name the dangerous spellings
  # were both incomplete, and the second was incomplete in a way nobody could
  # have enumerated their way out of: which text makes a shell run a command is
  # a property of the shell running this tool call and of its version, not of
  # any fixed set of sequences. zsh, this platform's default, has `=(...)`;
  # bash gained `${ ...; }` in 5.3; the next release adds whatever it adds. So
  # the character set below is what a pull-request reference, a flag and a
  # branch or URL need, and every other byte denies, including `$`, a backtick,
  # every bracket, both quotes, and every separator. It cannot be outrun by a
  # spelling nobody has thought of, because it never asks what the spelling
  # means.
  #
  # Blunt in the deny direction only: a merge carrying a quoted subject denies
  # and costs a marker requirement, which is this arm's whole downside.
  case "$cmd" in
    *[!A-Za-z0-9_\ /.,:@=+-]*) return 1 ;;
  esac

  # No positional at all: the command targets the current branch, which is the
  # branch the record was read for, so the record conjuncts already bind it.
  [ -n "$GAIA_GH_MERGE_REF" ] || return 0
  # A bare number is the only spelling this gate can confirm without a second
  # network read. A branch name or a URL denies rather than resolve one: this
  # arm is a relaxation, so an unconfirmable target must not clear it.
  case "$GAIA_GH_MERGE_REF" in
    *[!0-9]*) return 1 ;;
  esac
  [ -n "$pr_record_number" ] || return 1
  [ "$GAIA_GH_MERGE_REF" = "$pr_record_number" ]
}

# gate_empty_is_decisive: may an EMPTY base-to-HEAD range clear this gate on its
# own? Five conjuncts, and the last four are why this is a named predicate
# rather than a bare call to the shared trust check.
#
# The trust conjunct is the shared library's, never a local copy: an empty range
# means "nothing left to audit" only when the base it was taken against is one
# this checkout could not have invented.
#
# The other four bind the relaxation to the pull-request record AND to the
# command being gated. This gate scopes its range to LOCAL HEAD, so without
# them a checkout sitting on a synced default branch, where `merge-base HEAD
# refs/remotes/origin/<default>` IS HEAD so the range holds zero files on remote
# provenance, would clear `gh pr merge <N>` for an arbitrary, entirely unaudited
# pull request. Requiring a `pr-record` anchor means the base was actually taken
# against the pull request's own recorded base branch; requiring HEAD to equal
# the record's head sha means this checkout is on the pull request the RECORD
# describes; and requiring the command's own reference to match the record's
# number means that pull request is the one being merged. On a synced default
# branch there is no pull request for the current branch, the record is empty,
# the anchor is `default-branch`, and this returns 1.
#
# The last conjunct reads the command through the shared scanner and denies on
# every abstention, so what it proves is bounded to the shapes that scanner
# reads exactly: the merge is the first command in the tool call, it carries no
# flag shape the scanner declines to model, no separator or comment puts a
# second command beside it, and every byte of it is in the small set a merge
# invocation needs, so no expansion of any spelling can run a second command.
# Anything else denies rather than being read approximately.
#
# The command-binding conjunct is NOT scoped to this arm. Every other arm that
# can clear a merge on a current-branch record asks the same question, each at
# its own site: the chore(deps) and self-modification bypasses above, and the
# non-empty arm of this function's own caller. Keep it that way when adding an
# arm. A predicate proving something about the checkout says nothing about the
# pull request a command names, and the four arms reach that record by three
# different routes, so there is no one chokepoint to put the question behind.
gate_empty_is_decisive() {
  audit_provenance_empty_is_decisive "$gate_trust" || return 1
  [ "$gate_anchor" = "pr-record" ] || return 1
  [ -n "$pr_record_head" ] || return 1
  [ "$pr_record_head" = "$sha" ] || return 1
  gate_cmd_names_the_record_pr || return 1
  return 0
}

# Out-of-scope bypass: accept the merge when every file this PR changes lives
# on a surface outside audit scope. The agent has no rules that apply to wiki,
# instruction files, .gaia metadata, or prose, so there is nothing to audit and
# no marker is required, the same determination code-review-audit.yml's
# `has_source` check makes when it skips. The allowlist itself lives in the
# shared classifier (audit_out_of_scope_allowlisted), the ONE place this
# literal set is defined.
# Legacy-gate only: FC-4's auditable-base mirrors this check's complement, so
# any in-scope path here also dispatches a member, a non-empty dispatched set
# never reaches this function.
#
# Strict allowlist, evaluated fail-closed: the diff base must resolve, the diff
# must be non-empty OR its emptiness must be decisive under
# gate_empty_is_decisive above, and EVERY path must be out of scope. Any
# unresolved base, diff error, or in-scope path (app/, test/, configs,
# .github/workflows/) falls through to the normal deny. A PR that touches
# auditable source therefore can never reach this bypass, it cannot mask an
# audit that withheld its marker over unresolved findings, since that PR's diff
# carries in-scope paths by definition; and a decisive empty range says the
# merge introduces no content into its base at all, so there is nothing for a
# withheld marker to have been withheld over. No dependence on a CI stamp; the
# one network read is the base branch behind gate_resolve_base() above, whose
# failure widens the diff.
check_out_of_scope_pr() {
  # The merge base scopes the diff to THIS PR's changes, not unrelated drift
  # already on the base branch.
  gate_resolve_base
  [ -n "$gate_base" ] || return 1

  # Newline-delimited, derived NUL-delimited so git's default core.quotePath
  # cannot C-quote a non-ASCII path into a form the classifier below reads as an
  # unrecognized string. A non-zero return is a diff that never ran, which is
  # never an empty change set, so it denies here rather than reaching the
  # emptiness arm below.
  changed="$(audit_provenance_changed_files "$tree_root" "$gate_base")" || return 1

  if [ -z "$changed" ]; then
    # A REAL empty change set. Whether it clears this gate is the record-bound
    # question above, not this function's to answer: a locally-derived base, an
    # unresolvable one, or a checkout that is not on the pull request being
    # merged all deny here.
    gate_empty_is_decisive || return 1
    # The permit itself stays a silent zero exit with empty stdout, the shape
    # every other permit in this hook has. The reason is a diagnostic line on
    # stderr, not a permissionDecision emission: an explicit allow would
    # short-circuit the permission system for every `gh pr merge` this gate
    # sees, which is a far larger concession than the one being made here.
    echo "PR merge gate: no Code Audit Team marker required for HEAD ${sha:0:12}: the base-to-HEAD range is empty and the base carries ${gate_trust} provenance (anchor ${gate_anchor}, base ${gate_base:0:12})." >&2
    return 0
  fi

  # First path the shared classifier does not allowlist makes the marker
  # mandatory.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    audit_out_of_scope_allowlisted "$path" || return 1
  done <<< "$changed"

  # Bind to the pull request the COMMAND names, for the reason the chore(deps)
  # bypass above gives: every path checked so far belongs to the CURRENT
  # BRANCH's change set, which need not be the change set of the pull request
  # being merged. Placed here rather than at the top of this function on
  # purpose: the empty-change-set arm above routes through
  # gate_empty_is_decisive, which owns a strictly larger conjunct set including
  # this one, so hoisting would duplicate that call and blur which arm answers
  # for which conjuncts.
  gate_cmd_names_the_record_pr || return 1

  return 0
}

# Self-mod-only GAIA-update bypass: accept the merge when the ONLY in-scope path
# the PR changes is .github/workflows/code-review-audit.yml AND its committed
# bytes are a verbatim re-render of the bundled template
# (.gaia/cli/templates/workflows/code-review-audit.yml.tmpl), with every other
# changed path out of audit scope. This is the self-mod-only case /update-gaia
# Step 12 produces: it refreshes a stale installed audit workflow by copying the
# release template verbatim, which makes the update PR self-modifying.
# claude-code-action's workflow-validation guardrail then refuses to run CI's
# audit (no GAIA-Audit stamp can land), and the out-of-scope bypass above denies
# because .github/workflows/ is in scope, so without this signal the operator is
# forced into a ceremonial local re-audit of bytes that are GAIA's own template,
# not adopter code. The one in-scope path also sits in the auditable-base set,
# so this signal is reachable from the member-aware gate too (dispatched set
# {code-audit-frontend} alone).
#
# Stricter than check_out_of_scope_pr: exactly ONE in-scope path, it must be the
# audit workflow, and git-blob identity must prove its bytes equal the template.
# Fail-closed: any other in-scope path (app/, test/, a config, a second
# workflow), an absent template, or a single non-matching byte returns 1 and
# falls through to the normal deny. A malicious PR cannot smuggle code here, an
# app/test/config path is in scope and unrecognized, so the loop returns 1 on
# first sight. No CI stamp; the merge base comes from gate_resolve_base() above,
# on the same terms as the sibling bypass.
check_self_mod_only_update_pr() {
  audit_wf=".github/workflows/code-review-audit.yml"
  audit_tmpl=".gaia/cli/templates/workflows/code-review-audit.yml.tmpl"

  # Bind to the pull request the COMMAND names, for the reason the chore(deps)
  # bypass above gives. This arm earns the conjunct more than that one rather
  # than less: it is reachable from the member-aware gate, where
  # self_mod_only_pr() clears EVERY dispatched member at once, so a merge it
  # wrongly answers for is a merge nobody audited on any axis.
  resolve_pr_record
  gate_cmd_names_the_record_pr || return 1

  gate_resolve_base
  [ -n "$gate_base" ] || return 1

  # Newline-delimited, derived NUL-delimited for the reason the sibling
  # derivation above gives: a C-quoted path is an unrecognized string to the
  # classifier. A non-zero return is a diff that never ran.
  changed="$(audit_provenance_changed_files "$tree_root" "$gate_base")" || return 1
  # Deliberately NOT relaxed, unlike the sibling bypass. That one is reached
  # only once the dispatched member set is already empty, so treating a decisive
  # empty range as clearance there stays contained. This one is reachable from
  # the member-aware gate, where self_mod_only_pr() below clears EVERY
  # dispatched member at once, and it would do so across mismatched anchors:
  # the member set comes from a default-branch-anchored derivation while this
  # range is record-anchored. An empty range must never fire this bypass.
  [ -n "$changed" ] || return 1

  # Classify every changed path via the shared ORDERED THREE-WAY classifier
  # (audit_self_mod_classify): out-of-scope surfaces are always fine; the ONE
  # permitted in-scope path is the audit workflow itself; any other in-scope
  # path (app/, test/, configs, a different workflow) denies immediately.
  seen_audit_wf=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    class="$(audit_self_mod_classify "$path")"
    case "$class" in
      out-of-scope) continue ;;
      audit-workflow) seen_audit_wf=1 ;;
      *) return 1 ;;
    esac
  done <<< "$changed"

  # The audit workflow must actually be the in-scope change (otherwise this is a
  # pure out-of-scope PR the earlier bypass already cleared) AND its committed
  # bytes must be a verbatim copy of the bundled template. Git stores blobs by
  # content hash, so equal blob SHAs mean byte-identical files. Comparing HEAD's
  # blobs (not the working tree) keeps the check fail-closed against local dirt;
  # a missing file makes rev-parse fail and the merge denies.
  [ "$seen_audit_wf" -eq 1 ] || return 1
  wf_blob=$(git rev-parse "HEAD:${audit_wf}" 2>/dev/null) || return 1
  tmpl_blob=$(git rev-parse "HEAD:${audit_tmpl}" 2>/dev/null) || return 1
  [ "$wf_blob" = "$tmpl_blob" ] || return 1

  return 0
}

# code-audit-frontend clearance: a live refusal for the current digest is
# checked first and is absolute (C6); otherwise any one of the five member
# signals above (marker, trailer, CI status, chore(deps), self-mod-only).
# Reused by both the legacy gate and the member-aware gate below.
frontend_cleared() {
  [ "$frontend_refused" -eq 1 ] && return 1
  clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend && return 0
  check_trailer && return 0
  check_github_status && return 0
  check_chore_deps_pr && return 0
  check_self_mod_only_update_pr && return 0
  return 1
}

# _gate_frontend_disposition_denial: when code-audit-frontend's OWN earned
# digest marker is valid (regardless of whether a trailer/status/bypass signal
# is what ultimately clears the merge), re-verify its disposition sidecar.
# Seed-forward unions a still-open receipt across a digest rotation without
# re-verifying it against the backend, so this hook is the deterministic
# backstop: a filed key whose issue no longer exists, a pending(definitive)
# entry, or a machinery_waived entry recorded against a path that is neither
# gate machinery nor a file this pull request changes, denies. Fail closed
# when the marker is valid but its sidecar is absent (a valid marker proves
# nothing about dispositions with no sidecar to read). Prints the deny JSON
# and returns 1 on denial; returns 0 (silent) when there is nothing to deny.
_gate_frontend_disposition_denial() {
  clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend || return 0

  local sidecar reason offenders offender_list notes note_block
  sidecar="$root/.gaia/local/audit/${frontend_digest}.dispositions.json"

  if [ ! -f "$sidecar" ]; then
    reason="PR merge gate: code-audit-frontend's clearance marker is valid for HEAD ${sha:0:12}, but its disposition sidecar (${sidecar}) is absent.

A valid earned marker with no matching sidecar cannot prove its out-of-scope
findings were dispositioned, so this denies rather than assume none exist.
Re-spawn the code-audit-frontend agent on this HEAD so it re-files its
disposition sidecar, then retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."
    jq -n --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
    return 1
  fi

  command -v disposition_offenders >/dev/null 2>&1 || return 0
  offenders="$(disposition_offenders "$sidecar" "$tree_root" 2>/dev/null || true)"

  notes=""
  if command -v disposition_notes >/dev/null 2>&1; then
    notes="$(disposition_notes "$sidecar" "$tree_root" 2>/dev/null || true)"
  fi
  note_block=""
  if [ -n "$notes" ] && command -v disposition_note_block >/dev/null 2>&1; then
    note_block="$(disposition_note_block "$notes")"
  fi
  if [ -n "$note_block" ]; then
    printf '%s\n' "$note_block" >&2
  fi

  [ -n "$offenders" ] || return 0

  offender_list=$(printf '%s' "$offenders" | sed 's/^/  - /')
  reason="PR merge gate: code-audit-frontend's disposition sidecar names a finding that does not hold for HEAD ${sha:0:12}.

Offending finding key(s):

${offender_list}

A filed tech-debt issue named in the sidecar no longer exists, a
pending(definitive) entry remains, or a machinery-waived-not-eligible entry
names a path that is neither gate machinery nor a file this pull request
already changes.

To unblock a filed-but-missing or pending(definitive) offender, re-spawn the
code-audit-frontend agent on this HEAD so it re-files the missing disposition,
then retry gh pr merge.

To unblock a machinery-waived-not-eligible offender:
  1. If the pull request should still be changing that file and a plain revert
     commit dropped it from the diff, restore the change and retry. The
     eligibility set is the fork point against HEAD, and HEAD moves.
  2. Otherwise the finding is ordinary out-of-scope debt and takes its normal
     filing path: delete the stale entry from ${sidecar} (gitignored working
     state; no other file records it) and re-run the audit so it is filed as a
     tech-debt issue.
  3. Re-running the member with the entry in place reproduces the same waive
     and the same denial.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  if [ -n "$note_block" ]; then
    reason="${reason}

${note_block}"
  fi

  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  return 1
}

# --- Dispatch: resolve the Code Audit Team member set for this diff ---------
#
# Anchored on $tree_root, the ACTING tree: who must clear is a property of the
# content being merged. $root stays main-anchored, via gaia_resolve_main_root,
# for WHERE a clearance lives; the two roots answer different questions and
# neither substitutes for the other. Anchoring here never collapses that split,
# because it only pins the acting-tree half harder. Both the existence test and
# the invocation are anchored, since a cwd-relative path reports the resolver
# absent from any directory that is not the checkout root. The `cd` lives
# inside a command substitution, so it never persists into the rest of the hook
# chain (.claude/rules/shell-cwd.md).
#
# The exit status is captured separately from the output. Non-zero means the
# resolver could not answer, which is never "nothing owed": folding it into the
# empty-set branch below hands the legacy single-signal gate a diff whose
# dispatched members are unknown.
members=""
resolver_rc=0
if [ -x "${tree_root}/.gaia/scripts/resolve-audit-members.sh" ]; then
  members="$( cd "$tree_root" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null )" \
    || resolver_rc=$?
fi

if [ "$resolver_rc" -ne 0 ]; then
  reason="PR merge gate: the Code Audit Team member resolver cannot answer for HEAD ${sha:0:12}.

.gaia/scripts/resolve-audit-members.sh exited ${resolver_rc} for the tree at
${tree_root}, so which members this diff dispatches is unknown. An unanswerable
member query is not an empty member set, and this gate denies rather than fall
back to the single-signal path and clear a diff a required auditor may never
have read.

To unblock:
  1. Run \`bash .gaia/scripts/resolve-audit-members.sh\` from the tree above and
     read its stderr; it names what it could not resolve.
  2. Fix what it names (an unreadable or non-checkout root, a broken git).
  3. Retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'

  exit 0
fi

if [ -z "$members" ]; then
  # Zero-match (entire diff out of scope) OR the resolver script is
  # absent/unusable: fall through to the legacy single-signal gate verbatim.
  # NOT an unconditional allow, FC-4's auditable-base is strictly narrower
  # than check_out_of_scope_pr's denylist, so an ownerless-but-in-scope file
  # (root Makefile, public/**, ...) still denies here without a marker.
  if frontend_cleared; then
    _gate_frontend_disposition_denial
    exit 0
  fi

  if check_out_of_scope_pr; then
    exit 0
  fi

  # check_out_of_scope_pr above already populated the memo on every path that
  # reaches here; call it again anyway so the signal list below can never report
  # an empty provenance for a structural reason rather than a real one. The memo
  # makes the second call free.
  gate_resolve_base
  base_display="unresolved"
  [ -z "$gate_base" ] || base_display="${gate_base:0:12}"

  reason="PR merge gate: no code-audit-frontend signal for HEAD ${sha:0:12}.
${refusal_note}
None of the accepted signals is present:
  - Local marker:    ${marker} $(marker_state "$marker")
  - Commit trailer:  ${trailer_status:-missing}
  - GitHub CI status: absent or version/digest mismatch
  - chore(deps) PR:  PR title does not match \`chore(deps):\` or \`chore(deps-dev):\`
  - Out-of-scope:    PR changes at least one in-scope path (app/, test/, configs,
                     .github/workflows/), not a wiki/docs/.gaia-config-only diff
  - Diff base:       ${gate_trust:-unresolvable} provenance (anchor ${gate_anchor:-default-branch}, base ${base_display}); an empty
                     base-to-HEAD range clears this gate only on remote or supplied
                     provenance, with a pr-record anchor and HEAD at the pull
                     request's recorded head sha
  - Self-mod-only:   in-scope change is not a verbatim re-render of the bundled
                     code-review-audit.yml template (adopter edit, extra in-scope
                     path, or missing template)

To unblock:
  1. Spawn the code-audit-frontend agent locally, OR push to the PR branch
     and wait for CI's audit to stamp the GitHub commit status (CI skips
     when the audit workflow on this head differs from the copy on the
     default branch, whether this PR edited it or its base did, in that
     case only the local audit will satisfy the gate).
  2. Address any Critical/Important findings; commit and push.
  3. Re-spawn the agent on the new HEAD; let it write the marker.
  4. Retry gh pr merge.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: gh pr view <N> --json state, do NOT retry
the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  # --arg safely escapes $reason; never interpolate dynamic values directly into
  # the JSON template string.
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'

  exit 0
fi

# --- AND-aggregator: require every dispatched member's clearance ------------
#
# A non-empty dispatched set means at least one changed file is owned by a
# Code Audit Team member (FC-2). Every dispatched member must clear:
# code-audit-frontend via frontend_cleared() above, each specialized member
# <m> via its own marker .gaia/local/audit/<digest>.<m>.ok, keyed to that
# member's OWN content digest. A live refusal for a member's current digest is
# checked before its earned marker and is absolute (C6).

all_cleared=1
report=""

# The self-mod-only bypass proves a property of the PR, not of one member: the
# only in-scope changed path is the audit workflow, and its committed bytes are
# a verbatim copy of the bundled template. Any member dispatched under that
# condition is therefore dispatched for that one pinned artifact alone, and a
# reviewer reading it decides nothing a script has not already decided. Resolve
# it once here rather than per member: the predicate is a repo-wide read, and
# every member's answer to it is the same.
#
# Resolved on first need rather than up front, because the predicate reaches
# gate_resolve_base() and therefore the network, while a run whose every marker is
# already on disk decides the whole gate from local files. Answering a question
# that can only matter to an UNCLEARED member would put a `gh` round-trip, with
# no timeout of its own, in front of a merge this gate would otherwise allow
# instantly, and a blackholed network turns that into an OS-length stall.
# Deferring changes no verdict: every call site below reaches it only after
# that member's own clearance has already come up empty.
self_mod_only=-1
self_mod_only_pr() {
  if [ "$self_mod_only" -eq -1 ]; then
    self_mod_only=0
    check_self_mod_only_update_pr && self_mod_only=1
  fi
  [ "$self_mod_only" -eq 1 ]
}

while IFS= read -r m; do
  [ -n "$m" ] || continue

  member_cleared=0
  if [ "$m" = "code-audit-frontend" ]; then
    m_digest="$frontend_digest"
    m_refused="$frontend_refused"
    frontend_cleared && member_cleared=1
  else
    m_digest="$(member_digest "$m")" || m_digest=""
    m_refused=0
    if [ -n "$m_digest" ] && clearance_member_refused "$root" "$m_digest" "$m"; then
      m_refused=1
    fi
    if [ "$m_refused" -eq 0 ] && [ -n "$m_digest" ]; then
      clearance_member_cleared "$root" "$m_digest" "$m" && member_cleared=1
    fi
    # A live refusal stays absolute (C6): a member that refused this digest is
    # never cleared by the bypass.
    if [ "$m_refused" -eq 0 ] && [ "$member_cleared" -eq 0 ] && self_mod_only_pr; then
      member_cleared=1
    fi
  fi

  if [ "$member_cleared" -eq 1 ]; then
    report="${report}  - ${m}: CLEARED
"
  else
    all_cleared=0
    if [ "$m_refused" -eq 1 ]; then
      refused_path="$(clearance_refused_path "$root" "$m_digest" "$m")"
      report="${report}  - ${m}: REFUSED (a live refusal exists for this exact content at ${refused_path}; a bare re-spawn does not clear it, the member must supersede it, see below)
"
    elif [ "$m" = "code-audit-frontend" ]; then
      report="${report}  - code-audit-frontend: PENDING
      Local marker:    ${marker} $(marker_state "$marker")
      Commit trailer:  ${trailer_status:-missing}
      GitHub CI status: absent or version/digest mismatch
      chore(deps) PR:  PR title does not match \`chore(deps):\` or \`chore(deps-dev):\`
"
    else
      member_marker="$root/.gaia/local/audit/${m_digest:-<unavailable>}.${m}.ok"
      report="${report}  - ${m}: PENDING (marker ${member_marker} $(marker_state "$member_marker"))
"
    fi
  fi
done <<< "$members"

if [ "$all_cleared" -eq 1 ]; then
  _gate_frontend_disposition_denial
  exit 0
fi

reason="PR merge gate: not every dispatched Code Audit Team member has cleared HEAD ${sha:0:12} (tree ${tree:0:12}).

${report}
To unblock: spawn each PENDING member's agent on HEAD so it writes its marker
(code-audit-frontend writes ${root}/.gaia/local/audit/${frontend_digest}.ok; each
specialized member writes ${root}/.gaia/local/audit/<its-own-digest>.<member>.ok, NOT
the frontend digest), then retry gh pr merge. Markers are keyed to each
member's own content digest (the files it owns plus the shared gate
machinery), so an out-of-glob change never invalidates one, and a GAIA-Audit
trailer stamp (an empty commit) never invalidates any either.

A REFUSED member is not a PENDING one: its refusal outranks any earned marker
for the same content, and an ordinary re-spawn does not clear it (a plain
earned write leaves the refusal on disk). Resolve the finding, which rotates
that member's digest and retires the refusal with it; or, when the operator
acknowledges an Important with a stated reason and the content does not move,
re-spawn the member so it writes its earned marker with
--supersede-refusal \"<reason>\", removing its own refusal as an explicit,
recorded act.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: gh pr view <N> --json state, do NOT retry
the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'

exit 0
