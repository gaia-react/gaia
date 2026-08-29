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
  PRE_CHANGE="$SCRIPT_DIR/tests/fixtures/capability-oracle/pre-change-oracle.sh"
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

# --- Idiom: a script executed by its OWN path, no interpreter word ----------
#
# `_gaia_capcheck_scan_bare_invocations`. The arms come in pairs on purpose:
# each positive is followed by the negative that would fire if the detector's
# anchor or its token shape were widened by one notch, because the failure this
# idiom repairs was SILENCE and the failure a loose version introduces is a
# fabricated call edge into a subtree the caller never runs.

@test "a script run by its own path inside a command substitution is a call" {
  repo="$(make_fixture_repo barecall)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
BASE="$(.github/audit/base.sh 2>/dev/null || true)"
printf "%s\n" "$BASE"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":["invokes:.github/audit/base.sh"],
    "why":"runs the base resolver by its own path","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach a/s.sh
  [ "$status" -eq 0 ]
  grep -qxF -- "invokes:.github/audit/base.sh" <<<"$output"
}

@test "a bare-path call carries its target's whole subtree into the closure" {
  # The point of the idiom. Reporting the edge and stopping there would leave
  # the same capabilities outside the closure the edge exists to open.
  #
  # The manifest declares NOTHING, deliberately. Declaring the `invokes:` target
  # would put it on the frontier by declaration, so the target's subtree would
  # be walked whether or not the detector ever found the edge, and the `network`
  # assertion below would hold against a detector that matched nothing at all.
  repo="$(make_fixture_repo baresubtree)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
.github/audit/base.sh'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the base resolver by its own path","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
  grep -qF -- "UNDECLARED a/s.sh network" <<<"$output"
}

@test "a bare path in command position that resolves to nothing is UNRESOLVED-CALL, not silence" {
  # The whole defect this idiom repairs was a call site that produced no record
  # at all. A shape the detector accepts and cannot resolve has to say so.
  repo="$(make_fixture_repo bareunres)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
"$mystery"/runner.sh'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs whatever the variable names","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNRESOLVED a/s.sh a/s.sh:2" <<<"$output"
}

