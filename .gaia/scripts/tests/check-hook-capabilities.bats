#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-capabilities.sh, the
# reconciliation between what a REGISTERED hook DECLARES it can do and what
# the tree actually lets it reach.
#
# Every constructed-condition test drives a throwaway repo under
# $BATS_TEST_TMPDIR, handed to the check as its <repo_root> positional, so no
# test reads or mutates this repository's own settings, manifest, or exclude
# file. The one exception is the real-repo section at the bottom, mirroring
# check-script-capabilities.bats's own real-tree arm.
#
# The LOCAL-REGISTRATION arm is silent on every CI runner: .claude/settings
# .local.json is gitignored and therefore absent there. Its real exercise is
# a maintainer's own direct invocation of the checker; the fixtures below
# still pin its five criteria because nothing else does.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-capabilities.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-hook-capabilities.sh"
  SCOPE_CHECK="$SCRIPT_DIR/check-hook-scope-manifest.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-capabilities.sh
  source "$CHECK"
}

# make_fixture_repo <name>: a fresh throwaway tree under BATS_TEST_TMPDIR
# carrying the three files the check reads unconditionally -- an empty
# `hooks` block, an empty release-exclude, and a placeholder schema file.
# Callers add hooks and a manifest. Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1" dir
  dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude/hooks" "$dir/.gaia"
  printf '{"hooks":{}}\n' >"$dir/.claude/settings.json"
  printf '# fixture distribution boundary\n' >"$dir/.gaia/release-exclude"
  printf '{"$schema":"https://json-schema.org/draft/2020-12/schema"}\n' \
    >"$dir/.gaia/hook-capabilities.schema.json"
  printf '%s' "$dir"
}

# write_registrations <repo> <event> <command>...: rebuilds .claude/settings
# .json's `hooks` block from event/command pairs, one matcher group per pair
# so several commands can share an event without one clobbering another.
write_registrations() {
  local repo="$1" json='{}' event cmd
  shift
  while [ "$#" -ge 2 ]; do
    event="$1" cmd="$2"
    shift 2
    json="$(jq -n --argjson base "$json" --arg e "$event" --arg c "$cmd" \
      '$base | .[$e] = ((.[$e] // []) + [{"matcher":"","hooks":[{"type":"command","command":$c}]}])')"
  done
  jq -n --argjson h "$json" '{hooks:$h}' >"$repo/.claude/settings.json"
}

# write_local_registrations <repo> <event> <command>...: same shape, written
# to the gitignored .claude/settings.local.json instead.
write_local_registrations() {
  local repo="$1" json='{}' event cmd
  shift
  while [ "$#" -ge 2 ]; do
    event="$1" cmd="$2"
    shift 2
    json="$(jq -n --argjson base "$json" --arg e "$event" --arg c "$cmd" \
      '$base | .[$e] = ((.[$e] // []) + [{"matcher":"","hooks":[{"type":"command","command":$c}]}])')"
  done
  jq -n --argjson h "$json" '{hooks:$h}' >"$repo/.claude/settings.local.json"
}

# write_manifest <repo> <hooks-array-json>: the raw `hooks` array text,
# brackets included.
write_manifest() {
  printf '{"$schema":"./hook-capabilities.schema.json","hooks":%s}\n' "$2" \
    >"$1/.gaia/hook-capabilities.json"
}

# add_hook <repo> <relpath> <body>
add_hook() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

# write_exclude <repo> <line>...
write_exclude() {
  local repo="$1" l
  shift
  printf '# fixture distribution boundary\n' >"$repo/.gaia/release-exclude"
  for l in "$@"; do printf '%s\n' "$l" >>"$repo/.gaia/release-exclude"; done
}

# ========== UAT-001 / UAT-002 / UAT-016, coverage ==========

@test "UAT-001: a registration with no manifest entry is NO-ENTRY" {
  repo="$(make_fixture_repo noentry)"
  add_hook "$repo" .claude/hooks/lonely.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/lonely.sh
  write_manifest "$repo" '[]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "NO-ENTRY .claude/hooks/lonely.sh" <<<"$output"
}

