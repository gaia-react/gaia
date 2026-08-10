#!/usr/bin/env bats
#
# The five Code Audit Team members must resolve ONE review base, and the
# artifacts keyed off it must be readable by the consumers that read them.
#
# `gaia_audit_key` (.gaia/scripts/audit-key-lib.sh) is
# `<base_sha>.<branch-slug>`, and co-dispatched members share a branch, so
# the keys agree exactly when the base shas agree. Two members resolving the
# base two different ways therefore write and read two different ledgers:
# `post-findings-block.sh` globs one key and silently finds nothing under the
# other, so a whole member's findings drop out of the consolidated PR block
# with no error anywhere.
#
# This suite drives the REAL derivation snippets out of the REAL agent
# definitions -- it never restates them -- against a scratch repo carrying a
# stamped clean round. A member whose prose drifts to a private derivation
# reds here.
#
# Five probes:
#   1. base + key agreement across all five members
#   1b. the reviewed range is HEAD's content, not the working tree's, and the
#       fork point rather than an advanced ref tip
#   2. post-findings-block.sh reads a specialist's sidecar
#   3. the self-skip deadlock: a machinery-only increment with the
#      classifier libs unloadable
#   4. the eligibility-widening fence: presence and fork-point resolution,
#      unfiltered distinctness from the review-scope set, the review-scope
#      fence staying untouched, no empty-base guard, and write-side/verify-side
#      agreement across three repository shapes
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-base-agreement.bats`.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ... ]`
# for equality/status, `grep -qF` for substrings, explicit `return 1`
# branches, never a non-final `!`-negation.

# require_jq
#
# jq is a precondition on CI, not a maybe: audit-ci-tests.yml runs this suite
# on ubuntu-latest, where jq is preinstalled, so an absent jq there means the
# runner image or the job moved under this file. A bats `skip` reports
# `ok ... # skip` and greens the required check, which would retire every
# probe -- the entire base-agreement guarantee -- with nothing anywhere
# saying it did not run. The CI branch therefore FAILS instead of skipping.
# Off CI the skip stands: a workstation without jq is not the environment
# this suite makes a claim about. Same fail-closed shape as
# .gaia/scripts/tests/retrigger-reachability.bats' own precondition gates.
# Section 0 below proves the CI branch fires.
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # No `::error::` prefix: bats prefixes a test's stderr with `# `, and
    # Actions parses a workflow command only at column 0, so the annotation
    # that spelling promises would never render. The `return 1` is what gates.
    echo "jq not present on a CI runner; every probe here would report green. Check the runner image and the job's install step." >&2
    return 1
  fi
  skip "jq required"
}

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIR" rev-parse --show-toplevel)"
  AGENTS_DIR="$REPO_ROOT/.claude/agents"
  require_jq

  MEMBERS=(
    code-audit-frontend
    code-audit-github-workflows
    code-audit-maintainer-shell
    code-audit-maintainer-node
    code-audit-maintainer-prose
  )
  SPECIALISTS=(
    code-audit-github-workflows
    code-audit-maintainer-shell
    code-audit-maintainer-node
    code-audit-maintainer-prose
  )
}

# --- section 0: the gate itself ----------------------------------------------
#
# setup() stands every test in this file down when jq is absent, so it is the
# single place a weakening would silently retire the whole suite. This test is
# what makes that weakening red: revert require_jq to a bare `skip` and the CI
# arm below stops failing. It cannot escape the gate it guards (setup() runs
# first here as everywhere), so what it catches is the weakening, not the
# condition.

@test "the jq gate fails on a CI runner and still skips off CI" {
  local shim="$BATS_TEST_TMPDIR/no-jq" rc
  mkdir -p "$shim"

  # An empty directory is a sufficient PATH: the gate runs no command other
  # than `command -v jq`. Calling the gate in a subshell is what keeps its
  # `skip` arm from marking THIS test skipped -- bats' `skip` exits 0, so the
  # subshell's status is exactly the discriminator wanted here: non-zero is
  # the CI failure, 0 is the off-CI skip.
  rc=0
  ( PATH="$shim" GITHUB_ACTIONS=true; require_jq ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no jq; every probe would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_jq ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where an absent jq must still skip" >&2
    return 1
  }
}

# --- unresolvable FULL_BASE --------------------------------------------------
#
# A repo whose branch is not `main` and which has no `origin` remote. The
# default-branch probe finds no `refs/remotes/origin/HEAD`, falls back to the
# literal `main`, and neither `origin/main` nor `main` exists, so both
# merge-base arms fail and FULL_BASE comes back empty. This is a reachable
# adopter shape, not a contrivance: `git init` + `git remote add` creates no
# `origin/HEAD` symref.
make_no_base_repo() {
  local dir="$BATS_TEST_TMPDIR/no-base"
  mkdir -p "$dir/.gaia/scripts"
  git -C "$dir" init -q --initial-branch=master
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf 'x\n' > "$dir/.gaia/scripts/thing.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  printf '%s' "$dir"
}

