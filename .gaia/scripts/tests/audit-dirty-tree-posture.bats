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
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
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
code-audit-maintainer-prose
code-audit-maintainer-shell"

  # The members whose clearance actually gates a merge. They carry the
  # withhold contract. The prose member is deliberately NOT among them: it is
  # advisory-only and its own file states that it always writes an earned
  # marker and never deadlocks a merge. A clearance that always clears attests
  # nothing about content, so withholding there would buy no guarantee while
  # breaking the contract the member exists to keep. It records the divergence
  # instead. Splitting the pins this way is what stops the two contracts from
  # silently contradicting each other.
  GATING="code-audit-frontend
code-audit-github-workflows
code-audit-maintainer-node
code-audit-maintainer-shell"
  ADVISORY="code-audit-maintainer-prose"

  # The advisory member's counterpart pins.
  EXEMPTION='**A `DIRTY=` line does NOT withhold your pass, and the exemption is deliberate.**'
  ADVISORY_ANCHOR='record any `DIRTY=` line'
  ADVISORY_ARTIFACT='**Do not reach for a `.refused` artifact here under any reading:**'

  # The detection line, pinned in the one place it now lives. One line on
  # purpose: a wrapped command cannot be asserted with a fixed-string grep. The
  # behavioural tests below are what prove it runs over the right list; this
  # pin is what makes a change to the status call itself visible.
  CHECK_LINE='if ! printf '"'"'%s\0'"'"' "${changed[@]}" | xargs -0 git -C "$root" status --porcelain -z -- > "$ars_tmp/dirty"; then'

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

  # Withhold-shaped clauses, as an ERE alternation, for the advisory member's
  # drift guard below. This matches an instruction that the member withholds
  # ITS OWN pass, which is the meaning the advisory member must never acquire,
  # rather than the one bolded sentence a byte-identical pin could see.
  #
  # Two spellings are deliberately NOT in it, both because the advisory member
  # carries them legitimately. `write no marker` is its self-skip arm, and an
  # unqualified `withhold` covers its own exemption prose ("why the gating
  # members withhold on it"). Matching the verb plus the thing withheld is what
  # separates an instruction to this member from a description of a sibling.
  #
  # `the` belongs in the determiner class as much as `this` and `your` do:
  # `Withhold the marker on any unresolved Critical…` is a VERBATIM handshake
  # sentence gating members carry, so copy-pasting a sibling's real paragraph is
  # the most probable way this member acquires the contract.
  WITHHOLD_SHAPED='withhold(s|ing)? (this|your|the) (pass|clearance|marker)'

  # The one legitimate form the alternation above still reaches: the exemption
  # sentence's own negation, `does NOT withhold your pass`. The negator is
  # ANCHORED TO THE VERB rather than merely required somewhere nearby, because
  # `never` and `cannot` saturate this prose and an unanchored exclusion
  # discards real withhold clauses beside them (fixtures below).
  WITHHOLD_NEGATED='(does not|never|cannot) +withhold'

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
  awk '/^```bash$/ { f = 1; next } /^```$/ { f = 0 } f && /^<root>\/\.gaia\/scripts\/audit-resolve-scope\.sh --member / { print }' "$1"
}

# withhold_drift FILE: print every withhold-shaped clause in FILE that is not
# the exemption's own negation, one per line with up to 30 characters of
# preceding context. Case insensitive on purpose. Newlines are folded to spaces
# first, because `grep` is line-scoped and a clause split across a line break
# would otherwise be invisible.
withhold_drift() {
  tr '\n' ' ' < "$1" | grep -oiE ".{0,30}$WITHHOLD_SHAPED" | grep -viE "$WITHHOLD_NEGATED"
  # Both greps exit 1 on no match, which is the passing case here, so the
  # function's own status must not carry it into a `set -e` test body.
  return 0
}

# --- Behavioural fixture -----------------------------------------------------

