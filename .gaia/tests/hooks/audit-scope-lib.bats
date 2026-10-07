#!/usr/bin/env bats
# Structural, regression, and invariant tests for the shared ownership
# classifier (UAT-015), covering the parts owned by the ownership-classifier
# phase: exactly-one-classifier (part 1), every-consumer-sources-it
# (part 2), the remaining in-scope sets staying separately named plus the
# retired auditable-base literal's pins (part 3), the golden behavior table
# (part 4), and absent-module -> DENY (part 5). Plus two further invariants:
# SEC-007 (every machinery path is roster-claimed) and the scrub-marker
# survival check.
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  MACHINERY_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  PROVENANCE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh"
  RESOLVER="$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh"
  HOOK="$REPO_ROOT/.claude/hooks/pr-merge-audit-check.sh"
  # One entry per arm of the allowlist, not just the first. The uniqueness
  # invariant below is what stops a second copy of this set appearing in another
  # tracked script and drifting from this one, and an arm it does not name is an
  # arm that may be copied freely.
  ALLOWLIST_LITERAL='wiki/*|.claude/*|.gaia/*|docs/*'
}

# Count real invocations of a symbol in a file. A presence probe -- `type X` or
# `command -v X`, the shape a consumer uses to decide whether a guarded load
# actually defined the symbol -- names it without calling it, so it is excluded.
# The count assertions below are about invocations, and a bare grep for the name
# reads a degrade guard as a second call.
#
# The probe is stripped from the line rather than dropping the line, and counted
# per occurrence rather than per line, so `type X >/dev/null && X "$arg"` still
# counts the call it carries. Dropping the whole line reads that one-liner as
# zero invocations, which greens the "calls it once" assertion over a consumer
# that calls it twice.
#
# Counting occurrences is what makes the two other filters load-bearing, and
# per-line counting hid the need for both: comments go first, because a header
# naming the symbol twice in prose now contributes two, and the match is
# bounded by a non-identifier at BOTH ends, because `audit_scope_init` is a
# prefix of any longer name someone adds later, and because a terminator that
# demands whitespace declines every other one a real second call can carry --
# `audit_scope_init;`, a bare call at end of line -- which greens the
# calls-it-once pin over exactly the drift it exists to catch.
#
# Counted by splitting on the boundaries rather than by matching across them:
# `grep -o` CONSUMES the boundary character it matched and resumes after it, so
# two occurrences separated by exactly one non-identifier character -- the
# `audit_scope_init;audit_scope_init` spelling -- leave the second with no
# boundary left and it goes uncounted, which is the same green-over-drift the
# widened terminator was meant to end.
count_invocations() {
  sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$1" \
    | sed -E "s/(^|[[:space:]])(type|command -v)[[:space:]]+$2([[:space:]]|\$)/\1 /g" \
    | awk -v sym="$2" '
        { gsub(/[^A-Za-z0-9_]/, " ")
          n = split($0, w, " ")
          for (i = 1; i <= n; i++) if (w[i] == sym) c++ }
        END { print c + 0 }
      '
}

# Extract a named function's body (from its `name() {` line through the next
# column-0 `}`) so a structural assertion can inspect one function in
# isolation without matching a sibling's text.
extract_function() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\) \\{" { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Part 1: exactly one classifier. The merge gate's out-of-scope allowlist
# case-arm literal lives in exactly one tracked file.
# ---------------------------------------------------------------------------

@test "exactly one classifier: every out-of-scope allowlist arm lives in one tracked file" {
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    # -z and a NUL read: a carrier whose path holds a non-ASCII byte would
    # otherwise arrive C-quoted and fail the exact-path assertion below under a
    # name no file on disk has. Command substitution discards NUL bytes, so the
    # records are accumulated in the loop instead of captured from one.
    matches=""
    while IFS= read -r -d '' matched_file; do
      matches="${matches}${matched_file}
"
    done < <(git -C "$REPO_ROOT" grep -lF -z -- "$lit" -- '*.sh')
    count="$(printf '%s' "$matches" | grep -c .)"
    [ "$count" -eq 1 ] || return 1
    grep -qxF ".claude/hooks/lib/audit-scope.sh" <<<"$matches" || return 1
  done <<EOF
$ALLOWLIST_LITERAL
EOF
}

# ---------------------------------------------------------------------------
# Part 2: every consumer sources the module and calls audit_scope_init once
# per run, never once per path.
# ---------------------------------------------------------------------------

@test "surfaces exist: the classifier, the machinery list, and every consumer" {
  [ -f "$SCOPE_LIBRARY" ]
  [ -f "$MACHINERY_LIBRARY" ]
  [ -f "$RESOLVER" ]
  [ -f "$HOOK" ]
}

@test "resolve-audit-members.sh sources audit-scope.sh and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$RESOLVER" || return 1
  count="$(count_invocations "$RESOLVER" audit_scope_init)"
  [ "$count" -eq 1 ]
}

