#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-shipped-issue-refs.sh: the gate that flags an
# unqualified `#NNN` reference on a shipped non-Markdown file, where the number
# would resolve against the adopter's own tracker.
#
# Three jobs. Prove the detector fires on a bare reference and stays quiet on
# every legitimate shape (the qualified form, a third-party qualified form,
# Markdown, a file outside the manifest, a CSS colour). Assert the real shipped
# tree is clean, so a regression fails CI. And pin the release-boundary facts
# `.claude/rules/code-comments.md` states as prose against the manifest that
# decides them, so the rule cannot quietly stop being true.
#
# The colour tests are the ones worth reading twice. `#333` is simultaneously a
# valid issue number and a valid CSS short hex colour, shipped CSS is in the
# manifest, and the gate runs on every pull request -- so an unnarrowed detector
# reds the build on a colour, which is a false positive with no correct repair.
# The narrowing is punctuation-based and its accepted miss (`Fixes: #726;`) is
# pinned below as a test rather than left to be rediscovered.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves `.gaia/manifest.json` relative to cwd, so every fixture is a
# directory carrying its own manifest and the linter is run from inside it.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-shipped-issue-refs.sh"
  MANIFEST="$REPO_ROOT/.gaia/manifest.json"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_tree: an empty fixture directory in $TMP with no manifest yet.
fixture_tree() {
  TMP="$(mktemp -d -t shipped-issue-refs-XXXXXX)"
  mkdir -p "$TMP/.gaia"
}

# fixture_manifest <relpath...>: write a manifest naming exactly these files.
fixture_manifest() {
  local out="" p
  for p in "$@"; do
    [ -z "$out" ] || out="$out,"
    out="$out\"$p\":\"owned\""
  done
  printf '{"files":{%s}}\n' "$out" > "$TMP/.gaia/manifest.json"
}

# fixture_file <relpath> <body>: write <body> to $TMP/<relpath>.
fixture_file() {
  mkdir -p "$TMP/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/$1"
}

# run_linter: run the gate from the fixture root, where its cwd-relative
# manifest read resolves.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER'"
}

# 1. The real shipped tree is clean (regression gate)

@test "the real shipped tree carries no unqualified reference" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 2. The detector fires

@test "a bare reference in a shipped shell file reds, naming file and line" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  fixture_file hooks/probe.sh $'#!/usr/bin/env bash\n# the status 422s and never lands (#726)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "hooks/probe.sh:2:" <<<"$output"
  grep -qF -- "#726" <<<"$output"
}

@test "the report points the reader at the rule that owns the remedy" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  fixture_file hooks/probe.sh $'# see #1053 for the ruling'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/rules/code-comments.md" <<<"$output"
}

@test "a bare reference reds in a shipped YAML file too, not just shell" {
  fixture_tree
  fixture_manifest "workflows/ci.yml"
  fixture_file workflows/ci.yml $'# guards the 422 hazard from #726\njobs: {}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "workflows/ci.yml:1:" <<<"$output"
}

# 3. The legitimate shapes stay quiet

@test "the qualified gaia-react/gaia form is not a hit" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  fixture_file hooks/probe.sh $'# the status 422s and never lands (gaia-react/gaia#726)'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a third-party owner/repo form is not a hit" {
  fixture_tree
  fixture_manifest "test/a11y.ts"
  fixture_file test/a11y.ts $'// happy-dom breaks axe-core (capricorn86/happy-dom#978).'
  run_linter
  [ "$status" -eq 0 ]
}

