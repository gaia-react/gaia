#!/usr/bin/env bats
# Every test exports its own fixture into the subshell bats creates for it,
# which is the isolation this suite wants: the value must not leak to the next
# test, and the hook runs as a child of that same subshell, so it does see it.
# shellcheck disable=SC2030,SC2031
#
# Tests for .claude/hooks/post-findings-block-on-merge.sh.
#
# The hook is the deterministic caller for post-findings-block.sh: under
# local audit mode, no code path posted the machine-readable findings block
# before this hook existed, only a hand-run snippet did. It fires on a real
# `gh pr merge` invocation and, when the resolved audit mode is `local`,
# resolves the incremental audit base and calls the existing producer. It
# never blocks the merge and never emits a permission decision; success or
# failure of the underlying producer is invisible to the merge itself.
#
# Setup drives the REAL hook (by absolute path, never copied) against a
# sandbox git repo carrying real copies of the scripts it calls by
# repo-relative path (read-audit-ci-config.sh, resolve-audit-base.sh,
# post-findings-block.sh, audit-key-lib.sh, repo-scope.sh), and a fake `gh`
# on PATH that
# answers the hook's own PR lookups plus the producer's comment-post/patch
# calls, tracking state in files under $FAKE_GH_STATE so a test can assert
# on how many times each verb fired and what body was posted.
#
# No .gaia/VERSION is seeded, so resolve-audit-base.sh takes its documented
# "no usable ancestor" path and returns the `main` ref immediately, with zero
# extra gh calls; BASE_SHA is then the merge-base of `main` and the feature
# branch under test, i.e. the sandbox's own init commit.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/post-findings-block-on-merge.sh
  SETTINGS_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude" && pwd)/settings.json
  CI_CONFIG_RESOLVER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/read-audit-ci-config.sh
  BASE_RESOLVER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.github/audit" && pwd)/resolve-audit-base.sh
  PRODUCER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/post-findings-block.sh
  KEY_LIB_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/audit-key-lib.sh
  REPO_SCOPE_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh
  VERB_ARMING_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/verb-arming.sh
  VERB_ARMING_WALK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/verb-arming-walk.sh
  REPO=$(mktemp -d -t post-findings-merge-test-XXXXXX)

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

  git -C "$REPO" checkout --quiet -b feature
  echo "change" >> "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "feature change"

  mkdir -p "$REPO/.gaia/scripts" "$REPO/.github/audit" "$REPO/.claude/hooks/lib" "$REPO/.gaia/local/audit"
  cp "$CI_CONFIG_RESOLVER_ABS" "$REPO/.gaia/scripts/read-audit-ci-config.sh"
  cp "$BASE_RESOLVER_ABS" "$REPO/.github/audit/resolve-audit-base.sh"
  cp "$PRODUCER_ABS" "$REPO/.gaia/scripts/post-findings-block.sh"
  cp "$KEY_LIB_ABS" "$REPO/.gaia/scripts/audit-key-lib.sh"
  cp "$REPO_SCOPE_ABS" "$REPO/.claude/hooks/lib/repo-scope.sh"
  cp "$VERB_ARMING_ABS" "$REPO/.claude/hooks/lib/verb-arming.sh"
  cp "$VERB_ARMING_WALK_ABS" "$REPO/.claude/hooks/lib/verb-arming-walk.sh"
  chmod +x "$REPO/.gaia/scripts/read-audit-ci-config.sh" \
    "$REPO/.github/audit/resolve-audit-base.sh" \
    "$REPO/.gaia/scripts/post-findings-block.sh"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  FAKE_GH_STATE="$BATS_TEST_TMPDIR/gh-state"
  mkdir -p "$FAKE_GH_STATE"
  : > "$FAKE_GH_STATE/comment_id"
  : > "$FAKE_GH_STATE/post_count"
  : > "$FAKE_GH_STATE/patch_count"
  : > "$FAKE_GH_STATE/comment_body"
  : > "$FAKE_GH_STATE/comment_pr"
  write_gh_stub
  export PATH="$GH_BIN:$PATH"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Write a fake `gh` that answers exactly the calls this hook and