# The counter is what both pins above rest on, so its own boundary is asserted
# rather than trusted. A terminator that demands whitespace declines `;`, `)`,
# `|`, `&` and end-of-line, so a real second call written any of those ways
# would green a pin that exists to catch exactly that drift.
@test "count_invocations counts a second call whatever terminator it carries" {
  probe="$BATS_TEST_TMPDIR/probe.sh"

  printf '%s\n' 'audit_scope_init "$r"' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 1 ]

  printf '%s\n' 'audit_scope_init "$r"' 'audit_scope_init; :' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 2 ]

  printf '%s\n' 'audit_scope_init "$r"' 'audit_scope_init' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 2 ]

  # Exactly one non-identifier character between two occurrences, the spelling
  # a boundary-consuming match cannot see.
  printf '%s\n' 'audit_scope_init;audit_scope_init' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 2 ]

  printf '%s\n' '{ audit_scope_init; }' 'audit_scope_init&&audit_scope_init' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 3 ]

  # And still declines the two shapes the filters above it exist to drop.
  printf '%s\n' 'audit_scope_init "$r"' 'type audit_scope_init >/dev/null' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 1 ]

  printf '%s\n' 'audit_scope_init "$r"' '# audit_scope_init audit_scope_init in prose' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 1 ]

  # A longer name that merely starts with the symbol is not an invocation.
  printf '%s\n' 'audit_scope_init "$r"' 'audit_scope_init_extra "$r"' > "$probe"
  [ "$(count_invocations "$probe" audit_scope_init)" -eq 1 ]
}

# last_definition <file>: the name of the last function the file defines at top
# level, in either spelling bash accepts (`name()` and `function name`, the
# `()` optional after the keyword) and with the opening brace on the definition
# line or on the line below it. Reading only the canonical `name() {` would
# leave the pin below green when a function is appended as `function name {` or
# with extra spacing, which is the drift it exists to catch: `tail -1` would
# still return the previously-last definition.
#
# The boundary, stated rather than implied, because the pin is only as honest
# as this matcher: a definition that does not start at column 1 is out of
# reach. Both modules define at top level and neither has a reason not to, so
# an indented definition would be a larger change than the append this pin
# watches for; reaching it needs a parser rather than a line matcher, and a
# line matcher that claimed it would be the same over-claim this helper was
# repaired for.
last_definition() {
  sed -E -n \
    -e 's/^function[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*(\(\)[[:space:]]*)?\{.*$/\1/p' \
    -e 's/^([A-Za-z0-9_]+)[[:space:]]*\([[:space:]]*\)[[:space:]]*\{.*$/\1/p' \
    -e 's/^function[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*(\(\)[[:space:]]*)?$/\1/p' \
    -e 's/^([A-Za-z0-9_]+)[[:space:]]*\([[:space:]]*\)[[:space:]]*$/\1/p' \
    "$1" | tail -1
}

# The matcher is what the pin below rests on, so its own boundary is asserted
# rather than trusted, exactly as count_invocations` is above. A spelling it
# cannot see returns the PREVIOUSLY-last definition, which still equals the
# resolver`s probe, so the pin stays green while the probe has silently become
# the early-export kind the resolver rules out.
@test "last_definition reads a definition whose brace is on the next line" {
  probe="$BATS_TEST_TMPDIR/lib.sh"

  printf '%s\n' 'first() {' '  :' '}' > "$probe"
  [ "$(last_definition "$probe")" = "first" ]

  printf '%s\n' 'first() {' '  :' '}' 'second()' '{' '  :' '}' > "$probe"
  [ "$(last_definition "$probe")" = "second" ]

  printf '%s\n' 'first() {' '  :' '}' 'function second' '{' '  :' '}' > "$probe"
  [ "$(last_definition "$probe")" = "second" ]

  printf '%s\n' 'first() {' '  :' '}' 'function second ()' '{' '  :' '}' > "$probe"
  [ "$(last_definition "$probe")" = "second" ]

  # And still declines the shapes that are not definitions at all: a bare call,
  # and a command substitution in an assignment. Each one names something the
  # DEFINITION does not, so a matcher that wrongly credited either line returns
  # that name and the assertion reds. Reusing the defined name here would admit
  # the exact state the assertion forbids, which is the whole failure this
  # helper was repaired for, one level up.
  printf '%s\n' 'first() {' '  :' '}' 'second' > "$probe"
  [ "$(last_definition "$probe")" = "first" ]

  printf '%s\n' 'first() {' '  :' '}' 'x=$(second)' > "$probe"
  [ "$(last_definition "$probe")" = "first" ]
}

# The resolver argues that probing each module's LAST definition needs no
# reasoning about which internal call goes how deep: a truncated copy parses as
# far as the truncation and defines everything ahead of it, so an early-export
# probe answers yes for a copy missing what the call it gates will reach. That
# argument is a property of two other files, and appending a function to either
# silently demotes the probe to the early-export kind the argument rules out.
@test "each module probe in resolve-audit-members.sh names its module's last definition" {
  probed_scope="$(grep -oE '^type [A-Za-z0-9_]+' "$RESOLVER" | awk 'NR==1 {print $2}')"
  probed_prov="$(grep -oE '^type [A-Za-z0-9_]+' "$RESOLVER" | awk 'NR==2 {print $2}')"
  [ -n "$probed_scope" ]
  [ -n "$probed_prov" ]

  last_scope="$(last_definition "$SCOPE_LIBRARY")"
  last_prov="$(last_definition "$PROVENANCE_LIBRARY")"
  [ -n "$last_scope" ]
  [ -n "$last_prov" ]

  [ "$probed_scope" = "$last_scope" ]
  [ "$probed_prov" = "$last_prov" ]
}

