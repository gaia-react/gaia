#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-audit-base-derivation.sh, the
# static check keeping the five Code Audit Team definitions on one review
# base. The behavioral suite next door
# (.gaia/scripts/tests/audit-base-agreement.bats) proves the five agree by
# executing their real snippets; this one proves the STATIC check that stops
# them drifting apart actually fires, which a green run can never show on
# its own.
#
# Every test except the two marked "real repo" drives the check against a
# FIXTURE tree it builds, never the real repo, so "would this shape fail the
# check" is answerable without doctoring tracked source.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-audit-base-derivation.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-audit-base-derivation.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-audit-base-derivation.sh
  source "$CHECK"
}

# Fixtures live under $BATS_TEST_TMPDIR, which bats removes after each test,
# so this file keeps no cleanup bookkeeping of its own (the sibling
# audit-base-agreement.bats does the same). A tracked list would not work
# here anyway: every call site is a command substitution, so an append made
# inside this function lands in a subshell copy and never reaches teardown.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude/agents"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf '%s' "$dir"
}

write_agent_file() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" > "$repo/.claude/agents/$name"
}

commit_fixture_repo() {
  local repo="$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fixture
}

# ---------- fixture content ----------

CONVERTED_OK='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
```
'

# The unbraced `"$BASE_REF"` spelling, inside a markdown code span rather than
# a fence. Both shapes are reachable in an agent definition, which is prose
# carrying code, so the exemption has to hold for either. `$` is the character
# that has to clear the left-edge boundary here, where the fenced form above
# clears it on `{`.
BASE_REF_UNBRACED='Agent prose, per .github/audit/resolve-audit-base.sh.
From the same resolved base, compute `BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "$BASE_REF" HEAD 2>/dev/null || true)"`, then the key.
'

DRIFTED_BARE_MERGE_BASE='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

DRIFTED_LOWERCASE_ALIAS='Agent prose.
```bash
base=$(git merge-base HEAD "origin/main")
```
Derived per .github/audit/resolve-audit-base.sh.
'

NAMES_BASE_SHA_NO_RESOLVER='Pass the same `BASE_SHA` you already resolved at the start of the run.
'

UNRELATED_FILE='This agent never resolves a review base at all.
'

FULL_BASE_ONLY='```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
'

# The same drift as DRIFTED_BARE_MERGE_BASE, in the NON-origin form the real
# FULL_BASE line already carries as its own fallback arm. A pattern keyed to
# `origin/` alone matches nothing here, so the drift goes uncounted while
# assertion 2 still passes (the prose does name the resolver) and the check
# reports a clean tree.
DRIFTED_BARE_MERGE_BASE_NO_ORIGIN='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "${default_branch}" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# The same drift again, naming the branch as a bare literal. This is the form
# that defeats enumerating bad shapes in the ERE: `main` occurs in ordinary
# English inside these files, so a pattern carrying it reds a correct tree.
# Only the positive BASE_REF rule catches this one.
DRIFTED_BARE_LITERAL_BRANCH='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD main 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# FULL_BASE owns the FIRST merge-base on the line and a drifted BASE_SHA owns
# the SECOND. An ownership rule reading only the first occurrence clears the
# whole line on FULL_BASE'"'"'s exemption and never sees the second call.
TWO_CALLS_ONE_LINE='Agent prose.
```bash
FULL_BASE=$(git merge-base HEAD "origin/${default_branch}") ; BASE_SHA=$(git merge-base HEAD "${default_branch}")
```
Derived per .github/audit/resolve-audit-base.sh.
'

