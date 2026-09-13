#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Tests for .claude/hooks/audit-residual-shape-check.sh: the PreToolUse Bash
# hook that DENIES `gh pr merge` when a pull request's body records an audit
# residual disposition in a shape no command can find -- a recognized
# heading spelled as anything but its canonical form, or an entry beneath a
# canonical heading carrying no dedup key. Frozen contracts C1-C6, C8 live in
# .gaia/local/specs/SPEC-080/plan/README.md; this suite asserts against them,
# not against the hook's own source.
#
# WHY THE PERMIT CASES CARRY AS MUCH WEIGHT AS THE DENY CASES HERE. The hook
# always exits 0 on its permit paths, so a broken recognizer prints nothing,
# blocks nothing, and lets through exactly the shape it exists to catch --
# nothing observable changes. The deny cases below prove the guard fires; the
# permit cases prove it is a MATCH rather than a blanket. An over-broad
# recognizer would refuse merges the SPEC's `never` list gives no escape
# from, which is why Group 5 gives every permitting arm its own test.
#
# HONEST LIMIT OF WHAT THIS SUITE, AND THE HOOK IT DRIVES, CAN REACH. A
# PreToolUse Bash hook sees a `gh pr merge` issued as a Bash tool call in a
# session where `gh` and `jq` resolve; it pattern-matches command text and
# reads a pull-request body fetched at that moment. It has no view of a
# merge performed through the GitHub web UI, of a body edited after the
# check ran, or of a deliberately obfuscated command the shared verb-arming
# and merge-scanner libraries decline to model (Group 5's abstention arms).
# This suite drives the real hook by absolute path so it resolves its own
# libraries; it never asserts against a copy.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/audit-residual-shape-check.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=../helpers/path.sh
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"

  eval "$(derive_recognizer_data)"
  [ "${#REFUSED_HEADINGS[@]}" -gt 0 ] || {
    echo "audit-residual-shape-check.bats: derive_recognizer_data extracted no REFUSED_HEADINGS; every test in this suite depends on it" >&2
    return 1
  }
  [ "${#REFUSED_HEADINGS[@]}" -eq "${#REFUSED_REPLACEMENTS[@]}" ] || {
    echo "audit-residual-shape-check.bats: REFUSED_HEADINGS and REFUSED_REPLACEMENTS extracted at different lengths" >&2
    return 1
  }
  [ -n "$CANON_ACCEPT" ] && [ -n "$CANON_WAIVE" ] || {
    echo "audit-residual-shape-check.bats: CANON_ACCEPT or CANON_WAIVE extracted empty" >&2
    return 1
  }
}

# Extracts the hook's own literal recognizer data (CANON_ACCEPT, CANON_WAIVE,
# REFUSED_HEADINGS, REFUSED_REPLACEMENTS) as a snippet a caller `eval`s,
# rather than restating the set here where a later edit to the hook would not
# grow it. The block runs from CANON_ACCEPT's own assignment through the
# second bare `)` line, which closes REFUSED_REPLACEMENTS -- the first bare
# `)` closes REFUSED_HEADINGS. Both arrays hold only single-quoted string
# literals with no interior line that is itself a bare `)`, which is what
# makes counting those lines a safe way to bound the extraction.
derive_recognizer_data() {
  awk '
    /^CANON_ACCEPT=/ { flag = 1 }
    flag {
      print
      if ($0 == ")") {
        n++
        if (n == 2) exit
      }
    }
  ' "$HOOK_ABS"
}

# join_lines LINE...: prints its arguments joined by newlines, no trailing
# newline. Building a pull-request body this way keeps a fixture's line
# NUMBERS a property of its argument order rather than a hand-count a later
# edit could silently desync.
join_lines() {
  local IFS=$'\n'
  printf '%s' "$*"
}

# line_of NEEDLE BODY: the 1-indexed line number of BODY's first line
# containing NEEDLE. Fixtures compute the line number they expect the hook to
# report this way, rather than a hand-counted literal, so reordering a
# fixture's lines cannot desync the assertion from the content.
line_of() {
  printf '%s\n' "$2" | grep -n -F -- "$1" | head -1 | cut -d: -f1
}