# post-findings-block.sh make: PR lookups (isCrossRepository, author),
# `gh auth status`, `gh repo view`, and the comment list/POST/PATCH trio.
# State (posted body, call counts) lives under $FAKE_GH_STATE so a test can
# assert on it after run_merge_hook.
write_gh_stub() {
  cat > "$GH_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
STATE="$FAKE_GH_STATE"

case "$1" in
  auth)
    exit "${FAKE_GH_AUTH_EXIT:-0}"
    ;;
  repo)
    # gh identifies a repository as [HOST/]OWNER/REPO, and repo-scope's
    # act-on-home entry point reads the slug and the URL's authority from this
    # one call, so the stub answers both fields as JSON.
    jq -n --arg n "${FAKE_GH_REPO:-acme/repo}" \
      --arg u "https://${FAKE_GH_HOST:-github.com}/${FAKE_GH_REPO:-acme/repo}" \
      '{nameWithOwner: $n, url: $u}'
    exit 0
    ;;
  pr)
    shift; shift  # drop "pr" "view"
    json_field=""
    selector=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json_field="$2"; shift 2 ;;
        --jq) shift 2 ;;
        # The first non-flag word is the selector. Whether one is present is
        # the whole discriminator between "gh resolved the reference the merge
        # named" and "gh fell back to the current branch", and a stub blind to
        # it answers both from one variable, which greens a caller that reaches
        # the wrong arm.
        -*) shift ;;
        *) [ -n "$selector" ] || selector="$1"; shift ;;
      esac
    done
    case "$json_field" in
      isCrossRepository) printf '%s\n' "${FAKE_GH_IS_FORK:-false}" ;;
      author) printf '%s\n' "${FAKE_GH_AUTHOR:-alice}" ;;
      # `--json number` with no selector is the current-branch default; with a
      # selector it is gh resolving a URL or a branch name against the
      # repository that selector names. The two answer from different variables
      # so a test can tell which arm the hook reached.
      number)
        if [ -n "$selector" ]; then
          printf '%s\n' "${FAKE_GH_RESOLVED_PR:-}"
        else
          printf '%s\n' "${FAKE_GH_BRANCH_PR:-}"
        fi
        ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
  api)
    shift
    method="GET"
    if [ "$1" = "--method" ]; then method="$2"; shift 2; fi
    endpoint="$1"; shift
    case "$method" in
      GET)
        case "$endpoint" in
          repos/*/issues/*/comments)
            [ -s "$STATE/comment_id" ] && cat "$STATE/comment_id"
            ;;
        esac
        exit 0
        ;;
      POST|PATCH)
        # Real `gh api` expands `@<path>` for `-F/--field` only; `-f/--raw-field`
        # sends the value as the literal string it is (`gh api --help`). Both
        # answer 200, so a stub blind to the difference greens a caller that
        # posts the temp path instead of the block.
        body_path=""
        body_literal=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -F|--field)
              case "$2" in
                body=@*) body_path="${2#body=@}" ;;
              esac
              shift 2
              ;;
            -f|--raw-field)
              case "$2" in
                body=*) body_literal="${2#body=}" ;;
              esac
              shift 2
              ;;
            *) shift ;;
          esac
        done
        [ -n "$body_path" ] && cp "$body_path" "$STATE/comment_body"
        [ -n "$body_literal" ] && printf '%s' "$body_literal" > "$STATE/comment_body"
        # Record WHICH pull request the block landed on. The body alone cannot
        # answer that, and posting a correct block onto the wrong pull request
        # is the failure the reference resolution above exists to prevent.
        case "$endpoint" in
          repos/*/issues/*/comments)
            ep_pr="${endpoint#*/issues/}"
            printf '%s' "${ep_pr%%/*}" > "$STATE/comment_pr"
            ;;
        esac
        if [ "$method" = "POST" ]; then
          echo 1000 > "$STATE/comment_id"
          c=$(( $(cat "$STATE/post_count" 2>/dev/null || echo 0) + 1 ))
          echo "$c" > "$STATE/post_count"
        else
          c=$(( $(cat "$STATE/patch_count" 2>/dev/null || echo 0) + 1 ))
          echo "$c" > "$STATE/patch_count"
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$GH_BIN/gh"
}