@test "every specialist stops instead of self-skipping when FULL_BASE cannot resolve" {
  local repo member fence rc out
  repo="$(make_no_base_repo)"
  for member in "${SPECIALISTS[@]}"; do
    fence="$(extract_base_fence "$AGENTS_DIR/${member}.md")" || return 1
    rc=0
    out="$(AUDIT_ROOT="$repo" bash -c "$fence" 2>&1)" || rc=$?
    # Non-zero is the whole point: an empty FULL_BASE makes `full_changed`
    # empty at status 0, which the self-skip arm would read as "nothing in my
    # remit" and answer with no marker at all.
    [ "$rc" -ne 0 ] || {
      echo "$member continued with an unresolvable FULL_BASE; its self-skip would write no marker" >&2
      return 1
    }
    grep -qF "do NOT self-skip" <<<"$out" || {
      echo "$member exited non-zero but never said why" >&2
      return 1
    }
  done
}

@test "the FULL_BASE guard stays silent when the base does resolve" {
  local repo member fence out
  repo="$(make_repo full-base-control)"
  for member in "${SPECIALISTS[@]}"; do
    fence="$(extract_base_fence "$AGENTS_DIR/${member}.md")" || return 1
    out="$(AUDIT_ROOT="$repo" bash -c "$fence" 2>&1)" || return 1
    grep -qF "do NOT self-skip" <<<"$out" && {
      echo "$member's guard fired on a repo whose base resolves fine" >&2
      return 1
    }
  done
  return 0
}

# --- fence extraction --------------------------------------------------------
#
# Prints the one ```bash fence in <agent-file> whose body assigns BASE_SHA at
# column 0. Exits 1 when the file carries zero or more than one such fence,
# so a definition that stops declaring its base reds here rather than
# silently contributing an empty snippet.
extract_base_fence() {
  awk '
    /^```bash$/ { infence = 1; buf = ""; has = 0; next }
    /^```$/     { if (infence) { if (has) { printf "%s", buf; found++ } ; infence = 0 } ; next }
    infence     { buf = buf $0 "\n"; if ($0 ~ /^BASE_SHA=/) has = 1 }
    END         { if (found != 1) exit 1 }
  ' "$1"
}

# extract_eligibility_fence <agent-file>
#
# Prints the one ```bash fence in <agent-file> whose body assigns FULL_BASE at
# column 0. Exits 1 when the file carries zero or more than one such fence, so
# a definition that stops declaring its eligibility base reds here rather than
# silently contributing an empty snippet.
#
# A second extractor rather than a parameter on extract_base_fence: that
# helper's exactly-one contract is asserted against every member (all five
# carry a BASE_SHA fence), while this one is asserted against the default
# member alone (only it carries a FULL_BASE fence). Collapsing them into one
# parameterized helper would let one member's second fence satisfy another
# member's requirement, which is exactly the drift this suite exists to catch.
extract_eligibility_fence() {
  awk '
    /^```bash$/ { infence = 1; buf = ""; has = 0; next }
    /^```$/     { if (infence) { if (has) { printf "%s", buf; found++ } ; infence = 0 } ; next }
    infence     { buf = buf $0 "\n"; if ($0 ~ /^FULL_BASE=/) has = 1 }
    END         { if (found != 1) exit 1 }
  ' "$1"
}

# --- scratch repo ------------------------------------------------------------
#
# A repo carrying the machinery the snippets reach for, at its real
# repo-relative path. <name> names the directory; the caller commits into it.
# `include_machinery_lib` (arg 2, default "yes") decides whether
# .claude/hooks/lib/audit-machinery.sh is present: omitting it is what puts
# resolve-audit-base.sh's RT-006 check into its fail-open arm, which probe 3
# needs.
make_repo() {
  local name="$1" include_machinery_lib="${2:-yes}"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.gaia/scripts" "$dir/.gaia/local/audit" \
    "$dir/.github/audit" "$dir/.claude/hooks/lib" "$dir/bin"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$dir/.github/audit/"
  chmod +x "$dir/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$dir/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/post-findings-block.sh" "$dir/.gaia/scripts/"
  chmod +x "$dir/.gaia/scripts/post-findings-block.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$dir/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" "$dir/.claude/hooks/lib/"
  if [ "$include_machinery_lib" = "yes" ]; then
    cp "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" "$dir/.claude/hooks/lib/"
  fi
  printf '2.0.0\n' > "$dir/.gaia/VERSION"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "init"
  printf '%s' "$dir"
}

