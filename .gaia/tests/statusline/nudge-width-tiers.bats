#!/usr/bin/env bats

# The statusline's right side is a task queue that fits itself to COLUMNS: it
# drops reasons first, then collapses the lowest-priority nudges to an
# icon+count, then falls back to a `+N` for whatever still does not fit. This
# suite pins the four tiers and the priority order (update-gaia, serena-sync,
# update-deps, audit, harden, debt, residue) against exact widths, so a
# regression in the arithmetic reds here rather than silently shifting a tier
# boundary.
#
# Fixture mirrors segment-command-uniqueness.bats: a MAIN git checkout with
# setup marked complete, HOME pointing at an empty dir (left resolves to the
# "Claude Code" fallback, 11 columns), and a cache that arms every right-side
# nudge at once.

setup() {
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-tiers-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/local/cache/shared"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  cat > "$MAIN/.gaia/local/cache/shared/update-check.json" <<'JSON'
{
  "gaiaHasUpdate": true,
  "gaiaLatest": "9.9.9",
  "outdatedCount": 3,
  "hardenCandidateCount": 2,
  "hardenUnclassifiedCount": 1,
  "residueCandidateCount": 5,
  "auditNudge": true,
  "auditNudgeReason": "stale",
  "serenaLangDrift": ["go"]
}
JSON
  mkdir -p "$MAIN/.gaia/local/debt"
  printf '{"openCount":4}' > "$MAIN/.gaia/local/debt/count.json"

  TMP_HOME=$(mktemp -d -t gaia-sl-tiers-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# Renders at the given COLUMNS. Sets $output/$status (bats `run` convention)
# and $plain (the same output with ANSI color codes stripped).
render_at() {
  local cols="$1"
  local json
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" COLUMNS="$cols" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
}

@test "full tier renders every segment with its reason, in priority order" {
  render_at 274
  [ "$status" -eq 0 ]
  expected="Claude Code  Run /update-gaia (GAIA 9.9.9 available)  Run /gaia-serena-sync (Serena missing: go)  Run /update-deps (3 outdated)  Run /gaia-audit (stale)  Run /gaia-harden (2 recurring patterns, 1 unclassified)  Run /gaia-debt (4 issues)  Run /gaia-residue (5 aged residuals)"
  [ "$plain" = "$expected" ]
}

@test "priority order holds at the full tier" {
  render_at 400
  [ "$status" -eq 0 ]
  order=$(grep -oE 'Run /[a-z][a-z0-9-]*' <<<"$plain")
  expected=$(printf '%s\n' \
    "Run /update-gaia" \
    "Run /gaia-serena-sync" \
    "Run /update-deps" \
    "Run /gaia-audit" \
    "Run /gaia-harden" \
    "Run /gaia-debt" \
    "Run /gaia-residue")
  [ "$order" = "$expected" ]
}

@test "a two-line left sizes the right side against the last line's width" {
  mkdir -p "$TMP_HOME/.claude"
  cat > "$TMP_HOME/.claude/settings.json" <<'JSON'
{"statusLine": {"command": "printf 'line one\\n%s' \"$(printf '%052d' 0 | tr 0 x)\""}}
JSON
  local json last_line_x
  last_line_x=$(printf '%052d' 0 | tr 0 x)
  json=$(jq -n --arg d "$MAIN" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')

  # A measurement of the first line (8) or the old digit guard's 0, instead
  # of the last (joined) line's 52, both leave enough avail at 315 for the
  # full tier too, so a wrong measurement is not observable there on its own;
  # the exact pad (2, only correct at 52) is what tells them apart.
  run env HOME="$TMP_HOME" COLUMNS=315 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  last_line="${plain##*$'\n'}"
  expected_right="Run /update-gaia (GAIA 9.9.9 available)  Run /gaia-serena-sync (Serena missing: go)  Run /update-deps (3 outdated)  Run /gaia-audit (stale)  Run /gaia-harden (2 recurring patterns, 1 unclassified)  Run /gaia-debt (4 issues)  Run /gaia-residue (5 aged residuals)"
  [ "$last_line" = "${last_line_x}  ${expected_right}" ]

  # At 314 a 52-column measurement leaves avail 260, one below the full
  # tier's 261, so it drops to the short tier (no reason parens); a
  # first-line or zeroed measurement leaves enough avail for the full tier
  # to still fit, which is the observable difference this case pins.
  run env HOME="$TMP_HOME" COLUMNS=314 bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  last_line="${plain##*$'\n'}"
  grep -qF -- "(" <<<"$last_line" && return 1
  true
}

@test "short tier drops every parenthetical reason when the full tier does not fit" {
  render_at 273
  [ "$status" -eq 0 ]
  short_right="Run /update-gaia  Run /gaia-serena-sync  Run /update-deps  Run /gaia-audit  Run /gaia-harden  Run /gaia-debt  Run /gaia-residue"
  case "$plain" in
    *"$short_right") ;;
    *) return 1 ;;
  esac
  grep -qF -- "(" <<<"$plain" && return 1

  render_at 140
  [ "$status" -eq 0 ]
  case "$plain" in
    *"$short_right") ;;
    *) return 1 ;;
  esac
}