@test "pr-merge-audit-check.sh sources audit-scope.sh and audit-machinery.sh, and calls audit_scope_init once" {
  grep -qF -- "audit-scope.sh" "$HOOK" || return 1
  grep -qF -- "audit-machinery.sh" "$HOOK" || return 1
  count="$(count_invocations "$HOOK" audit_scope_init)"
  [ "$count" -eq 1 ]
}

@test "no consumer calls the classifier once per path (no per-path source or init inside a changed-path loop)" {
  # A per-path fork would show the source/init call INSIDE the "while IFS= read"
  # dispatch loop bodies; those loops call only the batch predicate
  # (audit_owners_for_paths) or the single-path predicates directly, never
  # re-source or re-init. Grep each consumer's post-init body for a second
  # audit_scope_init call is already covered above (count -eq 1); this test
  # additionally proves the dispatch loop itself never calls it.
  for consumer_file in "$RESOLVER" "$HOOK"; do
    dispatch_loop="$(awk '/while IFS= read -r path; do/,/^done/' "$consumer_file")"
    [ -z "$dispatch_loop" ] && continue
    grep -qF "audit_scope_init" <<<"$dispatch_loop" && return 1
  done
  true
}

# ---------------------------------------------------------------------------
# Part 3: the remaining in-scope sets stay separately named.
# audit_out_of_scope_allowlisted is the one path-classification predicate; the
# self-modification classifier it once had a sibling in is gone, along with
# the merge-gate bypass that was its only caller. CI's has_source stays
# a workflow-local grep pair, never replaced by a call into the module. No
# routing decision consults a hardcoded auditable-base literal: the function
# that once held one, audit_in_auditable_base, is gone, and ownership is a
# roster-declared two-tier precedence instead (claimant globs, then the
# default member's own declared globs).
# ---------------------------------------------------------------------------

@test "the out-of-scope allowlist is defined, and the self-modification classifier is gone from the library and the gate" {
  grep -qF "audit_out_of_scope_allowlisted() {" "$SCOPE_LIBRARY" || return 1
  grep -qF "audit_self_mod_classify" "$SCOPE_LIBRARY" && return 1
  grep -qE "audit_self_mod_classify|check_self_mod_only_update_pr|self_mod_only" "$HOOK" && return 1
  true
}

@test "no routing decision consults a hardcoded auditable-base literal, and the symbol is gone" {
  body="$(extract_function "$SCOPE_LIBRARY" _audit_scope_owner_of)"
  [ -n "$body" ] || return 1
  grep -qF "audit_in_auditable_base" <<<"$body" && return 1
  grep -qF "audit_in_auditable_base" "$SCOPE_LIBRARY" && return 1
  true
}

# ---------------------------------------------------------------------------
# UAT-015: a claimant beats an overlapping default glob regardless of roster
# order. A fabricated two-member fixture declares a claimant glob
# (app/special/**) that is a strict subset of the default's own declared glob
# (app/**), so a path under app/special/ matches both. Written in both roster
# orders (default first, default last) to prove the precedence is structural
# (claimant tier is exhausted before the default tier is ever consulted),
# never an accident of which entry the roster lists first.
# ---------------------------------------------------------------------------