# commit_file <repo> <path> <message>: writes a line into <path> and commits.
commit_file() {
  local repo="$1" path="$2" message="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf 'touched by %s\n' "$message" >> "$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

# stamp_clean_round <repo>: the content-preserving empty commit a clean audit
# round lands, carrying the GAIA-Audit trailer resolve-audit-base.sh anchors
# on. The digest and tree fields only have to satisfy the frozen trailer
# regex's 64-hex / 40-hex shape; the resolver compares the version alone. A
# printf-built digest rather than a hashed one keeps this off `shasum`, whose
# flags differ between BSD and GNU (.claude/rules/bats-assertions.md), and
# matches how .github/audit/tests/resolve-audit-base.bats builds its own.
stamp_clean_round() {
  local repo="$1" digest tree
  digest="$(printf '%064d' 0)"
  tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
  git -C "$repo" commit -q --allow-empty -m "audit: stamp

GAIA-Audit: 2.0.0 ${digest} ${tree}"
}

# --- snippet execution -------------------------------------------------------
#
# fence_eval <member> <repo> <trailer>: runs that member's real derivation
# fence against <repo>, then <trailer> in the same shell, and prints the
# trailer's stdout. `set -u` is deliberately NOT applied: an unset variable
# is the very drift this suite is written to catch, and it must surface as a
# failed assertion on a printed empty value rather than as an abort whose
# message reads the same as a missing binary.
fence_eval() {
  local member="$1" repo="$2" trailer="$3" fence
  fence="$(extract_base_fence "$AGENTS_DIR/${member}.md")" || return 1
  AUDIT_ROOT="$repo" bash -c "${fence}
${trailer}"
}

# elig_eval <member> <repo> <trailer>: the eligibility-fence counterpart to
# fence_eval, see its header for the `set -u` rationale (deliberately absent
# here too).
elig_eval() {
  local member="$1" repo="$2" trailer="$3" fence
  fence="$(extract_eligibility_fence "$AGENTS_DIR/${member}.md")" || return 1
  AUDIT_ROOT="$repo" bash -c "${fence}
${trailer}"
}

# base_sha_for <member> <repo>
base_sha_for() {
  fence_eval "$1" "$2" 'printf "%s\n" "${BASE_SHA:-}"'
}

# audit_key_for <member> <repo>
audit_key_for() {
  local repo="$2" base
  base="$(base_sha_for "$1" "$repo")" || return 1
  ( . "$repo/.gaia/scripts/audit-key-lib.sh" && gaia_audit_key "$base" "$repo" )
}

# owners_of <repo> <newline-separated-paths>: the REAL roster classifier's
# answer for a path list. Never a reimplementation of the remit globs -- the
# question "does this member self-skip on this list" is exactly the question
# audit_owners_for_paths answers, and restating the globs here would test
# this suite's own copy of them.
owners_of() {
  local repo="$1" paths="$2"
  ( . "$repo/.claude/hooks/lib/audit-scope.sh" \
      && audit_scope_init "$repo" \
      && printf '%s\n' "$paths" | audit_owners_for_paths \
      | awk -F'\t' '$2 != "-" { print $2 }' | LC_ALL=C sort -u )
}

# ---------- probe 1: base + key agreement ------------------------------------

@test "all five members resolve the same base and the same audit key after a stamped clean round" {
  local repo
  repo="$(make_repo agreement)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "app/a.txt" "commit A"
  commit_file "$repo" "app/b.txt" "commit B"
  stamp_clean_round "$repo"
  # The post-clean-pass push: touches no machinery, so RT-006 does not reset
  # the base and the increment is genuinely narrower than the whole PR.
  commit_file "$repo" "app/c.txt" "advisory prose fix after clean pass"

  local full_base
  full_base="$(git -C "$repo" merge-base HEAD main)"

  local expected_base expected_key m base key
  expected_base="$(base_sha_for code-audit-frontend "$repo")"
  expected_key="$(audit_key_for code-audit-frontend "$repo")"

  # Not vacuous: the resolver must actually have advanced past the whole-PR
  # fork point. If it had not, every member would agree on the full base and
  # this test would pass while proving nothing.
  [ -n "$expected_base" ]
  [ "$expected_base" != "$full_base" ]
  [ -n "$expected_key" ]

  for m in "${MEMBERS[@]}"; do
    base="$(base_sha_for "$m" "$repo")"
    key="$(audit_key_for "$m" "$repo")"
    if [ "$base" != "$expected_base" ]; then
      printf 'member %s resolved base %s, expected %s\n' "$m" "$base" "$expected_base"
      return 1
    fi
    if [ "$key" != "$expected_key" ]; then
      printf 'member %s resolved key %s, expected %s\n' "$m" "$key" "$expected_key"
      return 1
    fi
  done
}

# ---------- probe 1b: the review scope is HEAD, not the working tree ---------
#
# A member's clearance digest is computed over `git ls-tree HEAD`
# (.claude/hooks/lib/audit-digest.sh), so its review scope has to be HEAD's
# content or the marker attests to bytes the member never read. Two spellings
# diverge on exactly one input, a dirty tree:
#
#   git diff <base> -- <paths>          base vs the WORKING TREE (two-dot)
#   git diff <base>...HEAD -- <paths>   the fork point vs the HEAD COMMIT
#
# Both directions are wrong under two-dot, and each is probed below. A change
# committed and then reverted in the working tree VANISHES from the list while
# the marker still covers the committed version; an uncommitted edit ENTERS the
# list while no marker covers it and the dispatch oracle never saw it.
#
# The frontend is the member probed because it is the one whose scope is a
# TS/TSX pathspec; the four specialists' identical form is already covered by
# probe 1's shared BASE_SHA and by their own fences here.

@test "the frontend's changed-file list is HEAD's content, not the working tree's" {
  local repo changed
  repo="$(make_repo worktree-scope)"
  git -C "$repo" checkout -q -b feat

  # Both probe files must be TRACKED at the base. `git diff` compares tracked
  # content only, so an untracked path appears under neither spelling and an
  # assertion written against one could never fire: the dirty-file direction
  # has to be a modification to a tracked file, not a new file.
  mkdir -p "$repo/app"
  printf 'export const before = 1\n' > "$repo/app/reverted.ts"
  printf 'export const clean = 1\n' > "$repo/app/dirty.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "baseline for both probe files"
  stamp_clean_round "$repo"

  # Committed, then reverted in the working tree. Two-dot drops it; three-dot
  # keeps it, which is the arm that matches the digest.
  printf 'export const after = 2\n' > "$repo/app/reverted.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "commit a change to reverted.ts"
  printf 'export const before = 1\n' > "$repo/app/reverted.ts"

  # Modified in the working tree and never committed. Three-dot excludes it;
  # two-dot pulls it in, where no marker can cover it.
  printf 'export const scratch = 3\n' > "$repo/app/dirty.ts"

  changed="$(fence_eval code-audit-frontend "$repo" 'printf "%s\n" "${changed:-}"')"

  grep -qF 'app/reverted.ts' <<<"$changed" || {
    printf 'a file changed in HEAD but reverted in the working tree fell out of review scope, while the marker still covers it: %s\n' "$changed" >&2
    return 1
  }
  grep -qF 'app/dirty.ts' <<<"$changed" && {
    printf 'an uncommitted working-tree edit entered review scope, where no marker can cover it: %s\n' "$changed" >&2
    return 1
  }
  return 0
}

@test "the frontend's review scope is the fork point, not an advanced ref tip" {
  local repo changed
  repo="$(make_repo forkpoint-scope)"

  # The second failure direction, reachable only when the base is a REF whose
  # tip has advanced past this branch's fork point: the resolver's own
  # no-audited-ancestor fallback. It discriminates against the retired
  # two-dot-on-the-resolver-output shape specifically, which is the one that
  # combines both terms. It stays green under a two-dot form anchored on
  # BASE_SHA, correctly: a sha at the fork point cannot advance, so only the
  # sibling probe above catches that one. Three-dot resolves its own merge
  # base, so the current form is immune whichever the base turns out to be.
  git -C "$repo" checkout -q -b feat
  mkdir -p "$repo/app"
  printf 'export const mine = 1\n' > "$repo/app/pr-touched.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "the only file this PR touches"

  # `app/` only exists on feat, so checking out main removes the directory
  # along with the file that made it; recreate it before writing.
  git -C "$repo" checkout -q main
  mkdir -p "$repo/app"
  printf 'export const theirs = 1\n' > "$repo/app/main-only.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "main advances with an unrelated file"
  git -C "$repo" checkout -q feat

  changed="$(fence_eval code-audit-frontend "$repo" 'printf "%s\n" "${changed:-}"')"

  grep -qF 'app/pr-touched.ts' <<<"$changed" || {
    printf 'the file this PR actually changed is missing from review scope: %s\n' "$changed" >&2
    return 1
  }
  grep -qF 'app/main-only.ts' <<<"$changed" && {
    printf 'a file only the default branch touched entered review scope: %s\n' "$changed" >&2
    return 1
  }
  return 0
}

# ---------- probe 2: the consolidated findings block sees a specialist -------

@test "post-findings-block.sh finds a specialist's sidecar under the resolver-derived key" {
  local repo
  repo="$(make_repo findings-block)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "app/a.txt" "commit A"
  stamp_clean_round "$repo"
  commit_file "$repo" "app/c.txt" "advisory prose fix after clean pass"

  # The sidecar lands under the key the SPECIALIST itself derives -- that is
  # the writer's key, and hard-coding the reader's key here would test
  # nothing.
  local writer_key
  writer_key="$(audit_key_for code-audit-maintainer-shell "$repo")"
  [ -n "$writer_key" ]
  printf '{"schema":1,"member":"code-audit-maintainer-shell","findings":[{"finding_class":"shell/unquoted-expansion","severity":"error","area_tags":["shell"],"path":".gaia/scripts/x.sh","line":7,"title":"t","failure_mode":"f","verified_by":"v","suggested_fix":"s"}]}\n' \
    > "$repo/.gaia/local/audit/${writer_key}.code-audit-maintainer-shell.findings.json"

  # The reader resolves its base the way post-findings-block-on-merge.sh
  # does: the resolver, then merge-base against HEAD.
  local reader_ref reader_base
  reader_ref="$(cd "$repo" && ./.github/audit/resolve-audit-base.sh)"
  reader_base="$(git -C "$repo" merge-base "$reader_ref" HEAD)"
  [ -n "$reader_base" ]

  cat > "$repo/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
esac
case "\$1" in
  pr) [ "\$2" = "view" ] && echo 42 ;;
  repo) echo "acme/widgets" ;;
  api)
    method=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--method" ] && method="\$a"
      prev="\$a"
    done
    if [ -z "\$method" ]; then
      printf '%s' '[]'
    else
      prev=""
      for a in "\$@"; do
        case "\$prev" in
          -F|--field)
            case "\$a" in
              body=@*) cp "\${a#body=@}" "$repo/posted_body.txt" ;;
            esac
            ;;
          -f|--raw-field)
            case "\$a" in
              body=*) printf '%s' "\${a#body=}" > "$repo/posted_body.txt" ;;
            esac
            ;;
        esac
        prev="\$a"
      done
      echo '{"id":999}'
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$repo/bin/gh"

  run bash -c 'cd "$1" && PATH="$1/bin:$PATH" bash .gaia/scripts/post-findings-block.sh --base "$2" --pr 42' \
    _ "$repo" "$reader_base"
  [ "$status" -eq 0 ]
  grep -qF "findings: declined: no sidecars" <<<"$output" && return 1
  grep -qF "from 1 member(s)" <<<"$output" || return 1
  [ -f "$repo/posted_body.txt" ]
  grep -qF "shell/unquoted-expansion" "$repo/posted_body.txt" || return 1
}

