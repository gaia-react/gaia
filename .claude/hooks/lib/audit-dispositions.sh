#!/usr/bin/env bash
# audit-dispositions.sh: the shared disposition-ledger logic for the Code Audit
# Team. Sourced, never executed; does no work at source time.
#
# The disposition-ledger sidecar is keyed to the frontend member's content
# digest (<frontend-digest>.dispositions.json), valid iff the frontend earned
# marker for that digest is valid. Four functions:
#
#   disposition_offenders <sidecar> [<acting-root>]
#       Prints one offender line per unmet disposition on stdout; empty output
#       (and exit 0) means clean. FAIL-OPEN everywhere it cannot prove an
#       inconsistency: no sidecar, unparseable sidecar, backend "absent", or any
#       gh/tooling failure. Blocks ONLY on a confirmed present-backend
#       filed-but-missing key, a pending(definitive) entry, or a
#       `machinery_waived` entry whose key path is NEITHER a gate-machinery path
#       NOR a file the pull request under judgment already changes (the
#       abuse-check that keeps the machinery-waive disposition from becoming a
#       universal escape hatch). <acting-root> is the git tree whose whole-PR
#       diff supplies that changed-file set; omitted or empty, the changed-files
#       term contributes nothing and the gate-machinery term decides the arm
#       alone. Called by both the deterministic backstop hook
#       (.claude/hooks/audit-disposition-check.sh) and the merge gate
#       (.claude/hooks/pr-merge-audit-check.sh) to re-verify the current
#       sidecar's claims.
#
#   disposition_notes <sidecar> [<acting-root>]
#       Prints one operator-visible note line per `machinery_waived` entry whose
#       verdict is reached WITHOUT the changed-files term, so a gate can tell
#       "could not verify" from "verified clean". Takes the same arguments as
#       disposition_offenders and resolves the changed-file set through the same
#       helper, so there is one eligibility implementation rather than two. It
#       denies nothing itself; the gates decide what to do with the lines.
#
#   disposition_note_block <notes>
#       Renders disposition_notes' output as the block a gate writes to stderr
#       and appends to its deny reason. Both gates fire on the same
#       `gh pr merge` and describe the same conditions, so they render it from
#       here rather than each carrying a copy that can drift.
#
#   disposition_seed_forward <prev-sidecar> <new-sidecar>
#       Unions every still-open entry (`filed`, or `pending` with
#       `pending_reason` "definitive") from <prev-sidecar> into <new-sidecar>,
#       in place. A fresh incremental audit does not re-encounter a prior
#       out-of-scope finding, so a digest rotation alone would silently drop a
#       still-open receipt; the code-audit-frontend agent calls this when it
#       writes the sidecar for a new frontend digest, seeding it from the
#       immediately-prior frontend digest's sidecar so the receipt survives the
#       rotation. HEAD's fresh entry always wins on a key collision (a seeded
#       entry may only ADD keys). A plain still-open union: no anchor
#       selection, no ancestry, no backend precedence.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# --- eligibility helpers (private) -------------------------------------------
#
# The `machinery_waived` abuse-check asks two questions about the tree under
# judgment: which files the pull request changes, and whether the sidecar it is
# reading belongs to that pull request at all. Both answers are resolved once
# per call and shared by disposition_offenders and disposition_notes, so there
# is ONE eligibility implementation rather than two.

