#!/usr/bin/env bats

# Adversarial suite for .gaia/scripts/list-tracked-paths.sh, the boundary where
# the release staging pipeline turns git's NUL-delimited tracked set into the
# newline-delimited list `grep -f` and `rsync --files-from` read.
#
# The defect this guards (#1669) is that the conversion is lossy for exactly one
# input, a tracked path holding a literal newline, and that its damage is NOT
# uniform: rsync exits 23 when a split half names no file, but exits 0 whenever
# every name it is handed happens to exist, publishing a tarball without the
# file while .gaia/manifest.json records it as shipping. The general condition,
# not the enumeration of arms, is what the suite asserts against: the boundary
# refuses whenever any tracked path holds a newline, regardless of what the
# halves happen to name.
#
# Three families, described rather than enumerated, so adding a member to one
# does not leave a roster here saying otherwise.
#
# The E family drives fixture repositories through the boundary: the clean case,
# the refusal, the silent arm where both split halves name real files, a
# non-ASCII path the refusal must not over-reach onto, and the exit-code split
# the callers read, which is the whole contract between a refusal and a failure.
#
# The C family binds the callers. One holds the named staging sites to the
# boundary so the round-trip cannot return to one of them silently; the other
# asks the same invariant of the whole tree rather than of a list, so a site
# nobody named here is still covered.
#
# The A family arms the boundary's refusal (A1) and the tree scan C2 reads
# (A2, A3), because a guard whose red state has never been observed is an
# unverified claim: each one breaks the thing it arms and proves some test
# goes red. C1's own per-site assertions carry no such fixture; they were
# verified by hand (#1691). A green check here is evidence, not assumption.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], POSIX [ ] and grep only, so a broken assertion still fails on
# macOS bash 3.2.
#
# Maintainer-only. `.gaia/scripts/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/list-tracked-paths.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  OUT="$BATS_TEST_TMPDIR/all-tracked.txt"
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.email 'test@example.com'
  git -C "$FIXTURE" config user.name 'Test'
}

# Track $1 (a repo-relative path, which may contain a literal newline) holding
# body $2. Deliberately does NOT commit: `ls-files` reads the index, which is
# the same set the staging pipeline discovers from.
track() {
  local rel="$1" body="$2"
  mkdir -p "$FIXTURE/$(dirname "$rel")"
  printf '%s\n' "$body" > "$FIXTURE/$rel"
  git -C "$FIXTURE" add -- "$rel"
}

# E1. The ordinary case still works: every tracked path reaches the output file,
# one per line, and the script exits clean.
@test "E1: a clean tree converts to a newline-delimited list" {
  track 'a.txt' 'alpha'
  track 'dir/b.txt' 'beta'

  run bash "$SCRIPT" "$FIXTURE" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ "$(wc -l < "$OUT" | tr -d ' ')" = "2" ]
  grep -qxF -- 'a.txt' "$OUT"
  grep -qxF -- 'dir/b.txt' "$OUT"
}

# E2. The defect itself. A tracked path holding a literal newline is refused,
# the output file is never written, and the diagnostic names the path with its
# newline rendered so a maintainer reads the path rather than a fragment.
@test "E2: a newline-bearing tracked path is refused, with the path named" {
  track 'ok.txt' 'fine'
  track "$(printf 'two\nlines.ts')" 'split'

  run bash "$SCRIPT" "$FIXTURE" "$OUT"
  [ "$status" -eq 1 ]
  [ ! -f "$OUT" ]
  grep -qF -- 'two\nlines.ts' <<<"$output"
  grep -qF -- '1 tracked path(s)' <<<"$output"
}