@test "UAT-015: claimant wins over an overlapping default glob in either roster order" {
  ROOT_DEFAULT_FIRST=$(mktemp -d -t audit-scope-order-a-XXXXXX)
  mkdir -p "$ROOT_DEFAULT_FIRST/.gaia"
  cat > "$ROOT_DEFAULT_FIRST/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-example
    globs:
      - "app/**"
    audience: adopter
    push_fixes: true
    default: true
  - name: code-audit-claimant
    globs:
      - "app/special/**"
    audience: adopter
    push_fixes: false
YAML

  ROOT_DEFAULT_LAST=$(mktemp -d -t audit-scope-order-b-XXXXXX)
  mkdir -p "$ROOT_DEFAULT_LAST/.gaia"
  cat > "$ROOT_DEFAULT_LAST/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-claimant
    globs:
      - "app/special/**"
    audience: adopter
    push_fixes: false
  - name: code-audit-example
    globs:
      - "app/**"
    audience: adopter
    push_fixes: true
    default: true
YAML

  run bash -c '
    . "$1"
    audit_scope_init "$2"
    audit_owner_for_path "app/special/x.ts"
    audit_scope_init "$3"
    audit_owner_for_path "app/special/x.ts"
  ' _ "$SCOPE_LIBRARY" "$ROOT_DEFAULT_FIRST" "$ROOT_DEFAULT_LAST"

  rm -rf "$ROOT_DEFAULT_FIRST" "$ROOT_DEFAULT_LAST"

  [ "$status" -eq 0 ]
  expected="code-audit-claimant
code-audit-claimant"
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Part 4: the gate's decision is unchanged across a golden table of path
# sets. Each case drives the real merge-gate hook end to end (a sandbox on a
# `feature` branch off `main`, mirroring the sibling pr-merge-audit-check.bats
# fixture) and asserts allow/deny.
# ---------------------------------------------------------------------------

golden_setup() {
  GREPO=$(mktemp -d -t audit-scope-golden-XXXXXX)
  git -C "$GREPO" init --quiet --initial-branch=main
  git -C "$GREPO" config user.email "test@example.com"
  git -C "$GREPO" config user.name "Test"
  git -C "$GREPO" config commit.gpgsign false

  mkdir -p "$GREPO/.gaia"
  printf '1.4.0\n' > "$GREPO/.gaia/VERSION"
  echo "# readme" > "$GREPO/README.md"
  # Seed a bundled workflow template on the base (main), so a feature commit
  # can re-render it verbatim: the shape of pull request the removed
  # self-modification bypass used to clear, which the table pins as a deny.
  mkdir -p "$GREPO/.gaia/cli/templates/workflows"
  printf 'name: Code Review Audit\n' \
    > "$GREPO/.gaia/cli/templates/workflows/fixture-audit.yml.tmpl"
  seed_audit_roster "$GREPO"
  git -C "$GREPO" add .gaia/VERSION .gaia/audit-ci.yml README.md \
    .gaia/cli/templates/workflows/fixture-audit.yml.tmpl
  git -C "$GREPO" commit --quiet -m "init"
  git -C "$GREPO" checkout --quiet -b feature

  # The real hook (run by absolute path via $HOOK, never copied) delegates
  # dispatch to .gaia/scripts/resolve-audit-members.sh CWD-relatively, so the
  # golden table needs a real copy here too, mirroring the sibling
  # pr-merge-audit-check.bats fixture. That copy resolves its own libs
  # relative to ITSELF ($GREPO/.claude/hooks/lib/), so the sandbox needs its
  # own copy of the shared ownership classifier alongside it.
  mkdir -p "$GREPO/.gaia/scripts" "$GREPO/.claude/hooks/lib"
  cp "$RESOLVER" "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$GREPO/.gaia/scripts/resolve-audit-members.sh"
  cp "$SCOPE_LIBRARY" "$GREPO/.claude/hooks/lib/audit-scope.sh"
  cp "$MACHINERY_LIBRARY" "$GREPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" "$GREPO/.claude/hooks/lib/audit-base-provenance.sh"

  # A gh that answers the gate's fork query (`--json isCrossRepository`) with
  # `false` and fails everything else, so the table never reaches the
  # developer's own gh and a pull-request record stays unresolvable, which is
  # what the golden_run_hook comment below relies on.
  GOLDEN_GH_BIN="$GREPO.bin"
  mkdir -p "$GOLDEN_GH_BIN"
  cat > "$GOLDEN_GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
exit 1
EOF
  chmod +x "$GOLDEN_GH_BIN/gh"
}

golden_teardown() {
  [ -n "${GREPO:-}" ] && rm -rf "$GREPO" "$GREPO.bin"
  true
}

golden_commit() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$GREPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$GREPO/$path"
    git -C "$GREPO" add "$path"
  done
  git -C "$GREPO" commit --quiet -m "change"
}

# The command deliberately names NO pull request. Every arm that clears a merge
# off the current-branch record binds to the pull request the command names, and
# an absent positional is gh's current-branch default, so the binding holds by
# construction and this table keeps varying only the thing it is named for: the
# path set. Adding a number here would make each case turn on whether the
# sandbox can resolve a pull-request record, which it cannot and which is the
# sibling suite's subject, not this one's.
golden_run_hook() {
  local json
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge --squash"}}')
  PATH="$GOLDEN_GH_BIN:$PATH" invoke_hook_in "$GREPO" "$json" "$HOOK"
}