# install_gh_mock MODE [BODY]: puts a mock `gh` ahead of PATH.
#   ok <body>  -> `gh pr view ...` prints {"body": <body>}, exit 0
#   empty      -> prints {"body": ""}, exit 0 (a real PR with no body)
#   null       -> prints {"body": null}, exit 0 (gh's own encoding of no body)
#   fail       -> every `gh` invocation exits 1 (unreachable/unauthenticated)
# Every other `gh` subcommand (in particular `gh repo view`, which the shared
# repo-scope library uses to resolve this repository's own identity) prints
# nothing and exits 0, which is what makes that resolution fail closed to
# "cannot identify home" -- the safe direction the foreign-repo tests below
# rely on.
install_gh_mock() {
  local mode="$1" content="${2:-}"
  GH_BIN="$BATS_TEST_TMPDIR/gh-bin"
  mkdir -p "$GH_BIN"
  local body_file="$BATS_TEST_TMPDIR/gh-body.json"
  case "$mode" in
    ok) jq -n --arg b "$content" '{body: $b}' > "$body_file" ;;
    empty) printf '{"body":""}' > "$body_file" ;;
    null) printf '{"body":null}' > "$body_file" ;;
    fail)
      cat > "$GH_BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
      chmod +x "$GH_BIN/gh"
      export PATH="$GH_BIN:$PATH"
      return 0
      ;;
  esac
  cat > "$GH_BIN/gh" <<SH
#!/usr/bin/env bash
body_file="$body_file"
SH
  cat >> "$GH_BIN/gh" <<'SH'
case "$1 $2" in
  "pr view") cat "$body_file" ;;
esac
exit 0
SH
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# run_residual_hook [CMD]: delivers a `gh pr merge` Bash tool call to the real
# hook. Defaults to a numeric-reference merge so `gh pr view <n> --json body`
# is what the installed mock answers.
run_residual_hook() {
  local cmd="${1:-gh pr merge 123 --squash --delete-branch}" json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook "$json" "$HOOK_ABS"
}

# run_residual_hook_gh CMD: installs a present-but-empty-record gh mock, then
# drives CMD. For the arming/scanner-abstention tests in Group 5, where the
# point is that the hook never reaches a body at all, so what the mock would
# have answered does not matter.
run_residual_hook_gh() {
  install_gh_mock ok ""
  run_residual_hook "$1"
}

# drive_body BODY: installs BODY as the mocked pull-request body and runs the
# default merge command against it.
drive_body() {
  install_gh_mock ok "$1"
  run_residual_hook
}