@test "Markdown is outside the scan surface" {
  fixture_tree
  # A scannable, clean sibling so the empty-scan-set guard cannot make this
  # pass for the wrong reason: the exit 0 must come from the .md file being
  # unscanned, not from there being nothing to scan.
  fixture_manifest "hooks/probe.sh" "docs/notes.md"
  fixture_file hooks/probe.sh $'# nothing to see'
  fixture_file docs/notes.md $'Historic ruling in #726 and heading ### 12'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a file absent from the manifest is not scanned" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  fixture_file hooks/probe.sh $'# nothing to see'
  # Stands in for a release-excluded surface (.gaia/tests/, .gaia/scripts/tests/,
  # .github/audit/tests/), where the rule says the unqualified form stays.
  fixture_file tests/excluded.bats $'@test "reds against #1229" {\n  true\n}'
  run_linter
  [ "$status" -eq 0 ]
}

# 4. The colour exemption

@test "CSS short hex colours do not red the gate" {
  fixture_tree
  fixture_manifest "app/styles.css"
  # A colour is rarely the FIRST token of its declaration value, which is the
  # shape an earlier draft of the exemption was accidentally limited to. Every
  # line below carries a 3- or 4-digit shorthand in a position that draft
  # reported, so the suite covers the whole class rather than the easy case:
  # value-leading, inside a compound value, inside a function argument list,
  # and closing a declaration that omits its semicolon.
  fixture_file app/styles.css $'.a { color: #333; }\n.b { background: #0000; }\n.c { border: 1px solid #444; }\n.d { box-shadow: 0 0 4px #555; }\n.e { background: linear-gradient(#666, #777); }\n.f { background: var(--x, #888); }\n.g { outline: 2px dashed #999 }\n.h { border: 1px solid #123456; }'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a quoted hex colour in a shipped TS file does not red the gate" {
  fixture_tree
  fixture_manifest "app/theme.ts"
  fixture_file app/theme.ts $'export const theme = {bg: \'#333\', fg: "#0f0"};'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the colour exemption does not swallow a parenthesised reference" {
  fixture_tree
  fixture_manifest "app/styles.css"
  # `(#726)` opens on `(` rather than `:` or `=`, so it fails the colour test
  # and stays a hit even inside a CSS file.
  fixture_file app/styles.css $'/* ruled out in (#726) */\n.a { color: #333; }'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "#726" <<<"$output"
}

@test "a two-digit reference is never colour-exempt, whatever surrounds it" {
  fixture_tree
  fixture_manifest "app/styles.css"
  # No two-digit CSS hex colour exists, so the exemption must not reach one even
  # in perfect colour shape.
  fixture_file app/styles.css $'.a { color: #72; }'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "#72" <<<"$output"
}

@test "the accepted miss is pinned: a reference in exact colour shape is exempt" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  # Documented FAIL-OPEN limit of the punctuation test, asserted so a future
  # narrowing that closes it fails here and gets read rather than guessed at.
  # These are the shapes the script's header names, chosen because they are
  # what someone actually writes: any line carrying an earlier `:` or `=` where
  # a `,`, `;`, `)` or quote follows the reference. Pinning realistic shapes
  # rather than a contrived one is the point, so the fail-open surface is not
  # underestimated by whoever reads this next.
  fixture_file hooks/probe.sh $'# Fixes: #726;\n# TODO: fix #727, then remove\n# Why: the hook denies (#728).'
  run_linter
  [ "$status" -eq 0 ]
}

# 5. Fail-closed behaviour

@test "a manifest naming no files is a hard error, never a clean tree" {
  fixture_tree
  fixture_manifest
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
  grep -qF -- "clean" <<<"$output" && return 1
  true
}

@test "a missing manifest is a hard error rather than a pass" {
  fixture_tree
  fixture_file hooks/probe.sh $'# see #726'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "not found" <<<"$output"
}