@test "a bare-path call whose operand list ends at a separator is still a call" {
  # The trailing group is the token's boundary, and requiring whitespace there
  # dropped `$(<path>)` with no arguments while detecting the same call the
  # moment it grew one flag. Both spellings run the script.
  #
  # Two fixtures, one per separator, and the manifest declares nothing for the
  # same reason `baresubtree` above declares nothing.
  repo="$(make_fixture_repo baretrailingparen)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
X="$(.github/audit/base.sh)"
printf "%s\n" "$X"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the base resolver by its own path","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"

  repo="$(make_fixture_repo baretrailingsemi)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
.github/audit/base.sh; printf "done\n"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the base resolver by its own path","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "a script path behind plain whitespace is an operand, not a call" {
  # `[ -f <path> ]` and `--flag <path>` both put a real repo path one space
  # after another word. Reading either as a call would open a closure edge on
  # a line that runs nothing.
  repo="$(make_fixture_repo bareoperand)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
if [ -f .github/audit/base.sh ]; then
  printf "%s\n" --base .github/audit/base.sh
fi'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver without running it","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a script path in a parenthetical inside a message is prose, not a call" {
  # The reason _GAIA_CAPCHECK_PATHCMD narrows the bare `(` to `$(`: a deny
  # message naming a script in a parenthetical puts a real repo path behind a
  # real `(`, and no blanking reaches it the way it reaches a command word.
  repo="$(make_fixture_repo bareprose)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "%s\n" "BLOCKED: may not run the writer (.github/audit/base.sh). Report it."'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the writer in a message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a command-position word with no directory separator is not a bare-path call" {
  # `mktemp.sh` in command position is a PATH lookup, not a file in this tree,
  # and the separator is the line the detector draws rather than testing every
  # command-position token against the filesystem.
  repo="$(make_fixture_repo baresep)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
base.sh'
  add_script "$repo" base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs whatever PATH resolves","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

# --- Idiom: a command in the condition of `if`, `while`, or `until` ---------
#
# A condition is command position, so the SOURCE detector reads one: `if`,
# `while` and `until` are on _GAIA_CAPCHECK_DOTCMD, and the failure of missing
# a keyword there is SILENCE -- not an UNRESOLVED line, nothing at all. That is
# why each keyword is pinned by name here rather than left to the alternation's
# shape.
#
# The two anchors share `then`, `else`, `do`, `elif` and `!` and DIVERGE on
# these three: _GAIA_CAPCHECK_PATHCMD does not name them, so the bare-path
# detector deliberately does NOT read a condition. That is the third named
# departure in that constant's header, and it is why the pairs below are pairs.
# `if` is ordinary English in a way `then` and `elif` are not, so what makes it
# affordable on the source anchor is the lone-`.` blanking, which reaches a
# source and does not reach a path; the negatives carry more weight than the
# positives here because that asymmetry is the whole decision.

@test "a source in the condition of an if, while, or until is a call, not silence" {
  repo="$(make_fixture_repo dotkwif)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
if . .github/audit/base.sh; then true; fi'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"sources the base resolver from a condition","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
  grep -qF -- "UNDECLARED a/s.sh network" <<<"$output"

  repo="$(make_fixture_repo dotkwwhile)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
while . .github/audit/base.sh; do break; done'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"sources the base resolver from a condition","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"

  repo="$(make_fixture_repo dotkwuntil)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
until . .github/audit/base.sh; do break; done'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"sources the base resolver from a condition","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "a lone dot after if that is jq's identity filter is not a source" {
  # `if . == null then` is a jq program, and its `.` is the identity filter
  # rather than the source builtin. TWO layers keep it out of the closure, and
  # this fixture pins the second because the first cannot reach it here.
  #
  # The first is the word blanking in _gaia_capcheck_strip_quoted_code: a lone
  # `.` is one of _GAIA_CAPCHECK_QUOTED_WORDS, so inside an ordinary
  # double-quoted span the `\.` the anchor requires has nothing left to match.
  # That blanking has its own pin, the test directly below. It is deliberately
  # NOT what this fixture rests on: a line the blanking already silences never
  # reaches the anchor, so it can assert nothing about anything downstream.
  #
  # So the program sits inside a COMMAND SUBSTITUTION, which is the one
  # uncovered case _GAIA_CAPCHECK_DOTCMD's header names: strip_quoted_code
  # bails on a whole line carrying `$(` and blanks nothing on it (#1536). The
  # lone `.` survives, the anchor fires on ` if . `, and the only thing left is
  # the second layer -- the operand filter in _gaia_capcheck_scan_invocations,
  # which skips an operand carrying neither a `/` nor a `.sh` tail. Loosen that
  # filter and this test reports UNRESOLVED for `==`.
  #
  # The `if` sits behind a space rather than against the opening quote for the
  # reason the barekwprose comment below gives: against the quote the
  # `(^|[[:space:]])` guard fails, the anchor never matches, and the fixture
  # asserts nothing at all.
  repo="$(make_fixture_repo dotkwjq)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
x="$(jq -r ".result | if . == null then 1 else 2 end" /dev/null)"
printf "%s\n" "$x"'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"reads a jq program that names no script","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "the lone dot blanking is what keeps a source named in prose out of a closure" {
  # The premise the DOTCMD/PATHCMD split rests on, pinned. `if`, `while` and
  # `until` are affordable on the source anchor and not on the path anchor for
  # exactly one reason: a lone `.` is in _GAIA_CAPCHECK_QUOTED_WORDS and is
  # blanked inside a double-quoted span, so a sentence naming a source has
  # nothing left for the anchor to match, while nothing blanks a path.
  #
  # Nothing else in this tree held that reason to its word. Drop the lone `.`
  # from that list and every other guard here stays green while this fixture
  # starts reporting a fabricated CALL edge into the target and its whole
  # subtree: the over-read the third named departure in _GAIA_CAPCHECK_PATHCMD's
  # header exists to avoid, arriving through the source side instead.
  #
  # Both halves of the fixture are load-bearing. The `if` sits mid-sentence
  # behind a space, because against the opening quote the anchor never runs.
  # The operand is a real repo path rather than a jq token, because the scan's
  # own filter drops any operand carrying neither a `/` nor a `.sh` tail before
  # it resolves anything.
  repo="$(make_fixture_repo dotkwblank)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "%s\n" "stop if . .github/audit/base.sh is missing"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names a sourced file in a message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a bare path in an if condition is deliberately NOT a call, unlike a source there" {
  # The third named departure between the two anchors, pinned because it is a
  # deliberate under-read and a reader will otherwise repair it as an oversight.
  # `.` and a bare path are treated differently on purpose: a lone `.` is a
  # QUOTED_WORD, so prose naming it is blanked before any anchor runs, while
  # nothing blanks a repo path. Naming `if` on the path anchor would therefore
  # expose every message string carrying ` if <path>.sh `, and measured on the
  # real tree it buys no reach at all, because no shape here runs a bare path
  # out of a condition. The paired positive is the source form in the test
  # above, which IS detected.
  #
  # The `if` is INDENTED on purpose. Every keyword arm requires the keyword at
  # a line start or behind whitespace, so a fixture with `if` in column 0 would
  # stay green under the one mutation this test exists to catch, naming `if` on
  # the path anchor behind whitespace, and would assert nothing.
  repo="$(make_fixture_repo barekwdeparture)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
f() {
  if .github/audit/base.sh; then true; fi
}
f'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the base resolver from a condition","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a script path after if inside a message is prose, not a call" {
  # What the departure above buys, stated as the shape it protects. The keyword
  # sits MID-SENTENCE here, behind a space, which is the position the anchor
  # would actually match; putting `if` immediately after the opening quote
  # instead would make this test pass on the anchor missing the line entirely
  # and assert nothing about prose.
  #
  # Nothing blanks this span. _gaia_capcheck_strip_quoted_code blanks command
  # words and `>`, never a repo path, so the line reaches the detector intact
  # and the anchor is the only thing standing between it and a fabricated edge
  # into the target's whole subtree. Name `if` on _GAIA_CAPCHECK_PATHCMD and
  # this fixture reports UNDECLARED for both the edge and the target's network.
  repo="$(make_fixture_repo barekwprose)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "%s\n" "stop if .github/audit/base.sh is missing"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver in a message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a script path opening a here-document body is text, not a call" {
  # The negative the `^` arm has been missing. Its positive is the subtree test
  # above: a path alone at the start of a line is an execution. A here-document
  # body line begins the same way and runs nothing, and what separates the two
  # is the here-doc handling upstream of the anchor rather than the anchor
  # itself -- so widening either one fabricates an edge into a subtree the
  # caller never enters.
  repo="$(make_fixture_repo bareheredoc)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
cat <<EOF
.github/audit/base.sh is the writer
EOF'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"prints the resolver name in a here-document","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a bare path alone on a line inside an array literal is an element, not a call" {
  # The `^` arm's negative for the shape the here-document arm above does not
  # cover. An array element and a bare execution are the same bytes on the same
  # line; only the state carried from `files=(` separates them, and the splitter
  # is where that state lives.
  repo="$(make_fixture_repo barearray)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
files=(
.github/audit/base.sh
)
printf "%s\n" "${files[0]}"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver as an array element","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a bare path alone on a line inside a multi-line message string is prose, not a call" {
  # The same `^` arm negative for the shape this tree actually carries: a deny
  # message spanning real lines, with a script path opening one of them.
  repo="$(make_fixture_repo baremultiline)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
reason="the resolver cannot answer.

.github/audit/base.sh exited non-zero, so the member set is unknown.
"
printf "%s\n" "$reason"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver in a multi-line message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a multi-line string ending mid-line does not swallow the call beside it" {
  # The positive that bounds the two negatives above. Suppressing a whole line
  # because a string opened on an earlier one would lose a real call written
  # after the closing quote, and that loss is silent.
  repo="$(make_fixture_repo baremultilineresume)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
reason="first
second" && .github/audit/base.sh --now'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the resolver after a multi-line message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "a call inside a multi-line command substitution is still a call" {
  # The other bound. A substitution body is code however many lines it spans,
  # so the state that suppresses a string body must not suppress this.
  repo="$(make_fixture_repo baremultilinesubst)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
out="$(
  .github/audit/base.sh --x
)"
printf "%s\n" "$out"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the resolver inside a multi-line substitution","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "a substitution on a continuation line of a carried body is still a call" {
  # The reverse nesting of the bound above, and the one the carried state gets
  # wrong in the silent direction if the body is suppressed wholesale. A
  # `$( )` inside a double-quoted string RUNS, whichever line of that string it
  # sits on, so the line carrying it cannot be dropped just because the string
  # around it was opened earlier. Suppressing the line loses the call and its
  # whole transitive reach, and the gate then reports the caller declares
  # exactly what it has.
  #
  # The sibling above puts its `$(` at the END of the opening line, which
  # leaves the substitution frame on top and passes the line through, so it
  # never reaches this case.
  local body idx=0
  for body in 'msg="first line
second $(bash .github/audit/base.sh) tail"
printf "%s\n" "$msg"' 'args=(
  "$(bash .github/audit/base.sh)"
)
printf "%s\n" "${args[0]}"'; do
    idx=$((idx + 1))
    repo="$(make_fixture_repo "carriedsubst$idx")"
    add_script "$repo" a/s.sh "#!/usr/bin/env bash
$body"
    add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
    write_allow "$repo" "Bash(bash a/s.sh:*)"
    write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
      "why":"runs the resolver inside a carried body","maintainer_only":false}]'
    run bash "$CHECK" "$repo"
    [ "$status" -eq 1 ]
    grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
  done
}

@test "a substitution inside a carried SINGLE-quoted body is prose, not a call" {
  # The bound on the arm above, and the reason the span is kept off the frame
  # rather than off the line. A `$( )` runs inside a double-quoted string and
  # does not inside a single-quoted one, so keeping every substitution-shaped
  # run would fabricate exactly the edge this whole change exists to stop
  # fabricating. Nothing special enforces that here: the walk reads only `'`
  # inside an `S` frame, so no substitution frame is ever opened in one and
  # there is no span to keep. This pins that.
  repo="$(make_fixture_repo carriedsqsubst)"
  add_script "$repo" a/s.sh "#!/usr/bin/env bash
msg='first line
second \$(bash .github/audit/base.sh) tail'
printf '%s\n' \"\$msg\""
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver in a single-quoted message","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a kept span is not emitted a second time by the code that follows it" {
  # The bound on how far span tracking reaches along the line. Once the carried
  # body has closed, the rest is code `${t:cut}` already returns whole, so a
  # substitution sitting there needs no keeping and recording one emits it
  # twice: once as its own record and once inside the code record.
  #
  # Asserted on the span channel, not on the code channel. The code channel
  # returns the same bytes either way, so a test reading it alone stays green
  # over exactly the mistake this pins.
  run bash -c 'cd "$1" || exit 2
    . .gaia/scripts/capability-oracle-lib.sh
    _GAIA_CAPCHECK_QSTATE="D"
    _GAIA_CAPCHECK_QSHADOW=0
    _gaia_capcheck_quote_carry "def\" && echo \$(bash x.sh)"
    printf "spans[%s]\n" "$_GAIA_CAPCHECK_QSUBS"
    printf "code[%s]\n" "$_GAIA_CAPCHECK_RET"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "spans[]" ]
  [ "${lines[1]}" = "code[ && echo \$(bash x.sh)]" ]
}

@test "the substitution bail covers the kept span and not the code beside it" {
  # The two halves of one source line, asserted together because the repair is
  # the boundary between them and a fixture for either half alone passes under
  # a walk that has lost it.
  #
  # A line carrying `$(` keeps its anchors, because a separator inside a
  # substitution body is real shell: that is the one thing the quoting repair
  # leaves open, and _GAIA_CAPCHECK_PATHCMD's header says so. The first fixture
  # is that limit, unchanged and loud, and it is here so a reader cannot mistake
  # the second for a general repair.
  #
  # The second is the same shape with the substitution reached through a
  # carried body instead. Keeping that substitution is mandatory (the call
  # inside it is real reach, and dropping it loses that reach silently), and
  # handing it back joined to the code the line runs after the body closed
  # would put a `$(` in front of a tail whose quoting is fully known. The bail
  # would then cover the tail too and the `;` inside its span would read as
  # command position. The splitter emits the two as separate records so it
  # does not, which is what this asserts: same bytes after the body, opposite
  # verdict from the first fixture, because only the first has a substitution
  # in the region being judged.
  substbail_case() {
    local tag="$1" body="$2" want="$3" repo
    repo="$(make_fixture_repo "substbail$tag")"
    add_script "$repo" a/s.sh "#!/usr/bin/env bash
$body"
    add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
    write_allow "$repo" "Bash(bash a/s.sh:*)"
    write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
      "why":"prints a usage message beside a substitution","maintainer_only":false}]'
    run bash "$CHECK" "$repo"
    [ "$status" -eq "$want" ]
    if [ "$want" -eq 1 ]; then
      grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
    else
      grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
      true
    fi
  }
  substbail_case oneline 'x=$(date) ; printf "%s\n" "usage; .github/audit/base.sh --member X"' 1
  substbail_case carried 'msg="line one
line two $(date) end" ; printf "%s\n" "usage; .github/audit/base.sh --member X"' 0
}