# ---------- probe 3: the self-skip deadlock ----------------------------------
#
# The one case a single base cannot serve. A member's marker is invalid at
# HEAD exactly when its digest rotated, and a digest rotates on an owned-file
# change OR a machinery change. The owned-file case is safe under one base:
# the owned file is in the increment, so the member does not self-skip. The
# machinery case is normally safe too, because RT-006 resets the base to full
# scope. But that check FAILS OPEN when the classifier libs will not load
# (resolve-audit-base.sh's `libs unavailable` arm), and then the increment
# carries only the machinery file. A member that does not own that file sees
# an empty increment, self-skips, and writes no marker -- while membership,
# resolved over the whole PR diff, still demands one. The merge deadlocks
# with nothing left to clear it.
#
# So the self-skip arm reads the WHOLE-PR list and the review reads the
# increment. Each member is probed with a machinery path OUTSIDE its own
# remit (that is what makes its increment empty) and an owned path inside it.

# probe_deadlock <member> <owned-path> <machinery-path-outside-remit>
probe_deadlock() {
  local member="$1" owned="$2" machinery="$3" repo
  repo="$(make_repo "deadlock-${member}" no)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "$owned" "owned change"
  stamp_clean_round "$repo"
  commit_file "$repo" "$machinery" "machinery change"

  # The fail-open arm is genuinely exercised, not assumed: the resolver says
  # so on stderr and still emits the incremental candidate.
  local resolver_err
  resolver_err="$(cd "$repo" && ./.github/audit/resolve-audit-base.sh 2>&1 >/dev/null)"
  grep -qF "RT-006 base-reset check skipped" <<<"$resolver_err" || {
    printf 'expected the fail-open arm, got: %s\n' "$resolver_err"
    return 1
  }

  local incremental full
  incremental="$(fence_eval "$member" "$repo" 'printf "%s\n" "${changed:-}"')"
  full="$(fence_eval "$member" "$repo" 'printf "%s\n" "${full_changed:-}"')"

  # The increment is the machinery file alone; the whole-PR list also carries
  # the owned one.
  grep -qF "$machinery" <<<"$incremental" || {
    printf '%s: increment did not carry %s: %s\n' "$member" "$machinery" "$incremental"
    return 1
  }
  grep -qF "$owned" <<<"$incremental" && {
    printf '%s: increment unexpectedly carried %s\n' "$member" "$owned"
    return 1
  }
  grep -qF "$owned" <<<"$full" || {
    printf '%s: whole-PR list did not carry %s: %s\n' "$member" "$owned" "$full"
    return 1
  }

  # Self-skip is decided by the roster classifier, so ask it, not a copy of
  # the remit globs: the member is absent from the increment's owners (it
  # would self-skip) and present in the whole-PR list's owners (membership
  # demands its marker).
  local inc_owners full_owners
  inc_owners="$(owners_of "$repo" "$incremental")"
  full_owners="$(owners_of "$repo" "$full")"
  grep -qxF "$member" <<<"$inc_owners" && {
    printf '%s: owns something in the increment, so this is not the deadlock case\n' "$member"
    return 1
  }
  grep -qxF "$member" <<<"$full_owners" || {
    printf '%s: absent from whole-PR owners %s\n' "$member" "$full_owners"
    return 1
  }
  return 0
}

