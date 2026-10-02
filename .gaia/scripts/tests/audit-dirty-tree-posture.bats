#!/usr/bin/env bats
# The Code Audit Team's dirty-tree posture, held across every member.
#
# A member's clearance marker attests to a per-member content digest computed
# over tracked files AT HEAD (`git ls-tree HEAD`,
# .claude/hooks/lib/audit-digest.sh), while the member reviews a file by
# `Read`ing it, which returns WORKING-TREE bytes. On a dirty tree those two
# disagree, so a pass that reviews the working copy can write a marker
# certifying content nobody read. The posture that closes it is a refusal: the
# scope resolver every member runs (.gaia/scripts/audit-resolve-scope.sh)
# checks `git status --porcelain` over that member's OWN review list right after
# resolving it and prints one `DIRTY=` line per dirty entry, and a gating member
# refuses the pass on any such line.
#
# Scoping the check to the review list rather than the whole tree is
# load-bearing in both directions. It is wide enough, because that list is
# exactly the set the member reads and certifies. And it is narrow enough that a
# sibling member self-healing in a different remit, which is legitimate and
# expected under concurrent dispatch, cannot refuse this member's pass.
#
# The suite holds the posture in two halves. The check itself is code, so it is
# driven BEHAVIOURALLY: each member's own resolver invocation, lifted out of its
# definition, runs against a fixture with a dirty in-scope file, a clean tree, a
# dirty out-of-scope file, and a git whose `status` fails. The refusal contract
# is agent-executed instruction prose, so it is held STRUCTURALLY, in the shape
# of audit-guard-structural.bats: every member invokes the resolver ahead of the
# contract that consumes its output, and carries the same contract. Every pin
# carries its own non-vacuity proof at the bottom of this file; see the comment
# there for why those are meaning-changing edits rather than deletions of the
# pinned string.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh"

  # The Code Audit Team members. The list is spelled out rather than
  # globbed: a glob would silently pass if a member file were renamed away,
  # which is the fail-open this suite exists to prevent. The entries are the
  # authority on how many; deliberately no ROSTER count here or in any comment
  # or test name below, because such a count rots the next time a member joins
  # or leaves and the rotted number reads as an assertion nobody has checked.
  MEMBERS="code-audit-frontend
code-audit-github-workflows
code-audit-maintainer-node
code-audit-maintainer-shell"

  # The members whose clearance actually gates a merge. Currently every
  # roster member, so GATING equals MEMBERS; kept as a separate name because
  # the split (and the withhold contract it names) is a roster property, not
  # an accident of how many members exist today.
  GATING="$MEMBERS"

  # The detection line, pinned in the one place it now lives. One line on
  # purpose: a wrapped command cannot be asserted with a fixed-string grep. The
  # behavioural tests below are what prove it runs over the right list; this
  # pin is what makes a change to the status call itself visible.
  CHECK_LINE='if ! printf '"'"'%s\0'"'"' "${changed[@]}" | xargs -0 git -C "$root" status --porcelain -z -- > "$ars_temporary_directory/dirty"; then'

  # The print of the result to stderr, beside the DIRTY= lines on stdout.
  PRINT_LINE='printf '"'"'%s\n'"'"' "${dirty[@]}" >&2'

  # The sentinel the remit filter must never discard, and the artifact rule that
  # keeps a withheld pass from stranding a digest-keyed refusal across a revert.
  SENTINEL_CARVEOUT='is a sentinel rather than a path and withholds unconditionally'
  NO_REFUSAL_ARTIFACT='**Withhold without writing a `.refused` artifact.**'

  # The assignment that PRODUCES the sentinel the carve-out above protects.
  # Pinned separately because the two say different things: SENTINEL_CARVEOUT
  # pins the prose promising the sentinel is never remit-filtered, and
  # CHECK_LINE pins only the `if` that detects the failure. Matched without
  # leading indentation: the content is what must not drift.
  SENTINEL_LINE='dirty=("dirty-scope check failed")'

  # The byte-identical refusal contract.
  REFUSAL='**Any `DIRTY=` line WITHHOLDS this pass.**'

  # The obligation the refusal owes, pinned separately from the sentence that
  # opens it. A refusal that briefs nothing blocks a merge no one can clear, so
  # the sidecar write is the load-bearing half.
  SIDECAR_CLAUSE='write the findings sidecar naming each dirty path'

  # The run-order anchor, so the refusal is reachable from the member's own
  # order of operations rather than stated only beside the resolver command. The
  # specialists carry it in Methodology step 1; the default member's scope run
  # order lives under "Rules-Based Audit" -> "How to run". The two phrase the
  # condition differently, so the pin is the verb both share.
  METHOD_ANCHOR='refuse the pass on any `DIRTY=` line'
}