# A drifted call sharing its LINE with a legitimate BASE_REF assignment. The
# BASE_REF exemption has to bind to a call's own argument list: a line-wide
# test clears this whole line on the mention alone, which is the same
# unsoundness TWO_CALLS_ONE_LINE pins for the FULL_BASE exemption.
DRIFT_BESIDE_BASE_REF='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)" ; BASE_SHA=$(git merge-base HEAD "origin/${default_branch}")
```
'

# The same escape via a trailing comment rather than a second command. The
# stop set is what keeps `# was BASE_REF` from vouching for the call.
DRIFT_WITH_BASE_REF_COMMENT='Agent prose.
```bash
BASE_SHA=$(git merge-base HEAD "origin/${default_branch}")  # was BASE_REF, simplified
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# A drifted call whose `$( )` has already CLOSED before BASE_REF appears.
# The stop set has to end the argument list at `)`, not just at a command or
# comment boundary: prose describing the retired form mentions BASE_REF after
# the call, and the file IS the instruction, so the line still reds.
DRIFT_BASE_REF_AFTER_CLOSE='Agent prose.
The retired form was BASE_SHA=$(git merge-base HEAD main), now BASE_REF.
'

# A drifted call routed through a variable whose name merely ENDS in
# BASE_REF. The exemption is a rule about the token identity, not its
# presence, so a bare-substring test accepts the tail of a longer identifier
# and clears exactly the derivation it exists to reject. `GITHUB_BASE_REF` is
# the live spelling of this: an ordinary CI variable naming a branch, not an
# invented one.
DRIFT_ALIASED_BASE_REF_SUFFIX='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/$GITHUB_BASE_REF" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

# A drifted call whose exemption token abuts the `)` that closes it. The
# left-edge boundary has to subtract the stop set, not merely require a
# non-identifier character: a bare non-identifier class is a SUPERSET of the
# stop set, so it is satisfied BY that `)` and hands the exemption back on the
# very character the stop set exists to treat as a wall.
DRIFT_BASE_REF_ABUTTING_CLOSE='Agent prose.
The retired form was BASE_SHA=$(git merge-base HEAD main)BASE_REF and nothing else.
'

# ---------- assertion 1: no bare-merge-base review derivation ----------

@test "fixture: a converted file (FULL_BASE plus a resolver-derived BASE_SHA) passes clean" {
  local repo
  repo="$(make_fixture_repo converted-ok)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$CONVERTED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: a BASE_SHA derived by a bare merge-base fails assertion 1" {
  local repo
  repo="$(make_fixture_repo drifted-bare)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
  # Assertion 2 is satisfied here (the file does name the resolver), so this
  # red is assertion 1's alone -- the two are independently reportable.
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: a lowercase alias for the same bare derivation fails assertion 1" {
  local repo
  repo="$(make_fixture_repo drifted-alias)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DRIFTED_LOWERCASE_ALIAS"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: the non-origin bare merge-base form fails assertion 1 too" {
  local repo
  repo="$(make_fixture_repo drifted-bare-no-origin)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE_NO_ORIGIN"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: a drifted BASE_SHA sharing a line with FULL_BASE is still counted" {
  local repo
  repo="$(make_fixture_repo two-calls-one-line)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$TWO_CALLS_ONE_LINE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: a bare literal branch name in the merge-base fails assertion 1" {
  local repo
  repo="$(make_fixture_repo drifted-bare-literal)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DRIFTED_BARE_LITERAL_BRANCH"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: a drifted call sharing a line with BASE_REF is still counted" {
  local repo
  repo="$(make_fixture_repo drift-beside-base-ref)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFT_BESIDE_BASE_REF"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: a trailing BASE_REF comment does not vouch for a drifted call" {
  local repo
  repo="$(make_fixture_repo drift-base-ref-comment)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DRIFT_WITH_BASE_REF_COMMENT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: a BASE_REF named after the call closes does not exempt it" {
  local repo
  repo="$(make_fixture_repo drift-base-ref-after-close)"
  write_agent_file "$repo" code-audit-github-workflows.md "$DRIFT_BASE_REF_AFTER_CLOSE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: an alias whose name ends in BASE_REF does not exempt a drifted call" {
  local repo
  repo="$(make_fixture_repo drift-aliased-base-ref-suffix)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFT_ALIASED_BASE_REF_SUFFIX"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
  # Assertion 2 is satisfied (the prose names the resolver), so the exemption
  # boundary is the only thing this red can be coming from.
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: a boundary landing on the call-closing paren does not exempt it" {
  local repo
  repo="$(make_fixture_repo drift-base-ref-abutting-close)"
  write_agent_file "$repo" code-audit-github-workflows.md "$DRIFT_BASE_REF_ABUTTING_CLOSE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: the canonical resolver-derived call is still exempt on both spellings" {
  # The other half of the boundary. A left-edge rule that reds the alias above
  # but also reds `"${BASE_REF}"` or `"$BASE_REF"` would have closed the
  # escape by retiring the exemption, which is a different check.
  local repo
  repo="$(make_fixture_repo base-ref-both-spellings)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$CONVERTED_OK"
  write_agent_file "$repo" code-audit-frontend.md "$BASE_REF_UNBRACED"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

@test "fixture: the FULL_BASE self-skip derivation is exempt and never counted" {
  local repo
  repo="$(make_fixture_repo full-base-only)"
  write_agent_file "$repo" code-audit-github-workflows.md "$FULL_BASE_ONLY"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

# KEY_BASE joins FULL_BASE in the by-name exemption (contract F). Its call
# passes KEY_REF rather than BASE_REF, so the positive BASE_REF rule cannot
# exempt it on its own; only the by-name check can, and only for the exact
# name, not a lookalike.
KEY_BASE_DERIVED_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
KEY_REF="$BASE_REF"
KEY_BASE="$(git -C "$AUDIT_ROOT" merge-base "${KEY_REF}" HEAD 2>/dev/null || true)"
```
'