@test "deadlock: each specialist's self-skip arm reads the whole-PR list, not the increment" {
  probe_deadlock code-audit-maintainer-shell \
    ".claude/rules/fixture-rule.md" ".github/workflows/code-review-audit.yml"
  probe_deadlock code-audit-github-workflows \
    ".github/workflows/fixture-ci.yml" ".claude/hooks/lib/audit-clearance.sh"
  probe_deadlock code-audit-maintainer-node \
    ".gaia/cli/src/fixture.ts" ".claude/hooks/lib/audit-clearance.sh"
  probe_deadlock code-audit-maintainer-prose \
    ".claude/skills/fixture/SKILL.md" ".claude/hooks/lib/audit-clearance.sh"
}

@test "deadlock: each specialist's self-skip prose is wired to the whole-PR list" {
  local m
  for m in "${SPECIALISTS[@]}"; do
    grep -qF 'full_changed' "$AGENTS_DIR/${m}.md" || {
      printf '%s never names full_changed\n' "$m"
      return 1
    }
    grep -qF 'If no `full_changed` path matches' "$AGENTS_DIR/${m}.md" || {
      printf '%s does not key its self-skip arm on full_changed\n' "$m"
      return 1
    }
  done
}

# ---------- probe 3b: the membership list survives an unusual path -----------
#
# `full_changed` decides whether a specialist runs at all, and git's default
# `core.quotePath` makes that decision fail OPEN. `diff --name-only` C-quotes
# any path carrying non-ASCII or control bytes, emitting the surrounding double
# quotes as literal characters, and a quoted token matches no remit glob. The
# member then self-skips as if nothing it owned had changed, and the
# membership resolver reading the same list names no owner at all, which sends
# resolve-audit-spawn.sh to its ownerless fallback and the default member.
# Either way the specialist whose remit the file is in never reviews it, the
# outcome is indistinguishable from a genuine no-match, and nothing in the run
# records that it happened.
#
# check-audit-base-derivation.sh's assertion 4 pins the `-z` that prevents it,
# but a static check can only see that the flag is present. This proves the
# flag does what that check assumes, against a real repository and the REAL
# roster classifier, and it carries its own non-vacuity: the same repository is
# asked the same question through the pre-fix spelling, which must give the
# answer the flag exists to stop. Without that half, a fixture whose paths were
# quietly all-ASCII would pass while proving nothing.

