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
# The inversion reaches the whole question, not one arm of it. This entry point
# reads the merge with the lib's first-command scan rather than sharing the
# blocking guard's cwd arms, so any prefix ahead of the merge means the first
# command is not the merge and the verdict is foreign; s11 and s17 pin that.
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
#
# `set -u` is the consumers' own setting, and it is load-bearing here rather
# than hygiene: the scan hands back an array whose length the command decides,
# so an index read past the end is a fatal error under `set -u` and no error at
# all without it. Reading a verdict from a permissive shell would report every
# such read as the verdict it would have produced had it not aborted.
verdict() {
  ( cd "$REPO" || exit 1
    set -u
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

@test "s10: a merge naming no explicit target reads home" {
  # The merge is the first command in the tool call, so nothing redirected cwd
  # ahead of it and gh resolves from the hook's own checkout.
  [ "$(verdict 'gh pr merge 5')" = "home" ]
}

@test "s11: a cd into a sibling checkout is foreign" {
  # Not because the path is read and compared: the scan stops at the first
  # command, which is the `cd`, so the merge is never reached and the verdict
  # is the abstention's. A path this entry point cannot resolve reaches the
  # same verdict for the same reason, which is what s17 pins.
  [ "$(verdict "cd $SIBLING && gh pr merge 5")" = "foreign" ]
}

@test "s12: an unresolvable home is foreign, not home" {
  # Fail direction, and the whole reason this is a separate entry point: an
  # acting consumer that cannot identify its own repository must decline.
  export FAKE_GH_REPO_VIEW_EXIT=1
  [ "$(verdict 'gh pr merge --repo acme/widgets 5')" = "foreign" ]
}

@test "s13: a quoted flag value is read, quotes removed" {
  # The scan resolves quoting the way the shell does, so the value gh receives
  # is the value compared. A capture over the raw text keeps the quote
  # characters, misses the comparison, and declines on a merge aimed squarely
  # at home.
  [ "$(verdict 'gh pr merge --repo="acme/widgets" 5')" = "home" ]
  [ "$(verdict "gh pr merge --repo='other-org/widgets' 5")" = "foreign" ]
}

@test "s14: the blocking entry point is unchanged by the new one" {
  # The existing comparison is left exactly as the blocking consumers
  # depend on it, including the over-classification that is safe for them.
  [ "$(name_half_verdict 'gh pr merge --repo other-org/gaia 5')" = "home" ]
  [ "$(name_half_verdict 'gh pr merge --repo other-org/other-repo 5')" = "foreign" ]
}

@test "s15: a later command's unrelated ATTACHED -R does not decide this one" {
  # `-R` is a common short flag on other tools, and a tool call may run one
  # after the merge. Reading its letters as the target classifies an ordinary
  # command foreign, and an acting consumer then silently declines on it.
  [ "$(verdict 'gh pr merge 42 --squash && grep -Rn TODO .')" = "home" ]
  [ "$(verdict 'gh pr merge 42 --squash && cp -Rp a b')" = "home" ]
  [ "$(verdict 'gh pr merge 42 --squash && ls -RA')" = "home" ]
}

@test "s16: an attached -R still decides when it names a real slug" {
  # s15's safety direction: rejecting a bare-letter value must not also reject
  # the spelling s5 exists for.
  [ "$(verdict 'gh pr merge -Rother-org/widgets 5 && ls -RA')" = "foreign" ]
}

# s17 covers the redirections no pattern set models. Each puts a command ahead
# of the merge, so each fails the first-command requirement and reads foreign,
# and the third does so without the path being resolvable at all. Declining is
# the safe direction: it costs a findings-block posting rather than a write
# onto a pull request in a repository the merge never named.
@test "s17: a cwd redirection ahead of the merge is foreign" {
  [ "$(verdict "pushd $SIBLING && gh pr merge 5")" = "foreign" ]
  [ "$(verdict "(cd $SIBLING && gh pr merge 5)")" = "foreign" ]
  [ "$(verdict "cd $PARENT/does-not-exist && gh pr merge 5")" = "foreign" ]
}

# s18 is the sibling of s15 for the SEPARATED spelling, which no shape test on
# the value can tell from gh's own repository flag: a path argument carries a
# slash exactly as a slug does. Telling `-R app/routes` (grep's recursive flag
# plus a path) from `-R owner/repo` needs to know which command the flag
# belongs to, and the scan knows because it reads only the first command's
# words. The merge itself names no repository, so each of these reads home.
@test "s18: a separated -R on another command does not decide this one" {
  [ "$(verdict 'gh pr merge 42 --squash && grep -R app/routes .')" = "home" ]
  [ "$(verdict 'gh pr merge 42 && cp -R a/b c/d')" = "home" ]
  [ "$(verdict 'gh pr merge 42 && ls -R /tmp')" = "home" ]
}

# s19 pins the abstention the parser makes on its own account, separately from
# the first-command one. gh accepts a single-dash cluster and its flag library
# reads it letter by letter, so `-sR<slug>` is a squash merge of another
# repository; the parser does not model that and declines rather than reading
# the merge as home.
@test "s19: a single-dash flag cluster is foreign" {
  [ "$(verdict 'gh pr merge -sd 42')" = "foreign" ]
  [ "$(verdict 'gh pr merge -sRother-org/widgets 42')" = "foreign" ]
}

# s20 discriminates the three words that identify the merge. The redirection
# fixtures above cannot: each of those closes its first command in two words, so
# the length check alone decides them, and a conjunct dropped from the identity
# test would survive every one. Each of these carries a three-word first command
# that fails exactly one conjunct, and each names the HOME repository or names
# none, so a dropped conjunct reads it as home rather than agreeing by accident.
@test "s20: a first command that only resembles the merge is foreign" {
  # Fails on the subcommand.
  [ "$(verdict 'gh pr view --repo acme/widgets 5 && gh pr merge 5')" = "foreign" ]
  # Fails on the command group.
  [ "$(verdict 'gh browse merge && gh pr merge 5')" = "foreign" ]
  # Fails on the program: another tool whose first three words spell the same
  # phrase is not this one's invocation.
  [ "$(verdict 'hub pr merge 5 && gh pr merge 5')" = "foreign" ]
}

# s21 pins the length check that guards the identity test's own index reads.
# A first command shorter than the merge phrase leaves those indices unset, and
# `verdict` runs under the consumers' `set -u`, so dropping the check aborts the
# lib mid-question rather than answering it.
@test "s21: a first command shorter than the merge phrase is foreign" {
  [ "$(verdict 'gh pr && gh pr merge 5')" = "foreign" ]
  [ "$(verdict 'gh && gh pr merge 5')" = "foreign" ]
}