# A variable that merely resembles KEY_BASE. The exemption is by name, so this
# must still fail: widening it to "anything that looks like a key base" would
# reopen the hole the by-name rule exists to close.
SOME_OTHER_BARE_MERGE_BASE='Agent prose.
```bash
SOME_OTHER=$(git merge-base HEAD main)
```
Derived per .github/audit/resolve-audit-base.sh.
'

@test "fixture: KEY_BASE derived through KEY_REF is exempt by name, same as FULL_BASE" {
  local repo
  repo="$(make_fixture_repo key-base-derived-ok)"
  write_agent_file "$repo" code-audit-frontend.md "$KEY_BASE_DERIVED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

@test "fixture: a variable merely resembling KEY_BASE is not exempt by name" {
  local repo
  repo="$(make_fixture_repo some-other-bare)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$SOME_OTHER_BARE_MERGE_BASE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

# ---------- assertion 2: every BASE_SHA namer names the resolver ----------

@test "fixture: a file naming BASE_SHA without ever naming the resolver fails assertion 2" {
  local repo
  repo="$(make_fixture_repo names-base-no-resolver)"
  write_agent_file "$repo" some-agent.md "$NAMES_BASE_SHA_NO_RESOLVER"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "names BASE_SHA but never names resolve-audit-base.sh: .claude/agents/some-agent.md" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 1" <<<"$output" || return 1
  # ...and assertion 1 stays clean, because dropping the reference removes a
  # line rather than adding a bad one. This is the case assertion 1 cannot
  # see, which is why both run.
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

@test "fixture: a file that never names BASE_SHA is never required to name the resolver" {
  local repo
  repo="$(make_fixture_repo unrelated)"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: multiple violations across files are all named, and the check still fails once" {
  local repo
  repo="$(make_fixture_repo multi)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$NAMES_BASE_SHA_NO_RESOLVER"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "unrelated.md" <<<"$output" && return 1
  return 0
}

# ---------- assertion 3: no diff consumes an un-anchored base ----------
#
# Assertions 1 and 2 police how the base is DERIVED. This one polices what is
# then handed to `git diff`, an independent failure: a file can derive
# BASE_SHA correctly and scope its review off the raw ref one line later.

DIFF_ANCHORED_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}...HEAD" 2>/dev/null || true)
```
'

# The resolver piped straight into the diff, with no merge-base between them.
# `resolve-audit-base.sh` can return a REF, so this scopes the review off a tip
# that may have advanced past the fork point.
DIFF_RESOLVER_DIRECT='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)")
```
'

# The same defect one variable removed: BASE_REF holds the resolver output, so
# consuming it directly is the identical un-anchored diff.
DIFF_BASE_REF_DIRECT='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$BASE_REF")
```
'

# The three-dot requirement binds the CORRECT variable too. A two-dot diff on
# BASE_SHA compares the base to the working tree exactly as one on BASE_REF
# does, so keying the rule to the raw-base spellings alone would let the
# likelier drift through: the member names the right value and still reviews
# the wrong thing.
DIFF_BASE_SHA_TWO_DOT='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}" -- "*.ts")
```
'

# The same two-dot defect written as a markdown code span rather than a fence,
# which is how a definition restates its scope in prose. A restatement that
# drifts from the fence is still an instruction a model can follow.
DIFF_BASE_SHA_TWO_DOT_SPAN='The set is the exact `git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}" -- "*.ts"` list the audit resolved, per .github/audit/resolve-audit-base.sh.
'

# A three-dot range on BASE_REF narrows correctly, since git resolves the merge
# base inside `...`. This assertion is about the range, not about which
# spelling reached it, so this passes.
DIFF_BASE_REF_THREE_DOT_OK='Agent prose.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_REF}...HEAD")
```
'

# A correct call whose trailing comment happens to name BASE_REF. The `...`
# already precedes the token here, so this passes on the range test alone; the
# two fixtures below are the ones that isolate the walls.
DIFF_TRAILING_COMMENT_OK='Agent prose.
```bash
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}...HEAD")   # never BASE_REF here
```
'

# Ordinary prose naming the command and a base in one sentence, which
# .claude/agents/worthiness-evaluator.md really does. No target token follows
# at all, so this passes without either wall.
DIFF_PROSE_MENTION_OK='This agent takes its file list from the orchestrator (or resolves it from `git diff --name-only` against the audit base).
'

# The backtick wall, isolated. The code span CLOSES and the surrounding
# sentence then names BASE_REF, with no `...` anywhere on the line, so the
# range test cannot exempt it and only the wall can. Remove the wall and this
# reads as a raw-base diff, condemning a line that runs no diff at all.
DIFF_SPAN_CLOSES_BEFORE_TARGET_OK='Run `git diff --name-only` yourself only when the orchestrator supplied no list; otherwise the value you want is already in BASE_REF.
'

# The `#` wall, isolated. A legitimate two-dot call on an unrelated revset
# (the staged index), with a trailing comment naming BASE_REF and no `...` on
# the line. Same shape as above on the shell side.
DIFF_TRAILING_COMMENT_NO_RANGE_OK='Agent prose.
```bash
staged=$(git -C "$AUDIT_ROOT" diff --name-only --cached)   # not BASE_REF, deliberately
```
'

# A two-dot call sharing its LINE with a correct three-dot one. The window has
# to end at the NEXT call, or the later call's `...` satisfies the range test
# for the earlier one and the bad call escapes. Bad call FIRST is the ordering
# that requires the wall; the reverse is caught by the walk alone.
TWO_DIFFS_ONE_LINE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git diff --name-only -z "$BASE_SHA") ; full_changed=$(git diff --name-only -z "${FULL_BASE}...HEAD")
```
'

# A `;`-joined line whose trailing command is not a diff call at all and
# carries a `...` of its own. None of the other three walls closes the leading
# call: there is no second `diff --name-only`, no `#`, and no backtick. Without
# a `;` wall the window runs to end of line and the LATER command's range
# vouches for a two-dot call, so the check reports 0 in exactly the case it
# exists to catch. The fixture above needs the call wall; this one needs the
# `;` wall and nothing else can save it.
DIFF_SEMICOLON_LATER_RANGE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "$BASE_SHA") ; echo "${BASE_REF}...HEAD"
```
'

# The self-skip diff, correctly ranged.
DIFF_FULL_BASE_OK='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
full_changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${FULL_BASE}...HEAD" 2>/dev/null || true)
```
'