@test "each specialist's whole-PR list survives a non-ASCII path, where the pre-fix spelling does not" {
  local repo member full owners base quoted
  repo="$(make_repo quote-safety)"
  git -C "$repo" checkout -q -b feat
  # One in-remit path per specialist, each carrying non-ASCII bytes.
  commit_file "$repo" ".github/workflows/été.yml" "workflows"
  commit_file "$repo" ".claude/rules/règle.md" "shell"
  commit_file "$repo" ".gaia/cli/src/café.ts" "node"
  commit_file "$repo" ".claude/skills/naïve/SKILL.md" "prose"

  for member in "${SPECIALISTS[@]}"; do
    full="$(fence_eval "$member" "$repo" 'printf "%s\n" "${full_changed:-}"')"
    # Checked before the quoting assertion: an empty list carries no double
    # quote either, so a fence that stopped resolving anything would sail
    # through the check below rather than failing it.
    [ -n "$full" ] || {
      printf '%s: whole-PR list came back empty\n' "$member"
      return 1
    }
    # C-quoting is what wraps a path in literal double quotes, and no path this
    # fixture commits contains one, so a quote in the list can only be git's.
    grep -qF '"' <<<"$full" && {
      printf '%s: whole-PR list is C-quoted: %s\n' "$member" "$full"
      return 1
    }
    # The real classifier rather than a copy of the remit globs: "does this
    # member self-skip on this list" is the decision that fails open, and
    # audit_owners_for_paths is what answers it in production.
    owners="$(owners_of "$repo" "$full")"
    grep -qxF "$member" <<<"$owners" || {
      printf '%s: absent from the owners of its own non-ASCII path: %s\n' "$member" "$owners"
      return 1
    }
  done

  # Non-vacuity: the pre-fix spelling, same repository, same base.
  # `core.quotePath` is pinned rather than inherited: it is the DEFAULT this
  # probe asserts about, and a maintainer who turns it off in ~/.gitconfig
  # would otherwise get a red here against a tree with nothing wrong with it.
  base="$(git -C "$repo" merge-base HEAD main)"
  quoted="$(git -C "$repo" -c core.quotePath=true diff --name-only "${base}...HEAD")"
  grep -qF '"' <<<"$quoted" || {
    printf 'the pre-fix spelling did not quote, so this fixture proves nothing: %s\n' "$quoted"
    return 1
  }
  owners="$(owners_of "$repo" "$quoted")"
  for member in "${SPECIALISTS[@]}"; do
    grep -qxF "$member" <<<"$owners" && {
      printf '%s still owns something under the pre-fix spelling, so the defect is not reproduced: %s\n' \
        "$member" "$owners"
      return 1
    }
  done
  true
}