@test "golden table: pure wiki-only diff allows" {
  golden_setup
  golden_commit "wiki/x.md" "doc"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

@test "golden table: pure app/ diff denies (marker mandatory)" {
  golden_setup
  golden_commit "app/x.ts" "export const x = 1;"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: mixed app/ + wiki/ diff denies" {
  golden_setup
  golden_commit "app/x.ts" "export const x = 1;" "wiki/x.md" "doc"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: .gaia/**/*.sh-only diff denies (allowlisted AND owned; legacy branch never reached)" {
  golden_setup
  golden_commit ".gaia/scripts/probe.sh" "#!/bin/bash"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

# The witness must be a root file in scope that no member's globs claim, or the
# table loses its ownerless-in-scope row entirely. A root `Makefile` is that
# file; `Dockerfile` is claimed by the default member, so it would exercise the
# owned branch instead.
@test "golden table: ownerless-but-in-scope root Makefile denies" {
  golden_setup
  golden_commit "Makefile" "all:"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

# public/ is NOT allowlisted, and this row is what keeps it that way: the tree
# carries executed JavaScript under it, so the subtree stays in scope and a
# public-only diff still denies without a marker.
@test "golden table: nested public/ asset denies" {
  golden_setup
  golden_commit "public/logo.svg" "<svg></svg>"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

@test "golden table: a verbatim re-render of a bundled workflow template denies" {
  golden_setup
  # The template on the base and the installed workflow carry identical bytes,
  # which is exactly what the removed self-modification bypass cleared on.
  # The workflow is in scope, so with no marker the merge denies.
  golden_commit ".github/workflows/fixture-audit.yml" "name: Code Review Audit"
  golden_run_hook
  golden_teardown
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  true
}

# ---------------------------------------------------------------------------
# Part 5: absent module -> DENY. A COPY of the hook in a sandbox
# `.claude/hooks/` with no `lib/` at all must deny, never allow. Never `mv`
# the real module aside: a bats run must not mutate the working tree, and a
# copied hook exercises the same BASH_SOURCE-relative miss.
# ---------------------------------------------------------------------------

@test "absent classifier module: a copied hook with no lib/ directory denies, never allows" {
  SANDBOX=$(mktemp -d -t audit-scope-absent-XXXXXX)
  mkdir -p "$SANDBOX/.claude/hooks"
  cp "$HOOK" "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"
  chmod +x "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"

  # Seed the libraries the gate reaches BEFORE its classifier load, and no
  # others, so it arms normally and reaches ITS OWN classifier-absent deny
  # below rather than an earlier one. Only jq-availability.sh and
  # verb-arming.sh can send it to a different arm: the first refuses
  # fail-loud with its own text, ahead of even the arming library, and the
  # second denies every Bash tool call with its own. The rest keep the gate on
  # its ordinary path rather than change which arm it lands on, so a miss
  # there is invisible to the assertions below: repo-scope.sh is one of the
  # libraries the classifier deny itself names, so its own miss reads verbatim
  # as the text grepped for, and an absent verb-arming-walk.sh only degrades
  # the arming decision to its raw match.
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/jq-availability.sh" "$SANDBOX/.claude/hooks/lib/jq-availability.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" "$SANDBOX/.claude/hooks/lib/verb-arming.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$SANDBOX/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/repo-scope.sh" "$SANDBOX/.claude/hooks/lib/repo-scope.sh"

  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "gh pr merge 1 --squash"}}')
  invoke_hook_in "$SANDBOX" "$json" "$SANDBOX/.claude/hooks/pr-merge-audit-check.sh"
  rm -rf "$SANDBOX"

  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  # The classifier-specific deny text, not the arming library's: proves the
  # gate reached the classifier check rather than denying earlier for an
  # unrelated reason (audit finding DP-008).
  grep -qF -- 'cannot load the ownership classifier' <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# SEC-007: every machinery path is claimed by the committed .gaia/audit-ci.yml
# roster, the only roster the module loads. Bats suites are release-excluded,
# so this only ever runs where the maintainer members exist.
# ---------------------------------------------------------------------------

# Assert audit_owner_for_path returns a non-empty owner for every machinery
# path in $AUDIT_MACHINERY_PATHS, against the roster the caller already
# init'd. Real files
# under a `/**` prefix are enumerated from $REPO_ROOT. Ends in the pass/fail
# check, so it is safe as a @test's final command.
assert_every_machinery_path_owned() {
  local entry prefix rep owner tracked fail=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "#"*) continue ;;
      *"/**")
        prefix="${entry%\*\*}"
        rep="${prefix}__representative__.sh"
        owner="$(audit_owner_for_path "$rep")"
        if [ -z "$owner" ]; then
          echo "representative path unowned: $rep" >&2
          fail=1
        fi
        while IFS= read -r -d '' tracked; do
          [ -n "$tracked" ] || continue
          owner="$(audit_owner_for_path "$tracked")"
          if [ -z "$owner" ]; then
            echo "tracked file unowned: $tracked (entry $entry)" >&2
            fail=1
          fi
        done < <(git -C "$REPO_ROOT" ls-files -z "$prefix")
        ;;
      *)
        owner="$(audit_owner_for_path "$entry")"
        if [ -z "$owner" ]; then
          echo "machinery path unowned: $entry" >&2
          fail=1
        fi
        ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF
  [ "$fail" -eq 0 ]
}

@test "SEC-007: audit_owner_for_path returns a non-empty member for every machinery path" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIBRARY"
  audit_scope_init "$REPO_ROOT"

  assert_every_machinery_path_owned
}

@test "audit_scope_init fails closed with a named reason on a roster-less root" {
  # There is no fallback roster: a root whose .gaia/audit-ci.yml is absent or
  # carries no auditors: block must return non-zero and name the file, never
  # leave a populated roster behind from an earlier call.
  EMPTY_ROOT=$(mktemp -d -t audit-scope-noroster-XXXXXX)
  mkdir -p "$EMPTY_ROOT/.gaia"
  printf 'audit_authors: []\n' > "$EMPTY_ROOT/.gaia/audit-ci.yml"
  run bash -c '
    . "$1"
    audit_scope_init "$2" || { echo "rc=$?"; audit_owner_for_path "app/x.ts"; exit 0; }
    echo "rc=0"
  ' _ "$SCOPE_LIBRARY" "$EMPTY_ROOT"
  rm -rf "$EMPTY_ROOT"

  [ "$status" -eq 0 ]
  grep -qF 'rc=1' <<<"$output" || return 1
  grep -qF 'no auditors: roster in' <<<"$output" || return 1
  grep -qF '/.gaia/audit-ci.yml' <<<"$output" || return 1
  # Nothing owns a path once init has failed.
  [ "$(grep -c 'code-audit' <<<"$output")" -eq 0 ]
}

@test "the git commit hook is owned by the shell member" {
  # .githooks/pre-commit is the Quality Gate floor for every commit and is POSIX
  # shell, so the shell member (which holds the shellcheck oracle) owns it.
  # Without a glob claiming it, a PR that changes the hook alongside any other
  # owned surface dispatches members for the other files only, and the hook
  # itself merges with no member responsible for it.
  #
  # It is deliberately NOT in AUDIT_MACHINERY_PATHS: that list's generating
  # rule is bytes that change what a member reviews, who reviews it, where a
  # clearance lands, or whether a clearance is believed. This hook gates
  # commits, not audits, so SEC-007 does not reach it and this test is the pin.

  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"
  [ "$(audit_owner_for_path '.githooks/pre-commit')" = "code-audit-maintainer-shell" ]
}