# make_repo NAME [SCRIPT_SRC]: a committed repo carrying the resolver and
# everything it reaches for, on a feature branch that changed app/a.ts, with
# other/untouched.md committed on the base. SCRIPT_SRC overrides the resolver
# copied in, which is how the behavioural non-vacuity control runs a mutant.
make_repo() {
  local name="$1" script_src="${2:-$SCRIPT}"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.gaia/scripts" "$dir/.gaia/local/audit" \
    "$dir/.github/audit" "$dir/.claude/hooks/lib" "$dir/other" "$dir/app"
  cp "$script_src" "$dir/.gaia/scripts/audit-resolve-scope.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-respawn-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$dir/.gaia/scripts/"
  chmod +x "$dir/.gaia/scripts/audit-resolve-scope.sh" "$dir/.gaia/scripts/audit-scope-digest.sh"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$dir/.github/audit/"
  chmod +x "$dir/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$dir/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" \
    "$dir/.claude/hooks/lib/"
  printf '2.0.0\n' > "$dir/.gaia/VERSION"
  printf 'base\n' > "$dir/other/untouched.md"
  git -C "$dir" init -q --initial-branch=main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  git -C "$dir" checkout -q -b feat
  printf 'change\n' > "$dir/app/a.ts"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "touch app/a.ts"
  printf '%s' "$(cd "$dir" && pwd -P)"
}

# run_member_resolver MEMBER REPO: runs MEMBER's own resolver invocation, as its
# definition spells it, with <root> substituted by REPO. Output lands in bats'
# $output / $stderr / $status.
run_member_resolver() {
  local member="$1" repo="$2" cmd
  cmd="$(resolver_invocation "$(member_path "$member")")"
  [ -n "$cmd" ] || { echo "no resolver invocation in $member" >&2; return 1; }
  cmd="${cmd//<root>/$repo}"
  run --separate-stderr bash -c "$cmd"
}

# failing_status_shim DIR: a git that fails only `status`, so every other call
# the resolver makes runs for real and a sentinel can only come from the check.
failing_status_shim() {
  local shim="$1"
  mkdir -p "$shim"
  cat > "$shim/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = status ] && exit 128; done
exec $(command -v git) "\$@"
EOF
  chmod +x "$shim/git"
}

# --- Structural pins ----------------------------------------------------------

@test "every member file exists" {
  for m in $MEMBERS; do
    [ -f "$(member_path "$m")" ] || return 1
  done
}

@test "every member runs the scope resolver, exactly once, under its own member name" {
  local m cmd n
  for m in $MEMBERS; do
    cmd="$(resolver_invocation "$(member_path "$m")")"
    n="$(printf '%s' "$cmd" | grep -c 'audit-resolve-scope' || true)"
    [ "$n" -eq 1 ] || { echo "$m: expected one resolver invocation in a bash fence, found $n" >&2; return 1; }
    grep -qF -- "--member $m --root <root>" <<<"$cmd" || {
      echo "$m: resolver invocation does not name its own member and root: $cmd" >&2
      return 1
    }
  done
}

@test "the dirty-scope check lives once, in the resolver, and no member carries a private copy" {
  local m n
  n="$(grep -cF -- "$CHECK_LINE" "$SCRIPT" || true)"
  [ "$n" -eq 1 ] || { echo "resolver carries the dirty-scope check $n times" >&2; return 1; }
  for m in $MEMBERS; do
    grep -qE 'status --porcelain' "$(member_path "$m")" && {
      echo "$m derives its own dirty-scope check beside the resolver's" >&2
      return 1
    }
  done
  true
}

@test "every GATING member carries the byte-identical withhold contract" {
  for m in $GATING; do
    assert_carries "$(member_path "$m")" "$REFUSAL" || {
      echo "missing or drifted refusal contract: $m" >&2
      return 1
    }
  done
}

@test "the resolver runs before the dirty contract that reads its output" {
  local m f needle invocation_line contract_line
  for m in $MEMBERS; do
    f="$(member_path "$m")"
    needle="$REFUSAL"
    [ "$m" = "$ADVISORY" ] && needle="$EXEMPTION"
    invocation_line="$(grep -nF -- "<root>/.gaia/scripts/audit-resolve-scope.sh --member $m" "$f" | head -1 | cut -d: -f1)"
    contract_line="$(grep -nF -- "$needle" "$f" | head -1 | cut -d: -f1)"
    [ -n "$invocation_line" ] || { echo "no resolver invocation found: $m" >&2; return 1; }
    [ -n "$contract_line" ] || { echo "no dirty contract found: $m" >&2; return 1; }
    [ "$contract_line" -gt "$invocation_line" ] || {
      echo "dirty contract precedes the resolver it reads: $m" >&2
      return 1
    }
  done
}