# The self-skip diff gone two-dot. FULL_BASE is exempt from assertion 1 (it is
# the legitimate bare merge-base) but nothing exempts it here: a working-tree
# comparison decides membership as wrongly as it decides review scope, and a
# member that self-skips on a bad list writes no marker the gate still demands.
DIFF_FULL_BASE_TWO_DOT='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
full_changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${FULL_BASE}" 2>/dev/null || true)
```
'

@test "fixture: a diff anchored on the resolver-derived BASE_SHA passes assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-anchored-ok)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_ANCHORED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: the resolver piped straight into a diff fails assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-resolver-direct)"
  write_agent_file "$repo" code-audit-frontend.md "$DIFF_RESOLVER_DIRECT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
  # Assertions 1 and 2 are both satisfied here (no bare merge-base, and the
  # file never names BASE_SHA), so this red is assertion 3's alone.
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: BASE_REF consumed directly by a diff fails assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-base-ref-direct)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DIFF_BASE_REF_DIRECT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
}

@test "fixture: a two-dot diff on the CORRECT variable still fails assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-base-sha-two-dot)"
  write_agent_file "$repo" code-audit-frontend.md "$DIFF_BASE_SHA_TWO_DOT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
}

@test "fixture: a two-dot diff restated in a code span fails assertion 3 too" {
  local repo
  repo="$(make_fixture_repo diff-base-sha-two-dot-span)"
  write_agent_file "$repo" code-audit-frontend.md "$DIFF_BASE_SHA_TWO_DOT_SPAN"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
}

@test "fixture: a three-dot range anchored on BASE_REF narrows correctly and passes" {
  local repo
  repo="$(make_fixture_repo diff-base-ref-three-dot)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DIFF_BASE_REF_THREE_DOT_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a trailing comment naming BASE_REF does not condemn a correct diff" {
  local repo
  repo="$(make_fixture_repo diff-trailing-comment)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_TRAILING_COMMENT_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: prose naming the command and a base in one sentence is not a call" {
  local repo
  repo="$(make_fixture_repo diff-prose-mention)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DIFF_PROSE_MENTION_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a target named after the code span closes does not condemn the line" {
  local repo
  repo="$(make_fixture_repo diff-span-closes)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DIFF_SPAN_CLOSES_BEFORE_TARGET_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a target named in a trailing comment does not condemn a rangeless call" {
  local repo
  repo="$(make_fixture_repo diff-comment-no-range)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_TRAILING_COMMENT_NO_RANGE_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a two-dot call is not vouched for by a later call's range" {
  local repo
  repo="$(make_fixture_repo diff-two-calls-one-line)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$TWO_DIFFS_ONE_LINE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
}

@test "fixture: a later command on a ;-joined line does not vouch for a two-dot call" {
  local repo
  repo="$(make_fixture_repo diff-semicolon-later-range)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_SEMICOLON_LATER_RANGE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
}

@test "fixture: assertion 3 scans only the code-audit-* roster" {
  # An agent that takes its file list from the orchestrator has no review base,
  # so it is outside this assertion's claim. Pinned because the scan pathspec
  # is narrower than assertions 1 and 2's, which is easy to widen back by
  # accident when adding a fourth.
  local repo
  repo="$(make_fixture_repo diff-non-roster-agent)"
  write_agent_file "$repo" worthiness-evaluator.md "$DIFF_BASE_SHA_TWO_DOT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: the correctly-ranged FULL_BASE self-skip diff passes assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-full-base)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DIFF_FULL_BASE_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a two-dot FULL_BASE self-skip diff fails assertion 3" {
  local repo
  repo="$(make_fixture_repo diff-full-base-two-dot)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DIFF_FULL_BASE_TWO_DOT"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
  # Assertion 1 still exempts the FULL_BASE derivation itself; the two
  # assertions decide independently about the same variable.
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

# ---------- assertion 4: no diff lets git quote the paths it prints ----------
#
# Assertion 3 polices the RANGE a call compares; this one polices the ENCODING
# of what it prints back. Under git's default core.quotePath a correct
# three-dot call still C-quotes any path carrying non-ASCII or control bytes,
# and the quoted token matches no remit glob, so the member self-skips and the
# file merges unaudited. That failure is silent by construction, which is why
# it gets a static assertion rather than a convention.
#
# Every fixture above carries `-z` for the same reason each carries exactly one
# defect: a fixture that reds two assertions cannot show which one caught it.
# They carry the flag alone, not the `| tr` a real derivation also needs, both
# because that is all assertion 4 reads and because a literal single quote
# would end the single-quoted constant holding it.

# The self-skip diff with quoting left on: a correct three-dot range that still
# hands back a quoted token. This is the shape #1213 found live in four members.
DIFF_FULL_BASE_QUOTED='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
full_changed=$(git -C "$AUDIT_ROOT" diff --name-only "${FULL_BASE}...HEAD" 2>/dev/null || true)
```
'

