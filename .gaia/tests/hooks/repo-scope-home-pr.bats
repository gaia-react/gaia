#!/usr/bin/env bats

# Tests for `gaia_gh_merge_ref_to_home_pr` in
# `.claude/hooks/lib/repo-scope.sh`, the URL half of the act-on-home boundary.
#
# `-R`/`--repo` cannot qualify a URL: gh resolves the repository from the URL
# itself and ignores the flag, so the scanned repository is empty and
# `cmd_targets_foreign_repo_slug` reads it as home. This function is what the
# two acting consumers ask instead, and it lives in the lib so they cannot
# answer it differently.
#
# Two shapes are matched as loosely as gh matches them, and everywhere else
# the matcher stays deliberately tighter; h12 and h20 pin the limits. The two
# followed are the suffixed and port-bearing spellings: gh's URL matcher is
# unanchored after the number and its comparison drops a port, so each of
# those names the home pull request to gh, and declining one would cost a
# merge that really did land on home. That decline is a silent no-op rather
# than a wrong write, which is why the followed group reads as coverage
# rather than as safety.
#
# The tighter cases are not symmetric with it. An ACCEPT where gh declines is
# the one direction a boundary that acts cannot have, so the scheme, the
# separator before a suffix, and userinfo on the authority all stay strict on
# purpose, and h12 and h20 exist to keep a later reader from loosening them.
#
# The suite drives the REAL lib (sourced by absolute path, never copied)
# against a sandbox git repo, with a fake `gh` on PATH answering
# `repo view --json nameWithOwner,url`.
#
# Assertions are POSIX `[ ... ]` per `.claude/rules/bats-assertions.md`: a bare
# `[[ ]]` that is not a test's last command does not fail on bash 3.2.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  LIB_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh

  REPO=$(mktemp -d -t repo-scope-home-pr-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

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
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Ask the function about one reference, from inside the sandbox repo, in a
# fresh subshell so the lib's memoized home resolution never leaks between
# cases. Echoes the resolved number, or `decline` on a non-zero return.
#
# `set -u` is the consumers' own setting, and it is load-bearing rather than
# hygiene: a read of an unset capture is fatal under it and silent without it,
# so a permissive shell would report a verdict the consumers never reach.
resolve() {
  ( cd "$REPO" || exit 1
    set -u
    # shellcheck source=/dev/null
    . "$LIB_ABS"
    if gaia_gh_merge_ref_to_home_pr "$1"; then
      echo "$GAIA_HOME_PR_NUMBER"
    else
      echo decline
    fi )
}

@test "h1: a home-repository URL resolves to its number" {
  [ "$(resolve 'https://github.com/acme/widgets/pull/7')" = "7" ]
}

@test "h2: another repository's URL declines" {
  [ "$(resolve 'https://github.com/other-org/other-repo/pull/7')" = "decline" ]
}

@test "h3: the home slug on another host declines" {
  # The same OWNER/REPO served from another host is another repository, which
  # a slug-only comparison would accept.
  [ "$(resolve 'https://ghe.example.com/acme/widgets/pull/7')" = "decline" ]
}

@test "h4: on an enterprise home host, its own URL resolves and github.com does not" {
  # The mirror direction. Without it the host comparison could pass by
  # hardcoding github.com rather than by reading the home repository.
  export FAKE_GH_HOME_HOST="ghe.example.com"
  [ "$(resolve 'https://ghe.example.com/acme/widgets/pull/7')" = "7" ]
  [ "$(resolve 'https://github.com/acme/widgets/pull/7')" = "decline" ]
}

@test "h5: a slug differing only in case resolves" {
  # GitHub resolves OWNER/REPO case-insensitively, so this URL lands on the
  # home repository and a case-sensitive comparison would cost the action.
  [ "$(resolve 'https://github.com/ACME/Widgets/pull/7')" = "7" ]
}

@test "h6: a host differing only in case resolves" {
  [ "$(resolve 'https://GitHub.COM/acme/widgets/pull/7')" = "7" ]
}

# h7-h10 are the suffix group: gh's URL matcher is unanchored after the
# number, so each of these is a URL gh merges as home pull request 7 while an
# anchored matcher here declines and posts nothing. h7 is the one a human
# actually produces, by copying the address bar off the Files tab.
@test "h7: a /files suffix resolves" {
  [ "$(resolve 'https://github.com/acme/widgets/pull/7/files')" = "7" ]
}

@test "h8: a query suffix resolves" {
  [ "$(resolve 'https://github.com/acme/widgets/pull/7?w=1')" = "7" ]
}

@test "h9: a fragment suffix resolves" {
  [ "$(resolve 'https://github.com/acme/widgets/pull/7#issuecomment-1')" = "7" ]
}

@test "h10: a trailing slash resolves" {
  [ "$(resolve 'https://github.com/acme/widgets/pull/7/')" = "7" ]
}

@test "h11: a suffix does not widen the repository comparison" {
  # The relaxation is to the shape, never to the boundary: a foreign URL is
  # still foreign with the same suffix that makes a home one resolve.
  [ "$(resolve 'https://github.com/other-org/other-repo/pull/7/files')" = "decline" ]
  [ "$(resolve 'https://ghe.example.com/acme/widgets/pull/7/files')" = "decline" ]
}

@test "h12: the shapes gh accepts and this deliberately does not" {
  # The relaxation's own limits, pinned so the lib's comment about them is a
  # claim that re-checks itself. gh reads pull request 7 out of both of these,
  # so a reader who took "follow gh" as the rule would loosen the separator
  # class to `.*` and strip userinfo, and only this case would object.
  #
  # First: a suffix has to start with a separator, so `7files` is not pull
  # request 7 with a suffix, it is an unrecognized shape. Second: userinfo
  # stays on the compared authority, where gh's `u.Hostname()` drops it.
  [ "$(resolve 'https://github.com/acme/widgets/pull/7files')" = "decline" ]
  [ "$(resolve 'https://user@github.com/acme/widgets/pull/7')" = "decline" ]
}

@test "h13: the default port resolves, as gh's own Hostname() drops it" {
  [ "$(resolve 'https://github.com:443/acme/widgets/pull/7')" = "7" ]
}

@test "h14: a port does not widen the host comparison" {
  [ "$(resolve 'https://ghe.example.com:443/acme/widgets/pull/7')" = "decline" ]
}

@test "h15: a bracketed IPv6 authority keeps its brackets" {
  # The port strip cuts at a colon followed by digits, so it reaches the port
  # in the second spelling and none of the address's own colons in the first.
  # A strip written to cut at the LAST colon regardless would leave `[:` here
  # and decline a URL naming the home host outright.
  export FAKE_GH_HOME_HOST="[::1]"
  [ "$(resolve 'https://[::1]/acme/widgets/pull/7')" = "7" ]
  [ "$(resolve 'https://[::1]:443/acme/widgets/pull/7')" = "7" ]
}

@test "h16: a non-URL reference declines" {
  # The consumers gate this function behind a `*://*` arm, so a number or a
  # branch never reaches it there. It answers for itself anyway: a function
  # whose whole job is a boundary must not depend on its caller's arm to
  # refuse a value it cannot read.
  [ "$(resolve '7')" = "decline" ]
  [ "$(resolve 'some-branch')" = "decline" ]
  [ "$(resolve '')" = "decline" ]
}

@test "h17: a URL naming no pull request declines" {
  [ "$(resolve 'https://github.com/acme/widgets')" = "decline" ]
  [ "$(resolve 'https://github.com/acme/widgets/issues/7')" = "decline" ]
  [ "$(resolve 'https://github.com/acme/widgets/pull/')" = "decline" ]
}

@test "h18: an unresolvable home declines rather than reading the URL" {
  # Fail direction, and the same one the sibling entry point takes: an acting
  # consumer that cannot identify its own repository must not act.
  #
  # The behavior has two independent causes, and this pins the behavior rather
  # than either one: the early return, and the fact that an unresolved home
  # leaves both globals empty, which no authority or slug the URL can carry
  # compares equal to. Deleting the early return alone therefore leaves this
  # green, so read it as a claim about the answer and not about the line.
  export FAKE_GH_REPO_VIEW_EXIT=1
  [ "$(resolve 'https://github.com/acme/widgets/pull/7')" = "decline" ]
}

@test "h20: only http and https are read as a URL" {
  # gh reads no other scheme as a URL: it falls through to the branch lookup
  # and resolves nothing. A general scheme class here would hand a number back
  # for a reference gh never resolved, which is an accept where gh declines,
  # the one direction this function cannot diverge in. The `http` and mixed-
  # case rows are the control: narrowing the scheme must not cost a spelling
  # gh does merge, and a URL scheme is case-insensitive.
  [ "$(resolve 'ftp://github.com/acme/widgets/pull/7')" = "decline" ]
  [ "$(resolve 'ssh://github.com/acme/widgets/pull/7')" = "decline" ]
  [ "$(resolve 'httpx://github.com/acme/widgets/pull/7')" = "decline" ]
  [ "$(resolve 'http://github.com/acme/widgets/pull/7')" = "7" ]
  [ "$(resolve 'HTTPS://github.com/acme/widgets/pull/7')" = "7" ]
}

@test "h19: a decline leaves no number behind for a caller to read" {
  # The consumers read the global only after a zero return, but a stale value
  # surviving a decline is one `||` typo away from a post onto whatever the
  # previous question resolved.
  run bash -c '
    cd "'"$REPO"'" || exit 1
    set -u
    . "'"$LIB_ABS"'"
    gaia_gh_merge_ref_to_home_pr "https://github.com/acme/widgets/pull/7" || true
    gaia_gh_merge_ref_to_home_pr "https://github.com/other-org/other-repo/pull/9" || true
    printf "[%s]" "$GAIA_HOME_PR_NUMBER"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