@test "every GATING member names the refusal in its run order" {
  for m in $GATING; do
    assert_carries "$(member_path "$m")" "$METHOD_ANCHOR" || {
      echo "run order does not name the refusal: $m" >&2
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
  for m in $GATING; do
    assert_carries "$(member_path "$m")" "$SENTINEL_CARVEOUT" || {
      echo "fail-closed sentinel is filterable away: $m" >&2
      return 1
    }
  done
}

@test "every GATING member withholds without stranding a refusal artifact" {
  for m in $GATING; do
    assert_carries "$(member_path "$m")" "$NO_REFUSAL_ARTIFACT" || {
      echo "does not forbid the digest-keyed refusal artifact: $m" >&2
      return 1
    }
  done
}

@test "the refusal briefs: every member owes the sidecar on the dirty path" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$SIDECAR_CLAUSE" || {
      echo "refusal does not oblige the findings sidecar: $m" >&2
      return 1
    }
  done
}

@test "the advisory member is exempted, explicitly and not by omission" {
  f="$(member_path "$ADVISORY")"
  assert_carries "$f" "$EXEMPTION" || { echo "advisory member carries no explicit exemption" >&2; return 1; }
  assert_carries "$f" "$ADVISORY_ANCHOR" || { echo "advisory run order does not name the record step" >&2; return 1; }
  assert_carries "$f" "$ADVISORY_ARTIFACT" || { echo "advisory member does not forbid the refusal artifact" >&2; return 1; }
}

@test "the advisory member never acquires the withhold contract" {
  # Written as a positive match on the bad case per the bats-assertions rule.
  # Scanned by meaning rather than by the one bolded sentence: an exact-string
  # absence check only ever caught the byte-identical copy-paste, while ADDING a
  # reworded withhold clause restored the same contradiction.
  f="$(member_path "$ADVISORY")"
  drift="$(withhold_drift "$f")"
  [ -z "$drift" ] || {
    echo "advisory member has acquired a withhold clause it is exempt from:" >&2
    echo "$drift" >&2
    return 1
  }
  assert_carries "$f" "$NO_REFUSAL_ARTIFACT" && {
    echo "advisory member has acquired the gating withhold-artifact clause" >&2
    return 1
  }
  true
}

# --- Behavioural: each member's own invocation --------------------------------

@test "every member's resolver reports a dirty in-scope file as a DIRTY line" {
  local m repo
  repo="$(make_repo dirty-in-scope)"
  printf 'edit\n' >> "$repo/app/a.ts"
  for m in $MEMBERS; do
    run_member_resolver "$m" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$m: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY= M app/a.ts' <<<"$output" || { echo "$m: no DIRTY line for a dirty in-scope file" >&2; return 1; }
    grep -qF 'DIRTY IN REVIEW SCOPE:' <<<"$stderr" || { echo "$m: dirty set never reached stderr" >&2; return 1; }
  done
}

@test "every member's resolver reports nothing on a clean review list" {
  local m repo
  repo="$(make_repo clean)"
  for m in $MEMBERS; do
    run_member_resolver "$m" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$m: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$m: DIRTY line on a clean tree" >&2; return 1; }
    true
  done
}

@test "a dirty file outside the review list cannot refuse the pass" {
  local m repo
  repo="$(make_repo dirty-out-of-scope)"
  printf 'edit\n' >> "$repo/other/untouched.md"
  for m in $MEMBERS; do
    run_member_resolver "$m" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$m: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$m: a sibling's dirt outside the review list reached DIRTY" >&2; return 1; }
    true
  done
}

