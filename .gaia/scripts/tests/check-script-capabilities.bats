#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-script-capabilities.sh, the
# reconciliation between what an allowlisted script DECLARES it can do and what
# the tree actually lets it reach.
#
# Every test drives the check against a throwaway repo built under
# $BATS_TEST_TMPDIR and handed to the check as its <repo_root> positional, so no
# test reads or mutates this repository's own settings, manifest, or exclude
# file. The real-tree arm lives beside this one.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-script-capabilities.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-script-capabilities.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-script-capabilities.sh
  source "$CHECK"
}

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR carrying the
# three files the check reads unconditionally -- an empty allow list, an empty
# release-exclude, and a placeholder schema file. Callers add scripts and a
# manifest. Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1" dir
  dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude" "$dir/.gaia"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf '{"permissions":{"allow":[]}}\n' >"$dir/.claude/settings.json"
  printf '# fixture distribution boundary\n' >"$dir/.gaia/release-exclude"
  printf '{"$schema":"https://json-schema.org/draft/2020-12/schema"}\n' \
    >"$dir/.gaia/script-capabilities.schema.json"
  printf '%s' "$dir"
}

# write_allow <repo> <allow-entry>...: the permissions.allow list the obligated
# set is derived from.
write_allow() {
  local repo="$1" json="" e
  shift
  for e in "$@"; do json="${json:+$json,}\"$e\""; done
  printf '{"permissions":{"allow":[%s]}}\n' "$json" >"$repo/.claude/settings.json"
}

# write_manifest <repo> <scripts-array-json>: the raw `scripts` array text,
# brackets included.
write_manifest() {
  printf '{"$schema":"./script-capabilities.schema.json","scripts":%s}\n' "$2" \
    >"$1/.gaia/script-capabilities.json"
}

# add_script <repo> <relpath> <body>
add_script() {
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

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m fixture
}

@test "a fixture whose declarations match its reach exactly passes with no finding" {
  repo="$(make_fixture_repo clean)"
  add_script "$repo" .gaia/scripts/clean.sh '#!/usr/bin/env bash
mkdir -p "$ROOT/state"
printf "x\n" > "$ROOT/state/out.txt"'
  write_allow "$repo" "Bash(bash .gaia/scripts/clean.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/clean.sh",
    "capabilities":["fs-write:state","fs-write:state/out.txt"],
    "why":"writes its own state area","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED|NO-ENTRY|ORPHAN|DUPLICATE|BAD-)' <<<"$output" && return 1
  grep -qF -- "every allowlisted script declares exactly the reach it has" <<<"$output"
}

@test "a script that grows a literal curl line while its entry omits network is UNDECLARED" {
  repo="$(make_fixture_repo undeclared)"
  add_script "$repo" .gaia/scripts/net.sh '#!/usr/bin/env bash
curl https://example.com/thing'
  write_allow "$repo" "Bash(bash .gaia/scripts/net.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/net.sh","capabilities":[],
    "why":"declared as reaching nothing","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .gaia/scripts/net.sh network .gaia/scripts/net.sh:2" <<<"$output"
}

@test "a capability the declared invokes target reaches is attributed to the allowlisted caller" {
  repo="$(make_fixture_repo transitive)"
  add_script "$repo" .gaia/scripts/root.sh '#!/usr/bin/env bash
bash "$hook_path"'
  add_script "$repo" hooks/net.sh '#!/usr/bin/env bash
curl https://example.com/status'
  write_allow "$repo" "Bash(bash .gaia/scripts/root.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/root.sh",
    "capabilities":["invokes:hooks/net.sh"],
    "why":"reaches the hook through a variable","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .gaia/scripts/root.sh network hooks/net.sh:2" <<<"$output"
}

@test "an allow entry naming a script with no manifest entry is NO-ENTRY" {
  repo="$(make_fixture_repo noentry)"
  add_script "$repo" .gaia/scripts/lonely.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/lonely.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/other.sh","capabilities":[],
    "why":"placeholder","maintainer_only":false}]'
  add_script "$repo" .gaia/scripts/other.sh '#!/usr/bin/env bash
true'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "NO-ENTRY .gaia/scripts/lonely.sh" <<<"$output"
}

@test "a manifest entry no allow grant names is ORPHAN" {
  repo="$(make_fixture_repo orphan)"
  add_script "$repo" .gaia/scripts/kept.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/gone.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/kept.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/kept.sh","capabilities":[],
    "why":"pure","maintainer_only":false},
    {"script":".gaia/scripts/gone.sh","capabilities":[],
    "why":"no grant names it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "ORPHAN .gaia/scripts/gone.sh" <<<"$output"
}