# _disposition_changed_set <acting-root> <outfile>
#
# Writes the whole-PR changed-file set for <acting-root> to <outfile>:
# NUL-delimited, repo-relative POSIX paths, UNFILTERED by file type. The waive
# rule is about any file the pull request touches, so a review-scope pathspec
# has no place here.
#
# The derivation is the three-level chain the default member's own definition
# carries, and the two agree line for line: the default branch from
# `refs/remotes/origin/HEAD` with a literal `main` fallback, FULL_BASE from
# `merge-base` of HEAD against `origin/<name>` then against `<name>`, then a
# three-dot `diff --name-only -z` against HEAD.
#
# Returns 0 when the base RESOLVED: the file's contents are the answer, and an
# empty file is a real, empty answer. Returns 1 when the base did NOT resolve,
# <acting-root> is empty, or <acting-root> is not a git tree -- an UNKNOWN,
# never an empty answer.
#
# The base is tested for emptiness BEFORE the diff runs, and the emptiness of
# the diff is never the discriminator: git resolves an empty left side to HEAD,
# so an unresolved base and a resolved base with no differences produce
# identical empty output while demanding opposite verdicts.
#
# `-z` disables git's path quoting, so a non-ASCII path arrives as raw UTF-8
# bytes that compare byte for byte against the key's `path=`. Accepted
# limitation, named once: a path containing a literal newline is indistinguishable
# from two paths once read, so it fails to match and the finding is filed, which
# is the safe direction.
_disposition_changed_set() {
  local root="$1" outfile="$2"
  local default_branch FULL_BASE

  [ -n "$root" ] || return 1
  [ -n "$outfile" ] || return 1
  [ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || return 1

  default_branch=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  [ -n "$default_branch" ] || default_branch="main"
  FULL_BASE=$(git -C "$root" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
    || git -C "$root" merge-base HEAD "${default_branch}" 2>/dev/null || true)
  [ -n "$FULL_BASE" ] || return 1

  git -C "$root" diff --name-only -z "${FULL_BASE}...HEAD" > "$outfile" 2>/dev/null || return 1
  return 0
}

# _disposition_set_contains <set-file> <path>
#
# Exit 0 iff <path> is an EXACT whole-string match for one of the NUL-delimited
# entries in <set-file>. Never a prefix, suffix, basename, or substring test,
# in either direction: `app/y.ts`, `app/x.tsx`, `x.ts`, `vendor/app/x.ts`, and
# the directory prefixes `app/x` and `app` all fail against a set holding
# `app/x.ts`. Command substitution strips NUL bytes, which is why the
# set travels as a file and is read with `read -d ''` rather than held in a
# variable.
_disposition_set_contains() {
  local set_file="$1" want="$2" _p

  [ -f "$set_file" ] || return 1
  while IFS= read -r -d '' _p; do
    if [ "$_p" = "$want" ]; then
      return 0
    fi
  done < "$set_file"
  return 1
}

# _disposition_attributable <sidecar> <acting-root>
#
# Exit 0 iff the sidecar is ATTRIBUTABLE to the tree under judgment, meaning its
# entries may be judged against that tree's diff. The sidecar is named by the
# default member's content digest, which does not rotate for a diff touching
# nothing that member owns and no machinery, so one file can be read while
# judging several consecutive pull requests; a changed-files verdict on another
# pull request's entry would be a false deny.
#
# The branch term runs first and is the only DECISIVE one:
#
#   0. `branch` recorded, the acting root resolves a branch of its own, and the
#      two differ                                      -> NOT attributable
#
# Everything else falls through to the sha chain:
#
#   1. `sha` absent, empty, or not 40 hex digits       -> attributable
#   2. `merge-base --is-ancestor <sha> HEAD` exits 0   -> attributable
#   3. it exits 1 (a REAL non-ancestor)                -> the orphan probe,
#      `for-each-ref --contains <sha> --count=1 refs/heads refs/remotes`:
#        non-empty (the commit lives on another live ref) -> NOT attributable
#        empty (orphaned)                                 -> attributable
#   4. any other status (128 on an unknown object, git unavailable, no acting
#      root), or a probe that errors                   -> attributable
#
# The exit statuses are discriminated explicitly because only 1 means "resolved,
# and not an ancestor". Reading mere non-zero collapses an unknown object into a
# real non-ancestor and sets aside entries that cannot be judged either way.
#
# The orphan probe separates another pull request's commit, reachable from that
# branch's ref, from this branch's own rewritten-away commit, reachable from
# none. Without it an amend, rebase, or force-push sets every entry aside, and a
# waive on a path that is neither machinery nor changed silently stops denying.
#
# WHY THE BRANCH TERM EXISTS: reachability cannot tell those two cases apart
# once the other pull request is squash-merged with `--delete-branch`. The
# squash writes a NEW commit and the branch is gone, so the merged head is
# reachable from no ref and takes the orphan arm while belonging to the
# other-pull-request arm, and the previous pull request's entries are judged
# against an unrelated diff. The recorded branch answers directly what
# reachability can only approximate. It is offline and deterministic, which a
# `gh` lookup of the sha's pull request would not be, and it holds in CI, which
# a reflog probe would not.
#
# Its honest limit: a sidecar written before the field existed records no
# branch, so it falls through to the sha chain and behaves exactly as it does
# without this term. That is the fail-toward-unchanged direction, and it is
# self-clearing, the sidecar is gitignored local state that a digest rotation
# replaces.
#
# A branch MATCH decides nothing and falls through on purpose. Only a mismatch
# is positive evidence of another branch; a match leaves the sha chain's own
# arms, an ancestor sha is attributability proof the branch name cannot supply,
# in place rather than short-circuiting past them.
#
# Attributable is the fail-toward-unchanged-behavior direction throughout: the
# check never sets an entry aside on a guess.
_disposition_attributable() {
  local sidecar="$1" root="$2"
  local sha rc probe sidecar_branch acting_branch

  [ -n "$root" ] || return 0

  sidecar_branch=$(jq -r '.branch // ""' "$sidecar" 2>/dev/null || true)
  if [ -n "$sidecar_branch" ]; then
    # Empty on a detached HEAD, which is a real state in a CI checkout: with no
    # branch to compare against, the recorded one proves nothing either way.
    acting_branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$acting_branch" ] && [ "$sidecar_branch" != "$acting_branch" ]; then
      return 1
    fi
  fi

  sha=$(jq -r '.sha // ""' "$sidecar" 2>/dev/null || true)
  case "$sha" in
    *[!0-9a-fA-F]*) return 0 ;;
  esac
  [ "${#sha}" -eq 40 ] || return 0

  rc=0
  git -C "$root" merge-base --is-ancestor "$sha" HEAD >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -ne 1 ]; then
    return 0
  fi

  probe=$(git -C "$root" for-each-ref --contains "$sha" --count=1 refs/heads refs/remotes 2>/dev/null) || return 0
  if [ -n "$probe" ]; then
    return 1
  fi
  return 0
}