member_path() {
  printf '%s/.claude/agents/%s.md' "$REPO_ROOT" "$1"
}

# resolver_invocation FILE: the scope-resolver command inside FILE's bash
# fences, one per line. Fence-scoped so a prose mention of the script cannot
# stand in for the command the member actually runs.
resolver_invocation() {
  awk '/^```bash$/ { in_bash_fence = 1; next } /^```$/ { in_bash_fence = 0 } in_bash_fence && /^<root>\/\.gaia\/scripts\/audit-resolve-scope\.sh --member / { print }' "$1"
}

# --- Behavioural fixture -----------------------------------------------------

# make_repo NAME [SCRIPT_SRC]: a committed repo carrying the resolver and
# everything it reaches for, on a feature branch that changed app/a.ts, with
# other/untouched.md committed on the base. SCRIPT_SRC overrides the resolver
# copied in, which is how the behavioural non-vacuity control runs a mutant.
make_repo() {
  local name="$1" script_source_path="${2:-$SCRIPT}"
  local repository_directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$repository_directory/.gaia/scripts" "$repository_directory/.gaia/local/audit" \
    "$repository_directory/.github/audit" "$repository_directory/.claude/hooks/lib" "$repository_directory/other" "$repository_directory/app"
  cp "$script_source_path" "$repository_directory/.gaia/scripts/audit-resolve-scope.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$repository_directory/.gaia/scripts/"
  chmod +x "$repository_directory/.gaia/scripts/audit-resolve-scope.sh" "$repository_directory/.gaia/scripts/audit-scope-digest.sh"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$repository_directory/.github/audit/"
  chmod +x "$repository_directory/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$repository_directory/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" \
    "$repository_directory/.claude/hooks/lib/"
  printf '2.0.0\n' > "$repository_directory/.gaia/VERSION"
  printf 'base\n' > "$repository_directory/other/untouched.md"
  git -C "$repository_directory" init -q --initial-branch=main
  git -C "$repository_directory" config user.email t@example.com
  git -C "$repository_directory" config user.name T
  git -C "$repository_directory" config commit.gpgsign false
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit -q -m init
  git -C "$repository_directory" checkout -q -b feat
  printf 'change\n' > "$repository_directory/app/a.ts"
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit -q -m "touch app/a.ts"
  printf '%s' "$(cd "$repository_directory" && pwd -P)"
}

# run_member_resolver MEMBER REPO: runs MEMBER's own resolver invocation, as its
# definition spells it, with <root> substituted by REPO. Output lands in bats'
# $output / $stderr / $status.
run_member_resolver() {
  local member="$1" repo="$2" resolver_command
  resolver_command="$(resolver_invocation "$(member_path "$member")")"
  [ -n "$resolver_command" ] || { echo "no resolver invocation in $member" >&2; return 1; }
  resolver_command="${resolver_command//<root>/$repo}"
  run --separate-stderr bash -c "$resolver_command"
}

# failing_status_shim DIR: a git that fails only `status`, so every other call
# the resolver makes runs for real and a sentinel can only come from the check.
failing_status_shim() {
  local shim="$1"
  mkdir -p "$shim"
  cat > "$shim/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do [ "\$argument" = status ] && exit 128; done
exec $(command -v git) "\$@"
EOF
  chmod +x "$shim/git"
}