# ---------- probe 4: the eligibility-widening fence --------------------------
#
# The out-of-scope machinery-waive rule reads an ELIGIBILITY set that is wider
# than the review scope: the union of the gate-machinery paths and every file
# this pull request already changes. `full_changed`, assigned by a second
# ```bash fence in code-audit-frontend.md, is that set's write side; the
# shared library's `_disposition_changed_set` is its verify side. Four things
# about the write side are load-bearing and none of them is checked by any
# other suite in this tree: that the fence exists at all and resolves the
# fork point, that its set is distinct from the TS/TSX-filtered review-scope
# set, that it continues rather than exiting when the base cannot resolve,
# and that it agrees byte for byte with the verify side.

@test "the eligibility derivation is present and resolves the fork point" {
  local repo expected_base full_base full_changed

  repo="$(make_repo elig-presence)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "app/owned.ts" "a file the default member owns"
  commit_file "$repo" ".claude/rules/fixture.md" "a file the default member does not own"

  expected_base="$(git -C "$repo" merge-base HEAD main)"

  full_base="$(elig_eval code-audit-frontend "$repo" 'printf "%s\n" "${FULL_BASE:-}"')" || {
    echo "the eligibility fence failed to run" >&2
    return 1
  }
  [ "$full_base" = "$expected_base" ] || {
    printf 'FULL_BASE=%s, expected the fork point %s\n' "$full_base" "$expected_base" >&2
    return 1
  }

  full_changed="$(elig_eval code-audit-frontend "$repo" 'printf "%s\n" "${full_changed:-}"')"
  [ -n "$full_changed" ] || {
    echo "full_changed came back empty" >&2
    return 1
  }
  grep -qxF "app/owned.ts" <<<"$full_changed" || {
    printf 'full_changed missing app/owned.ts: %s\n' "$full_changed" >&2
    return 1
  }
  grep -qxF ".claude/rules/fixture.md" <<<"$full_changed" || {
    printf 'full_changed missing .claude/rules/fixture.md: %s\n' "$full_changed" >&2
    return 1
  }
}

@test "the eligibility set is unfiltered and distinct from the review-scope set" {
  local repo eligibility review

  repo="$(make_repo elig-unfiltered)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "bin/setup.sh" "a shell script"
  commit_file "$repo" "docs/readme.md" "a markdown file"
  commit_file "$repo" ".github/workflows/fixture.yml" "a yaml file"

  eligibility="$(elig_eval code-audit-frontend "$repo" 'printf "%s\n" "${full_changed:-}"')"
  review="$(fence_eval code-audit-frontend "$repo" 'printf "%s\n" "${changed:-}"')"

  grep -qxF "bin/setup.sh" <<<"$eligibility" || {
    printf 'eligibility set missing bin/setup.sh: %s\n' "$eligibility" >&2
    return 1
  }
  grep -qxF "docs/readme.md" <<<"$eligibility" || {
    printf 'eligibility set missing docs/readme.md: %s\n' "$eligibility" >&2
    return 1
  }
  grep -qxF ".github/workflows/fixture.yml" <<<"$eligibility" || {
    printf 'eligibility set missing .github/workflows/fixture.yml: %s\n' "$eligibility" >&2
    return 1
  }

  [ -z "$review" ] || {
    printf 'review-scope set should be empty with no TS/TSX committed, got: %s\n' "$review" >&2
    return 1
  }
}

@test "the review-scope fence is untouched by the eligibility widening" {
  local repo fence pathspec_count base expected got

  repo="$(make_repo review-scope-untouched)"
  git -C "$repo" checkout -q -b feat
  mkdir -p "$repo/app"
  printf 'export const a = 1\n' > "$repo/app/a.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add a.ts"

  fence="$(extract_base_fence "$AGENTS_DIR/code-audit-frontend.md")" || {
    echo "exactly one BASE_SHA-assigning fence no longer resolves" >&2
    return 1
  }

  pathspec_count="$(grep -oF -- "'*.ts' '*.tsx'" <<<"$fence" | wc -l | tr -d ' ')"
  [ "$pathspec_count" -eq 1 ] || {
    printf "expected exactly one '*.ts' '*.tsx' pathspec in the review-scope fence, found %s\n" "$pathspec_count" >&2
    return 1
  }

  base="$(base_sha_for code-audit-frontend "$repo")"
  [ -n "$base" ]
  expected="$(git -C "$repo" diff --name-only "${base}...HEAD" -- '*.ts' '*.tsx')"
  got="$(fence_eval code-audit-frontend "$repo" 'printf "%s\n" "${changed:-}"')"
  [ "$got" = "$expected" ] || {
    printf 'review-scope fence produced %s, expected %s\n' "$got" "$expected" >&2
    return 1
  }
}

