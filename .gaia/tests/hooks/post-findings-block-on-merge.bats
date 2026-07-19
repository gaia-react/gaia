#!/usr/bin/env bats

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
# post-findings-block.sh, repo-scope.sh), and a fake `gh` on PATH that
# answers the hook's own PR lookups plus the producer's comment-post/patch
# calls, tracking state in files under $FAKE_GH_STATE so a test can assert
# on how many times each verb fired and what body was posted.
#
# No .gaia/VERSION is seeded, so resolve-audit-base.sh takes its documented
# "no usable ancestor" path and returns the `main` ref immediately, with zero
# extra gh calls; BASE_SHA is then the merge-base of `main` and the feature
# branch under test, i.e. the sandbox's own init commit.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/post-findings-block-on-merge.sh
  SETTINGS_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude" && pwd)/settings.json
  CI_CONFIG_RESOLVER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/read-audit-ci-config.sh
  BASE_RESOLVER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.github/audit" && pwd)/resolve-audit-base.sh
  PRODUCER_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/post-findings-block.sh
  REPO_SCOPE_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh
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
  cp "$REPO_SCOPE_ABS" "$REPO/.claude/hooks/lib/repo-scope.sh"
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
    printf '%s\n' "${FAKE_GH_REPO:-acme/repo}"
    exit 0
    ;;
  pr)
    shift; shift  # drop "pr" "view"
    json_field=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json_field="$2"; shift 2 ;;
        --jq) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$json_field" in
      isCrossRepository) printf '%s\n' "${FAKE_GH_IS_FORK:-false}" ;;
      author) printf '%s\n' "${FAKE_GH_AUTHOR:-alice}" ;;
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
        body_path=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -f)
              case "$2" in
                body=@*) body_path="${2#body=@}" ;;
              esac
              shift 2
              ;;
            *) shift ;;
          esac
        done
        [ -n "$body_path" ] && cp "$body_path" "$STATE/comment_body"
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
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

write_sidecar() {
  printf '{"schema":1,"member":"code-audit-frontend","findings":[{"finding_class":"holistic/swallowed-error","severity":"warning","area_tags":["app/services"]}]}\n' \
    > "$REPO/.gaia/local/audit/${BASE_SHA}.code-audit-frontend.findings.json"
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