# --- Structural pins ----------------------------------------------------------

@test "every member file exists" {
  for member_name in $MEMBERS; do
    [ -f "$(member_path "$member_name")" ] || return 1
  done
}

@test "every member runs the scope resolver, exactly once, under its own member name" {
  local member_name resolver_command invocation_count
  for member_name in $MEMBERS; do
    resolver_command="$(resolver_invocation "$(member_path "$member_name")")"
    invocation_count="$(printf '%s' "$resolver_command" | grep -c 'audit-resolve-scope' || true)"
    [ "$invocation_count" -eq 1 ] || { echo "$member_name: expected one resolver invocation in a bash fence, found $invocation_count" >&2; return 1; }
    grep -qF -- "--member $member_name --root <root>" <<<"$resolver_command" || {
      echo "$member_name: resolver invocation does not name its own member and root: $resolver_command" >&2
      return 1
    }
  done
}

@test "the dirty-scope check lives once, in the resolver, and no member carries a private copy" {
  local member_name check_copy_count
  check_copy_count="$(grep -cF -- "$CHECK_LINE" "$SCRIPT" || true)"
  [ "$check_copy_count" -eq 1 ] || { echo "resolver carries the dirty-scope check $check_copy_count times" >&2; return 1; }
  for member_name in $MEMBERS; do
    grep -qE 'status --porcelain' "$(member_path "$member_name")" && {
      echo "$member_name derives its own dirty-scope check beside the resolver's" >&2
      return 1
    }
  done
  true
}

@test "every GATING member carries the byte-identical withhold contract" {
  for member_name in $GATING; do
    assert_carries "$(member_path "$member_name")" "$REFUSAL" || {
      echo "missing or drifted refusal contract: $member_name" >&2
      return 1
    }
  done
}

@test "the resolver runs before the dirty contract that reads its output" {
  local member_name member_file needle invocation_line contract_line
  for member_name in $MEMBERS; do
    member_file="$(member_path "$member_name")"
    needle="$REFUSAL"
    invocation_line="$(grep -nF -- "<root>/.gaia/scripts/audit-resolve-scope.sh --member $member_name" "$member_file" | head -1 | cut -d: -f1)"
    contract_line="$(grep -nF -- "$needle" "$member_file" | head -1 | cut -d: -f1)"
    [ -n "$invocation_line" ] || { echo "no resolver invocation found: $member_name" >&2; return 1; }
    [ -n "$contract_line" ] || { echo "no dirty contract found: $member_name" >&2; return 1; }
    [ "$contract_line" -gt "$invocation_line" ] || {
      echo "dirty contract precedes the resolver it reads: $member_name" >&2
      return 1
    }
  done
}

@test "every GATING member names the refusal in its run order" {
  for member_name in $GATING; do
    assert_carries "$(member_path "$member_name")" "$METHOD_ANCHOR" || {
      echo "run order does not name the refusal: $member_name" >&2
      return 1
    }
  done
}

@test "the resolver assigns the fail-closed sentinel" {
  assert_carries "$SCRIPT" "$SENTINEL_LINE" || {
    echo "fail-closed arm produces no sentinel to withhold on" >&2
    return 1
  }
}

@test "the resolver prints the result it computed to stderr" {
  assert_carries "$SCRIPT" "$PRINT_LINE" || {
    echo "computes the dirty set and never prints it to stderr" >&2
    return 1
  }
}

@test "every GATING member exempts the failure sentinel from the remit filter" {
  for member_name in $GATING; do
    assert_carries "$(member_path "$member_name")" "$SENTINEL_CARVEOUT" || {
      echo "fail-closed sentinel is filterable away: $member_name" >&2
      return 1
    }
  done
}

@test "every GATING member withholds without stranding a refusal artifact" {
  for member_name in $GATING; do
    assert_carries "$(member_path "$member_name")" "$NO_REFUSAL_ARTIFACT" || {
      echo "does not forbid the digest-keyed refusal artifact: $member_name" >&2
      return 1
    }
  done
}