@test "the eligibility fence carries no empty-base guard" {
  local repo rc full_changed

  repo="$(make_no_base_repo)"

  rc=0
  full_changed="$(elig_eval code-audit-frontend "$repo" 'printf "%s\n" "${full_changed:-}"' 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || {
    printf 'eligibility fence exited %s on an unresolvable base, expected 0: %s\n' "$rc" "$full_changed" >&2
    return 1
  }
  [ -z "$full_changed" ] || {
    printf 'expected an empty eligibility set on an unresolvable base, got: %s\n' "$full_changed" >&2
    return 1
  }
}

# assert_write_verify_agree <acting-root> <label>
#
# Drives the agent's eligibility fence (write side) and the shared library's
# _disposition_changed_set (verify side) against the SAME acting root and
# asserts the two changed-file sets are byte-identical. The library is
# sourced from THIS repo's own copy (never the scratch repo's): it is pure
# git plumbing parameterized entirely by its <acting-root> argument, and the
# question here is agreement on that root's diff, not the library's own
# portability.
#
# Normalization, per README.md frozen contract A: the write side holds
# full_changed in a shell VARIABLE, which cannot carry a NUL, so its
# `-z`-delimited diff is piped through `tr '\0' '\n'` before the variable is
# ever assigned. The verify side writes its NUL-delimited set to a file, kept
# on disk so the NULs survive, and is normalized here with the same `tr`. The
# two sides agree on paths and order and differ only in delimiter; that
# normalization is the whole of this helper, not a shortcut around it. A path
# containing a literal newline is the accepted, named limitation on both
# sides (see the fence's own comment).
assert_write_verify_agree() {
  local root="$1" label="$2" write verify outfile

  write="$(elig_eval code-audit-frontend "$root" 'printf "%s\n" "${full_changed:-}"')" || {
    echo "$label: the eligibility fence failed to run" >&2
    return 1
  }

  outfile="$BATS_TEST_TMPDIR/verify-changed-${label}"
  ( . "$REPO_ROOT/.claude/hooks/lib/audit-dispositions.sh" && _disposition_changed_set "$root" "$outfile" ) || {
    echo "$label: _disposition_changed_set failed to resolve a base" >&2
    return 1
  }
  verify="$(tr '\0' '\n' < "$outfile")"

  [ "$write" = "$verify" ] || {
    printf '%s: write side and verify side disagree.\nwrite:\n%s\nverify:\n%s\n' "$label" "$write" "$verify" >&2
    return 1
  }
}

@test "the write side and the verify side agree across three repository shapes" {
  local repo wt

  repo="$(make_repo elig-agreement)"
  git -C "$repo" checkout -q -b origin-sim
  commit_file "$repo" "docs/origin-only.md" "a commit only origin/main will carry"
  git -C "$repo" checkout -q main
  commit_file "$repo" "docs/main-advance.md" "advance local main past origin/main"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "docs/note.md" "feat's own commit"

  # Shape 1: refs/remotes/origin/HEAD set, built from a remote-tracking ref
  # rather than a real remote (origin/HEAD only ever needs to resolve, never
  # to fetch). origin/main points at origin-sim, which shares no ancestry
  # with feat's actual fork point (local main) beyond their common root, so
  # the origin/<name> arm and the bare <name> arm resolve to two DIFFERENT
  # commits here. Swapping which arm is tried first therefore changes
  # FULL_BASE, which is exactly what this shape exists to catch.
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/origin-sim
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  assert_write_verify_agree "$repo" "origin-head-set"

  # Shape 2: the same repository without it. Removing both the symref and the
  # tracking ref falls the default-branch probe back to the literal `main`,
  # and only the bare `<name>` merge-base arm can resolve: no origin/main ref
  # exists anymore to satisfy the first.
  git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD
  git -C "$repo" update-ref -d refs/remotes/origin/main
  assert_write_verify_agree "$repo" "no-origin-refs"

  # Shape 3: a linked worktree. The diff belongs to the tree that holds HEAD,
  # the same acting-tree requirement the gates carry, so both sides read the
  # worktree's own root, never the main tree's.
  wt="$BATS_TEST_TMPDIR/elig-agreement-wt"
  git -C "$repo" worktree add -q -b wt-feat "$wt" main
  commit_file "$wt" "docs/wt-note.md" "the worktree's own commit"
  assert_write_verify_agree "$wt" "worktree"
}