@test "the CLI workspace policy file is owned by the node member" {
  # .gaia/cli/pnpm-workspace.yaml carries the .gaia/cli workspace's entire
  # supply-chain policy: minimumReleaseAge and its strict-enforcement flag,
  # trustPolicy, and both exclusion
  # lists. The node member already owns the rest of that dependency surface
  # (package.json, pnpm-lock.yaml, tsconfig*.json), so this file belongs with
  # it. Without a glob claiming it, a PR whose only change lowers
  # minimumReleaseAge, drops trustPolicy, or adds an exclusion entry resolves
  # an empty dispatched set: no member runs, no marker is required, and it
  # merges with no member responsible for it.
  #
  # It is deliberately NOT in AUDIT_MACHINERY_PATHS: that list's generating
  # rule is bytes that change what a member reviews, who reviews it, where a
  # clearance lands, or whether a clearance is believed. This file governs
  # dependency admission, not audits, so SEC-007 does not reach it and this
  # test is the pin.

  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"
  [ "$(audit_owner_for_path '.gaia/cli/pnpm-workspace.yaml')" = "code-audit-maintainer-node" ]
  # The default member's own `pnpm-workspace.yaml` glob never crosses a `/`,
  # so the repository-root file stays with it and the two do not collide.
  [ "$(audit_owner_for_path 'pnpm-workspace.yaml')" = "code-audit-frontend" ]
}

@test "the CLI's own tool config files are owned by the node member" {
  # `.gaia/cli/` carries three tool configs beside src/: vitest.config.ts,
  # eslint.config.mjs, and prettier.config.mjs. The default member's bare
  # `*.config.ts` / `*.config.mjs` globs never cross a `/`, so they claim the
  # repository-root files only and reach none of these; the node member's
  # explicit CLI build/config list named package.json, pnpm-lock.yaml,
  # pnpm-workspace.yaml, and tsconfig*.json but not these. Without a glob
  # claiming them, a PR whose only change is one of the three resolves an
  # empty dispatched set: no member runs, no marker is required, and it merges
  # with no member responsible for it. vitest.config.ts is the sharpest of the
  # three, since its `setupFiles` executes arbitrary code in every CLI test
  # run.

  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"
  [ "$(audit_owner_for_path '.gaia/cli/vitest.config.ts')" = "code-audit-maintainer-node" ]
  [ "$(audit_owner_for_path '.gaia/cli/eslint.config.mjs')" = "code-audit-maintainer-node" ]
  [ "$(audit_owner_for_path '.gaia/cli/prettier.config.mjs')" = "code-audit-maintainer-node" ]
  # The default member's own bare config globs never cross a `/`, so the
  # repository-root files stay with it and the two do not collide.
  [ "$(audit_owner_for_path 'vitest.config.ts')" = "code-audit-frontend" ]
  [ "$(audit_owner_for_path 'eslint.config.mjs')" = "code-audit-frontend" ]
}

@test "UAT-002: skills-md and non-md under skills both stay ownerless" {
  # The prose-legibility member that used to own `.claude/skills/**/*.md`
  # is deleted (harness triage P3-09); nothing replaces its lens, so both
  # a skills .md file and a non-.md helper under skills are ownerless.
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"
  [ -z "$(audit_owner_for_path '.claude/skills/gaia/references/debt.md')" ]
  [ -z "$(audit_owner_for_path '.claude/skills/gaia/helper.py')" ]
}

@test "the shared awk source carries exactly one copy of each transformation" {
  # The module concatenates $_AUDIT_SCOPE_GLOB_AWK into both of its awk
  # programs precisely so the glob compiler and the YAML unquoter exist once.
  # That is a claim in the file's own prose, and a second copy would reintroduce
  # the silent-drift failure the sharing exists to prevent while every test here
  # still passed, so it is asserted rather than trusted.
  local scope_library_path="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  [ "$(grep -c '^ *function glob_to_regex(' "$scope_library_path")" -eq 1 ]
  [ "$(grep -c '^ *function unq(' "$scope_library_path")" -eq 1 ]
}

@test "the unowned: reader compiles a glob to the same regex the roster reader does" {
  # The sharing above is only worth asserting if the two readers actually agree,
  # so this pins the outcome rather than the arrangement: one glob spelling, fed
  # through each parser, must compile identically.
  local yaml_roster yaml_unowned from_roster from_unowned
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  yaml_roster="$(printf 'auditors:\n  - name: code-audit-x\n    globs:\n      - ".gaia/**/*.sh"\n')"
  yaml_unowned="$(printf 'unowned:\n  - ".gaia/**/*.sh"\n')"
  from_roster="$(printf '%s\n' "$yaml_roster" | _audit_scope_parse_auditors | awk '$1 == "GLOB" { print $3 }')"
  from_unowned="$(printf '%s\n' "$yaml_unowned" | _audit_scope_parse_unowned | cut -f3)"
  [ -n "$from_roster" ]
  [ "$from_roster" = "$from_unowned" ]
}

# SPEC-092 C5 exempt row: audit-scope.sh reads no package descriptor, because the
# `*/*` arm already puts every nested path in scope. A frontend/ path therefore
# classifies exactly as its retired root form does, and no registry state can
# move it (the second test pins that nothing here reads one). frontend/.claude/**
# and frontend/CLAUDE.md stay in scope on purpose (C14: code-audit-frontend
# claims them), so a package harness diff is never allowlisted past review.
@test "package paths: frontend/ classifies in scope like the root form" {
  run bash -c '. "$1"; for p in frontend/app/routes/x.tsx app/routes/x.tsx frontend/.claude/rules/x.md frontend/CLAUDE.md frontend/public/logo.svg; do audit_out_of_scope_allowlisted "$p" && echo "allowlisted:$p" || echo "in-scope:$p"; done' _ "$SCOPE_LIBRARY"
  [ "$status" -eq 0 ]
  local path
  for path in frontend/app/routes/x.tsx app/routes/x.tsx frontend/.claude/rules/x.md frontend/CLAUDE.md frontend/public/logo.svg; do
    grep -qxF "in-scope:$path" <<<"$output" || { echo "$path not in scope"; return 1; }
  done
}