@test "the refusal briefs: every member owes the sidecar on the dirty path" {
  for member_name in $MEMBERS; do
    assert_carries "$(member_path "$member_name")" "$SIDECAR_CLAUSE" || {
      echo "refusal does not oblige the findings sidecar: $member_name" >&2
      return 1
    }
  done
}

# --- Behavioural: each member's own invocation --------------------------------

@test "every member's resolver reports a dirty in-scope file as a DIRTY line" {
  local member_name repo
  repo="$(make_repo dirty-in-scope)"
  printf 'edit\n' >> "$repo/app/a.ts"
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY= M app/a.ts' <<<"$output" || { echo "$member_name: no DIRTY line for a dirty in-scope file" >&2; return 1; }
    grep -qF 'DIRTY IN REVIEW SCOPE:' <<<"$stderr" || { echo "$member_name: dirty set never reached stderr" >&2; return 1; }
  done
}

@test "every member's resolver reports nothing on a clean review list" {
  local member_name repo
  repo="$(make_repo clean)"
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$member_name: DIRTY line on a clean tree" >&2; return 1; }
    true
  done
}

@test "a dirty file outside the review list cannot refuse the pass" {
  local member_name repo
  repo="$(make_repo dirty-out-of-scope)"
  printf 'edit\n' >> "$repo/other/untouched.md"
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$member_name: a sibling's dirt outside the review list reached DIRTY" >&2; return 1; }
    true
  done
}

@test "every member's resolver fails closed to the sentinel when status cannot run" {
  local member_name repo shim="$BATS_TEST_TMPDIR/shim"
  repo="$(make_repo status-fails)"
  failing_status_shim "$shim"
  for member_name in $MEMBERS; do
    PATH="$shim:$PATH" run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY=dirty-scope check failed' <<<"$output" || {
      echo "$member_name: a status that could not run read as a clean tree" >&2
      return 1
    }
  done
}

# --- Non-vacuity ------------------------------------------------------------
#
# These prove the pins above are worth something, and they are deliberately NOT
# "delete the pinned string, confirm it is gone". That form is a tautology: it
# can only fail if `grep -v` is broken, so it holds for any pin however weak.
#
# Each proof instead applies a MEANING-CHANGING edit to a COPY of a real member
# or of the resolver and requires the pin to stop holding. A pin strong enough
# to be worth having breaks under it; a pin weakened to some short common
# substring survives the edit and the proof reds. Tracked files are never
# touched.

# assert_carries FILE NEEDLE: the single definition of "this file satisfies the
# pin". Both the real tests and the mutants call THIS function, so a mutant
# cannot pass by exercising a re-implementation of the check.
assert_carries() {
  grep -qF -- "$2" "$1"
}

# mutate_copy SOURCE_PATH TAG SED_EXPR NEEDLE: copy SOURCE_PATH, confirm the copy satisfies
# NEEDLE before the edit (so a red is the mutation talking, not a broken
# fixture), apply the edit, and print the mutant's path.
mutate_copy() {
  local source_path="$1" tag="$2" sed_expression="$3" needle="$4" mutant_path="$BATS_TEST_TMPDIR/mutant-$2"
  cp "$source_path" "$mutant_path"
  assert_carries "$mutant_path" "$needle" || {
    echo "fixture broken: pin does not hold before mutation ($tag)" >&2
    return 1
  }
  sed "$sed_expression" "$mutant_path" > "$mutant_path.new" && mv "$mutant_path.new" "$mutant_path"
  printf '%s' "$mutant_path"
}

# assert_pin_breaks SOURCE_PATH TAG SED_EXPR NEEDLE: the whole shape in one line.
assert_pin_breaks() {
  local mutant
  mutant="$(mutate_copy "$1" "$2" "$3" "$4")" || return 1
  # Bad case written as a positive match per the bats-assertions rule.
  assert_carries "$mutant" "$4" && {
    echo "pin still holds after a meaning-changing edit; it is too weak to assert the posture ($2)" >&2
    return 1
  }
  return 0
}