@test "UAT-002: a manifest entry no registration names is ORPHAN" {
  repo="$(make_fixture_repo orphan)"
  add_hook "$repo" .claude/hooks/kept.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/kept.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/kept.sh","capabilities":[],
    "why":"pure","maintainer_only":false},
    {"hook":".claude/hooks/gone.sh","capabilities":[],
    "why":"no registration names it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "ORPHAN .claude/hooks/gone.sh" <<<"$output"
}

@test "UAT-016: two manifest entries naming the same hook are DUPLICATE, never last-wins" {
  repo="$(make_fixture_repo duplicate)"
  add_hook "$repo" .claude/hooks/pure.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/pure.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/pure.sh","capabilities":[],
    "why":"first","maintainer_only":false},
    {"hook":".claude/hooks/pure.sh","capabilities":[],
    "why":"second","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "DUPLICATE .claude/hooks/pure.sh" <<<"$output"
}

# ========== UAT-003, obligation from registration, not a filesystem sweep ==========

@test "UAT-003a: a script outside .claude/hooks/** newly registered is NO-ENTRY" {
  repo="$(make_fixture_repo obligation-added)"
  add_hook "$repo" .gaia/scripts/newhook.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .gaia/scripts/newhook.sh
  write_manifest "$repo" '[]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "NO-ENTRY .gaia/scripts/newhook.sh" <<<"$output"
}

@test "UAT-003b: a hook still under .claude/hooks/** but removed from the registration is ORPHAN" {
  repo="$(make_fixture_repo obligation-removed)"
  add_hook "$repo" .claude/hooks/stillhere.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/other.sh
  add_hook "$repo" .claude/hooks/other.sh '#!/usr/bin/env bash
true'
  write_manifest "$repo" '[{"hook":".claude/hooks/other.sh","capabilities":[],
    "why":"still registered","maintainer_only":false},
    {"hook":".claude/hooks/stillhere.sh","capabilities":[],
    "why":"entry survives a dropped registration","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "ORPHAN .claude/hooks/stillhere.sh" <<<"$output"
}

# ========== UAT-004, UNDECLARED located inside the invoked target ==========

@test "UAT-004: an invoked target's authenticated mutating gh verb is UNDECLARED, located in the target" {
  repo="$(make_fixture_repo undeclared-github)"
  add_hook "$repo" .claude/hooks/caller.sh '#!/usr/bin/env bash
bash .claude/hooks/lib/target.sh'
  add_hook "$repo" .claude/hooks/lib/target.sh '#!/usr/bin/env bash
gh issue edit 1 --add-label in-progress'
  write_registrations "$repo" PostToolUse .claude/hooks/caller.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/caller.sh",
    "capabilities":["invokes:.claude/hooks/lib/target.sh"],
    "why":"omits github-write","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .claude/hooks/caller.sh github-write .claude/hooks/lib/target.sh:2" <<<"$output"
}

# ========== UAT-005 / UAT-007, SURPLUS and BAD-TERM ==========

@test "UAT-005: a declared capability nothing in the closure reaches is SURPLUS" {
  repo="$(make_fixture_repo surplus)"
  add_hook "$repo" .claude/hooks/pure.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/pure.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/pure.sh","capabilities":["network"],
    "why":"claims more than it does","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "SURPLUS .claude/hooks/pure.sh network" <<<"$output"
}

@test "UAT-007: a term outside the closed vocabulary is BAD-TERM" {
  repo="$(make_fixture_repo badterm)"
  add_hook "$repo" .claude/hooks/pure.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/pure.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/pure.sh","capabilities":["exec-anything"],
    "why":"invented term","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-TERM .claude/hooks/pure.sh exec-anything" <<<"$output"
}

# ========== UAT-008, waiver scope, printing, and the non-waivable set ==========

