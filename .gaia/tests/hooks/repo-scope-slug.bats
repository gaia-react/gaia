#!/usr/bin/env bats

# Tests for `cmd_targets_foreign_repo_slug` in
# `.claude/hooks/lib/repo-scope.sh`, the act-on-home entry point.
#
# The sibling `cmd_targets_foreign_repo` serves BLOCKING consumers, where
# "home" means enforce, so it resolves every ambiguity to "home" and compares
# only the repo-NAME half of a `-R`/`--repo` value against the checkout's
# directory basename. A consumer that ACTS on the home repo inverts both
# properties: reading a foreign command as home makes it write to a pull
# request or an issue the command never named, so ambiguity resolves to
# "foreign", and the comparison is the whole [HOST/]OWNER/REPO that gh uses to
# identify a repository.
#
# The inversion reaches the `-R`/`--repo` arm only. A command naming no
# explicit target is delegated back to the blocking guard's cwd arms, which
# keep their fail-toward-home direction; s17 pins that rather than leaving it
# to be inferred from the paragraph above.
#
# The suite drives the REAL lib (sourced by absolute path, never copied)
# against a sandbox git repo, with a fake `gh` on PATH answering
# `repo view --json nameWithOwner,url`. The sandbox's directory basename and
# its home slug are deliberately UNRELATED (`gaia` vs `acme/widgets`), which
# is what lets a single fixture tell the two comparisons apart: a value the
# name-half comparison calls home and the slug comparison calls foreign.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  LIB_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh

  PARENT=$(mktemp -d -t repo-scope-slug-test-XXXXXX)
  REPO="$PARENT/gaia"
  SIBLING="$PARENT/other"
  for d in "$REPO" "$SIBLING"; do
    mkdir -p "$d"
    git -C "$d" init --quiet --initial-branch=main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config commit.gpgsign false
    echo "# readme" > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit --quiet -m "init"
  done

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
[ "${FAKE_GH_REPO_VIEW_EXIT:-0}" -eq 0 ] || exit "$FAKE_GH_REPO_VIEW_EXIT"
HOME_REPO="${FAKE_GH_HOME_REPO:-acme/widgets}"
HOME_HOST="${FAKE_GH_HOME_HOST:-github.com}"
case "$1 $2" in
  "repo view")
    jq -n --arg n "$HOME_REPO" --arg u "https://$HOME_HOST/$HOME_REPO" \
      '{nameWithOwner: $n, url: $u}'
    exit 0
    ;;
esac
exit 1
STUBEOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# Ask the entry point about one command, from inside the sandbox repo, in a
# fresh subshell so the lib's memoized home resolution never leaks between
# cases. Echoes `foreign` or `home` so a test asserts on a word rather than on
# an inverted exit status.
verdict() {
  ( cd "$REPO" || exit 1
    # shellcheck source=/dev/null
    . "$LIB_ABS"
    if cmd_targets_foreign_repo_slug "$1"; then echo foreign; else echo home; fi )
}

# The name-half verdict of the blocking guard, for the fixtures whose whole
# point is that the two disagree.
name_half_verdict() {
  ( cd "$REPO" || exit 1
    # shellcheck source=/dev/null
    . "$LIB_ABS"
    if cmd_targets_foreign_repo "$1"; then echo foreign; else echo home; fi )
}

@test "s1: a same-named sibling is foreign, where the name-half guard says home" {
  # The load-bearing fixture. The sandbox directory is `gaia`, so
  # `--repo other-org/gaia` matches the name-half comparison and reads as home
  # there; the home slug is `acme/widgets`, so the whole-slug comparison reads
  # it as the different repository it is.
  [ "$(name_half_verdict 'gh pr merge --repo other-org/gaia 5')" = "home" ]
  [ "$(verdict 'gh pr merge --repo other-org/gaia 5')" = "foreign" ]
}

@test "s2: the home slug is home" {
  [ "$(verdict 'gh pr merge --repo acme/widgets 5')" = "home" ]
}

@test "s3: a home slug differing only in case is home" {
  # GitHub resolves OWNER/REPO case-insensitively, so this lands on the home
  # repository and a case-sensitive comparison would cost the action.
  [ "$(verdict 'gh pr merge --repo ACME/Widgets 5')" = "home" ]
}

@test "s4: an owner differing from home is foreign even with the same name" {
  [ "$(verdict 'gh pr merge --repo other-org/widgets 5')" = "foreign" ]
}

@test "s5: a -R attached to its value is read" {
  [ "$(verdict 'gh pr merge -Rother-org/widgets 5')" = "foreign" ]
  [ "$(verdict 'gh pr merge -Racme/widgets 5')" = "home" ]
}

@test "s6: the = form is read" {
  [ "$(verdict 'gh pr merge --repo=other-org/widgets 5')" = "foreign" ]
}

@test "s7: a trailing flag decides as much as a leading one" {
  # gh accepts flags in any position, so a leading-flag-only read would leave
  # every trailing spelling unguarded.
  [ "$(verdict 'gh pr merge 5 --repo other-org/widgets')" = "foreign" ]
}