@test "a shell script no allow grant names and no entry carries is not a finding" {
  repo="$(make_fixture_repo unrelated)"
  add_script "$repo" .gaia/scripts/kept.sh '#!/usr/bin/env bash
true'
  add_script "$repo" scripts/unrelated.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_allow "$repo" "Bash(bash .gaia/scripts/kept.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/kept.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "unrelated.sh" <<<"$output" && return 1
  true
}

@test "a term outside the six-term vocabulary is BAD-TERM" {
  repo="$(make_fixture_repo badterm)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":["exec-anything"],
    "why":"invented term","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-TERM .gaia/scripts/pure.sh exec-anything" <<<"$output"
}

@test "an absolute or dot-dot bearing fs-write glob is BAD-TERM" {
  repo="$(make_fixture_repo badglob)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh",
    "capabilities":["fs-write:/**","fs-write:../outside/**"],
    "why":"escapes the repo","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-TERM .gaia/scripts/pure.sh fs-write:/**" <<<"$output"
  grep -qF -- "BAD-TERM .gaia/scripts/pure.sh fs-write:../outside/**" <<<"$output"
}

@test "two manifest entries naming the same script are DUPLICATE" {
  repo="$(make_fixture_repo duplicate)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"first","maintainer_only":false},
    {"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"second","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "DUPLICATE .gaia/scripts/pure.sh" <<<"$output"
}

@test "a missing or non-boolean maintainer_only and an empty why are BAD-SCHEMA" {
  repo="$(make_fixture_repo badschema)"
  add_script "$repo" .gaia/scripts/a.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/b.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/c.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/a.sh:*)" \
    "Bash(bash .gaia/scripts/b.sh:*)" "Bash(bash .gaia/scripts/c.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/a.sh","capabilities":[],"why":"no marking"},
    {"script":".gaia/scripts/b.sh","capabilities":[],"why":"string marking","maintainer_only":"false"},
    {"script":".gaia/scripts/c.sh","capabilities":[],"why":"","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-SCHEMA .gaia/scripts/a.sh: missing maintainer_only" <<<"$output"
  grep -qF -- "BAD-SCHEMA .gaia/scripts/b.sh: maintainer_only is not a boolean" <<<"$output"
  grep -qF -- "BAD-SCHEMA .gaia/scripts/c.sh: why is empty" <<<"$output"
}

@test "a dot-dot bearing source target normalizes before anything compares it" {
  repo="$(make_fixture_repo dotdot)"
  add_script "$repo" a/b/s.sh '#!/usr/bin/env bash
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_d}/../../x.sh" 2>/dev/null || true'
  add_script "$repo" x.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash a/b/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/b/s.sh","capabilities":["invokes:x.sh"],
    "why":"sources the shared lib through a relative hop","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNRESOLVED" <<<"$output" && return 1
  grep -qF -- "SURPLUS" <<<"$output" && return 1
  true
}

@test "a file-relative shellcheck source directive resolves against the sourcing file" {
  repo="$(make_fixture_repo screl)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
# shellcheck source=../x.sh
. "$LIB_PATH"'
  add_script "$repo" x.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":["invokes:x.sh"],
    "why":"the directive names the target","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNRESOLVED" <<<"$output" && return 1
  true
}

@test "a write built from a literal prefix and a variable tail generalizes to a glob" {
  repo="$(make_fixture_repo prefixglob)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
d="$root/a/b"
printf "x\n" > "$d/$name.txt"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:a/b/**"],
    "why":"writes a computed basename under a fixed directory","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNRESOLVED" <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  grep -qxF -- "fs-write:a/b/**" <<<"$output"
}

@test "a write whose very first segment is an unresolvable variable is UNRESOLVED" {
  repo="$(make_fixture_repo nowriteprefix)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
printf "x\n" > "$mystery"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":[],
    "why":"writes wherever it is told","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNRESOLVED .gaia/scripts/w.sh .gaia/scripts/w.sh:2" <<<"$output"
}

@test "a write into a positional-derived directory with a literal suffix is one caller-chosen term" {
  repo="$(make_fixture_repo callerwithsuffix)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
target="$1"
rm -f "$target/RUNNING"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"clears a sentinel inside the directory it is handed","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  grep -qF -- "fs-write:RUNNING" <<<"$output" && return 1
  grep -qxF -- "fs-write:**" <<<"$output"
}

@test "a write into a positional-derived directory with no suffix is the same caller-chosen term" {
  repo="$(make_fixture_repo callernosuffix)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
target="$1"
rm -rf -- "$target"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"deletes the directory it is handed","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  grep -qxF -- "fs-write:**" <<<"$output"
}

@test "a write through a variable whose assignment ends in a positional is caller-chosen too" {
  repo="$(make_fixture_repo callerchained)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
raw="$1"
dir="$root/$raw"
find "$dir" -mindepth 1 -exec rm -rf {} +'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"prunes the folder its caller names","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  grep -qxF -- "fs-write:**" <<<"$output"
}

@test "a positional joined to a path the repo has is read as a checkout root, not a caller directory" {
  repo="$(make_fixture_repo callerroot)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
ROOT="$1"
printf "x\n" > "$ROOT/.gaia/state.json"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh",
    "capabilities":["fs-write:.gaia/state.json"],
    "why":"writes into the .gaia area of the checkout it is pointed at","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  grep -qxF -- "fs-write:**" <<<"$output" && return 1
  grep -qxF -- "fs-write:.gaia/state.json" <<<"$output"
}

@test "print-reach runs with no manifest on disk and exits 0" {
  repo="$(make_fixture_repo noreachmanifest)"
  add_script "$repo" .gaia/scripts/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_allow "$repo" "Bash(bash .gaia/scripts/net.sh:*)"
  [ ! -f "$repo/.gaia/script-capabilities.json" ]
  run bash "$CHECK" "$repo" --print-reach
  [ "$status" -eq 0 ]
  grep -qF -- "network" <<<"$output"
}

@test "print-reach gives a pure script its own empty-reach line" {
  repo="$(make_fixture_repo purereach)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)" "Bash(bash .gaia/scripts/net.sh:*)"
  run bash "$CHECK" "$repo" --print-reach
  [ "$status" -eq 0 ]
  grep -qF -- ".gaia/scripts/pure.sh	-" <<<"$output"
}

@test "an invocation target with two disagreeing assignments is UNRESOLVED and names both routes" {
  repo="$(make_fixture_repo twoassign)"
  add_script "$repo" .gaia/scripts/root.sh '#!/usr/bin/env bash
tool=".gaia/scripts/a.sh"
tool=".gaia/scripts/b.sh"
bash "$tool"'
  add_script "$repo" .gaia/scripts/a.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/b.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/root.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/root.sh","capabilities":[],
    "why":"the target is chosen at run time","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNRESOLVED .gaia/scripts/root.sh .gaia/scripts/root.sh:4" <<<"$output"
  grep -qF -- "make the call literal, or declare invokes:<path> for the target" <<<"$output"
}

@test "declaring the target clears that unresolvable line without becoming SURPLUS" {
  repo="$(make_fixture_repo declaredtarget)"
  add_script "$repo" .gaia/scripts/root.sh '#!/usr/bin/env bash
tool=".gaia/scripts/a.sh"
tool=".gaia/scripts/b.sh"
bash "$tool"'
  add_script "$repo" .gaia/scripts/a.sh '#!/usr/bin/env bash
true'
  add_script "$repo" .gaia/scripts/b.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/root.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/root.sh",
    "capabilities":["invokes:.gaia/scripts/a.sh"],
    "why":"the target is declared rather than made literal","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNRESOLVED" <<<"$output" && return 1
  grep -qF -- "SURPLUS" <<<"$output" && return 1
  true
}

@test "a declared capability nothing in the closure reaches is SURPLUS" {
  repo="$(make_fixture_repo surplus)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":["network"],
    "why":"claims more than it does","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "SURPLUS .gaia/scripts/pure.sh network" <<<"$output"
}

@test "a bare mktemp and a root-variable write reduce to the repo-relative declaration" {
  repo="$(make_fixture_repo tmpandroot)"
  add_script "$repo" .gaia/scripts/t.sh '#!/usr/bin/env bash
scratch="$(mktemp)"
out="$ROOT/state/data.json"
printf "x\n" > "$out"'
  write_allow "$repo" "Bash(bash .gaia/scripts/t.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/t.sh",
    "capabilities":["tmp","fs-write:state/**"],
    "why":"stages in the system temp dir and publishes into its state area",
    "maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "maintainer_only disagreeing with release-exclude is MARKING in both directions" {
  repo="$(make_fixture_repo marking)"
  add_script "$repo" .gaia/scripts/a.sh '#!/usr/bin/env bash
true'
  add_script "$repo" tools/b.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/a.sh:*)" "Bash(bash tools/b.sh:*)"
  write_exclude "$repo" "tools"
  write_manifest "$repo" '[{"script":".gaia/scripts/a.sh","capabilities":[],
    "why":"claims withheld but ships","maintainer_only":true},
    {"script":"tools/b.sh","capabilities":[],
    "why":"claims shipped but a directory line withholds it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "MARKING .gaia/scripts/a.sh manifest=true release-exclude=false" <<<"$output"
  grep -qF -- "MARKING tools/b.sh manifest=false release-exclude=true" <<<"$output"
}

@test "a waiver suppresses an otherwise-failing UNDECLARED and still prints its line" {
  repo="$(make_fixture_repo waiveundeclared)"
  add_script "$repo" .gaia/scripts/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_allow "$repo" "Bash(bash .gaia/scripts/net.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/net.sh","capabilities":[],
    "why":"the reach is known and accepted","maintainer_only":false,
    "waived":[{"capability":"network","why":"accepted for the release probe"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "UNDECLARED" <<<"$output" && return 1
  grep -qF -- "WAIVER .gaia/scripts/net.sh network accepted for the release probe" <<<"$output"
}

@test "a waiver suppresses an otherwise-failing SURPLUS and still prints its line" {
  repo="$(make_fixture_repo waivesurplus)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":["network"],
    "why":"the declaration is held deliberately ahead of the code",
    "maintainer_only":false,
    "waived":[{"capability":"network","why":"held ahead of the code"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "SURPLUS" <<<"$output" && return 1
  grep -qF -- "WAIVER .gaia/scripts/pure.sh network held ahead of the code" <<<"$output"
}

@test "a waiver suppresses only its own pair, never a BAD-TERM or a MARKING" {
  repo="$(make_fixture_repo waivescope)"
  add_script "$repo" .gaia/scripts/net.sh '#!/usr/bin/env bash
curl https://example.com/'
  write_allow "$repo" "Bash(bash .gaia/scripts/net.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/net.sh","capabilities":["exec-anything"],
    "why":"one waived pair, two live findings of other classes",
    "maintainer_only":true,
    "waived":[{"capability":"network","why":"accepted"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED" <<<"$output" && return 1
  grep -qF -- "BAD-TERM .gaia/scripts/net.sh exec-anything" <<<"$output"
  grep -qF -- "MARKING .gaia/scripts/net.sh manifest=true release-exclude=false" <<<"$output"
}

@test "a waiver on a passing tree still prints its line" {
  repo="$(make_fixture_repo waivepassing)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"reaches nothing","maintainer_only":false,
    "waived":[{"capability":"git-write","why":"kept while the caller is reworked"}]}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "WAIVER .gaia/scripts/pure.sh git-write kept while the caller is reworked" <<<"$output"
}

@test "an allow entry naming a dot-sh path in an unrecognized form is BAD-GRANT" {
  repo="$(make_fixture_repo badgrant)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)" \
    "Bash(sh .gaia/scripts/pure.sh --flag:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "BAD-GRANT Bash(sh .gaia/scripts/pure.sh --flag:*)" <<<"$output"
}

@test "an allow entry carrying sh only inside the word bash is not a BAD-GRANT" {
  repo="$(make_fixture_repo shinbash)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)" "Bash(pnpm run lint:*)" \
    "Bash(bash -lc *)" "Bash(gh pr view:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "BAD-GRANT" <<<"$output" && return 1
  true
}

@test "a cycle in the declared closure terminates and still reports a verdict" {
  repo="$(make_fixture_repo cycle)"
  add_script "$repo" .gaia/scripts/a.sh '#!/usr/bin/env bash
. ".gaia/scripts/b.sh"'
  add_script "$repo" .gaia/scripts/b.sh '#!/usr/bin/env bash
. ".gaia/scripts/a.sh"'
  write_allow "$repo" "Bash(bash .gaia/scripts/a.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/a.sh",
    "capabilities":["invokes:.gaia/scripts/a.sh","invokes:.gaia/scripts/b.sh"],
    "why":"the two libs source each other","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/a.sh
  [ "$status" -eq 0 ]
  [ "$(grep -c 'invokes:.gaia/scripts/b.sh' <<<"$output")" -eq 1 ]
}

@test "the check's own failures exit 2 rather than 0 or 1" {
  repo="$(make_fixture_repo exit2)"
  add_script "$repo" .gaia/scripts/pure.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash .gaia/scripts/pure.sh:*)"

  run bash "$CHECK" "$repo"
  [ "$status" -eq 2 ]
  grep -qF -- "missing or unreadable .gaia/script-capabilities.json" <<<"$output"

  printf 'not json at all\n' >"$repo/.gaia/script-capabilities.json"
  run bash "$CHECK" "$repo"
  [ "$status" -eq 2 ]
  grep -qF -- "is not valid JSON" <<<"$output"

  write_manifest "$repo" '[{"script":".gaia/scripts/pure.sh","capabilities":[],
    "why":"pure","maintainer_only":false}]'
  chmod 000 "$repo/.gaia/scripts/pure.sh"
  run bash "$CHECK" "$repo"
  chmod 644 "$repo/.gaia/scripts/pure.sh"
  [ "$status" -eq 2 ]
  grep -qF -- "unreadable obligated script" <<<"$output"

  mkdir -p "$BATS_TEST_TMPDIR/emptybin"
  run env "PATH=$BATS_TEST_TMPDIR/emptybin" "$BASH" "$CHECK" "$repo"
  [ "$status" -eq 2 ]
  grep -qF -- "jq not found on PATH" <<<"$output"
}

@test "the verdict from a linked worktree matches the verdict from the main checkout" {
  repo="$(make_fixture_repo worktree)"
  add_script "$repo" .gaia/scripts/t.sh '#!/usr/bin/env bash
scratch="$(mktemp)"
out="$ROOT/state/data.json"
printf "x\n" > "$out"'
  write_allow "$repo" "Bash(bash .gaia/scripts/t.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/t.sh",
    "capabilities":["tmp","fs-write:state/**"],
    "why":"stages in the system temp dir and publishes into its state area",
    "maintainer_only":false}]'
  commit_all "$repo"
  git -C "$repo" worktree add -q -b side "$BATS_TEST_TMPDIR/wt"

  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  main_out="$output"
  run bash "$CHECK" "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 0 ]
  [ "$output" = "$main_out" ]
}

@test "a bare unknown flag exits 2 with a usage message on stderr" {
  run bash -c "bash '$CHECK' --nonsense 2>&1 1>/dev/null"
  [ "$status" -eq 2 ]
  grep -qF -- "usage: check-script-capabilities.sh" <<<"$output"
}

@test "sourcing the check produces no output and defines every assertion" {
  run bash -c "source '$CHECK' && printf 'sourced\n'"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced" ]
  local f
  for f in gaia_capcheck_obligated gaia_capcheck_coverage gaia_capcheck_schema \
    gaia_capcheck_vocabulary gaia_capcheck_reach gaia_capcheck_reconcile \
    gaia_capcheck_marking gaia_capcheck_waivers gaia_check_script_capabilities; do
    declare -f "$f" >/dev/null || return 1
  done
}

# ========== real repo ==========
#
# Every test below drives the check against THIS repository's own tree
# (REPO_ROOT), mirroring check-hook-scope-manifest.bats's real-tree arm. No
# test here mutates .claude/settings.json, .gaia/script-capabilities.json, or
# .gaia/release-exclude; they only read the tree as it stands.

@test "real repo: the check script is executable" {
  [ -x "$CHECK" ]
}

@test "real repo: sourcing the script defines its functions with no side effects" {
  run bash -c "source '$CHECK' && printf 'sourced\n'"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced" ]
}

@test "real repo: the manifest conforms to its schema" {
  run gaia_capcheck_schema "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every allowlisted script has exactly one entry, with no orphans or duplicates" {
  run gaia_capcheck_coverage "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every declared term is in the closed vocabulary" {
  run gaia_capcheck_vocabulary "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: every maintainer_only marking agrees with the release boundary" {
  run gaia_capcheck_marking "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "real repo: the full reconciliation gate passes" {
  run bash "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "real repo: no obligated script reports an unresolvable invocation at the three named idiom-4 sites" {
  run bash "$CHECK" "$REPO_ROOT"
  # audit-write-clearance.sh:status_hook, resolve-audit-spawn.sh:resolver, and
  # plan-archive.sh:verify_script are the three one-hop-constant-propagation
  # sites; each resolves its invoked script, so none of the three surfaces its
  # own variable target on an UNRESOLVED line.
  grep -qF -- 'status_hook' <<<"$output" && return 1
  grep -qF -- 'resolver=' <<<"$output" && return 1
  grep -qF -- 'verify_script' <<<"$output" && return 1
  true
}