# E3. The general condition, not the arms. Both halves of this path name real
# tracked files, which is the arm where rsync exits 0 and the release publishes
# silently without the file. The boundary must refuse identically here; a guard
# built against the exit-23 arm alone would pass this.
@test "E3: refusal does not depend on whether the split halves name files" {
  track 'a.txt' 'alpha'
  track 'b.txt' 'beta'
  track "$(printf 'a.txt\nb.txt')" 'the silent arm'

  run bash "$SCRIPT" "$FIXTURE" "$OUT"
  [ "$status" -eq 1 ]
  [ ! -f "$OUT" ]
  grep -qF -- 'a.txt\nb.txt' <<<"$output"
}

# E5. The 1-versus-2 split, which is the whole contract the callers read. Every
# other test in this suite passes identically against a bare `>` redirect, and a
# bare redirect bash cannot open leaves status 1, the refusal code: the release
# workflow would then annotate a full disk as a tracked path needing a rename.
# Without this test the guard that prevents it can be deleted with nothing red.
@test "E5: a write that cannot open exits 2, never the refusal code" {
  track 'a.txt' 'alpha'

  run bash "$SCRIPT" "$FIXTURE" "$BATS_TEST_TMPDIR/no-such-dir/out.txt"
  [ "$status" -eq 2 ]
  grep -qF -- 'could not write the tracked-path list' <<<"$output"
}

# E4. The refusal must not over-reach onto the input `-z` exists to protect. A
# non-ASCII path is exactly what git would C-quote under its default
# core.quotePath (#1662); it survives this boundary intact and byte-identical.
@test "E4: a non-ASCII tracked path passes through intact" {
  track 'wiki/café.md' 'accented'

  run bash "$SCRIPT" "$FIXTURE" "$OUT"
  [ "$status" -eq 0 ]
  grep -qxF -- 'wiki/café.md' "$OUT"
  grep -qF -- '"wiki/caf' "$OUT" && return 1
  true
}

# Every tracked file under $1 that pairs the raw round-trip with an
# `rsync --files-from` consumer, one per line. Shared by C2 and A2 so the
# adversarial fixture exercises the same scan the contract check runs.
#
# The pair is the closed property, and it has to be the pair: the round-trip
# alone is legitimate wherever the names are compared or counted rather than
# resolved (a diagnostic `head -20`, a `comm` membership check, a roster drift
# scan), which is most of its uses in this tree, and a guard that reds on those
# is one that gets bypassed rather than fixed. `--files-from` is what turns a
# name into a file the release must find on disk.
#
# The round-trip half is matched as a regex rather than as the one spelling the
# migrated sites happened to use. A scan that only recognises a copy-paste of an
# existing site has a guarantee that expires on the first site somebody writes
# rather than copies, so the pattern tolerates the flags and spacing between
# `ls-files` and its `-z`, and tolerates a command prefix on the `tr`: a locale
# pin, a `command` builtin bypass, or an absolute path. The locale prefix is not
# hypothetical, it is the spelling the boundary script itself uses, so it is the
# one a next author is likeliest to reach for.
#
# What is still outside it: a round-trip split across two statements, and one
# whose `--files-from` consumer lives in another file. Widening past that means
# matching on the consumer rather than on the call text, which is a judgment
# about downstream rather than a closed property of the file, and the sibling
# lint declines to make it for the same reason.
#
# Each grep's status is read on three outcomes, not two: 0 matched, 1 did not,
# and anything above that is grep failing to read the file at all. Folding the
# third into "did not match" is how a scan reports clean over a file it never
# opened, which for a path in the index but absent from the worktree is an
# ordinary state rather than a corrupt one. Each status is captured with
# `|| status=$?` rather than a bare call followed by `$?`: bats runs a test body
# under errexit, and the bare form survives only where the caller happens to
# blunt it (a command substitution, or bats' own `run`), so it would abort the
# first time somebody called this helper directly.
scan_raw_roundtrip() {
  local root="$1" f status
  while IFS= read -r -d '' f; do
    # This suite carries both patterns as assertion literals, by construction.
    case "$f" in
      '.gaia/scripts/tests/list-tracked-paths.bats') continue ;;
    esac

    status=0
    grep -qE -- "ls-files[^|]*-z[^|]*[|]([[:space:]]*|[^|]*[[:space:]/])tr[[:space:]]" "$root/$f" || status=$?
    [ "$status" -le 1 ] || { printf 'unreadable: %s\n' "$f"; return 1; }
    [ "$status" -eq 0 ] || continue

    status=0
    grep -qF -- '--files-from' "$root/$f" || status=$?
    [ "$status" -le 1 ] || { printf 'unreadable: %s\n' "$f"; return 1; }
    [ "$status" -eq 0 ] || continue

    printf '%s\n' "$f"
  done < <(git -C "$root" ls-files -z)
}