@test "every member's resolver fails closed to the sentinel when status cannot run" {
  local m repo shim="$BATS_TEST_TMPDIR/shim"
  repo="$(make_repo status-fails)"
  failing_status_shim "$shim"
  for m in $MEMBERS; do
    PATH="$shim:$PATH" run_member_resolver "$m" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$m: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY=dirty-scope check failed' <<<"$output" || {
      echo "$m: a status that could not run read as a clean tree" >&2
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

# mutate_copy SRC TAG SED_EXPR NEEDLE: copy SRC, confirm the copy satisfies
# NEEDLE before the edit (so a red is the mutation talking, not a broken
# fixture), apply the edit, and print the mutant's path.
mutate_copy() {
  local src="$1" tag="$2" expr="$3" needle="$4" tmp="$BATS_TEST_TMPDIR/mutant-$2"
  cp "$src" "$tmp"
  assert_carries "$tmp" "$needle" || {
    echo "fixture broken: pin does not hold before mutation ($tag)" >&2
    return 1
  }
  sed "$expr" "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  printf '%s' "$tmp"
}

# assert_pin_breaks SRC TAG SED_EXPR NEEDLE: the whole shape in one line.
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

# assert_drift_caught TAG CLAUSE: the advisory member with CLAUSE inserted ahead
# of the handshake's "There is no withhold path here", exemption paragraph left
# exactly where it is, must trip the drift guard.
assert_drift_caught() {
  local tag="$1" clause="$2" src tmp anchor
  src="$(member_path "$ADVISORY")"
  tmp="$BATS_TEST_TMPDIR/mutant-advisory-$tag.md"
  anchor='There is no withhold path here;'

  grep -qF -- "$anchor" "$src" || {
    echo "fixture broken: advisory member no longer carries the insertion anchor ($tag)" >&2
    return 1
  }
  [ -z "$(withhold_drift "$src")" ] || {
    echo "fixture broken: advisory member already carries a withhold clause ($tag)" >&2
    return 1
  }

  awk -v anchor="$anchor" -v clause="$clause" \
    'index($0, anchor) && !done { print clause; print ""; done = 1 } { print }' \
    "$src" > "$tmp"

  grep -qF -- "$REFUSAL" "$tmp" && {
    echo "fixture is not the reworded case: it carries the byte-identical contract ($tag)" >&2
    return 1
  }
  [ -n "$(withhold_drift "$tmp")" ] || {
    echo "drift guard misses a withhold clause it must catch ($tag)" >&2
    return 1
  }
  return 0
}

@test "the advisory drift guard catches a reworded withhold clause (non-vacuity)" {
  assert_drift_caught reworded 'When a `DIRTY=` line comes back, you withhold this pass and report that you must be re-dispatched once the operator commits or reverts.'
}

@test "the advisory drift guard is not evaded by a nearby 'cannot' (non-vacuity)" {
  assert_drift_caught nearby_cannot 'A pass over a dirty tree cannot be trusted, so withhold your marker until it is clean.'
}

@test "the advisory drift guard is not evaded by a nearby 'never' (non-vacuity)" {
  assert_drift_caught nearby_never 'This member never self-heals, and it will withhold this pass on dirt.'
}

# gating_withhold_phrases: every withhold-bearing phrase the GATING members
# actually carry, deduped, one per line. Extraction is deliberately BROADER than
# WITHHOLD_SHAPED, because its job is to describe what the siblings really say
# rather than to judge it; a phrasing the scan cannot see reds here as soon as a
# gating member adopts it.
gating_withhold_phrases() {
  local m
  for m in $GATING; do
    tr '\n' ' ' < "$(member_path "$m")" \
      | grep -oiE 'withhold[a-z]* [a-z]+ (pass|clearance|marker)'
  done | sort -u
  return 0
}

@test "the drift guard catches every withhold phrasing the gating members really use" {
  local phrase n=0
  while IFS= read -r phrase; do
    [ -n "$phrase" ] || continue
    n=$((n + 1))
    assert_drift_caught "real-$n" \
      "When the check comes back non-empty you $phrase until the operator commits or reverts." || return 1
  done <<PHRASES
$(gating_withhold_phrases)
PHRASES

  # A floor, so a broken extraction cannot quietly turn this into a test that
  # asserts nothing. It sits below the number of distinct phrasings the gating
  # members carry today.
  [ "$n" -ge 4 ] || {
    echo "extraction yielded only $n phrases; the derived fixture set has gone vacuous" >&2
    return 1
  }
}

@test "the advisory drift guard sees a clause split across a line break (non-vacuity)" {
  # awk processes escape sequences in a `-v` assignment, so `\n` reaches the
  # mutant as a real line break, while a literal one is a hard error on BSD awk.
  assert_drift_caught line_split 'When the check comes back non-empty you\nwithhold this pass until the operator commits or reverts.'
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
