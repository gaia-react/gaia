#!/usr/bin/env bats

# The /update-deps nudge folds the cached security count in beside the
# outdated count. Null (no advisory source answered) and an absent count never
# render a security term, and a zero count never claims "0 security".
#
# Fixture mirrors nudge-width-tiers.bats: a MAIN git checkout with setup
# marked complete and a cache holding only the update-deps fields.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-sec-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared"
  cp "$STATUSLINE_SOURCE/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"
  TEMPORARY_HOME=$(mktemp -d -t gaia-sl-sec-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

write_cache() {
  printf '%s' "$1" > "$MAIN/.gaia/local/cache/shared/update-check.json"
}

render_at() {
  local columns="$1"
  local json
  json=$(jq -n --arg current_directory "$MAIN" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TEMPORARY_HOME" COLUMNS="$columns" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

@test "UAT-001: outdated and security both render at Large" {
  write_cache '{"outdatedCount":3,"securityCount":2,"securitySource":"dependabot","securityUnavailableReason":""}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated, 2 security)") ;;
    *) return 1 ;;
  esac
}

@test "UAT-002: security alone renders without an outdated term" {
  write_cache '{"outdatedCount":0,"securityCount":2,"securitySource":"pnpm-audit","securityUnavailableReason":"forbidden"}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (2 security)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "outdated" <<<"$plain" && return 1
  true
}

@test "UAT-003: outdated alone renders without a security term" {
  write_cache '{"outdatedCount":3,"securityCount":0,"securitySource":"dependabot","securityUnavailableReason":""}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "security" <<<"$plain" && return 1
  true
}

@test "UAT-004: zero or unavailable security with no outdated renders no nudge at any tier" {
  local cache width
  for cache in \
    '{"outdatedCount":0,"securityCount":0,"securitySource":"dependabot","securityUnavailableReason":""}' \
    '{"outdatedCount":0,"securityCount":null,"securitySource":"unavailable","securityUnavailableReason":"forbidden"}'; do
    write_cache "$cache"
    for width in 200 60 30 16; do
      render_at "$width"
      [ "$status" -eq 0 ]
      grep -qF -- "/update-deps" <<<"$output" && return 1
      grep -qF -- "0 security" <<<"$output" && return 1
      grep -qF -- "📦" <<<"$output" && return 1
    done
  done
  true
}

@test "TST-004: a null security count beside outdated renders only the outdated form" {
  write_cache '{"outdatedCount":3,"securityCount":null,"securitySource":"unavailable","securityUnavailableReason":"cli-failed"}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "null" <<<"$plain" && return 1
  true
}

@test "a cache with no security fields renders the outdated form" {
  write_cache '{"outdatedCount":3}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated)") ;;
    *) return 1 ;;
  esac
}

@test "a non-numeric security count is treated as absent" {
  write_cache '{"outdatedCount":3,"securityCount":"two","securitySource":"dependabot"}'
  render_at 200
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated)") ;;
    *) return 1 ;;
  esac
}