@test "a paren that closes nothing does not swallow the rest of a substitution" {
  # The bound on the carried state's own reach. A `case` arm, a function
  # definition, and a bare subshell each put a `)` inside a multi-line
  # substitution that closes nothing the reader opened, and a reader that let
  # one of them close the substitution would hand the enclosing quote back to
  # the top of the stack and drop every remaining line of real shell. That loss
  # is silent: nothing downstream reports a line the splitter never emitted.
  local body idx=0
  for body in 'case $x in
    a) echo one ;;
  esac' 'helper() {
    true
  }
  helper' '( cd /tmp && pwd )'; do
    idx=$((idx + 1))
    repo="$(make_fixture_repo "bareunmatched$idx")"
    add_script "$repo" a/s.sh "#!/usr/bin/env bash
x=b
out=\"\$(
  $body
  .github/audit/base.sh --real
)\"
printf \"%s\n\" \"\$out\""
    add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
    write_allow "$repo" "Bash(bash a/s.sh:*)"
    write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
      "why":"runs the resolver inside a substitution","maintainer_only":false}]'
    run bash "$CHECK" "$repo"
    [ "$status" -eq 1 ]
    grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
  done
}

@test "a character the quoting walk acts on is never skipped past" {
  # The bound on the run-skip that carries the walk between the characters it
  # reads. Skipping a run is only sound while that run cannot change the stack,
  # so a skip set missing one of its own arm's characters walks straight past
  # the thing deciding where a span ends, and the state it hands the next line
  # is wrong in the suppressing direction. Each opener below is BALANCED, and
  # balanced only when its own character is read: the call beneath it survives
  # when the walk stops there and is silently dropped when it does not.
  #
  # One case per skip set. A `'` and a `#` a line ends up carrying under the
  # unbalanced `"` they respectively quote and comment out, and a backtick
  # nested in a double-quoted span, which needs an inner `"` to matter at all,
  # since a plain pair leaves the same empty stack either way.
  carry_case() {
    local tag="$1" opener="$2" repo
    repo="$(make_fixture_repo "bareskip$tag")"
    add_script "$repo" a/s.sh "#!/usr/bin/env bash
$opener
.github/audit/base.sh --real"
    add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
    write_allow "$repo" "Bash(bash a/s.sh:*)"
    write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
      "why":"runs the resolver after a balanced span","maintainer_only":false}]'
    run bash "$CHECK" "$repo"
    [ "$status" -eq 1 ]
    grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
  }
  carry_case sq "msg='the \" character'"
  carry_case hash "true  # don't skip past a comment"
  carry_case bt 'msg="a `echo "x"` b"'
  # The same comment case with the `#` word-initial after a separator rather
  # than after whitespace, which is the other half of what bash accepts. An arm
  # that demands whitespace reads this line as code, the apostrophe opens a
  # frame nothing closes, and every line after it is dropped as carried body.
  carry_case semi "true;# don't skip past a comment"
  carry_case pipe "true|# don't skip past a comment"
  # `$'...'` is the one single-quoted form where a backslash escapes, so a walk
  # that reads it as an ordinary `'` span closes the span at the escaped quote
  # and reopens it at the real terminator, leaving a frame open.
  carry_case ansic "msg=\$'don\\'t skip past this'"
}