# Run the hook with a `gh pr merge` (or other) command and tool_name, from
# inside the repo, exactly as the harness invokes a PreToolUse hook.
run_merge_hook() {
  local cmd="${1:-gh pr merge 42 --squash --delete-branch}"
  local tool="${2:-Bash}"
  local json
  json=$(jq -n --arg c "$cmd" --arg t "$tool" '{tool_name: $t, tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}

write_sidecar() {
  # Keyed to base-sha + branch slug (gaia_audit_key, audit-key-lib.sh); the
  # sandbox's acting branch is "feature" (checked out in setup()), so the
  # slug is that name verbatim -- nothing in it needs percent-encoding.
  printf '{"schema":1,"member":"code-audit-frontend","findings":[{"finding_class":"holistic/swallowed-error","severity":"warning","area_tags":["app/services"]}]}\n' \
    > "$REPO/.gaia/local/audit/${BASE_SHA}.feature.code-audit-frontend.findings.json"
}

@test "UAT-005: a registered gh pr merge posts one non-empty findings block with auditor local" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ ! -s "$FAKE_GH_STATE/patch_count" ]

  body="$(cat "$FAKE_GH_STATE/comment_body")"
  grep -qF -- '<!-- gaia-harden:findings:start -->' <<<"$body" || return 1
  grep -qF -- '"auditor":"local"' <<<"$body" || return 1
  grep -qF -- 'holistic/swallowed-error' <<<"$body" || return 1
}

@test "UAT-005: a second invocation UPDATES the single comment rather than duplicating it" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]

  run_merge_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/patch_count")" = "1" ]
}

@test "wiring: settings.json registers the hook and the hook calls post-findings-block.sh" {
  run grep -q "post-findings-block-on-merge.sh" "$SETTINGS_ABS"
  [ "$status" -eq 0 ]

  run grep -q "post-findings-block.sh" "$HOOK_ABS"
  [ "$status" -eq 0 ]
}

@test "CI-mode guard: a fork PR resolves to ci and the hook posts nothing" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="true" FAKE_GH_AUTHOR="alice"

  run_merge_hook
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
  [ ! -s "$FAKE_GH_STATE/comment_id" ]
}

@test "ignores commands that are not gh pr merge" {
  write_sidecar
  export FAKE_GH_STATE
  run_merge_hook "git status"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "ignores a gh pr merge aimed at a foreign repo" {
  write_sidecar
  export FAKE_GH_STATE
  run_merge_hook "gh pr merge 42 -R other-org/other-repo --squash"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "ignores a non-Bash tool_name payload" {
  write_sidecar
  export FAKE_GH_STATE
  run_merge_hook "gh pr merge 42" "Read"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "no sidecars: the hook runs but posts nothing, and still exits 0" {
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  run_merge_hook
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "settings.json remains valid JSON" {
  run jq . "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

# The sandbox toplevel is a mktemp directory, and the home repo gh reports is
# `acme/repo`, so the two are deliberately unrelated. That is what makes the
# next fixture decisive: `-R other-org/<toplevel-basename>` is the value the
# repo-NAME comparison calls home and the whole-slug comparison calls foreign.
# This hook ACTS on the home repo, so calling it home posts a findings block
# onto THIS repository's pull request of that number.
@test "a same-named sibling repo posts nothing" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook "gh pr merge 42 -R other-org/$(basename "$REPO") --squash"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "a -R attached to a same-named sibling posts nothing" {
  # gh accepts `-R` attached to its value, a spelling the shared capture
  # misses; missing it here means posting to the wrong repository's pull
  # request rather than merely over-enforcing.
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook "gh pr merge 42 -Rother-org/$(basename "$REPO")"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "a --repo naming the home repo still posts" {
  # The boundary's other direction: tightening it must not cost the posting it
  # exists to let through.
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook "gh pr merge 42 --repo acme/repo --squash"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

@test "a --repo naming the home repo in another case still posts" {
  # GitHub resolves OWNER/REPO case-insensitively, so this lands on the home
  # repository and a case-sensitive comparison would cost the posting.
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook "gh pr merge 42 --repo ACME/Repo --squash"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

# The lib is resolved from the hook's own location rather than from cwd. Run
# from a subdirectory, a cwd-relative source misses, which left the boundary
# function undefined; the old `type f && f` guard then fell THROUGH to posting.
# The two defects composed into no boundary check at all, so this fixture fails
# on either half alone.
@test "from a non-root cwd, a foreign merge still posts nothing" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  mkdir -p "$REPO/sub/dir"
  local json
  json=$(jq -n --arg c "gh pr merge 42 -R other-org/other-repo --squash" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO/sub/dir" "$json" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

# The reference the merge names comes from the shared first-command scan, not
# from a pattern over the raw command text. These three pin the rows a pattern
# gets wrong, and each asserts WHICH pull request the block landed on, because
# a correct block posted onto the wrong pull request is indistinguishable from
# a correct post by every other assertion in this file.
@test "the merge's own reference decides, even when its flags come first" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  # A pattern anchored to a number right after the verb misses this spelling
  # entirely and falls back to the current branch's pull request.
  export FAKE_GH_BRANCH_PR="99"

  run_merge_hook "gh pr merge --squash 42"
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "42" ]
}

@test "a later command's own merge reference does not decide this one" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  # A regex takes its first match anywhere in the string, so with this merge
  # spelling its flags first the only text it matches is the trailing mention
  # of another pull request, and the block lands over there.
  run_merge_hook 'gh pr merge --squash 42 && echo "see gh pr merge 1520"'
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "42" ]
}

@test "a merge naming no reference falls back to the current branch's PR" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_BRANCH_PR="77"

  run_merge_hook "gh pr merge --squash"
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "77" ]
}

# gh resolves a URL against the repository the URL names, and a branch name
# against whatever pull request that branch has. Neither is necessarily this
# repository's, while the block always posts here, so the reference arms carry
# their own boundary and their own fail direction. `issue-claim-release.sh`
# already answers both for the identical scanned value.
@test "a foreign repository's pull-request URL posts nothing" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo"
  # gh would resolve this URL against other-org/other-repo and hand back THAT
  # repository's number, which the post would then apply to this one.
  export FAKE_GH_RESOLVED_PR="7"

  run_merge_hook "gh pr merge https://github.com/other-org/other-repo/pull/7"
  [ "$status" -eq 0 ]

  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "a pull-request URL naming the home repository still posts, reduced to its number" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo"

  run_merge_hook "gh pr merge https://github.com/acme/repo/pull/7"
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "7" ]
}

@test "a named reference gh cannot resolve declines rather than falling back" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  # The merge named a branch; gh resolves no pull request for it (a typo, one
  # not opened yet, a transient failure). The current branch's pull request is
  # a DIFFERENT one, so falling back to it acts on something the merge never
  # named, and PATCHes over whatever block already sits there.
  export FAKE_GH_RESOLVED_PR=""
  export FAKE_GH_BRANCH_PR="99"

  run_merge_hook "gh pr merge some-other-branch"
  [ "$status" -eq 0 ]

  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "a pull-request URL on another host posts nothing, even naming the home slug" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo" FAKE_GH_HOST="github.com"

  # The same OWNER/REPO served from another host is another repository, which a
  # slug-only comparison accepts.
  run_merge_hook "gh pr merge https://ghe.example.com/acme/repo/pull/7"
  [ "$status" -eq 0 ]

  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

# gh's own URL matcher is unanchored after the number and its host comparison
# drops a port, so each of the next two merges home pull request 7 while a
# tighter matcher declines and the merge contributes nothing to the
# finding-recurrence tally. The shape rules live in the lib and
# `repo-scope-home-pr.bats` covers them exhaustively; these pin that THIS hook
# reaches them, which is the half a lib-only suite cannot see.
@test "a home pull-request URL carrying a /files suffix still posts" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo"

  # The spelling a human actually produces, by copying the address bar off the
  # Files tab.
  run_merge_hook "gh pr merge https://github.com/acme/repo/pull/7/files"
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "7" ]
}