# C1. Every site that discovers the tracked set for a staging build routes
# through this script. The raw `ls-files -z | tr` round-trip returning to any
# one of them is how this class comes back, and it is invisible in a diff that
# reads as a local simplification.
#
# Why each entry is a member:
#
#   release.yml               produces the published tarball; the live instance
#   lib/build-staging.sh      the harness's own staging build, which mirrors it
#   03-marker-strip.sh        walks the tracked set a second time to pick the
#                             marker-bearing source files out of it
#   09-exclude-parser-parity  builds the same list over a fixture tree, and the
#                             parity it asserts is against build-staging.sh
#   runbook.md                a live call site, not illustration: an
#                             always-loaded rule has the agent run that page's
#                             steps as written, and the fenced block ends in the
#                             same `rsync --files-from`
#
# Deliberately not members: the sites that carry the round-trip to compare or
# count names rather than resolve them. `scan_raw_roundtrip` above states why
# they are excluded and what separates them; C2 is keyed to hold that line
# without this list having to name any of them.
@test "C1: every staging discovery site calls the shared boundary" {
  local site
  for site in \
    '.github/workflows/release.yml' \
    '.gaia/tests/distribution/lib/build-staging.sh' \
    '.gaia/tests/distribution/03-marker-strip.sh' \
    '.gaia/tests/distribution/09-exclude-parser-parity.sh' \
    '.gaia/cli/health/runbook.md'; do
    # An invocation, not a mention. release.yml's comment names the boundary by
    # filename directly above the call, so there a bare filename match is
    # satisfied by the prose alone and a reverted call that kept the comment
    # would still pass; the other four sites name "the shared boundary" without
    # the filename. Anchoring on the interpreter separates the two at every
    # site, and it holds for both spellings in use: a repo-relative path and a
    # "$PROJECT_ROOT"-prefixed one.
    grep -qE -- 'bash [^ ]*list-tracked-paths[.]sh' "$REPO_ROOT/$site" \
      || { printf 'no list-tracked-paths.sh invocation in %s\n' "$site" >&2; return 1; }
    # The same pattern the tree scan carries, so a round-trip wearing a flag or
    # a locale prefix reds here too. 03-marker-strip.sh needs it: it is the one
    # site with no `rsync --files-from`, so C2 declines it by design and this is
    # the only assertion standing between it and a silent revert.
    grep -qE -- "ls-files[^|]*-z[^|]*[|]([[:space:]]*|[^|]*[[:space:]/])tr[[:space:]]" "$REPO_ROOT/$site" \
      && { printf 'raw ls-files round-trip still present in %s\n' "$site" >&2; return 1; }
  done
  true
}

# C2. C1's roster is an enumeration, and an enumeration goes one site short the
# moment somebody adds another. This asks the same invariant of the tree rather
# than of a list, so a site nobody named here is still covered.
#
# What it pins, stated so the guarantee is not read wider than it is: a call
# whose `ls-files` and its `tr` sit in one pipeline, tolerant of the flags and
# spacing between them, in a file that also names an `rsync --files-from`.
# A round-trip split across two statements, or one whose consumer is reached
# through a variable in another file, is outside it. Widening further means
# matching on the consumer rather than on the call text, which is a judgment
# about downstream rather than a closed property of the file, and the sibling
# lint declines to make it for the same reason.
@test "C2: no tracked file pairs the raw round-trip with an rsync --files-from" {
  local hits
  hits="$(scan_raw_roundtrip "$REPO_ROOT")"
  [ -z "$hits" ] || { printf 'raw round-trip feeding --files-from:\n%s\n' "$hits" >&2; return 1; }
}