@test "a comment inside a nested quoted body opens no heredoc" {
  # The bound on how the comment and blank arms are gated. Those arms are
  # skipped while a STRING body is open, because inside one a leading `#` is
  # prose; but a body is only OPEN in that sense at the same depth
  # _gaia_capcheck_quote_carry suppresses at, one unshadowed frame. Gating them
  # on the TOP frame instead admits every deeper stack: `records="$(awk '`
  # opens D, P and S, so the top is S and the arms switch off, while the carry
  # correctly passes the line through as code because the depth is three. The
  # comment then reaches the heredoc reader, which takes a `<<WORD` out of the
  # prose and waits for a terminator no line supplies, so the rest of the file
  # is eaten as heredoc body and no detector ever sees it.
  #
  # This is not hypothetical: .gaia/scripts/lint-errexit-source-guard.sh
  # carries an awk comment naming `cat <<A <<B`, and it sits inside the scan
  # roots of a merge-blocking lint, which reported clean over the lines the
  # oracle had stopped reading.
  repo="$(make_fixture_repo nestedcomment)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
records="$(awk '"'"'
  # A line may open more than one (`cat <<A <<B` runs the bodies in order),
  # so the caller consumes them as a queue.
  { print }
'"'"' /dev/null)"
printf "%s\n" "$records"
.github/audit/base.sh --real'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the resolver after an awk body","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "the run-skip changes no answer the walk reaches without it" {
  # The guard over the skip sets AS A SET, which the fixtures above cannot be.
  # Each set restates the characters its own arm of the walk reads, so the two
  # can drift apart, and a hand-written fixture only catches the drift somebody
  # already thought of: a `"` and a backtick pop and push each other
  # symmetrically, so the shapes separating a sound set from an unsound one are
  # the ones nobody writes down.
  #
  # So it is a differential rather than a fixture. `?` matches at every
  # position, which leaves the skip with nothing to remove and reproduces the
  # character-at-a-time walk the sets exist to shortcut; the two must agree
  # line for line. The corpus is every shell file the repo tracks, discovered
  # rather than listed, so a file added later is compared without an edit here.
  #
  # The neutered set is DERIVED from the library, not listed here. A list is the
  # one thing this differential cannot afford to hand-write: the diff that adds
  # a fourth set is exactly the diff that owes the check, and a list left at
  # three arms neither side of the comparison, so both walks run the same skip
  # and the drift the test exists for is invisible while it reports clean.
  #
  # The corpus is listed the way the gate discovers its own: NUL-delimited with
  # `core.quotepath` off. Under git's default quoting a tracked path carrying a
  # non-ASCII byte comes back C-quoted, `_gaia_capcheck_logical_lines` takes its
  # `[ -f ]` arm on it, and the file leaves BOTH sides silently, so the diff
  # still agrees over a file neither walk read.
  local walk out_skip="$BATS_TEST_TMPDIR/skip.txt" out_plain="$BATS_TEST_TMPDIR/plain.txt"
  walk='cd "$1" || exit 2
    . .gaia/scripts/capability-oracle-lib.sh
    if [ -n "$2" ]; then
      seen=0
      got=0
      for v in $(compgen -A variable _GAIA_CAPCHECK_QSKIP_); do
        # Discovered and neutered are counted SEPARATELY, and every set found
        # has to have taken. A `readonly` on something the library calls a
        # constant is a plausible hardening edit; `eval` then writes to stderr
        # and returns 1, and a count of successes alone still clears any floor
        # below the number of sets while one set stays REAL. The no-skip side
        # then runs that real set, both walks skip identically for its frame,
        # and the comparison goes vacuous for exactly the arm whose drift it
        # was built to catch.
        seen=$((seen + 1))
        eval "$v=\"?\"" 2>/dev/null || true
        if [ "$(eval printf %s "\"\$$v\"")" = "?" ]; then got=$((got + 1)); fi
      done
      # A derivation that came back empty, or found only one set, would neuter
      # nothing or nearly nothing and leave the two walks agreeing trivially.
      if [ "$seen" -le 2 ] || [ "$got" -ne "$seen" ]; then
        echo "skip-set derivation saw $seen neutered $got" >&2
        exit 3
      fi
    fi
    git -c core.quotepath=false ls-files -z "*.sh" "*.bats" | while IFS= read -r -d "" f; do
      printf "== %s\n" "$f"
      _gaia_capcheck_logical_lines "$f"
    done'
  bash -c "$walk" _ "$REPO_ROOT" "" >"$out_skip"
  bash -c "$walk" _ "$REPO_ROOT" no-skip >"$out_plain"
  # Short-read guard: a corpus that resolved no file, or a walk that emitted
  # nothing, agrees with itself and would report this clean having compared
  # nothing at all.
  [ -s "$out_skip" ]
  [ "$(grep -c '^== ' "$out_skip")" -gt 100 ]
  diff "$out_skip" "$out_plain"
}