@test "package paths: the classifier names no package registry or descriptor (structural, no descriptor read)" {
  run grep -n "gaia-packages\|packages\.json\|gaia\.package" "$SCOPE_LIBRARY"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Light-review roster keys and the public glob matcher.
# ---------------------------------------------------------------------------

# Writes a one-member roster fixture to <directory>/.gaia/audit-ci.yml; the
# member body (everything after `globs:`' list) comes from the second argument.
write_light_roster() {
  local directory="$1" body="$2"
  mkdir -p "$directory/.gaia"
  printf '%s\n' "$body" > "$directory/.gaia/audit-ci.yml"
}

LIGHT_ROSTER_WITH_KEYS='auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light_review: true
    light_line_cap: 50   # inline comment is stripped
    light_hard_full:
      - "owned/tests/**"
      # a comment between items never ends the list
      - "*.config.ts"
    audience: adopter
    push_fixes: true
    default: true
  - name: code-audit-plain
    globs:
      - "plain/**"
    audience: adopter
    push_fixes: false'

@test "audit_roster_light_config: opted member yields true, the cap, and one HARDFULL line per item in order" {
  local fixture
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  write_light_roster "$fixture" "$LIGHT_ROSTER_WITH_KEYS"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_roster_light_config "$fixture" code-audit-light
  rm -rf "$fixture"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(printf 'true\t50')" ]
  [ "${lines[1]}" = "$(printf 'HARDFULL\towned/tests/**')" ]
  [ "${lines[2]}" = "$(printf 'HARDFULL\t*.config.ts')" ]
}

@test "audit_roster_light_config: a member without the keys, and an unknown member, answer false and no cap" {
  local fixture
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  write_light_roster "$fixture" "$LIGHT_ROSTER_WITH_KEYS"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_roster_light_config "$fixture" code-audit-plain
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'false\t-')" ]
  run audit_roster_light_config "$fixture" code-audit-no-such-member
  rm -rf "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'false\t-')" ]
}

@test "audit_roster_light_config: only the literal true opts in, and the cap comes back raw" {
  local fixture value
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  for value in yes '"true"' True 1 ''; do
    write_light_roster "$fixture" "auditors:
  - name: code-audit-light
    globs:
      - \"owned/**\"
    light_review: $value
    light_line_cap: abc
    audience: adopter"
    run audit_roster_light_config "$fixture" code-audit-light
    [ "$status" -eq 0 ] || { rm -rf "$fixture"; return 1; }
    [ "$output" = "$(printf 'false\tabc')" ] || { rm -rf "$fixture"; echo "value '$value' gave: $output" >&2; return 1; }
  done
  rm -rf "$fixture"
}

@test "audit_roster_light_config: a roster that cannot be read exits 1 with nothing on stdout" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_roster_light_config "$BATS_TEST_TMPDIR/no-such-root" code-audit-light
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "light_hard_full items never reach ownership, and the ownership parser's output is unchanged by the keys" {
  local fixture bare
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  write_light_roster "$fixture" "$LIGHT_ROSTER_WITH_KEYS"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$fixture"
  # `*.config.ts` is a hard-Full item only; no member owns a root config file.
  run audit_owners_for_paths <<<"vite.config.ts"
  [ "$output" = "$(printf 'vite.config.ts\t-')" ]
  # `owned/tests/x.ts` is owned through `owned/**` and by nothing the list adds.
  run audit_owners_for_paths <<<"owned/tests/x.ts"
  [ "$output" = "$(printf 'owned/tests/x.ts\tcode-audit-light')" ]
  # The ownership records are byte-identical with the three keys stripped.
  bare="$(printf '%s\n' "$LIGHT_ROSTER_WITH_KEYS" | grep -v -e 'light_' -e 'owned/tests/\*\*' -e '\*\.config\.ts' -e 'a comment between items')"
  [ "$(_audit_scope_parse_auditors <<<"$LIGHT_ROSTER_WITH_KEYS")" = "$(_audit_scope_parse_auditors <<<"$bare")" ]
  rm -rf "$fixture"
}

@test "a hyphenated key is the leak the snake_case rule prevents: its items become owned globs" {
  local fixture
  fixture="$(mktemp -d -t audit-light-roster-XXXXXX)"
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"

  # Hyphenated spelling: the ownership parser's key pattern is [A-Za-z_]+, so
  # `light-hard-full:` does not end `globs:` and `leaked/**` is read as an
  # owned glob. The light reader sees no list at all.
  write_light_roster "$fixture" 'auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light-hard-full:
      - "leaked/**"
    audience: adopter'
  audit_scope_init "$fixture"
  run audit_owners_for_paths <<<"leaked/x.ts"
  [ "$output" = "$(printf 'leaked/x.ts\tcode-audit-light')" ]
  run audit_roster_light_config "$fixture" code-audit-light
  [ "$output" = "$(printf 'false\t-')" ]

  # Snake_case spelling of the same roster: the item reaches no ownership.
  write_light_roster "$fixture" 'auditors:
  - name: code-audit-light
    globs:
      - "owned/**"
    light_hard_full:
      - "leaked/**"
    audience: adopter'
  audit_scope_init "$fixture"
  run audit_owners_for_paths <<<"leaked/x.ts"
  [ "$output" = "$(printf 'leaked/x.ts\t-')" ]
  run audit_roster_light_config "$fixture" code-audit-light
  rm -rf "$fixture"
  [ "${lines[1]}" = "$(printf 'HARDFULL\tleaked/**')" ]
}