# A quoting call sharing its LINE with a quote-safe one. The window has to end
# at the NEXT call or the later `-z` satisfies the token test for the earlier
# call, which is the same wall assertion 3 needs and the reason both assertions
# run through one walk rather than two copies of it.
TWO_DIFFS_ONE_LINE_ONE_QUOTED='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git diff --name-only "${BASE_SHA}...HEAD") ; full_changed=$(git diff --name-only -z "${FULL_BASE}...HEAD")
```
'

# A quoting call whose line goes on to test the resulting variable for
# emptiness. `[ -z "$changed" ]` is an ordinary thing to write beside a diff,
# and its `-z` is not the diff's, so without the `)` wall the window runs to
# end of line and the emptiness test vouches for a call that quotes. None of
# the other walls closes this: no second call, no comment, no code span.
DIFF_LATER_DASH_Z_ON_LINE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only "${BASE_SHA}...HEAD") && [ -z "$changed" ]
```
'

# Assertion 4 requires TWO things of the token and they need separate fixtures,
# because a mutant that drops one is invisible to a fixture the other already
# rejects. The token is ` -z` with a LEADING SPACE, and the match is ANCHORED at
# the position immediately after the call. Which fixture pins which, stated
# from the mutants rather than from intent:
#
#   - the ANCHOR is pinned by DIFF_DASH_Z_AFTER_PIPE below, the only test that
#     goes green when the anchor alone is dropped;
#   - the LEADING SPACE is pinned by the CORRECT-CALL fixtures, which red when
#     the space alone is dropped, because `-z` unanchored-by-a-space no longer
#     sits at index 1 in a window that opens with one;
#   - this fixture pins NEITHER on its own. It survives both single mutants and
#     turns green only on the both-absent pre-fix spelling, so what it rejects
#     is the original anywhere-in-the-call substring test.
#
# The distinction matters to a later editor: deleting a correct-call fixture on
# the belief that this one covers the space would retire the space's only
# guard.
#
# A quoting call whose PATHSPEC happens to contain the token. `[a-z]` is an
# ordinary character class and it carries `-z` inside it, so a bare
# anywhere-in-the-call substring test vouches for a call that quotes. The `)`
# wall does not help, because the pathspec is inside the call rather than after
# it.
DIFF_DASH_Z_INSIDE_PATHSPEC='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only "${BASE_SHA}...HEAD" -- "app/[a-z]/*")
```
'

@test "fixture: a -z inside a pathspec does not count as the call passing -z" {
  local repo
  repo="$(make_fixture_repo diff-dash-z-in-pathspec)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DIFF_DASH_Z_INSIDE_PATHSPEC"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
  # Correctly ranged, so this red is the anchored token test alone.
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

# A quoting call piping into a command that legitimately takes `-z` of its own.
# The token here is spelled with its leading space, so the space test admits it
# and ONLY the anchor rejects it: this is the fixture that discriminates the
# two mechanisms. `|` is deliberately not a window wall, so ` -z` really does
# land inside this call's window, at an index that is not 1.
DIFF_DASH_Z_AFTER_PIPE='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only "${BASE_SHA}...HEAD" | sort -z)
```
'