# _disposition_machinery_ready
#
# Exit 0 iff `audit_path_is_machinery` is callable, sourcing audit-machinery.sh
# lazily from this lib's OWN on-disk dir (via BASH_SOURCE, never cwd) when a
# caller has not already sourced it. FAIL-OPEN for the whole waive arm when it
# is unavailable: this file never blocks on an inability to verify, and
# audit-machinery.sh is a naming aid, never a security boundary (an actor who
# can rewrite the working tree can rewrite the guard too), consistent with that
# lib's own header.
_disposition_machinery_ready() {
  local _adisp_dir

  if ! command -v audit_path_is_machinery >/dev/null 2>&1; then
    _adisp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -n "$_adisp_dir" ] && [ -f "$_adisp_dir/audit-machinery.sh" ]; then
      # shellcheck source=/dev/null
      . "$_adisp_dir/audit-machinery.sh"
    fi
  fi
  command -v audit_path_is_machinery >/dev/null 2>&1
}

# --- disposition_offenders <sidecar> [<acting-root>] -------------------------
#
# The sidecar `key` is the dedup-key INNER content `v1 class=… path=… line=…`
# WITHOUT the `<!-- gaia-debt-key: … -->` wrapper; a filed issue body carries
# the wrapped form. A match reconstructs the WRAPPED form and tests the issue
# body for it as a SUBSTRING (the trailing ` -->` prevents a `line=4` key
# digit-prefix-matching a sibling `line=42 -->` issue), never whole-line
# equality. A CLOSED matching issue is a SATISFIED disposition, not an offender.
#
# The `machinery_waived` disposition is a sanctioned NON-file outcome for a
# non-security out-of-scope finding: the finding is recorded in the pull-request
# body instead of opening a durable tech-debt issue. It is legitimate ONLY when
# the key's `path=` falls in the UNION of two sets -- the gate-machinery paths
# (`audit_path_is_machinery`) and the files the pull request under judgment
# already changes (<acting-root>'s whole-PR diff). Anywhere else the entry is an
# unfiled out-of-scope finding wearing a machinery label, so it is an offender.
# This is the deterministic abuse-check shared by the backstop hook and the
# merge gate.
#
# The arm queries no backend and is offline in that sense, but it does make
# LOCAL git calls in its verdict path: one for the changed-file set, one to
# attribute the sidecar to the tree under judgment.
#
# Three states are distinguished from "verified clean", each carried by a
# `disposition_notes` line rather than left silent:
#
#   - the machinery classifier cannot be resolved -> the WHOLE arm produces no
#     offenders and neither term runs. Running the changed-files term alone
#     would make the arm stricter than the machinery term alone is, turning a
#     machinery-path waive into an offender whenever the classifier is missing;
#   - the sidecar is not attributable to the tree under judgment (it was written
#     while judging a different pull request) -> the entry is set aside: no
#     offender line and no changed-files verdict;
#   - the sidecar is attributable but the diff base does not resolve -> the
#     changed-files term contributes nothing and the machinery term decides
#     alone, so a non-machinery entry is an offender.
disposition_offenders() {
  local sidecar="$1" acting_root="${2:-}"
  local backend offenders="" pending_keys filed_keys issues_json gh_ok k key needle present
  local mw_keys mw_path mw_attributable mw_base_ok mw_changed

  command -v jq >/dev/null 2>&1 || return 0

  # No sidecar / unparseable / backend "absent" -> fail-open (nothing to verify).
  [ -f "$sidecar" ] || return 0
  jq -e . "$sidecar" >/dev/null 2>&1 || return 0
  backend=$(jq -r '.backend // ""' "$sidecar" 2>/dev/null || true)
  [ "$backend" = "absent" ] && return 0

  # (a) pending(definitive): a genuinely-missing disposition. A local sidecar
  # fact, so deny regardless of backend reachability.
  pending_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "pending"
         and (.pending_reason // "") == "definitive")
    | (.key // "(no key)")' "$sidecar" 2>/dev/null || true)
  if [ -n "$pending_keys" ]; then
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      offenders="${offenders}pending(definitive): ${k}
"
    done <<EOF
$pending_keys
EOF
  fi

  # (b) filed entries: each key must resolve to a tech-debt issue, OPEN or
  # CLOSED, on a REACHABLE backend. Only query when there is a filed entry.
  filed_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "filed")
    | (.key // empty)' "$sidecar" 2>/dev/null || true)

  if [ -n "$filed_keys" ]; then
    issues_json=""
    gh_ok=0
    if command -v gh >/dev/null 2>&1; then
      if issues_json=$(gh issue list --label tech-debt --state all \
          --json number,body --limit 1000 2>/dev/null) \
         && printf '%s' "$issues_json" | jq -e . >/dev/null 2>&1; then
        gh_ok=1
      fi
    fi

    if [ "$gh_ok" -eq 1 ]; then
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        needle="<!-- gaia-debt-key: ${key} -->"
        present=$(printf '%s' "$issues_json" \
          | jq -r --arg k "$needle" 'any(.[]?; (.body // "") | contains($k))' \
              2>/dev/null || true)
        if [ "$present" != "true" ]; then
          offenders="${offenders}filed-but-missing: ${key}
"
        fi
      done <<EOF
$filed_keys
EOF
    fi
    # gh_ok == 0 -> backend unreachable/transient: fail open, no filed offenders.
  fi

  # (c) machinery_waived entries: the abuse-check. A `machinery_waived` entry is
  # legitimate ONLY when its key `path=` is in the union of the gate-machinery
  # set and this pull request's own changed files; anywhere else it is an
  # unfiled out-of-scope finding wearing a machinery label -> offender. This
  # runs after the backend-"absent" early return above, matching the
  # pending(definitive) posture: it fires unless the backend is definitively
  # absent, in which case every out-of-scope finding waives to prose regardless.
  mw_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "machinery_waived")
    | (.key // empty)' "$sidecar" 2>/dev/null || true)
  if [ -n "$mw_keys" ] && _disposition_machinery_ready; then
    # The two call-level facts, resolved ONCE per call and never per entry. A
    # sidecar that is not attributable is never diffed against this tree at all.
    mw_attributable=1
    mw_base_ok=0
    mw_changed=""
    if [ -n "$acting_root" ]; then
      _disposition_attributable "$sidecar" "$acting_root" || mw_attributable=0
      if [ "$mw_attributable" -eq 1 ]; then
        mw_changed=$(mktemp "${TMPDIR:-/tmp}/.audit-changed-set.XXXXXX" 2>/dev/null) || mw_changed=""
        if [ -n "$mw_changed" ] && _disposition_changed_set "$acting_root" "$mw_changed"; then
          mw_base_ok=1
        fi
      fi
    fi

    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # Fail closed on the key shape. A key the extractor cannot parse is an
      # offender, and neither term is evaluated for it, so a malformed key is
      # never cleared by a changed-files match on a path it does not name.
      if ! printf '%s\n' "$key" | LC_ALL=C grep -qE '^v1 class=[^[:space:]]+ path=.+ line=[0-9]+$'; then
        offenders="${offenders}machinery-waived-not-eligible: ${key}
"
        continue
      fi
      # Key format: `v1 class=<class> path=<repo-relative-posix-path> line=<int>`.
      # Extract the path= value: strip through the first `path=`, then the
      # shortest trailing ` line=...`, so a path containing spaces survives.
      mw_path="${key#*path=}"
      mw_path="${mw_path% line=*}"
      # Gate-machinery term, evaluated on every path that reaches here,
      # including under an unresolved base and a non-attributable sidecar.
      if audit_path_is_machinery "$mw_path"; then
        continue
      fi
      # A sidecar belonging to a different pull request, by branch or by sha, is
      # set aside: no offender line, and disposition_notes reports why.
      if [ "$mw_attributable" -ne 1 ]; then
        continue
      fi
      # Changed-files term: exact whole-string equality against the set. An
      # unresolved base contributes nothing, which leaves the entry an offender.
      if [ "$mw_base_ok" -eq 1 ] && _disposition_set_contains "$mw_changed" "$mw_path"; then
        continue
      fi
      offenders="${offenders}machinery-waived-not-eligible: ${key}
"
    done <<EOF
$mw_keys
EOF
    if [ -n "$mw_changed" ]; then
      rm -f "$mw_changed"
    fi
  fi

  [ -n "$offenders" ] && printf '%s' "$offenders"
  return 0
}

# --- disposition_notes <sidecar> [<acting-root>] -----------------------------
#
# One line per `machinery_waived` entry whose verdict is reached WITHOUT the
# changed-files term, so a gate can report "could not verify" distinguishably
# from "verified clean". Three line shapes, in this precedence:
#
#   machinery-classifier-unavailable: <key>
#       the machinery path list could not be loaded, so the waive abuse-check
#       did not run at all for this merge
#   changed-files-not-attributable: <key>
#       the sidecar was written while judging a different pull request, so its
#       entries are set aside rather than judged against this diff
#   changed-files-unverified: <key>
#       the sidecar is attributable, but this tree's pull-request diff base does
#       not resolve, so only the gate-machinery term is evaluated
#
# An attributable sidecar under a resolved base emits NO line, for a
# gate-machinery path as much as for a changed one: that verdict is "verified
# clean", the state these notes exist to be distinguishable from.
#
# All three conditions are properties of the CALL rather than of an individual
# entry, so every `machinery_waived` entry in the sidecar carries the same line.
# The preconditions mirror disposition_offenders exactly -- no jq, no sidecar,
# an unparseable sidecar, or backend "absent" -- because in each of those the
# waive arm does not run for a reason that is not about eligibility, and there
# is no line shape for it.
#
# Exit 0 unconditionally. This function denies nothing; the gates decide.
disposition_notes() {
  local sidecar="$1" acting_root="${2:-}"
  local backend mw_keys key notes="" line changed_file

  command -v jq >/dev/null 2>&1 || return 0

  # Same preconditions as disposition_offenders: nothing to report when the
  # sidecar is missing, unparseable, or declares its backend absent.
  [ -f "$sidecar" ] || return 0
  jq -e . "$sidecar" >/dev/null 2>&1 || return 0
  backend=$(jq -r '.backend // ""' "$sidecar" 2>/dev/null || true)
  [ "$backend" = "absent" ] && return 0

  mw_keys=$(jq -r '
    .findings[]?
    | select((.disposition // "") == "machinery_waived")
    | (.key // empty)' "$sidecar" 2>/dev/null || true)
  [ -n "$mw_keys" ] || return 0

  if ! _disposition_machinery_ready; then
    line="machinery-classifier-unavailable"
  elif [ -n "$acting_root" ] && ! _disposition_attributable "$sidecar" "$acting_root"; then
    line="changed-files-not-attributable"
  else
    # The set itself is discarded; what this call reads is whether the base
    # resolved. Deriving it through the same helper disposition_offenders uses
    # is what keeps the two verdicts from drifting apart.
    line="changed-files-unverified"
    changed_file=$(mktemp "${TMPDIR:-/tmp}/.audit-changed-set.XXXXXX" 2>/dev/null) || changed_file=""
    if [ -n "$changed_file" ]; then
      if _disposition_changed_set "$acting_root" "$changed_file"; then
        line=""
      fi
      rm -f "$changed_file"
    fi
  fi
  [ -n "$line" ] || return 0

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    notes="${notes}${line}: ${key}
"
  done <<EOF
$mw_keys
EOF

  [ -n "$notes" ] && printf '%s' "$notes"
  return 0
}

# --- disposition_note_block <notes> ------------------------------------------
#
# Renders disposition_notes' raw output as the operator-visible block a gate
# writes to stderr, and appends to its deny reason when it also denies. Empty
# output when <notes> is empty. Never changes an allow/deny decision: a gate
# that allows still prints it, because "could not verify" has to stay
# distinguishable from "verified clean".
#
# It lives here rather than in either gate because both gates fire on the same
# `gh pr merge` and describe the same three conditions. Two copies drift into
# two different explanations of one condition, and which one an operator reads
# depends on nothing more principled than which gate denies first.
disposition_note_block() {
  local notes="$1" block=""
  [ -n "$notes" ] || return 0

  block="Disposition abuse-check notes for machinery_waived entries whose changed-files verdict could not run:

${notes%$'\n'}"

  if printf '%s\n' "$notes" | grep -q '^machinery-classifier-unavailable:'; then
    block="${block}

machinery-classifier-unavailable: the machinery path list could not be loaded, so the waive abuse-check did not run at all for this merge."
  fi
  if printf '%s\n' "$notes" | grep -q '^changed-files-not-attributable:'; then
    block="${block}

changed-files-not-attributable: the sidecar was written while judging a different pull request, so its entries were set aside rather than judged against this diff."
  fi
  if printf '%s\n' "$notes" | grep -q '^changed-files-unverified:'; then
    block="${block}

changed-files-unverified: this tree's pull-request diff base could not be resolved, so only the gate-machinery term was evaluated for that entry."
  fi

  printf '%s' "$block"
  return 0
}

# --- disposition_seed_forward <prev-sidecar> <new-sidecar> -------------------
#
# Unions every still-open entry from <prev-sidecar> into <new-sidecar>, writing
# <new-sidecar> in place (atomically: temp file + mv). "Still-open" is the SAME
# predicate the janitor's open-receipt keep-arm applies:
#
#   .disposition == "filed"
#   OR (.disposition == "pending" AND .pending_reason == "definitive")
#
# On a key collision, HEAD's fresh entry in <new-sidecar> always wins; a seeded
# entry may only ADD keys, never overwrite one already present. A plain
# still-open union: no anchor selection, no ancestry walk, no backend
# precedence logic.
#
# A missing <new-sidecar> is treated as an empty record, so still-open entries
# write through (all keys are new). A missing/unparseable <prev-sidecar>, an
# absent jq, or any error is a no-op that leaves <new-sidecar> untouched.
disposition_seed_forward() {
  local prev="$1" new="$2"
  local prev_json new_json merged tmp

  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$prev" ] && [ -n "$new" ] || return 0
  [ -f "$prev" ] || return 0
  prev_json=$(jq -e . "$prev" 2>/dev/null) || return 0

  if [ -f "$new" ]; then
    new_json=$(jq -e . "$new" 2>/dev/null) || new_json='{}'
  else
    new_json='{}'
  fi

  merged=$(printf '%s\n%s\n' "$prev_json" "$new_json" | jq -s '
    .[0] as $prev | .[1] as $new |
    ($new.findings // []) as $nf |
    ([ $nf[] | .key ]) as $nkeys |
    ($prev.findings // []) as $pf |
    ([ $pf[] | select(
        (.disposition // "") == "filed"
        or ((.disposition // "") == "pending" and (.pending_reason // "") == "definitive")
      )
    ]) as $still_open |
    ($still_open | map(select((.key as $k | $nkeys | index($k)) | not))) as $seeded |
    $new | .findings = ($nf + $seeded)
  ' 2>/dev/null) || return 0
  [ -n "$merged" ] || return 0

  mkdir -p "$(dirname "$new")" 2>/dev/null || true
  tmp=$(mktemp "$(dirname "$new")/.audit-dispositions.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$merged" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$new" 2>/dev/null || { rm -f "$tmp"; return 0; }
  return 0
}