@test "a home pull-request URL carrying the default port still posts" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo"

  run_merge_hook "gh pr merge https://github.com:443/acme/repo/pull/7"
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
  [ "$(cat "$FAKE_GH_STATE/comment_pr")" = "7" ]
}

@test "a suffix does not carry a foreign pull-request URL past the boundary" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  export FAKE_GH_REPO="acme/repo"

  # The relaxation is to the shape, never to the repository comparison.
  run_merge_hook "gh pr merge https://github.com/other-org/other-repo/pull/7/files"
  [ "$status" -eq 0 ]

  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

# ---------- Shared arming decision (data proof, bound, tokenizer) ----------

@test "a heredoc body carrying the verb produces no post, and the same text without the heredoc does" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\ngh pr merge 42\nEOF'
  run_merge_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]

  run_merge_hook "gh pr merge 42"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

# The generic past-bound pairing (case 2's heredoc, padded past
# GAIA_VERB_ARM_MAX_CHARS, arms because the walker abstains above the bound)
# cannot discriminate through THIS hook's observable side effect: the
# opener's command word is necessarily `cat`/`tee`, never `gh`, so
# repo-scope's act-on-home boundary (which requires the merge to BE the tool
# call's first command) declines here regardless of arming or masking, above
# the bound or below it. The bound's effect on arming is proven once, at the
# library level, in verb-arming-lib.bats ("a payload at the bound is
# suppressed and the same payload past it is not"); this pins that the
# boundary decline still holds past the bound, so a bigger heredoc never
# becomes a spurious post for the wrong reason.
@test "the same heredoc-body payload padded past the arming bound still posts nothing (boundary, not masking)" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  local pad heredoc_cmd
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge 42\nEOF'
  [ "${#heredoc_cmd}" -gt 16384 ] || return 1

  run_merge_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GH_STATE/post_count" ]
}