@test "a bare path behind a separator inside a double-quoted span is prose, not a call" {
  # The negatives for the separator arms. A `;`, `|`, or `&` inside a span is
  # text the shell never acts on, and each one puts the path that follows it in
  # what the anchor reads as command position.
  repo="$(make_fixture_repo baresepspan)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "%s\n" "usage; .github/audit/base.sh --member X"
msg="pipeline | .github/audit/base.sh runs later"
amp="queued & .github/audit/base.sh after that"
printf "%s %s\n" "$msg" "$amp"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver in three messages","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a bare path behind a keyword inside a double-quoted span is prose, not a call" {
  # The negatives for the keyword arms, which fabricate the same edge without a
  # separator anywhere on the line.
  repo="$(make_fixture_repo barekwspan)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "%s\n" "if the marker is stale then .github/audit/base.sh rewrites it"
loop="for each tree do .github/audit/base.sh once"
printf "%s\n" "$loop"'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"names the resolver in two messages","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a bare path behind a real separator outside a quoted span is still a call" {
  # The bound on both span negatives. The separator arms exist for lines like
  # these, and blanking a separator that is not inside quotes would lose them.
  repo="$(make_fixture_repo baresepreal)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
printf "start\n"; .github/audit/base.sh --after-sep'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the resolver after a separator","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
}

@test "a quoted bare-path execution keeps its call when the anchor is outside the quotes" {
  # The bound the span blanking is easiest to overshoot. This tree executes a
  # script through a quoted path whose directory is a variable, and the token
  # sits inside the span while the anchor does not. Blanking the span rather
  # than the anchors inside it would lose exactly this.
  repo="$(make_fixture_repo barequotedexec)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
d=.github/audit
"$d/base.sh" 2>/dev/null || true'
  add_script "$repo" .github/audit/base.sh '#!/usr/bin/env bash
curl -sS https://example.com/x'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs the resolver through a quoted path","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED a/s.sh invokes:.github/audit/base.sh" <<<"$output"
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

@test "a write into a bare positional with a literal suffix is the same caller-chosen term" {
  repo="$(make_fixture_repo callerbare)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
rm -f "$1/RUNNING"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"clears a sentinel inside the directory it is handed","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  # The spelling must not change the answer: reading the positional as the repo
  # root here would report `fs-write:RUNNING`, a narrower term than the write
  # actually has, which is a fail-open.
  grep -qF -- "fs-write:RUNNING" <<<"$output" && return 1
  grep -qxF -- "fs-write:**" <<<"$output"
}

@test "an assignment is read boundary-anchored, not as a substring of a longer name" {
  repo="$(make_fixture_repo anchoredassign)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
PLAN_root=zzz; root="$1"
printf "x\n" > "$root/out.txt"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"writes inside the directory it is handed","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  run bash "$CHECK" "$repo" --print-reach .gaia/scripts/w.sh
  [ "$status" -eq 0 ]
  # Stripping at the first `root=` would take PLAN_root's value and report a
  # confident, wrong directory rather than the caller-chosen term.
  grep -qF -- "fs-write:zzz/out.txt" <<<"$output" && return 1
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

@test "a prefix-less fs-write glob that is not the sentinel is BAD-TERM" {
  repo="$(make_fixture_repo prefixlessglob)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
mkdir -p app/x'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  # `**/*` compiles to a pattern matching every path with a directory
  # component, so without this rule it is a blanket declaration wearing a
  # spelling the sentinel narrowing does not recognize. The whole prefix-less
  # class is refused, not the one spelling that was noticed.
  for term in '**/*' '*/**' '*'; do
    write_manifest "$repo" "[{\"script\":\".gaia/scripts/w.sh\",\"capabilities\":[\"fs-write:$term\"],
      \"why\":\"blanket by another spelling\",\"maintainer_only\":false}]"
    run bash "$CHECK" "$repo"
    [ "$status" -eq 1 ]
    grep -qF -- "BAD-TERM .gaia/scripts/w.sh fs-write:$term" <<<"$output"
  done
}

@test "a declared fs-write:** does not cover a concrete write in the same closure" {
  repo="$(make_fixture_repo sentinelconcrete)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
rm -f "$1/RUNNING"
mkdir -p app/secretstash'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"clears a sentinel where told","maintainer_only":false}]'
  # The sentinel says "wherever the caller points it"; it is not a wildcard the
  # rest of the closure can hide behind. Reading it as a glob would let one
  # caller-chosen write silently declare every other write in the script.
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .gaia/scripts/w.sh fs-write:app/secretstash" <<<"$output"
}

@test "a bare fs-write:** on a script with no caller-designated write fails both directions" {
  repo="$(make_fixture_repo blanketsentinel)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
mkdir -p app/x'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:**"],
    "why":"blanket declaration covering nothing it actually reaches","maintainer_only":false}]'
  # This is the "a blanket declaration fails on its first run" claim the check
  # header makes, in its plainest case.
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- "UNDECLARED .gaia/scripts/w.sh fs-write:app/x" <<<"$output"
  grep -qF -- "SURPLUS .gaia/scripts/w.sh fs-write:**" <<<"$output"
}