@test "UAT-008a: a waiver suppresses only its own pair; an unrelated UNDECLARED still exits 1 and the waiver still prints" {
  repo="$(make_fixture_repo waive-a)"
  add_hook "$repo" .claude/hooks/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  add_hook "$repo" .claude/hooks/net2.sh '#!/usr/bin/env bash
curl https://example.com/2'
  write_registrations "$repo" PreToolUse .claude/hooks/net.sh PreToolUse .claude/hooks/net2.sh
  write_manifest "$repo" '[
    {"hook":".claude/hooks/net.sh","capabilities":[],"why":"the reach is known and accepted",
     "maintainer_only":false,
     "waived":[{"capability":"network","why":"accepted for the release probe"}]},
    {"hook":".claude/hooks/net2.sh","capabilities":[],"why":"unrelated undeclared","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .claude/hooks/net2.sh network" <<<"$output"
  grep -qF -- "UNDECLARED .claude/hooks/net.sh network" <<<"$output" && return 1
  grep -qF -- "WAIVER .claude/hooks/net.sh network accepted for the release probe" <<<"$output"
}

@test "UAT-008b: the same waiver on an otherwise-clean tree exits 0 and the waiver still prints" {
  repo="$(make_fixture_repo waive-b)"
  add_hook "$repo" .claude/hooks/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_registrations "$repo" PreToolUse .claude/hooks/net.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/net.sh","capabilities":[],
    "why":"the reach is known and accepted","maintainer_only":false,
    "waived":[{"capability":"network","why":"accepted for the release probe"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "WAIVER .claude/hooks/net.sh network accepted for the release probe" <<<"$output"
}

@test "UAT-008c: a waiver over each of the eight non-waivable classes suppresses none of them" {
  repo="$(make_fixture_repo waive-c)"
  add_hook "$repo" .claude/hooks/carrier.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/unresolved.sh '#!/usr/bin/env bash
printf "x\n" > "$mystery"'
  add_hook "$repo" .claude/hooks/badterm.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/lonely.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/dup.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/marking.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" \
    PreToolUse .claude/hooks/carrier.sh \
    PreToolUse .claude/hooks/unresolved.sh \
    PreToolUse .claude/hooks/badterm.sh \
    PreToolUse .claude/hooks/lonely.sh \
    PreToolUse .claude/hooks/dup.sh \
    PreToolUse .claude/hooks/marking.sh \
    PreToolUse '$HOME/.claude/hooks/x.sh'
  write_local_registrations "$repo" Stop .claude/hooks/local-only.sh
  write_manifest "$repo" '[
    {"hook":".claude/hooks/carrier.sh","capabilities":[],"why":"pure","maintainer_only":false,
     "waived":[
       {"capability":"UNRESOLVED","why":"1"},
       {"capability":"BAD-TERM","why":"2"},
       {"capability":"BAD-REGISTRATION","why":"3"},
       {"capability":"NO-ENTRY","why":"4"},
       {"capability":"ORPHAN","why":"5"},
       {"capability":"DUPLICATE","why":"6"},
       {"capability":"MARKING","why":"7"},
       {"capability":"LOCAL-REGISTRATION","why":"8"}
     ]},
    {"hook":".claude/hooks/unresolved.sh","capabilities":[],
     "why":"writes wherever it is told","maintainer_only":false},
    {"hook":".claude/hooks/badterm.sh","capabilities":["exec-anything"],
     "why":"invented term","maintainer_only":false},
    {"hook":".claude/hooks/dup.sh","capabilities":[],"why":"first","maintainer_only":false},
    {"hook":".claude/hooks/dup.sh","capabilities":[],"why":"second","maintainer_only":false},
    {"hook":".claude/hooks/marking.sh","capabilities":[],
     "why":"claims withheld but ships","maintainer_only":true},
    {"hook":".claude/hooks/orphaned.sh","capabilities":[],
     "why":"no registration names it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNRESOLVED .claude/hooks/unresolved.sh" <<<"$output"
  grep -qF -- "BAD-TERM .claude/hooks/badterm.sh exec-anything" <<<"$output"
  grep -qF -- "BAD-REGISTRATION \$HOME/.claude/hooks/x.sh" <<<"$output" || \
    grep -qF -- 'BAD-REGISTRATION $HOME/.claude/hooks/x.sh' <<<"$output"
  grep -qF -- "NO-ENTRY .claude/hooks/lonely.sh" <<<"$output"
  grep -qF -- "ORPHAN .claude/hooks/orphaned.sh" <<<"$output"
  grep -qF -- "DUPLICATE .claude/hooks/dup.sh" <<<"$output"
  grep -qF -- "MARKING .claude/hooks/marking.sh" <<<"$output"
  grep -qF -- "LOCAL-REGISTRATION .claude/hooks/local-only.sh" <<<"$output"
}

# ========== UAT-009, MARKING in both directions ==========

@test "UAT-009: maintainer_only disagreeing with release-exclude is MARKING in both directions" {
  repo="$(make_fixture_repo marking)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/tools/b.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh PreToolUse .claude/hooks/tools/b.sh
  write_exclude "$repo" ".claude/hooks/tools"
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"claims withheld but ships","maintainer_only":true},
    {"hook":".claude/hooks/tools/b.sh","capabilities":[],
    "why":"claims shipped but a directory line withholds it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "MARKING .claude/hooks/a.sh manifest=true release-exclude=false" <<<"$output"
  grep -qF -- "MARKING .claude/hooks/tools/b.sh manifest=false release-exclude=true" <<<"$output"
}

# ========== UAT-010, the CI filter self-coverage ==========
#
# This lives here rather than in workflow-filter-coverage.bats because that
# suite is a FLOOR over paths a gated step names literally in its own run
# body and deliberately puts transitive inputs out of scope (see its own
# header, lines 29-46): it is silent about a manifest a checker reads rather
# than a workflow names. It cannot produce this assertion.

@test "UAT-010: the audit-ci-tests.yml code filter names the hook-capabilities manifest" {
  grep -qF -- "'.gaia/hook-capabilities.json'" "$REPO_ROOT/.github/workflows/audit-ci-tests.yml"
}

@test "UAT-010: the audit-ci-tests.yml code filter names the hook-capabilities schema" {
  grep -qF -- "'.gaia/hook-capabilities.schema.json'" "$REPO_ROOT/.github/workflows/audit-ci-tests.yml"
}

# ========== UAT-013, two-manifest independence ==========

@test "UAT-013: an unregistered .claude/hooks/** file scoped by hook-scopes but absent from hook-capabilities leaves both checks unmoved" {
  repo="$(make_fixture_repo two-manifest)"
  add_hook "$repo" .claude/hooks/registered.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/lib/audit-digest.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/registered.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/registered.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  printf '{"entries":[]}\n' >"$repo/.gaia/state-registry.json"
  printf '{"$schema":"https://json-schema.org/draft/2020-12/schema"}\n' \
    >"$repo/.gaia/hook-scopes.schema.json"

  # Baseline: hook-scopes covers both files, hook-capabilities covers only
  # the registered one. Both checks exit 0.
  cat >"$repo/.gaia/hook-scopes.json" <<'JSON'
{"$schema":"./hook-scopes.schema.json","hooks":[
  {"hook":".claude/hooks/registered.sh","scope":"any","state":[],"why":"x"},
  {"hook":".claude/hooks/lib/audit-digest.sh","scope":"any","state":[],"why":"y"}
]}
JSON
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  run bash "$SCOPE_CHECK" "$repo"
  [ "$status" -eq 0 ]

  # Variant: hook-scopes.json absent. The capability check's verdict does
  # not move.
  mv "$repo/.gaia/hook-scopes.json" "$repo/.gaia/hook-scopes.json.bak"
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  mv "$repo/.gaia/hook-scopes.json.bak" "$repo/.gaia/hook-scopes.json"

  # Variant: hook-scopes.json declares a scope for audit-digest.sh that
  # contradicts nothing in hook-capabilities (there is no entry to
  # contradict). The scope check's verdict does not move when the
  # capability manifest is absent.
  mv "$repo/.gaia/hook-capabilities.json" "$repo/.gaia/hook-capabilities.json.bak"
  run bash "$SCOPE_CHECK" "$repo"
  [ "$status" -eq 0 ]
  mv "$repo/.gaia/hook-capabilities.json.bak" "$repo/.gaia/hook-capabilities.json"
}

@test "UAT-013: neither checker's source names the other manifest's path" {
  grep -qF -- ".gaia/hook-scopes.json" "$CHECK" && return 1
  grep -qF -- ".gaia/hook-capabilities.json" "$SCOPE_CHECK" && return 1
  true
}

# ========== UAT-014, UNRESOLVED on both shapes ==========

@test "UAT-014: an unresolvable invocation target and a separate unresolvable write target are both UNRESOLVED, carrying file and line and their own clearing route" {
  repo="$(make_fixture_repo unresolved-both)"
  add_hook "$repo" .claude/hooks/root.sh '#!/usr/bin/env bash
tool=".claude/hooks/a.sh"
tool=".claude/hooks/b.sh"
bash "$tool"'
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/b.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/w.sh '#!/usr/bin/env bash
printf "x\n" > "$mystery"'
  write_registrations "$repo" PreToolUse .claude/hooks/root.sh PreToolUse .claude/hooks/w.sh
  write_manifest "$repo" '[
    {"hook":".claude/hooks/root.sh","capabilities":[],
     "why":"the target is chosen at run time","maintainer_only":false},
    {"hook":".claude/hooks/w.sh","capabilities":[],
     "why":"writes wherever it is told","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  local inv wri
  inv="$(grep -F -- "UNRESOLVED .claude/hooks/root.sh .claude/hooks/root.sh:4" <<<"$output")"
  wri="$(grep -F -- "UNRESOLVED .claude/hooks/w.sh .claude/hooks/w.sh:2" <<<"$output")"
  [ -n "$inv" ]
  [ -n "$wri" ]
  # An invocation target has two ways out, a write target one. Advising a
  # reader to declare `invokes:` for a write target names a route that cannot
  # clear it, so each direction is asserted against the other's wording too.
  grep -qF -- "-- make the call literal, or declare invokes:<path> for the target" <<<"$inv"
  grep -qF -- "-- make the path literal" <<<"$wri"
  grep -qF -- "invokes:" <<<"$wri" && return 1
  grep -qF -- "make the path literal" <<<"$inv" && return 1
  # The two kinds stay distinct through the closure walk, so every consumer
  # that strips unresolvable records strips both spellings. A missed one
  # arrives as a capability term named after the record itself.
  grep -qF -- "UNRESOLVED-CALL" <<<"$output" && return 1
  grep -qF -- "UNDECLARED" <<<"$output" && return 1
  [ -z "$(gaia_hookcap_reach "$repo" .claude/hooks/root.sh)" ]
  true
}

@test "UAT-014: declaring the invocation target clears its unresolvable line without becoming SURPLUS" {
  repo="$(make_fixture_repo unresolved-cleared)"
  add_hook "$repo" .claude/hooks/root.sh '#!/usr/bin/env bash
tool=".claude/hooks/a.sh"
tool=".claude/hooks/b.sh"
bash "$tool"'
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  add_hook "$repo" .claude/hooks/b.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/root.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/root.sh",
    "capabilities":["invokes:.claude/hooks/a.sh"],
    "why":"the target is declared rather than made literal","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNRESOLVED" <<<"$output" && return 1
  grep -qF -- "SURPLUS" <<<"$output" && return 1
  true
}

# ========== UAT-015, BAD-REGISTRATION on four unrecognized forms ==========

@test "UAT-015: a \$HOME-prefixed, \${VAR}-interpolated, bash -c wrapped, and piped .sh path are each BAD-REGISTRATION" {
  repo="$(make_fixture_repo bad-registration)"
  write_registrations "$repo" \
    PreToolUse '$HOME/.claude/hooks/a.sh' \
    PreToolUse '${HOOK_DIR}/b.sh' \
    PreToolUse 'bash -c .claude/hooks/c.sh' \
    PreToolUse 'cat .claude/hooks/d.sh | bash'
  write_manifest "$repo" '[]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'BAD-REGISTRATION $HOME/.claude/hooks/a.sh' <<<"$output"
  grep -qF -- 'BAD-REGISTRATION ${HOOK_DIR}/b.sh' <<<"$output"
  grep -qF -- 'BAD-REGISTRATION bash -c .claude/hooks/c.sh' <<<"$output"
  grep -qF -- 'BAD-REGISTRATION cat .claude/hooks/d.sh | bash' <<<"$output"
}

# ========== UAT-021, BAD-REGISTRATION on a script-less registration, with a clearing arm ==========

@test "UAT-021: an inline pipeline and a non-shell interpreter registration are each BAD-REGISTRATION; naming a script clears it" {
  repo="$(make_fixture_repo scriptless)"
  write_registrations "$repo" \
    PreToolUse 'echo hi | grep hi' \
    PreToolUse 'python3 .claude/hooks/e.py'
  write_manifest "$repo" '[]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'BAD-REGISTRATION echo hi | grep hi' <<<"$output"
  grep -qF -- 'BAD-REGISTRATION python3 .claude/hooks/e.py' <<<"$output"

  add_hook "$repo" .claude/hooks/f.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/f.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/f.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
}

# ========== UAT-020, a script double-covered by the allowlisted and registered surfaces ==========

@test "UAT-020: an UNDECLARED reached through a shared library located inside that library, not the calling hook" {
  repo="$(make_fixture_repo double-covered)"
  add_hook "$repo" .claude/hooks/caller.sh '#!/usr/bin/env bash
bash .gaia/scripts/shared.sh'
  add_hook "$repo" .gaia/scripts/shared.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_registrations "$repo" PreToolUse .claude/hooks/caller.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/caller.sh","capabilities":["invokes:.gaia/scripts/shared.sh"],
    "why":"omits the network the shared library reaches","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .claude/hooks/caller.sh network .gaia/scripts/shared.sh:2" <<<"$output"
}

# ========== UAT-022, schema and the fs-write:** sentinel ==========

@test "UAT-022a: an entry missing its required why is a schema finding naming that entry" {
  repo="$(make_fixture_repo missing-why)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],"maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-SCHEMA .claude/hooks/a.sh: missing why" <<<"$output"
}

@test "UAT-022b: fs-write:** does not cover a closure that reaches only a literal-prefix glob" {
  repo="$(make_fixture_repo sentinel-not-covering)"
  add_hook "$repo" .claude/hooks/w.sh '#!/usr/bin/env bash
printf "x\n" > "app/data/sub/$name.txt"'
  write_registrations "$repo" PreToolUse .claude/hooks/w.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/w.sh","capabilities":["fs-write:**"],
    "why":"claims blanket","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "SURPLUS .claude/hooks/w.sh fs-write:**" <<<"$output"
}

# ========== UAT-024, no SPEC/UAT id, no maintainer-only path, no prevention vocabulary ==========
#
# Reads 4a's two shipping files. Both assertions are absence checks, so both
# end their failing branch, not their passing one, with the trailing `true`
# per .claude/rules/bats-assertions.md.

@test "UAT-024: the shipped manifest and schema carry no SPEC/UAT id and no maintainer-paths entry" {
  local manifest="$REPO_ROOT/.gaia/hook-capabilities.json"
  local schema="$REPO_ROOT/.gaia/hook-capabilities.schema.json"
  [ -f "$manifest" ] || return 1
  [ -f "$schema" ] || return 1
  grep -qE 'SPEC-[0-9]+|UAT-[0-9]+' "$manifest" "$schema" && return 1
  # release-scrub.yml is YAML: the pattern's double-quoted scalar spells a
  # literal backslash as \\, so the raw grep match carries that doubling and
  # must be collapsed back to \ before the string is a usable ERE.
  local pattern line
  line="$(sed -n '/id: maintainer-paths/,/^      - id:/p' "$REPO_ROOT/.gaia/release-scrub.yml" | grep -m1 'pattern:')"
  pattern="${line#*pattern: \"}"
  pattern="${pattern%\"}"
  pattern="${pattern//\\\\/\\}"
  [ -n "$pattern" ] || return 1
  grep -qE -- "$pattern" "$manifest" "$schema" && return 1
  true
}

@test "UAT-024: the schema's own description carries no prevention vocabulary" {
  local schema="$REPO_ROOT/.gaia/hook-capabilities.schema.json"
  [ -f "$schema" ] || return 1
  local desc
  desc="$(jq -r '.description // empty' "$schema")"
  [ -n "$desc" ] || return 1
  grep -qiE 'prevent|permit|allow|constrain|block' <<<"$desc" && return 1
  true
}

# ========== UAT-025, mutually sourcing files terminate, each visited once ==========

@test "UAT-025: a mutually sourcing fixture pair terminates and reports each file's reach once" {
  repo="$(make_fixture_repo mutual)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
. ".claude/hooks/b.sh"'
  add_hook "$repo" .claude/hooks/b.sh '#!/usr/bin/env bash
. ".claude/hooks/a.sh"
curl https://example.com/'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh",
    "capabilities":["invokes:.claude/hooks/a.sh","invokes:.claude/hooks/b.sh","network"],
    "why":"the two libs source each other","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  run bash "$CHECK" "$repo" --print-reach .claude/hooks/a.sh
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "invokes:.claude/hooks/b.sh" <<<"$output")" -eq 1 ]
}

# ========== UAT-017, the shared oracle, sourced not forked ==========
#
# The vendored pre-fix copy at .gaia/scripts/tests/fixtures/capability-oracle
# /pre-change-oracle.sh (Phase 1's UAT-006 fixture) is a deliberate second
# copy of the pre-fix bodies, not a fork of the checker's own reach. This
# assertion excludes that one known file rather than hardcoding a raw tree-
# wide count, so the load-bearing claim stays "the checker sources the
# oracle and forks nothing" rather than a count that drifts with the fixture
# suite.

@test "UAT-017: the checker sources the shared oracle and defines none of its closure functions itself" {
  grep -qF -- "capability-oracle-lib.sh" "$CHECK"
  local fn
  for fn in _gaia_capcheck_closure _gaia_capcheck_scan_writes _gaia_capcheck_strip_tests; do
    grep -qE -- "^${fn}\(\) \{" "$CHECK" && return 1
  done
  true
}

@test "UAT-017: exactly one production definition of each closure function exists outside the vendored fixture" {
  local fn hits
  local vendored=".gaia/scripts/tests/fixtures/capability-oracle/pre-change-oracle.sh"
  for fn in _gaia_capcheck_closure _gaia_capcheck_scan_writes _gaia_capcheck_strip_tests; do
    hits="$(git -C "$REPO_ROOT" grep -l -E -- "^${fn}\(\) \{" -- '*.sh' \
      | grep -vxF -- "$vendored" || true)"
    [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || return 1
    grep -qxF -- ".gaia/scripts/capability-oracle-lib.sh" <<<"$hits" || return 1
  done
}

# ========== The LOCAL-REGISTRATION arm, plan-authored, no covering UAT ==========

@test "LOCAL-REGISTRATION 1: no .claude/settings.local.json means no finding and no diagnostic" {
  repo="$(make_fixture_repo local-absent)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  [ ! -f "$repo/.claude/settings.local.json" ]
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "LOCAL-REGISTRATION" <<<"$output" && return 1
  true
}

@test "LOCAL-REGISTRATION 2: a local command the committed settings also carries raises no finding" {
  repo="$(make_fixture_repo local-shared)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_local_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "LOCAL-REGISTRATION" <<<"$output" && return 1
  true
}

@test "LOCAL-REGISTRATION 3: a local-only command the committed settings does not carry is a finding naming that command" {
  repo="$(make_fixture_repo local-only)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_local_registrations "$repo" Stop .claude/hooks/local-only.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "LOCAL-REGISTRATION .claude/hooks/local-only.sh" <<<"$output"
}

@test "LOCAL-REGISTRATION 4: the finding is not waivable" {
  repo="$(make_fixture_repo local-waived)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_local_registrations "$repo" Stop .claude/hooks/local-only.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false,
    "waived":[{"capability":"LOCAL-REGISTRATION","why":"attempted suppression"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "LOCAL-REGISTRATION .claude/hooks/local-only.sh" <<<"$output"
}

@test "LOCAL-REGISTRATION 5: a local-only registration creates no coverage obligation; a manifest entry for it is ORPHAN, not a clearer" {
  repo="$(make_fixture_repo local-no-obligation)"
  add_hook "$repo" .claude/hooks/a.sh '#!/usr/bin/env bash
true'
  write_registrations "$repo" PreToolUse .claude/hooks/a.sh
  write_local_registrations "$repo" Stop .claude/hooks/local-only.sh
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "NO-ENTRY .claude/hooks/local-only.sh" <<<"$output" && return 1
  grep -qF -- "LOCAL-REGISTRATION .claude/hooks/local-only.sh" <<<"$output" || return 1

  add_hook "$repo" .claude/hooks/local-only.sh '#!/usr/bin/env bash
true'
  write_manifest "$repo" '[{"hook":".claude/hooks/a.sh","capabilities":[],
    "why":"pure","maintainer_only":false},
    {"hook":".claude/hooks/local-only.sh","capabilities":[],
    "why":"a manifest entry for a local-only command","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "ORPHAN .claude/hooks/local-only.sh" <<<"$output"
  grep -qF -- "LOCAL-REGISTRATION .claude/hooks/local-only.sh" <<<"$output"
}

# ========== UAT-018, the single live-tree arm, flag-gated ==========
#
# The suite's only live-tree closure walk, and it is opt-in for a maintainer
# running this suite by hand: nothing in the repository sets the flag. A
# live-tree walk must stay out of the size-weighted bats-shards.sh partition,
# which weights a suite by file size as a runtime proxy, so a short suite
# shelling out to a minute-long checker would break the partition.
#
# CI does not reach this arm. The dedicated `Hook Capabilities (live tree)`
# job in .github/workflows/audit-ci-tests.yml runs the checker directly and
# bounds it with its own `timeout-minutes`, so the walk is gated there rather
# than here. The 300-second ceiling below is deliberately generous: it exists
# so a non-terminating walk fails loudly instead of hanging, not as a
# performance assertion.

run_bounded() {
  local limit="$1" i
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || {
      wait "$pid" 2>/dev/null
      return 0
    }
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}

@test "real repo: the checker walks every registered hook's closure and exits 0 within 300s" {
  [ "${GAIA_HOOKCAP_LIVE_TREE:-}" = "1" ] || skip "live-tree walk: opt-in, set GAIA_HOOKCAP_LIVE_TREE=1 (CI gates it in its own job, not here)"
  run_bounded 300 bash "$CHECK" "$REPO_ROOT"
  local bounded_status=$?
  [ "$bounded_status" -eq 0 ] || { printf 'the live-tree walk did not finish inside 300s\n' >&2; return 1; }
}

# ========== Real-repo arms, cheap ones ==========
#
# None of these calls gaia_hookcap_reconcile / gaia_hookcap_reach /
# gaia_check_hook_capabilities, so none performs a closure walk. Each reads
# the committed manifest and fails rather than skipping when it is absent,
# so deleting that file cannot retire an assertion into a silent pass.

@test "real repo: the check script is executable" {
  [ -x "$CHECK" ]
}

@test "real repo: sourcing the check produces no output and defines every assertion" {
  run bash -c "source '$CHECK' && printf 'sourced\n'"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced" ]
  local f
  for f in gaia_hookcap_obligated gaia_hookcap_coverage gaia_hookcap_schema \
    gaia_hookcap_vocabulary gaia_hookcap_reconcile gaia_hookcap_marking \
    gaia_hookcap_waivers gaia_hookcap_local_registrations gaia_hookcap_reach \
    gaia_hookcap_print_reach gaia_check_hook_capabilities; do
    declare -f "$f" >/dev/null || return 1
  done
}

@test "real repo: the manifest conforms to its schema" {
  run gaia_hookcap_schema "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every registered hook has exactly one entry, with no orphans or duplicates" {
  run gaia_hookcap_coverage "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every declared term is in the closed vocabulary" {
  run gaia_hookcap_vocabulary "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every maintainer_only marking agrees with the release boundary" {
  run gaia_hookcap_marking "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