@test "a quoted verb in the first command produces the post (tokenizer arm)" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook 'gh pr "merge" 42'
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

# The merge stays first, with a trailing statement after it: this hook's own
# boundary check (repo-scope's act-on-home entry point) requires the merge to
# BE the tool call's first command, so a leading `<something> &&` before the
# merge declines regardless of arming, unchanged by this work. This is the
# multi-statement shape that already worked and must keep working.
@test "a trailing statement after the merge does not cost the post" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"

  run_merge_hook "gh pr merge 42 --squash && echo done"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

# ---------- library-load degradation (gaia-react/gaia#1556) ----------
# Two ways a library goes unusable, and this hook's contract ("never blocks the
# merge, never emits a permission decision") must hold through both: it is
# gone, and it is present but does not parse (an unresolved merge conflict, a
# truncated write). Under `set -e` a failed `.` abandons the shell ahead of the
# ERR trap in both cases, at different cost: a file bash cannot open exits 1,
# an advisory, while one it cannot parse exits 2 -- the PreToolUse DENY code,
# which refuses the very merge this hook promises never to block.
#
# The two loads sit on opposite sides of the arming gate and take different
# repairs, so each gets its own case. repo-scope.sh is past the gate and
# parse-checks; verb-arming.sh runs before the gate knows the call is a merge
# at all, so it takes the free `|| true` arm, closing the bash 5 half only.
#
# These run a COPY of the hook staged inside the sandbox: both loads resolve
# off the hook's own BASH_SOURCE, so $HOOK_ABS would always reach the real
# checkout's libs, where neither case can be expressed.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

stage_merge_hook() {
  STAGED_HOOK="$REPO/.claude/hooks/post-findings-block-on-merge.sh"
  cp "$HOOK_ABS" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

run_staged_merge_hook() {
  local json
  json=$(jq -n --arg c "gh pr merge 42 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$STAGED_HOOK"
}

# The control that gives the two cases teeth: their assertions (exit 0, no
# deny) are equally satisfied by a hook that does nothing at all, so the same
# staging has to be shown posting normally first.
@test "staged hook, every lib usable: posts the findings block (control)" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  stage_merge_hook

  run_staged_merge_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_GH_STATE/post_count")" = "1" ]
}

# Unpinned on purpose: the form each load replaced was a bare `.` behind an
# `-f` test, carrying no arm at all, so both die on bash 5 as well as 3.2 and
# these cases have teeth on Linux CI. Asserting a non-2 status is the point:
# exit 2 is what a PreToolUse hook means by "deny", and this hook has no deny
# to emit.
@test "repo-scope.sh holds conflict markers: exit 0, the merge is not denied" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  stage_merge_hook
  write_conflicted_lib "$REPO/.claude/hooks/lib/repo-scope.sh"

  run_staged_merge_hook
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision"' <<<"$output" && return 1
  return 0
}

# The pre-gate load, and the widest exposure of the four hooks that share it:
# this one is PreToolUse and the load sits ahead of the arming gate, so an
# unparseable verb-arming.sh denied EVERY Bash tool call rather than merges
# alone. It parse-checks rather than taking the cheap arm for exactly that
# reason, so both halves are closed and both are pinned for below. The 3.2 case
# is the one the arm would have left open, and it would have been left open
# SILENTLY: a PreToolUse exit 2 surfaces stderr as the deny reason, and the
# arm's `2>/dev/null` suppressed the syntax error naming the broken file.
@test "verb-arming.sh holds conflict markers: exit 0, the merge is not denied" {
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  stage_merge_hook
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  run_staged_merge_hook
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision"' <<<"$output" && return 1
  return 0
}

@test "verb-arming.sh holds conflict markers, under stock /bin/bash: exit 0, the merge is not denied" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  write_sidecar
  export FAKE_GH_STATE FAKE_GH_IS_FORK="false" FAKE_GH_AUTHOR="alice"
  stage_merge_hook
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  local json
  json=$(jq -n --arg c "gh pr merge 42 --squash --delete-branch" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'cd "$1" && printf %s "$2" | /bin/bash "$3"' _ "$REPO" "$json" "$STAGED_HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision"' <<<"$output" && return 1
  return 0
}