@test "a declared fs-write glob that is not the sentinel still covers what it matches" {
  repo="$(make_fixture_repo nonsentinelglob)"
  add_script "$repo" .gaia/scripts/w.sh '#!/usr/bin/env bash
printf "x\n" > "app/data/sub/$name.txt"'
  write_allow "$repo" "Bash(bash .gaia/scripts/w.sh:*)"
  write_manifest "$repo" '[{"script":".gaia/scripts/w.sh","capabilities":["fs-write:app/data/**"],
    "why":"writes a computed basename under a fixed directory","maintainer_only":false}]'
  # Only the exact `**` term is narrowed; ordinary globbing is untouched.
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
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
  grep -qF -- 'resolver' <<<"$output" && return 1
  grep -qF -- 'verify_script' <<<"$output" && return 1
  true
}

# The obligated scripts' reach is the reconciliation's whole input, so a change
# to the checker underneath it can move every verdict on this surface at once.
# Two before-sides guard that, and they answer different questions.
#
# The FORK-POINT arm is the one that follows the checker. It materializes
# check-script-capabilities.sh and capability-oracle-lib.sh as they stood at the
# commit this branch forked from into a directory of their own and runs THAT
# checker against this repository, so whatever a branch rewrites sits on exactly
# one side of the comparison whichever function holds it. A before side keyed to
# one past change cannot do that: a change outside the names it vendors lands
# identically on both sides, and the comparison then holds two runs that already
# carry the change and reports green (#1612).
#
# Its limits, stated because a comparison that never ran looks exactly like one
# that passed. It has nothing to compare when the branch leaves both files
# alone, and it can build no before side where no fork point resolves, which is
# what a depth-1 CI checkout leaves behind. Both exits are `skip`s carrying their
# reason rather than passes, so the only green it reports is a comparison it ran.
# The runner that makes it real is the local pre-merge bats run
# .claude/rules/pr-merge.md prescribes, which has the history: this arm is the
# by-hand `--print-reach` comparison an oracle change establishes its reach claim
# with today, run by the suite instead of by the author. And it reports that
# reach MOVED, never that moving it was wrong; a change that should move reach
# turns it red and the author says why in the pull request.
#
# The #1527 arms are the other before side, and they are a per-change pin rather
# than a following one: `pre-change-oracle.sh` vendors that change's pre-change
# bodies and no others, layered over the shipped check. Read that scope
# literally. What they buy is a comparison that runs unconditionally, on any
# tree and with no history at all: that one change is still reach-neutral on the
# surface as it stands.
#
# The mechanism matters, and for the #1527 arms two obvious spellings do not
# work.
#
# Running `bash "$CHECK" "$REPO_ROOT" --print-reach` cannot be overridden from
# here: the check resolves and sources the oracle from its own directory at load
# time, so it re-sources the shipped one and clobbers any inherited definition.
# A pin written that way compares two identical shipped runs and can never fail.
# What makes a child shell work is ORDER -- sourcing the check first and the
# vendored bodies after it, so the override is the last definition to land.
#
# The fork-point arm needs none of that, and the reason is the same resolution
# rule read forwards: a directory holding both files IS a checker, so the before
# side inherits nothing from the shipped one and covers the check script as well
# as the oracle.
#
# Running both sides in THIS process works but is not affordable. bats installs
# a DEBUG trap on every command in a test body, and the oracle executes on the
# order of a million commands per walk, so the two walks that cost ~32s as child
# processes were still running after four minutes in-process. The suite sits in
# a CI shard whose matrix leg has no headroom, so both sides run as children.
reach_side() {
  # $1: `vendored` to load the pre-change bodies after the check, anything else
  # for the shipped ones as they stand.
  bash -c '
    set -uo pipefail
    . "$1"
    [ "$3" = vendored ] && . "$2"
    gaia_capcheck_print_reach "$4" 2>/dev/null
  ' _ "$CHECK" "$PRE_CHANGE" "$1" "$REPO_ROOT"
}

# declare_side <side> <function>: the body a side actually holds, which is what
# proves the swap is real rather than two identical runs.
declare_side() {
  bash -c '
    set -uo pipefail
    . "$1"
    [ "$3" = vendored ] && . "$2"
    declare -f "$5"
  ' _ "$CHECK" "$PRE_CHANGE" "$1" "$REPO_ROOT" "$2"
}

# vendored_names <file>: the function names <file> defines, one per line, as
# bash reports them across sourcing it. The fixture is the authority on what the
# fixture holds, and asking bash is asking that authority directly; a regex over
# the file or a list kept in this suite is a second answer that can disagree
# with the first, which is the shape a per-site memory takes here.
vendored_names() {
  bash -c '
    set -uo pipefail
    before="$(declare -F | sed "s/^declare -f //")"
    . "$1"
    declare -F | sed "s/^declare -f //" | while IFS= read -r fn; do
      printf "%s\n" "$before" | grep -qxF -- "$fn" || printf "%s\n" "$fn"
    done
  ' _ "$1"
}

# fork_point <repo>: the commit <repo>'s HEAD forked from. It tries the remote's
# default branch ahead of the local one, so it answers in a clone that has a
# remote and in one that does not; it prints nothing and returns 1 when no ref
# it tries resolves, which is what a depth-1 clone leaves behind.
fork_point() {
  local repo="$1" ref base
  for ref in origin/HEAD origin/main main; do
    base="$(git -C "$repo" merge-base HEAD "$ref" 2>/dev/null)" || continue
    if [ -n "$base" ]; then
      printf '%s' "$base"
      return 0
    fi
  done
  return 1
}

# base_checker <repo> <dir>: the checker and the oracle as they stood at
# <repo>'s fork point, written into <dir>. Both files, because the check
# resolves its oracle from its own directory: the pair in one directory is the
# before-side checker, complete and inheriting nothing from the shipped one.
#
# The two ways it can fail return different statuses because they want different
# things said. 1 is no fork point, which is the environment. 2 is a fork point
# that resolved and carries no file at one of the paths, which is a rename or a
# new file -- an author's own change, and exactly the change this comparison
# exists to run. Collapsing them sends that author to inspect their clone.
base_checker() {
  local repo="$1" dir="$2" base f
  base="$(fork_point "$repo")" || return 1
  mkdir -p "$dir"
  for f in check-script-capabilities.sh capability-oracle-lib.sh; do
    git -C "$repo" show "$base:.gaia/scripts/$f" >"$dir/$f" 2>/dev/null || return 2
  done
}