# glob, path, expected. Tab-separated; every glob is also given to a roster so
# ownership has to agree with the matcher, pair by pair.
GLOB_MATCH_TABLE=$'**/x\tx\tmatch
**/x\ta/b/x\tmatch
**/x\ta/b/xy\tnomatch
*.config.ts\tvite.config.ts\tmatch
*.config.ts\tfrontend/vite.config.ts\tnomatch
*.config.ts\tviteXconfigXts\tnomatch
frontend/*.config.ts\tfrontend/vite.config.ts\tmatch
frontend/*.config.ts\tfrontend/sub/vite.config.ts\tnomatch
frontend/app/**/tests/**\tfrontend/app/a/tests/b.ts\tmatch
frontend/app/**/tests/**\tfrontend/app/a/b.ts\tnomatch
frontend/.claude/**\tfrontend/.claude/rules/a.md\tmatch
frontend/.claude/**\tfrontend/CLAUDE.md\tnomatch
.github/workflows/**\t.github/workflows/ci.yml\tmatch
tsconfig*.json\ttsconfig.app.json\tmatch
tsconfig*.json\tfrontend/tsconfig.json\tnomatch
package.json\tfrontend/package.json\tnomatch
.npmrc\tXnpmrc\tnomatch
frontend/**\tfrontend/a/b/c.ts\tmatch'

# Prints one line per pair on which the matcher in <library> disagrees with the
# table or with the ownership classifier in the same library. Empty means they
# agree everywhere.
glob_matcher_disagreements() {
  local library="$1"
  GLOB_MATCH_TABLE="$GLOB_MATCH_TABLE" LIBRARY="$library" bash -c '
    . "$LIBRARY"
    fixture="$(mktemp -d)"
    mkdir -p "$fixture/.gaia"
    while IFS=$'"'"'\t'"'"' read -r glob path expected; do
      printf "auditors:\n  - name: code-audit-parity\n    globs:\n      - \"%s\"\n    audience: adopter\n" "$glob" > "$fixture/.gaia/audit-ci.yml"
      audit_scope_init "$fixture"
      owner="$(audit_owner_for_path "$path")"
      audit_glob_matches "$glob" "$path"
      matcher_status=$?
      if [ "$matcher_status" -eq 0 ]; then matcher_says=match; elif [ "$matcher_status" -eq 1 ]; then matcher_says=nomatch; else matcher_says=error; fi
      if [ -n "$owner" ]; then owner_says=match; else owner_says=nomatch; fi
      if [ "$matcher_says" != "$expected" ] || [ "$owner_says" != "$matcher_says" ]; then
        printf "%s | %s | table=%s matcher=%s ownership=%s\n" "$glob" "$path" "$expected" "$matcher_says" "$owner_says"
      fi
    done <<<"$GLOB_MATCH_TABLE"
    rm -rf "$fixture"
  '
}

@test "audit_glob_matches: every table pair matches as stated and agrees with ownership" {
  [ "$(printf '%s\n' "$GLOB_MATCH_TABLE" | grep -c .)" -ge 18 ]
  run glob_matcher_disagreements "$SCOPE_LIBRARY"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "audit_glob_matches: a matcher with a hand-rolled regex is caught by the ownership parity case" {
  # Scratch copy of the library whose matcher is redefined with its own regex
  # (`**` compiled like a single `*`) instead of the shared compiler. The
  # parity case must go red on it; on the real library it is green (test above).
  local scratch_library="$BATS_TEST_TMPDIR/audit-scope-handrolled.sh"
  cat "$SCOPE_LIBRARY" > "$scratch_library"
  cat >> "$scratch_library" <<'MUTANT'

audit_glob_matches() {
  local pattern="${1//./\\.}"
  pattern="${pattern//\*\*/@@}"
  pattern="${pattern//\*/[^/]*}"
  pattern="${pattern//@@/[^/]*}"
  [[ "$2" =~ ^${pattern}$ ]]
}
MUTANT
  run glob_matcher_disagreements "$scratch_library"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF '**/x | x |' <<<"$output"
}

@test "audit_glob_matches: a missing or empty argument exits 2 and prints nothing" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_glob_matches
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "**/x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "" "x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run audit_glob_matches "**/x" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "audit_glob_matches: regex metacharacters and backslashes in a path are literal data" {
  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  run audit_glob_matches 'a.b' 'aXb'
  [ "$status" -eq 1 ]
  run audit_glob_matches 'a.b' 'a.b'
  [ "$status" -eq 0 ]
  # Passed through the environment, so a backslash stays a backslash.
  run audit_glob_matches 'dir/*' 'dir/a\nb'
  [ "$status" -eq 0 ]
  run audit_glob_matches 'dir/*' 'dir/a"; system("echo pwned"); "'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