# make_mutant_dir NAME: a fresh scratch directory under $BATS_TEST_TMPDIR
# holding a real copy of .claude/hooks/lib/ (unmodified). The hook resolves
# its libraries off its OWN on-disk location rather than cwd, so a mutated
# copy dropped alone in a scratch directory cannot find them and fails at the
# jq-availability guard before it ever reads the mutation. Prints the
# directory path.
make_mutant_dir() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/lib"
  cp "$HOOKS_SRC"/lib/*.sh "$dir/lib/"
  printf '%s' "$dir"
}

# run_hook_at HOOK BODY: like drive_body, but against an arbitrary hook path.
# Used only by the Group 8 mutation controls, which must never point at
# $HOOK_ABS itself.
run_hook_at() {
  local hook="$1" body="$2" json
  install_gh_mock ok "$body"
  json=$(jq -n --arg c "gh pr merge 123 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook "$json" "$hook"
}

# The permit contract is silence, not merely exit 0: `assert_allowed_by_json`
# (helpers/run-hook.sh) only asserts no deny field is present, which a
# non-empty non-deny payload would also satisfy. This hook's own contract is
# that a permit writes nothing at all.
assert_permits_silently() {
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# Deliberately excluded literals (README.md C1's exclusion table), hand-
# transcribed because the hook carries no data structure for an exclusion --
# it is simply absent from both the canonical and refused sets. Each entry's
# individual warrant lives in that table; this array exists only to drive
# each one through the hook once.
EXCLUDED_HEADINGS=(
  "## Out-of-scope findings"
  "## Out of scope"
  "## Out of scope, filed"
  "## Out-of-scope finding, filed"
  "## Audit dispositions"
  "## Audit disposition"
  "## Audit rounds and dispositions"
  "## Out-of-scope findings filed"
  "## Out of scope, filed separately"
  "## Filed, not fixed here"
  "## Deliberately out of scope"
  "## Out of scope, noted not fixed"
)

# ---------------------------------------------------------------------------
# Group 1: refusal on a non-canonical heading, per refused literal, derived,
# with the mapped canonical (C1, C4).
# ---------------------------------------------------------------------------

@test "every refused heading outside the two pinned members denies, naming its own derived canonical mapping, and the loop accounts for the whole derived set" {
  local driven=0 i heading replacement
  for i in "${!REFUSED_HEADINGS[@]}"; do
    heading="${REFUSED_HEADINGS[$i]}"
    case "$heading" in
      "## Waived findings" | "## Noted, not filed") continue ;;
    esac
    driven=$((driven + 1))
    replacement="${REFUSED_REPLACEMENTS[$i]}"

    drive_body "$heading"
    assert_denied_by_json
    grep -qF -- "Offending heading count: 1" <<<"$output" || return 1
    case "$replacement" in
      accept)
        grep -qF -- "$CANON_ACCEPT" <<<"$output" || return 1
        grep -qF -- "$CANON_WAIVE" <<<"$output" && return 1
        ;;
      waive)
        grep -qF -- "$CANON_WAIVE" <<<"$output" || return 1
        grep -qF -- "$CANON_ACCEPT" <<<"$output" && return 1
        ;;
      *)
        echo "unexpected replacement token '$replacement' for heading '$heading'; this loop and the two pinned tests below need a matching arm" >&2
        return 1
        ;;
    esac
  done

  # The two pinned members below (## Waived findings, ## Noted, not filed)
  # account for the remainder of the derived set, so this loop plus those two
  # tests together cover every element without restating its size here.
  [ "$((driven + 2))" -eq "${#REFUSED_HEADINGS[@]}" ] || return 1
}

@test "## Waived findings denies, naming only the waive canonical" {
  drive_body "## Waived findings"
  assert_denied_by_json
  grep -qF -- "Offending heading count: 1" <<<"$output" || return 1
  grep -qF -- "$CANON_WAIVE" <<<"$output" || return 1
  grep -qF -- "$CANON_ACCEPT" <<<"$output" && return 1
  true
}

@test "## Noted, not filed denies, naming both canonicals because it is ambiguous on the filed-versus-fixed axis" {
  drive_body "## Noted, not filed"
  assert_denied_by_json
  grep -qF -- "Offending heading count: 1" <<<"$output" || return 1
  grep -qF -- "$CANON_ACCEPT" <<<"$output" || return 1
  grep -qF -- "$CANON_WAIVE" <<<"$output" || return 1
}

@test "an accept-mapped and a waive-mapped refused heading in one body are each named with their own count, never a rename to both literals" {
  local body
  body="$(join_lines "## Accepted residuals" "## Waived findings")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Offending heading count: 2" <<<"$output" || return 1
  grep -qF -- "1 heading(s) must be renamed to: ${CANON_ACCEPT}" <<<"$output" || return 1
  grep -qF -- "1 heading(s) must be renamed to: ${CANON_WAIVE}" <<<"$output" || return 1
  grep -qF -- "Rename each to: ${CANON_ACCEPT} and ${CANON_WAIVE}" <<<"$output" && return 1
  true
}

@test "the ambiguous both-mapped heading alongside a single-target heading names every applicable canonical without conflating them" {
  local body
  body="$(join_lines "## Noted, not filed" "## Accepted residuals")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Offending heading count: 2" <<<"$output" || return 1
  grep -qF -- "1 heading(s) must be renamed to: ${CANON_ACCEPT}" <<<"$output" || return 1
  grep -qF -- "heading(s) must be renamed to: ${CANON_WAIVE}" <<<"$output" && return 1
  grep -qF -- "ambiguous on the accept/waive axis" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Group 2: refusal on a keyless entry (C2, C4).
# ---------------------------------------------------------------------------

@test "a single keyless bullet beneath the accept canonical heading denies, naming its own line number" {
  local body l
  body="$(join_lines "$CANON_ACCEPT" "- residual-alpha, no key attached")"
  l="$(line_of "residual-alpha" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "several keyless bullets beneath one canonical heading are each named by their own line number" {
  local body l1 l2
  body="$(join_lines "$CANON_ACCEPT" "- residual-bravo, first with no key" "- residual-charlie, second with no key")"
  l1="$(line_of "residual-bravo" "$body")"
  l2="$(line_of "residual-charlie" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 2" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l1}, ${l2}." <<<"$output" || return 1
}

@test "a mix of keyed and keyless bullets reports only the keyless one's line number" {
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-delta, keyed on the next line" \
    "<!-- gaia-debt-key: v1 class=lint path=app/delta.ts line=1 -->" \
    "- residual-echo, no key")"
  l="$(line_of "residual-echo" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "both canonical headings are judged independently, not just the first one encountered" {
  local body l1 l2
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-foxtrot, keyless under accept" \
    "$CANON_WAIVE" \
    "- residual-golf, keyless under waive")"
  l1="$(line_of "residual-foxtrot" "$body")"
  l2="$(line_of "residual-golf" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 2" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l1}, ${l2}." <<<"$output" || return 1
}

@test "the waive canonical heading alone with a keyless entry denies, binding the waive disposition symmetrically with accept" {
  local body l
  body="$(join_lines "$CANON_WAIVE" "- residual-hotel, keyless under waive alone")"
  l="$(line_of "residual-hotel" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Group 3: both refusal conditions in one body produce one refusal (C4).
# ---------------------------------------------------------------------------

@test "a refused heading and a keyless canonical entry in one body produce one refusal reporting both" {
  local body l
  body="$(join_lines \
    "## Accepted residuals" \
    "$CANON_WAIVE" \
    "- residual-india, keyless under waive")"
  l="$(line_of "residual-india" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Offending heading count: 1" <<<"$output" || return 1
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Group 4: the refusal echoes no body text (C4), for both refusal shapes.
# ---------------------------------------------------------------------------

@test "the non-canonical-heading refusal echoes no body-derived text" {
  local sentinel="ZZQ_SENTINEL_9f2c9a"
  local body
  body="$(join_lines \
    "## Accepted residuals" \
    "- references the heading text 'Accepted residuals ${sentinel}' and mentions ${sentinel} in prose, path=${sentinel}/app.ts")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "$sentinel" <<<"$output" && return 1
  true
}

@test "the keyless-entry refusal echoes no body-derived text" {
  local sentinel="ZZQ_SENTINEL_7a1eb2"
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- references the heading text 'Accepted residuals (recorded, not fixed) ${sentinel}', mentions ${sentinel} in its prose, path=${sentinel}/app.ts, no key")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "$sentinel" <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# Group 5: every permitting arm (C5), each its own test.
# ---------------------------------------------------------------------------

@test "a body with no recognized heading anywhere permits silently, proving a match rather than a blanket" {
  local body
  body="$(join_lines "## Verification" "Ran the suite." "## What changed" "Nothing residual here.")"
  drive_body "$body"
  assert_permits_silently
}

@test "a body carrying only canonical headings with every entry keyed permits silently" {
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-juliet, keyed" \
    "<!-- gaia-debt-key: v1 class=lint path=app/juliet.ts line=1 -->" \
    "$CANON_WAIVE" \
    "- residual-kilo, keyed" \
    "<!-- gaia-debt-key: v1 class=lint path=app/kilo.ts line=2 -->")"
  drive_body "$body"
  assert_permits_silently
}

@test "every deliberately excluded heading outside the two load-bearing ones permits (the closed set never widens on inference)" {
  local h
  for h in "${EXCLUDED_HEADINGS[@]}"; do
    case "$h" in
      "## Out-of-scope findings" | "## Out of scope, noted not fixed") continue ;;
    esac
    drive_body "$h"
    assert_permits_silently
  done
}

@test "## Out-of-scope findings permits, because /gaia-audit composes exactly this heading and must never refuse itself" {
  drive_body "## Out-of-scope findings"
  assert_permits_silently
}

@test "## Out of scope, noted not fixed permits, excluded by decision rather than by principle" {
  drive_body "## Out of scope, noted not fixed"
  assert_permits_silently
}

@test "a whitespace-only pull-request body permits silently" {
  drive_body "   $(printf '\t')   "
  assert_permits_silently
}

@test "gh absent from PATH permits silently" {
  PATH="$(path_shim_without gh)"
  export PATH
  [ -z "$(command -v gh)" ] || return 1
  run_residual_hook
  assert_permits_silently
}

@test "gh present but exiting non-zero permits silently (no record)" {
  install_gh_mock fail
  run_residual_hook
  assert_permits_silently
}

@test "gh present but returning an empty body permits silently (no record)" {
  install_gh_mock empty
  run_residual_hook
  assert_permits_silently
}

@test "gh present but returning a JSON null body permits silently (no record)" {
  install_gh_mock null
  run_residual_hook
  assert_permits_silently
}

@test "a tool call that is not Bash permits silently" {
  local json
  json=$(jq -n '{tool_name: "Edit", tool_input: {file_path: "app/x.ts"}}')
  invoke_hook "$json" "$HOOK_ABS"
  assert_permits_silently
}

@test "a Bash call carrying no gh pr merge permits silently" {
  run_residual_hook_gh "pnpm test"
  assert_permits_silently
}

@test "a merge aimed at a foreign repository permits silently" {
  run_residual_hook_gh "gh pr merge 5 --repo other-org/other-repo --squash"
  assert_permits_silently
}

@test "a single-dash flag cluster the merge scanner does not model permits (abstention permits, never denies)" {
  run_residual_hook_gh "gh pr merge -sd 123"
  assert_permits_silently
}

@test "a merge that is not the first command in its tool call permits" {
  run_residual_hook_gh "echo starting && gh pr merge 123 --squash"
  assert_permits_silently
}

@test "a branch-name reference permits, because the scanner declines a value it cannot resolve to a pull-request number" {
  run_residual_hook_gh "gh pr merge feature-branch --squash"
  assert_permits_silently
}

@test "a URL naming another repository permits" {
  run_residual_hook_gh "gh pr merge https://github.com/other-org/other-repo/pull/5 --squash"
  assert_permits_silently
}

# ---------------------------------------------------------------------------
# Group 6: the entry unit (C2), each position pinned independently.
# ---------------------------------------------------------------------------

@test "a key on the bullet line itself keys the entry" {
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-lima <!-- gaia-debt-key: v1 class=lint path=app/lima.ts line=1 --> keyed inline")"
  drive_body "$body"
  assert_permits_silently
}

@test "a key on a continuation line keys the entry" {
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-mike, no key on the bullet line" \
    "  continuation prose <!-- gaia-debt-key: v1 class=lint path=app/mike.ts line=1 -->")"
  drive_body "$body"
  assert_permits_silently
}

@test "a key on an indented sub-bullet keys the entry" {
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-november, no key on the bullet line" \
    "  - sub-bullet <!-- gaia-debt-key: v1 class=lint path=app/november.ts line=1 -->")"
  drive_body "$body"
  assert_permits_silently
}

@test "a key inside an indented fenced code block within the unit keys the entry (C2 has no fence model, only indentation)" {
  local body
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-oscar, no key on the bullet line" \
    '  ```' \
    "  <!-- gaia-debt-key: v1 class=lint path=app/oscar.ts line=1 -->" \
    '  ```')"
  drive_body "$body"
  assert_permits_silently
}

@test "a key belonging to the previous unit does not satisfy the next adjacent bullet" {
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-papa, keyed <!-- gaia-debt-key: v1 class=lint path=app/papa.ts line=1 -->" \
    "- residual-quebec, no key")"
  l="$(line_of "residual-quebec" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "a key appearing after the next heading does not satisfy the previous unit" {
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-romeo, no key before the next heading" \
    "## Some other heading" \
    "<!-- gaia-debt-key: v1 class=lint path=app/romeo.ts line=1 -->")"
  l="$(line_of "residual-romeo" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "prose beneath a canonical heading before any top-level bullet is not an entry and is never reported keyless" {
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "Some free-form prose that precedes the first bullet." \
    "- residual-sierra, no key")"
  l="$(line_of "residual-sierra" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "a malformed key with no wrapped HTML-comment form does not count as a key (README divergence D3's stated residual)" {
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-tango, bare inline Dedup key: v1 class=lint path=app/tango.ts line=1, no wrapper")"
  l="$(line_of "residual-tango" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

@test "a column-0 bullet inside a fenced sample splits the entry unit: a documented consequence, pinned rather than worked around" {
  # C2 defines no fence model, so a fenced sample beginning a line with "- "
  # at column 0 opens a NEW entry unit mid-fence rather than staying inside
  # the one it visually belongs to. The escape is to indent the fenced
  # sample by at least one space, or to key the split unit directly; the
  # `never` list forbids a bypass flag, so this is pinned as a known
  # consequence rather than treated as a defect.
  local body l
  body="$(join_lines \
    "$CANON_ACCEPT" \
    "- residual-uniform, keyed <!-- gaia-debt-key: v1 class=lint path=app/uniform.ts line=1 -->" \
    '```' \
    "- sample line inside the fence, unindented" \
    '```')"
  l="$(line_of "sample line inside the fence" "$body")"
  drive_body "$body"
  assert_denied_by_json
  grep -qF -- "Keyless entry count: 1" <<<"$output" || return 1
  grep -qF -- "Opening-bullet line number(s): ${l}." <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Group 7: the jq posture (C6), the one fail-closed arm in the whole check.
# ---------------------------------------------------------------------------

@test "jq absent with a gh-carrying payload denies loudly: exit 2, plain-text stderr, no JSON on stdout" {
  local json shim
  json=$(jq -n --arg c "gh pr merge 123 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
  shim="$(path_shim_without jq)"
  run --separate-stderr bash -c 'PATH="$1"; printf %s "$2" | bash "$3"' _ "$shim" "$json" "$HOOK_ABS"
  [ "$status" -eq 2 ] || return 1
  grep -qF -- "BLOCKED" <<<"$stderr" || return 1
  [ -z "$output" ] || return 1
}

@test "jq absent with no gh anywhere in the tool_input region permits" {
  local json shim
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "pnpm test"}}')
  shim="$(path_shim_without jq)"
  run --separate-stderr bash -c 'PATH="$1"; printf %s "$2" | bash "$3"' _ "$shim" "$json" "$HOOK_ABS"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# ---------------------------------------------------------------------------
# Group 8: non-vacuity control. Samples one mutant per mechanism deliberately
# -- Groups 1 through 7 carry the real coverage, this only proves an
# assertion is not vacuous. Every mutation runs against a scratch copy under
# $BATS_TEST_TMPDIR; the hook under review is never touched.
# ---------------------------------------------------------------------------

@test "mutation control: dropping one refused-heading literal from a scratch copy permits that heading instead of denying" {
  local dir mutant
  dir="$(make_mutant_dir mutant-heading)"
  mutant="$dir/audit-residual-shape-check.sh"
  sed "s/'## Accepted residuals'/'## MUTATED Accepted residuals'/" "$HOOK_ABS" > "$mutant"
  chmod +x "$mutant"
  run_hook_at "$mutant" "## Accepted residuals"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "mutation control: disabling the keyless scoring on a scratch copy permits a keyless entry instead of denying" {
  local dir mutant body
  dir="$(make_mutant_dir mutant-keyless)"
  mutant="$dir/audit-residual-shape-check.sh"
  sed 's/\[ "\$unit_keyed" != 1 \]; then/[ "$unit_keyed" != 1 ] \&\& false; then/' "$HOOK_ABS" > "$mutant"
  chmod +x "$mutant"
  body="$(join_lines "$CANON_ACCEPT" "- residual-victor, no key at all")"
  run_hook_at "$mutant" "$body"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}