@test "real repo: the byte-identity pin really swaps the oracle, so it can fail" {
  local shipped vendored
  shipped="$(declare_side shipped _gaia_capcheck_strip_tests)"
  vendored="$(declare_side vendored _gaia_capcheck_strip_tests)"
  [ -n "$shipped" ]
  [ -n "$vendored" ]
  [ "$shipped" != "$vendored" ]
}

@test "real repo: every function the #1527 oracle change rewrote is vendored on the before side" {
  # The pin is only as good as its before side: vendoring fewer functions than
  # the change rewrote leaves that side already carrying part of the fix.
  #
  # Both sides of this arm are frozen by design: the fixture holds bodies a past
  # change replaced and is never updated, and the list below is that change's
  # rewritten set. So the list is not a memory that rots, it is the second
  # opinion that makes a fixture LOSING a function red -- an SC2034 tidy-up, a
  # bad conflict resolution. Deriving the list from the fixture instead asserts
  # the fixture against itself, and a shrunk fixture then takes the assertion
  # about the function it dropped along with it. Bash still derives what the
  # loop drives; the disagreement between the two is the whole detector.
  #
  # It is #1527's set and no claim about any other change: a function a LATER
  # change rewrites is absent from both, and the fork-point arm covers that one.
  local fn shipped vendored names rewritten
  rewritten="$(printf '%s\n' \
    _gaia_capcheck_strip_tests _gaia_capcheck_dirhop \
    _gaia_capcheck_state_root_hop _gaia_capcheck_assignment_values \
    _gaia_capcheck_split_var _gaia_capcheck_resolve_dir \
    _gaia_capcheck_resolve_invocation _gaia_capcheck_write_paths \
    _gaia_capcheck_scan_writes _gaia_capcheck_scan_invocations \
    _gaia_capcheck_file_sites | LC_ALL=C sort)"
  names="$(vendored_names "$PRE_CHANGE" | LC_ALL=C sort)"
  [ -n "$names" ]
  [ "$names" = "$rewritten" ]
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    shipped="$(declare_side shipped "$fn")"
    vendored="$(declare_side vendored "$fn")"
    [ -n "$vendored" ] || return 1
    [ "$shipped" != "$vendored" ] || return 1
  done <<EOF
$names
EOF
}

@test "real repo: computed reach is byte-identical to the #1527 pre-change oracle's" {
  local after before
  after="$(reach_side shipped)"
  before="$(reach_side vendored)"
  [ -n "$after" ]
  [ "$before" = "$after" ]
}

@test "real repo: this branch's checker computes the reach the fork point's checker does" {
  local dir="$BATS_TEST_TMPDIR/fork-point" before after rc=0
  base_checker "$REPO_ROOT" "$dir" || rc=$?
  if [ "$rc" -eq 2 ]; then
    skip "the fork point has no file at one of the two paths, so this branch renames or adds one"
  elif [ "$rc" -ne 0 ]; then
    skip "no fork point resolves here, so there is no before side to build"
  fi
  if cmp -s "$dir/capability-oracle-lib.sh" "$SCRIPT_DIR/capability-oracle-lib.sh" &&
    cmp -s "$dir/check-script-capabilities.sh" "$CHECK"; then
    skip "this branch changes neither file, so both sides would be one program"
  fi
  before="$(bash "$dir/check-script-capabilities.sh" "$REPO_ROOT" --print-reach 2>/dev/null)"
  after="$(bash "$CHECK" "$REPO_ROOT" --print-reach 2>/dev/null)"
  [ -n "$before" ]
  [ -n "$after" ]
  [ "$before" = "$after" ]
}

@test "the fork-point before side is built from the fork point, not from the branch tip" {
  # base_checker decides which revision the arm above compares against, and a
  # helper answering HEAD would make that comparison two identical runs, which
  # is the silent green the arm exists to end. No remote here, so this drives
  # the local-default fallback too.
  local repo="$BATS_TEST_TMPDIR/forkpoint" dir="$BATS_TEST_TMPDIR/forkpoint-base" f
  mkdir -p "$repo/.gaia/scripts"
  git init -q --initial-branch=main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  for f in check-script-capabilities.sh capability-oracle-lib.sh; do
    printf 'fork-point body\n' >"$repo/.gaia/scripts/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b topic
  printf 'branch body\n' >"$repo/.gaia/scripts/capability-oracle-lib.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m topic
  base_checker "$repo" "$dir"
  grep -qxF -- 'fork-point body' "$dir/capability-oracle-lib.sh"
}

@test "a fork point carrying neither file is reported apart from one that does not resolve" {
  # The arm above skips on both, and an author who has just renamed or added one
  # of the two files is the one likeliest to meet the second. Told the first
  # reason, they go and inspect their clone's history instead of their own diff.
  #
  # Both statuses are driven here, because what the name claims is that the two
  # are APART. An arm driving one of them stays green when they collapse back
  # into a single status, which is the defect it is named for.
  local repo="$BATS_TEST_TMPDIR/norepo" dir="$BATS_TEST_TMPDIR/norepo-base" rc=0
  local nohist="$BATS_TEST_TMPDIR/nohist" nodir="$BATS_TEST_TMPDIR/nohist-base" nrc=0
  # A fork point that resolves, over a tree carrying neither file.
  git init -q --initial-branch=main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'unrelated\n' >"$repo/README"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  base_checker "$repo" "$dir" || rc=$?
  [ "$rc" -eq 2 ]
  # A repository whose HEAD reaches none of the refs fork_point tries: no
  # remote, and a default branch under a name none of them spells. This is the
  # depth-1 CI checkout's shape, reproduced without a shallow clone.
  git init -q --initial-branch=topic "$nohist"
  git -C "$nohist" config user.email t@example.com
  git -C "$nohist" config user.name T
  git -C "$nohist" config commit.gpgsign false
  printf 'unrelated\n' >"$nohist/README"
  git -C "$nohist" add -A
  git -C "$nohist" commit -q -m base
  base_checker "$nohist" "$nodir" || nrc=$?
  [ "$nrc" -eq 1 ]
}