@test "icon tier keeps the highest-priority segments as text and collapses the lowest first" {
  render_at 139
  [ "$status" -eq 0 ]
  right="Run /update-gaia  Run /gaia-serena-sync  Run /update-deps  Run /gaia-audit  Run /gaia-harden  Run /gaia-debt  🧹5"
  case "$plain" in
    *"$right") ;;
    *) return 1 ;;
  esac

  render_at 60
  [ "$status" -eq 0 ]
  right="Run /update-gaia  🔭 📦3 🔎 🔨 💸4 🧹5"
  case "$plain" in
    *"$right") ;;
    *) return 1 ;;
  esac
}

@test "the icon-collapse boundary is exact: 126 keeps six segments as text, 125 drops to five" {
  render_at 126
  [ "$status" -eq 0 ]
  expected="Claude Code  Run /update-gaia  Run /gaia-serena-sync  Run /update-deps  Run /gaia-audit  Run /gaia-harden  Run /gaia-debt  🧹5"
  [ "$plain" = "$expected" ]

  render_at 125
  [ "$status" -eq 0 ]
  right="Run /gaia-harden  💸4 🧹5"
  case "$plain" in
    *"$right") ;;
    *) return 1 ;;
  esac
}

@test "each icon is counted as exactly two columns" {
  render_at 36
  [ "$status" -eq 0 ]
  expected="Claude Code  🌍 🔭 📦3 🔎 🔨 💸4 🧹5"
  [ "$plain" = "$expected" ]

  render_at 35
  [ "$status" -eq 0 ]
  expected="Claude Code  🌍 🔭 📦3 🔎 🔨 💸4 +1"
  [ "$plain" = "$expected" ]

  render_at 40
  [ "$status" -eq 0 ]
  expected="Claude Code      🌍 🔭 📦3 🔎 🔨 💸4 🧹5"
  [ "$plain" = "$expected" ]
}

@test "+N names exactly how many segments are hidden, and never vanishes" {
  render_at 20
  [ "$status" -eq 0 ]
  case "$plain" in
    *"🌍 +6") ;;
    *) return 1 ;;
  esac

  render_at 5
  [ "$status" -eq 0 ]
  [ -n "$plain" ]
  case "$plain" in
    *"+7") ;;
    *) return 1 ;;
  esac
  grep -qF -- "gaia-status" <<<"$plain" && return 1
  true
}

@test "text forms keep their segment color and icons render uncolored" {
  render_at 139
  [ "$status" -eq 0 ]
  grep -qF -- $'\033[01;34mRun /gaia-debt\033[00m' <<<"$output"
  grep -qF -- $'\033[01;36mRun /update-gaia\033[00m' <<<"$output"

  render_at 36
  [ "$status" -eq 0 ]
  after_left="${output#*Claude Code}"
  grep -qF -- $'\033' <<<"$after_left" && return 1
  true
}

@test "the setup-gaia nudge renders alone and never collapses" {
  rm -f "$MAIN/.gaia/local/setup-state.json"
  render_at 20
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /setup-gaia (Required)") ;;
    *) return 1 ;;
  esac
  grep -qF -- "🌍" <<<"$plain" && return 1
  grep -qF -- "🔭" <<<"$plain" && return 1
  grep -qF -- "+" <<<"$plain" && return 1
  true
}

@test "a lone segment degrades through all four tiers" {
  printf '{"outdatedCount":3}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  rm -f "$MAIN/.gaia/local/debt/count.json"

  render_at 42
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps (3 outdated)") ;;
    *) return 1 ;;
  esac

  render_at 41
  [ "$status" -eq 0 ]
  case "$plain" in
    *"Run /update-deps") ;;
    *) return 1 ;;
  esac
  grep -qF -- "(" <<<"$plain" && return 1

  render_at 28
  [ "$status" -eq 0 ]
  case "$plain" in
    *"📦3") ;;
    *) return 1 ;;
  esac
  grep -qF -- "Run /" <<<"$plain" && return 1

  render_at 15
  [ "$status" -eq 0 ]
  case "$plain" in
    *"+1") ;;
    *) return 1 ;;
  esac
  grep -qF -- "📦" <<<"$plain" && return 1
  true
}