# A2. Arming fixture for C2. A scan that reports nothing is indistinguishable
# from a scan that looks at nothing, so plant the defect in a fixture tree and
# prove the same function reports it.
@test "A2: the tree scan reports a planted raw round-trip" {
  track 'stage.sh' "git ls-files -z | tr '\\0' '\\n' > list.txt; rsync -a --files-from=list.txt . out/"
  # The same defect wearing a flag and wider spacing. Pinning one spelling is
  # what would let the next author reintroduce this with the scan still green.
  track 'flagged.sh' "git ls-files --cached -z  |  tr '\\0' '\\n' > l.txt; rsync -a --files-from=l.txt . o/"
  # And wearing a locale pin, which is the boundary script's own spelling and so
  # the likeliest thing a next author writes rather than copies.
  track 'localed.sh' "git ls-files -z | LC_ALL=C tr '\\0' '\\n' > l.txt; rsync -a --files-from=l.txt . o/"
  track 'innocent.sh' "git ls-files -z | tr '\\0' '\\n' > names.txt; comm -12 names.txt other.txt"

  local hits
  hits="$(scan_raw_roundtrip "$FIXTURE")"
  grep -qxF -- 'stage.sh' <<<"$hits"
  grep -qxF -- 'flagged.sh' <<<"$hits"
  grep -qxF -- 'localed.sh' <<<"$hits"
  # The round-trip without a --files-from consumer must NOT be reported, or the
  # scan is a rename of the lint that already declined to red on those sites.
  grep -qxF -- 'innocent.sh' <<<"$hits" && return 1
  true
}

# A3. The scan's third outcome. A file in the index but absent from the
# worktree makes grep exit 2, and a scan that reads that as "no match" reports
# clean over a file it never opened. This is the state of an ordinary
# deleted-but-unstaged file, not a corrupt tree.
@test "A3: an unreadable tracked file fails the scan rather than passing it" {
  track 'stage.sh' "git ls-files -z | tr '\\0' '\\n' > list.txt; rsync -a --files-from=list.txt . out/"
  track 'vanished.sh' 'placeholder'
  rm -f "$FIXTURE/vanished.sh"

  run scan_raw_roundtrip "$FIXTURE"
  [ "$status" -ne 0 ]
  grep -qF -- 'unreadable: vanished.sh' <<<"$output"
}

# A1. Arming fixture. Strip the refusal out of a scratch copy and the
# newline-bearing path splits into two records that name no file, which is the
# behaviour E2 and E3 assert is gone. Without this, a green E2 is equally
# consistent with a guard that never fires.
@test "A1: without the refusal the path splits into two bogus records" {
  track "$(printf 'two\nlines.ts')" 'split'

  local scratch="$BATS_TEST_TMPDIR/no-guard.sh"
  awk '/^if \[ "\$lf_bytes" != "0" \]; then$/ {skip = 1} skip && /^fi$/ {skip = 0; next} !skip' \
    "$SCRIPT" > "$scratch"
  # The mutation must actually have removed something, or A1 proves nothing.
  [ "$(wc -l < "$scratch" | tr -d ' ')" -lt "$(wc -l < "$SCRIPT" | tr -d ' ')" ]

  run bash "$scratch" "$FIXTURE" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT" | tr -d ' ')" = "2" ]
  grep -qxF -- 'two' "$OUT"
  grep -qxF -- 'lines.ts' "$OUT"
}