@test "fixture: a -z belonging to a piped command does not count as the call passing -z" {
  local repo
  repo="$(make_fixture_repo diff-dash-z-after-pipe)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DIFF_DASH_Z_AFTER_PIPE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
  # Correctly ranged, so this red is the anchor alone. Drop the `anchored`
  # argument at the call site and this is the test that goes green while the
  # pathspec fixture beside it stays red.
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: an unrelated -z later on the line does not vouch for a quoting call" {
  local repo
  repo="$(make_fixture_repo diff-later-dash-z)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_LATER_DASH_Z_ON_LINE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
  # The range is correct, so assertion 3 stays green and this red is the token
  # test catching a call the `)` wall is what scoped correctly.
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

@test "fixture: a base-consuming diff without -z fails assertion 4" {
  local repo
  repo="$(make_fixture_repo diff-full-base-quoted)"
  write_agent_file "$repo" code-audit-github-workflows.md "$DIFF_FULL_BASE_QUOTED"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-github-workflows.md" <<<"$output" || return 1
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
  # The range is correct and the FULL_BASE derivation is exempt from assertion
  # 1, so this red is assertion 4's alone. Without that isolation the test
  # would pass on any red at all, including one it did not cause.
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

@test "fixture: the same self-skip diff carrying -z passes assertion 4" {
  local repo
  repo="$(make_fixture_repo diff-full-base-unquoted)"
  write_agent_file "$repo" code-audit-github-workflows.md "$DIFF_FULL_BASE_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "changed-file diffs that let git C-quote a path: 0" <<<"$output" || return 1
}

@test "fixture: a diff that consumes no base is never required to carry -z" {
  # The `--cached` call reaches no base at all, so assertion 4 has nothing to
  # be about. Without the `consumes` test it would condemn every `git diff` an
  # agent definition happens to mention.
  local repo
  repo="$(make_fixture_repo diff-no-base-no-z)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_TRAILING_COMMENT_NO_RANGE_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "changed-file diffs that let git C-quote a path: 0" <<<"$output" || return 1
}

@test "fixture: a quoting call is not vouched for by a later call's -z" {
  local repo
  repo="$(make_fixture_repo diff-two-calls-one-quoted)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$TWO_DIFFS_ONE_LINE_ONE_QUOTED"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
  # Both calls are correctly ranged, so assertion 3 stays green and the line is
  # condemned by the token test alone.
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
}

# KEY_BASE joined the `consumes` spelling list assertions 3 and 4 share
# (contract F). No real derivation diffs against it today, but the net has to
# catch a future one on the new variable exactly as it catches the other four
# spellings.
DIFF_KEY_BASE_TWO_DOT_NO_Z='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only "${KEY_BASE}" -- x)
```
'

DIFF_KEY_BASE_THREE_DOT_OK='Agent prose, per .github/audit/resolve-audit-base.sh.
```bash
changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${KEY_BASE}...HEAD" -- x)
```
'

@test "fixture: a two-dot, unquoted diff on KEY_BASE fails both assertions 3 and 4" {
  local repo
  repo="$(make_fixture_repo diff-key-base-two-dot)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_KEY_BASE_TWO_DOT_NO_Z"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 1" <<<"$output" || return 1
  grep -qF "changed-file diffs that let git C-quote a path: 1" <<<"$output" || return 1
}

@test "fixture: the three-dot -z form on KEY_BASE passes both assertions 3 and 4" {
  local repo
  repo="$(make_fixture_repo diff-key-base-three-dot)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$DIFF_KEY_BASE_THREE_DOT_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
  grep -qF "changed-file diffs that let git C-quote a path: 0" <<<"$output" || return 1
}

# ---------- real repo: the standing guarantee ----------

@test "real repo: every Code Audit Team definition resolves its review base through the resolver" {
  run gaia_check_audit_base_derivation "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
  grep -qF "review diffs consuming a base that never reached the fork point: 0" <<<"$output" || return 1
  grep -qF "changed-file diffs that let git C-quote a path: 0" <<<"$output" || return 1
}

@test "real repo: every changed-file diff in the roster is a three-dot range and quote-safe" {
  # Assertions 3 and 4 state their rules negatively (counts of violations), so
  # this pins the positive form directly: every `diff --name-only` the five
  # definitions carry inside a fence resolves `<something>...HEAD` and carries
  # `-z`. A definition that drops to two-dot, or that lets git quote what it
  # prints, reds here as well as on the check.
  #
  # The `"?` accepts both spellings of the assignment. Requiring `$(` to sit
  # immediately after the `=` matches the unquoted form alone, so a definition
  # normalized to `changed="$(git ...)"` drops out of the net entirely.
  run git -C "$REPO_ROOT" grep -hIE '^[a-z_]+="?\$\(git .*diff --name-only' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Pin the breadth, not just non-emptiness. `[ -n "$output" ]` is satisfied by
  # any ONE surviving line, so a net that quietly stops covering most of the
  # roster still passes it and the shrink is reported nowhere. A roster change
  # that moves this number is a deliberate update to the number, never a reason
  # to relax the assertion back to non-emptiness.
  # The pin and the message it prints read ONE constant, so an update to the
  # number cannot leave the failure text claiming a different expectation.
  expected_lines=9
  net_lines="$(grep -c . <<<"$output")"
  [ "$net_lines" -eq "$expected_lines" ] || {
    printf 'roster diff-line net covered %s lines, expected %s\n' \
      "$net_lines" "$expected_lines"
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF '...HEAD' <<<"$line" || {
      printf 'changed-file diff is not a three-dot range: %s\n' "$line"
      return 1
    }
    grep -qF -- '--name-only -z' <<<"$line" || {
      printf 'changed-file diff lets git quote the paths it prints: %s\n' "$line"
      return 1
    }
  done <<< "$output"
}

@test "real repo: the guarantee above is not vacuous -- definitions do name BASE_SHA and do keep a FULL_BASE" {
  # Both verdicts are counts of violations, so a scan that saw no candidate
  # at all reports zero and passes. Pin both candidate sets as non-empty: the
  # BASE_SHA namers assertion 2 ranges over, and the exempted FULL_BASE
  # derivation assertion 1 must be deciding about rather than never meeting.
  run git -C "$REPO_ROOT" grep -lIF 'BASE_SHA' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1

  run git -C "$REPO_ROOT" grep -lIE '^FULL_BASE=' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
}

# ---------- structural ----------

@test "a repo_root that is not a git repository reports 2, never a clean 0" {
  local outside="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$outside"
  run gaia_check_audit_base_derivation "$outside"
  # 2, not 1: "the check could not run" is a different answer from "the check
  # says no", and neither is the 0 an unscanned tree used to report.
  [ "$status" -eq 2 ]
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || return 1
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" && {
    echo "printed a clean verdict for a tree it never scanned" >&2
    return 1
  }
  return 0
}

@test "a repo_root that is a subdirectory of a repo reports 2, never a clean 0" {
  # --git-dir alone succeeds from anywhere inside a repo, so this is the case
  # that separates "is in a repo" from "is a repo root". The scan would find
  # no .claude/agents/ beneath a subdirectory and report the same clean 0/0.
  run gaia_check_audit_base_derivation "$REPO_ROOT/.gaia/scripts"
  [ "$status" -eq 2 ]
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || return 1
}

@test "a bare repository and a .git directory both report 2, never a clean 0" {
  # --show-prefix alone clears both (exit 0, empty output). The work-tree
  # check is what separates "has a prefix of empty" from "has a work tree",
  # and without it `git grep` fails below with its diagnostic swallowed.
  local bare="$BATS_TEST_TMPDIR/bare.git"
  git init -q --bare "$bare"
  run gaia_check_audit_base_derivation "$bare"
  [ "$status" -eq 2 ]

  local live
  live="$(make_fixture_repo gitdir-probe)"
  write_agent_file "$live" some-agent.md "$UNRELATED_FILE"
  commit_fixture_repo "$live"
  run gaia_check_audit_base_derivation "$live/.git"
  [ "$status" -eq 2 ]
  grep -qF "is not a git repository root; nothing was scanned" <<<"$output" || return 1
}

@test "structural: check-audit-base-derivation.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_audit_base_derivation with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_audit_base_derivation >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  code_lines="$(grep -vE '^[[:space:]]*#' "$CHECK")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$CHECK" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$CHECK"
}