@test "the check pin breaks when the status call changes meaning (non-vacuity)" {
  # --untracked-files=no narrows what the check can see.
  assert_pin_breaks "$SCRIPT" check 's|status --porcelain -z -- >|status --porcelain -z --untracked-files=no -- >|' "$CHECK_LINE"
}

@test "the refusal pin breaks when the refusal becomes a warning (non-vacuity)" {
  assert_pin_breaks "$(member_path code-audit-maintainer-shell)" refusal 's|WITHHOLDS this pass|is worth noting|' "$REFUSAL"
}

@test "the print pin breaks when the result stops reaching stderr (non-vacuity)" {
  assert_pin_breaks "$SCRIPT" print 's|"${dirty\[@\]}" >&2|"${dirty[@]}"|' "$PRINT_LINE"
}

@test "the sentinel-assignment pin breaks when the arm stops failing closed (non-vacuity)" {
  assert_pin_breaks "$SCRIPT" sentinel_line 's|dirty=("dirty-scope check failed")|dirty=()|' "$SENTINEL_LINE"
}

@test "the fail-closed behaviour reds when the resolver's sentinel is emptied (non-vacuity)" {
  # The behavioural half's own control: the same mutation as above, run rather
  # than grepped. A resolver that keeps its warning but assigns nothing reports
  # a clean tree on a status that could not run, and the behavioural test's
  # assertion must see that.
  local mutant repo shim="$BATS_TEST_TMPDIR/shim-mutant"
  mutant="$(mutate_copy "$SCRIPT" sentinel_run 's|dirty=("dirty-scope check failed")|dirty=()|' "$SENTINEL_LINE")" || return 1
  repo="$(make_repo status-fails-mutant "$mutant")"
  failing_status_shim "$shim"
  PATH="$shim:$PATH" run_member_resolver code-audit-maintainer-shell "$repo" || return 1
  [ "$status" -eq 0 ] || { echo "mutant resolver exited $status: $stderr" >&2; return 1; }
  grep -qxF 'DIRTY=dirty-scope check failed' <<<"$output" && {
    echo "the sentinel assertion still holds against a resolver that no longer fails closed" >&2
    return 1
  }
  true
}

@test "the dirty-in-scope behaviour reds when the check stops running (non-vacuity)" {
  local mutant repo
  mutant="$(mutate_copy "$SCRIPT" check_run 's|if \[ "${#changed\[@\]}" -gt 0 \]; then|if false; then|' 'if [ "${#changed[@]}" -gt 0 ]; then')" || return 1
  repo="$(make_repo dirty-mutant "$mutant")"
  printf 'edit\n' >> "$repo/app/a.ts"
  run_member_resolver code-audit-maintainer-shell "$repo" || return 1
  [ "$status" -eq 0 ] || { echo "mutant resolver exited $status: $stderr" >&2; return 1; }
  grep -qxF 'DIRTY= M app/a.ts' <<<"$output" && {
    echo "the DIRTY assertion still holds against a resolver whose check never runs" >&2
    return 1
  }
  true
}

@test "the sentinel pin breaks when the carve-out is softened (non-vacuity)" {
  assert_pin_breaks "$(member_path code-audit-maintainer-shell)" sentinel 's|withholds unconditionally|is worth a look|' "$SENTINEL_CARVEOUT"
}

@test "the artifact pin breaks when the prohibition is softened (non-vacuity)" {
  assert_pin_breaks "$(member_path code-audit-maintainer-shell)" artifact 's|Withhold without writing|Consider not writing|' "$NO_REFUSAL_ARTIFACT"
}

@test "the sidecar pin breaks when the obligation is softened (non-vacuity)" {
  assert_pin_breaks "$(member_path code-audit-maintainer-shell)" sidecar 's|write the findings sidecar naming each dirty path|mention the dirty paths somewhere|' "$SIDECAR_CLAUSE"
}

@test "the run-order pin breaks when the anchor stops refusing (non-vacuity)" {
  assert_pin_breaks "$(member_path code-audit-maintainer-shell)" anchor 's|refuse the pass|warn|g' "$METHOD_ANCHOR"
}