@test "s8: a host qualifier naming the home host is home" {
  [ "$(verdict 'gh pr merge --repo github.com/acme/widgets 5')" = "home" ]
}

@test "s9: a host qualifier naming another host is foreign" {
  # The same OWNER/REPO served from another host is another repository, which
  # a slug-only comparison would accept.
  [ "$(verdict 'gh pr merge --repo ghe.example.com/acme/widgets 5')" = "foreign" ]
}

@test "s10: no explicit target falls through to the cwd arms and reads home" {
  [ "$(verdict 'gh pr merge 5')" = "home" ]
}

@test "s11: a cd into a sibling checkout is foreign, via the shared cwd arms" {
  # Arms 2 and 3 of the blocking guard are shared verbatim rather than
  # reimplemented; only the -R/--repo comparison is replaced. Losing them
  # would silently drop the protection this entry point inherited.
  [ "$(verdict "cd $SIBLING && gh pr merge 5")" = "foreign" ]
}

@test "s12: an unresolvable home is foreign, not home" {
  # Fail direction, and the whole reason this is a separate entry point: an
  # acting consumer that cannot identify its own repository must decline.
  export FAKE_GH_REPO_VIEW_EXIT=1
  [ "$(verdict 'gh pr merge --repo acme/widgets 5')" = "foreign" ]
}

@test "s13: a quoted flag value is foreign, the documented limit" {
  # The capture keeps the quote characters, so the comparison misses. For an
  # acting consumer that direction is the safe one: it declines to act on a
  # value it did not parse, rather than acting on the wrong repository.
  [ "$(verdict 'gh pr merge --repo="acme/widgets" 5')" = "foreign" ]
}

@test "s14: the blocking entry point is unchanged by the new one" {
  # The existing comparison is left exactly as the nine blocking consumers
  # depend on it, including the over-classification that is safe for them.
  [ "$(name_half_verdict 'gh pr merge --repo other-org/gaia 5')" = "home" ]
  [ "$(name_half_verdict 'gh pr merge --repo other-org/other-repo 5')" = "foreign" ]
}

@test "s15: a later command's unrelated ATTACHED -R does not decide this one" {
  # `-R` is a common short flag on other tools, and a tool call may run one
  # after the merge. Reading its letters as the target classifies an ordinary
  # command foreign, and an acting consumer then silently declines on it.
  # Scoped to the attached spelling on purpose: the separated one is a live
  # gap, and s18 pins it rather than letting this name imply it is covered.
  [ "$(verdict 'gh pr merge 42 --squash && grep -Rn TODO .')" = "home" ]
  [ "$(verdict 'gh pr merge 42 --squash && cp -Rp a b')" = "home" ]
  [ "$(verdict 'gh pr merge 42 --squash && ls -RA')" = "home" ]
}

@test "s16: an attached -R still decides when it names a real slug" {
  # s15's safety direction: rejecting a bare-letter value must not also reject
  # the spelling s5 exists for.
  [ "$(verdict 'gh pr merge -Rother-org/widgets 5 && ls -RA')" = "foreign" ]
}

# s17 pins what the delegated cwd arms actually do, rather than what the
# inverted fail direction of the -R/--repo arm might suggest they do. A command
# naming no explicit target is handed to the blocking guard, which fails toward
# home, and these three redirections are not among the shapes it models. An
# acting consumer therefore does act on them. Inherited, not introduced here,
# and tracked as #1515; pinned so the gap stays visible and so closing it reds
# this test rather than passing unnoticed.
@test "s17: a cwd redirection the shared arms do not model reads home" {
  [ "$(verdict "pushd $SIBLING && gh pr merge 5")" = "home" ]
  [ "$(verdict "(cd $SIBLING && gh pr merge 5)")" = "home" ]
  [ "$(verdict "cd $PARENT/does-not-exist && gh pr merge 5")" = "home" ]
}

# s18 pins a live limit, not a desired behavior. The arm-1 capture requires a
# separator but nothing of the value, so a SEPARATED `-R` belonging to another
# command in the same tool call still supplies the target, and the `/`
# requirement s15 relies on does not discriminate here: a path argument carries
# a slash exactly as a slug does. Telling `-R app/routes` (grep's recursive
# flag plus a path) from `-R owner/repo` (gh's repository flag) needs to know
# which command the flag belongs to, which is the first-command contract this
# lib does not have and #1515 tracks. Arm 1 itself must stay byte-identical for
# the nine blocking consumers, so the repair belongs there, not here.
#
# The direction is the safe one: it declines rather than acting on the wrong
# repository, so it costs a findings-block posting rather than causing a wrong
# write, and it is not a regression, the boundary this replaced read the same
# way. Pinned so the limit is visible and so closing it reds this test.
@test "s18: a separated -R on another command still decides, the tracked limit" {
  [ "$(verdict 'gh pr merge 42 --squash && grep -R app/routes .')" = "foreign" ]
  [ "$(verdict 'gh pr merge 42 && cp -R a/b c/d')" = "foreign" ]
  [ "$(verdict 'gh pr merge 42 && ls -R /tmp')" = "foreign" ]
}