@test "a before side whose oracle sees less reach fails the fork-point comparison" {
  # Non-vacuity for the arm above: without this, a comparison that can never
  # differ reads exactly like one that never has. It blinds one detector on
  # purpose rather than every one of them, because what needs proving is that a
  # reach difference reaches the comparison at all.
  #
  # The mutation names an oracle internal, so renaming that internal turns this
  # red rather than quietly leaving the comparison unproven.
  local dir="$BATS_TEST_TMPDIR/blinded" repo before after
  mkdir -p "$dir"
  cp "$CHECK" "$dir/check-script-capabilities.sh"
  cp "$SCRIPT_DIR/capability-oracle-lib.sh" "$dir/capability-oracle-lib.sh"
  printf '\n_gaia_capcheck_detect_tmp() { return 1; }\n' >>"$dir/capability-oracle-lib.sh"
  repo="$(make_fixture_repo reachdelta)"
  add_script "$repo" .gaia/scripts/t.sh '#!/usr/bin/env bash
mktemp -d'
  write_allow "$repo" "Bash(bash .gaia/scripts/t.sh:*)"
  before="$(bash "$dir/check-script-capabilities.sh" "$repo" --print-reach 2>/dev/null)"
  after="$(bash "$CHECK" "$repo" --print-reach 2>/dev/null)"
  # Both sides non-empty first: a before side that failed to run is unequal to
  # the after side for a reason that proves nothing about reach.
  [ -n "$before" ]
  [ -n "$after" ]
  [ "$before" != "$after" ]
}

@test "a path token that merely begins with a keyword is not split at the keyword" {
  # The keyword arms match a keyword, not a prefix of the next word. `docs/`
  # opens with `do`, and an arm that did not require the space after it would
  # anchor mid-token and hand the resolver `cs/build.sh` -- a path no tree has,
  # reported at a line whose real target it never names.
  repo="$(make_fixture_repo barekwprefix)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
X=1 docs/build.sh'
  add_script "$repo" docs/build.sh '#!/usr/bin/env bash
true'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs a build script behind an assignment prefix","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "cs/build.sh" <<<"$output" && return 1
  true
}

@test "a parse check is not an invocation, so its target's reach stays outside the closure" {
  # `bash -n <path>` compiles the file and executes none of it, so it reaches
  # for nothing the target reaches for. The flag walk in
  # _gaia_capcheck_scan_invocations skips every `-`-prefixed token on the way to
  # the script operand, and skipping the one flag that decides whether the
  # operand runs makes the parse check indistinguishable from the real
  # invocation directly below it (gaia-react/gaia#1599).
  #
  # The fixture is written so ONLY the fabricated edge can produce the term:
  # `a/s.sh` reaches for nothing itself and declares nothing, and the `curl` is
  # in the target. An oracle that reads the parse check as a call walks `b/t.sh`
  # and reports `network` UNDECLARED against `a/s.sh`.
  repo="$(make_fixture_repo parsecheck)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
bash -n b/t.sh'
  add_script "$repo" b/t.sh '#!/usr/bin/env bash
curl -fsS https://example.com/'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"parse-checks a sibling script and runs nothing","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "clustered short options carry the parse-only flag too" {
  # `-nu` is `-n` and `-u` in one token. An arm that matched the literal `-n`
  # and nothing else would read the cluster as an ordinary flag and fabricate
  # the edge the test above pins, which is the shape the repair has to survive.
  repo="$(make_fixture_repo parsecheckcluster)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
bash -nu b/t.sh'
  add_script "$repo" b/t.sh '#!/usr/bin/env bash
curl -fsS https://example.com/'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"parse-checks a sibling script and runs nothing","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "the parse-only flag is recognized in a non-leading cluster position" {
  # The flag-walk arm is an alternation and each alternative owns a different
  # shape. `-n` and `-nu` are the leading-position half; `-vn` is the other one,
  # and without a fixture driving it that alternative can be dropped with the
  # whole suite still green, which would restore the fabricated edge on the one
  # shape nothing pins.
  repo="$(make_fixture_repo parsecheckmidcluster)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
bash -vn b/t.sh'
  add_script "$repo" b/t.sh '#!/usr/bin/env bash
curl -fsS https://example.com/'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"parse-checks a sibling script and runs nothing","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 0 ]
  grep -qE '^(UNDECLARED|SURPLUS|UNRESOLVED)' <<<"$output" && return 1
  true
}

@test "a real invocation behind ordinary flags still resolves after the parse-check repair" {
  # The direction the repair must not over-reach in. Under-reporting is the
  # failure this oracle cannot surface as a finding: an abandoned site emits no
  # record at all, so a dropped edge is silence rather than an UNRESOLVED line,
  # and the caller comes back clean over a subtree nothing walked.
  #
  # Two halves of the fixture are load-bearing and neither is obvious.
  #
  # The manifest declares NOTHING, and the assertion is that the check reports
  # the reach it found. A declared `invokes:` target joins the closure frontier
  # by definition, so a fixture that declares the edge and asserts the absence of
  # findings is satisfied by its own manifest and stays green under a flag walk
  # that abandons every site it sees. That is the shape this test had first, and
  # it could not fail in the direction its own comment named.
  #
  # The target carries an `n` in its NAME. The parse-check arm matches the
  # current token, and a version of it matched against the whole remainder of
  # the line read the `n` in `run-thing.sh` as the parse-only flag and dropped
  # this very edge. `--noprofile` covers the other half: a long option carrying
  # an `n` that does not stop the operand executing.
  repo="$(make_fixture_repo realinvokeflags)"
  add_script "$repo" a/s.sh '#!/usr/bin/env bash
bash --noprofile -x b/run-thing.sh'
  add_script "$repo" b/run-thing.sh '#!/usr/bin/env bash
curl -fsS https://example.com/'
  write_allow "$repo" "Bash(bash a/s.sh:*)"
  write_manifest "$repo" '[{"script":"a/s.sh","capabilities":[],
    "why":"runs a sibling script that calls the network","maintainer_only":false}]'
  run bash "$CHECK" "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'UNDECLARED a/s.sh invokes:b/run-thing.sh' <<<"$output" || return 1
  grep -qF -- 'UNDECLARED a/s.sh network' <<<"$output" || return 1
  true
}