@test "a shipped binary asset is skipped rather than reported" {
  fixture_tree
  fixture_manifest "assets/icon.png"
  mkdir -p "$TMP/assets"
  # Binary whose bytes happen to spell a reference. Without the content-based
  # skip this is reported as a hit, naming a line number inside a PNG that the
  # reader cannot act on and that no edit can repair.
  #
  # The byte layout is what makes this observable, and both halves are load
  # bearing. The reference comes FIRST, because awk ends a record at a NUL and
  # would never reach a reference sitting after one. The NUL padding comes
  # after, because that is what `grep -I` keys on: a file of high and control
  # bytes with no NUL is called text in some environments and binary in others,
  # so a fixture resting on that would assert nothing here and fail elsewhere.
  { printf '# see #726\n'; head -c 4096 /dev/zero; } > "$TMP/assets/icon.png"
  run_linter
  [ "$status" -eq 0 ]
}

@test "a text file after a binary one is still scanned" {
  fixture_tree
  # `assets/` so the binary sorts BEFORE the text file: the scan set is
  # LC_ALL=C sorted, so a `public/` name would sort after `hooks/` and the
  # ordering this test depends on would not hold.
  fixture_manifest "assets/icon.png" "hooks/probe.sh"
  mkdir -p "$TMP/assets"
  printf '\211PNG\r\n\032\n\000\001\002\003\377\376\375' > "$TMP/assets/icon.png"
  fixture_file hooks/probe.sh $'# a bare #726 after the binary must still be reported'
  run_linter
  # An awk that aborts on the binary rather than skipping it would lose this
  # hit entirely, so the run must survive the binary and keep going.
  [ "$status" -eq 1 ]
  grep -qF -- "hooks/probe.sh:1:" <<<"$output"
}

@test "a manifest entry with no file on disk is skipped without stopping the scan" {
  fixture_tree
  # `absent.sh` sorts before `probe.sh` under LC_ALL=C, so a `break` where the
  # loop has a `continue` would truncate the scan at the first missing entry
  # and still print `clean`: the same lie-green the empty-scan-set guard exists
  # to prevent, reached by another route. The reference below is what makes a
  # truncating loop observable; without it this test passes either way.
  fixture_manifest "hooks/probe.sh" "hooks/absent.sh"
  fixture_file hooks/probe.sh $'# a bare #726 after the missing entry'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "hooks/probe.sh:1:" <<<"$output"
  # The absent entry is skipped silently rather than reported as a finding.
  grep -qF -- "absent.sh" <<<"$output" && return 1
  true
}

# 6. Reporting contract

@test "a clean tree reports clean and exits 0" {
  fixture_tree
  fixture_manifest "hooks/probe.sh"
  fixture_file hooks/probe.sh $'# nothing to see'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# 7. Release-boundary parity with the rule's prose
#
# `.claude/rules/code-comments.md` states which surfaces carry the qualification
# obligation and which are release-excluded and exempt. Nothing else checks that
# those statements are still true, and a wrong one fails silently green: the
# rule keeps claiming something that quietly stopped being the case. These
# assertions read the manifest, which is what actually decides it.

# manifest_has_prefix <prefix>: succeed when the manifest names at least one
# file under <prefix>.
manifest_has_prefix() {
  jq -e --arg p "$1" '.files | keys | map(select(startswith($p))) | length > 0' \
    "$MANIFEST" >/dev/null
}

@test "the surfaces the rule calls shipped are in the manifest" {
  manifest_has_prefix ".claude/hooks/"
  manifest_has_prefix ".github/audit/"
  manifest_has_prefix ".github/actions/"
}

@test "the surfaces the rule calls release-excluded are absent from the manifest" {
  manifest_has_prefix ".gaia/tests/" && return 1
  manifest_has_prefix ".gaia/scripts/tests/" && return 1
  manifest_has_prefix ".github/audit/tests/" && return 1
  true
}

@test "code-review-audit.yml is unshipped but its render template ships" {
  # The rule states this pair as the reason the workflow's absence from the
  # manifest is not a coverage hole: the gate reaches the template instead.
  jq -e '.files | has(".github/workflows/code-review-audit.yml")' "$MANIFEST" >/dev/null && return 1
  jq -e '.files | has(".gaia/cli/templates/workflows/code-review-audit.yml.tmpl")' "$MANIFEST" >/dev/null
}
