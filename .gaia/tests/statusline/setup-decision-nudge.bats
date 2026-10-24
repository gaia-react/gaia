#!/usr/bin/env bats

# The statusline's post-completion setup nudge: once setup is complete, a
# machine-scope setup choice the shipped list holds and this machine has not
# decided arms a `⚙️ /setup-gaia (<N> choice[s] pending)` segment at the
# highest priority. An undecided project-scope id arms it only when this
# machine can act on it (the predicate in setup-owed.sh), the incomplete-setup
# `⚙️ /setup-gaia (Required)` segment is untouched, and a linked worktree
# stays dark because the nudge is a main-checkout task like the rest.
#
# The fixture is a MAIN git checkout holding copies of the statusline and the
# main-root resolver (without the resolver a linked worktree never reads as
# one), a linked worktree off it, and HOME pointing at an empty directory so the
# left side is inert. Decisions are recorded through the real CLI bundle run
# from the fixture checkout, so the file shape the nudge reads is the shape the
# recorder writes.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  # The committed CLI bundle, .gaia/cli/gaia. The change selector matches it by
  # its trailing path, which the built path below does not spell, so this line
  # is what selects the suite when the bundle changes.
  GAIA_COMMAND="$(cd "$BATS_TEST_DIRNAME/../../cli" && pwd)/gaia"

  MAIN=$(mktemp -d -t gaia-sl-setup-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local/cache/shared" "$MAIN/.gaia/local/debt"
  cp "$STATUSLINE_SOURCE/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  cp "$STATUSLINE_SOURCE/gaia-statusline-right.sh" "$MAIN/.gaia/statusline/gaia-statusline-right.sh"
  cp "$STATUSLINE_SOURCE/setup-owed.sh" "$MAIN/.gaia/statusline/setup-owed.sh"
  cp "$SCRIPTS_SOURCE/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  echo "x" > "$MAIN/README.md"
  write_features alpha beta gamma
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"

  write_setup_state '"2026-01-01T00:00:00Z"'

  WORKTREE="${MAIN}-wt"
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature

  TEMPORARY_HOME=$(mktemp -d -t gaia-sl-setup-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# Write the fixture list: alpha and beta are machine scope, gamma is an
# admin-gated project id, and github-repository is the project id anyone can
# act on. Each argument names which to include, in list order.
write_features() {
  local entries="" id scope admin
  for id in "$@"; do
    case "$id" in
      gamma) scope="project" admin="true" ;;
      github-repository) scope="project" admin="false" ;;
      *) scope="machine" admin="false" ;;
    esac
    [ -n "$entries" ] && entries="${entries},"
    entries="${entries}{\"id\":\"${id}\",\"scope\":\"${scope}\",\"required\":false,\"admin\":${admin},\"standalone\":false,\"reference\":\"README.md\"}"
  done
  printf '{"version":1,"description":"Fixture list for the statusline setup nudge.","features":[%s]}\n' "$entries" > "$MAIN/.gaia/setup-features.json"
}

# Write main's setup-state with the given JSON value for completed_at. It
# carries the fields the real recorder requires, so `gaia setup record` accepts
# it.
write_setup_state() {
  printf '{"version":1,"started_at":"2026-01-01T00:00:00Z","completed_at":%s,"completed_steps":[]}\n' "$1" > "$MAIN/.gaia/local/setup-state.json"
}

# Cache this machine's admin answer in main's setup-state, as an ok
# `setup check-admin` probe does.
cache_admin() {
  local state
  state=$(jq --argjson admin "$1" '.admin = $admin' "$MAIN/.gaia/local/setup-state.json")
  printf '%s\n' "$state" > "$MAIN/.gaia/local/setup-state.json"
}

record_decision() {
  (cd "$MAIN" && "$GAIA_COMMAND" setup record "$1" "$2") > /dev/null
}

arm_other_nudges() {
  printf '{"gaiaHasUpdate":true,"gaiaLatest":"9.9.9","outdatedCount":3}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  printf '{"openCount":5}' > "$MAIN/.gaia/local/debt/count.json"
}

status_payload() {
  jq -n --arg current_directory "$1" '{workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}'
}

# Render MAIN's statusline from session directory $1 at width $2, with the
# colors stripped so assertions read plain text. HOME is empty so the left side
# is inert.
render() {
  local json
  json=$(status_payload "$1")
  run env HOME="$TEMPORARY_HOME" COLUMNS="${2:-400}" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh' | sed \$'s/\\x1b\\\\[[0-9;]*m//g'"
}

@test "two pending machine choices nudge, and recording them clears the nudge one by one" {
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  record_decision alpha applied
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (1 choice pending)" <<<"$output"

  record_decision beta applied
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "declined and not-applicable clear the nudge exactly as applied does" {
  render "$MAIN"
  grep -qF -- "(2 choices pending)" <<<"$output"

  record_decision alpha declined
  render "$MAIN"
  grep -qF -- "(1 choice pending)" <<<"$output"

  record_decision beta not-applicable
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "an admin-gated project id never arms the nudge without a cached admin answer" {
  # Positive control: with a machine id pending the slot renders.
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"

  write_features gamma
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "an undecided github-repository arms the nudge with no cached admin answer" {
  write_features github-repository gamma
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (1 choice pending)" <<<"$output"
}

@test "a cached admin counts every undecided project id with the machine ones" {
  write_features alpha github-repository gamma
  cache_admin true
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (3 choices pending)" <<<"$output"
}

@test "a cached non-admin is never nagged about project ids, github-repository included" {
  write_features github-repository gamma
  cache_admin false
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1

  # Positive control: the same machine as an admin is nagged.
  cache_admin true
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"
}

@test "project ids decided in the committed project config stay quiet for an admin" {
  write_features github-repository gamma
  cache_admin true
  printf '{"setup_decisions":{"github-repository":"applied","gamma":"declined"}}\n' > "$MAIN/.gaia/project.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1

  printf '{"setup_decisions":{"github-repository":"applied"}}\n' > "$MAIN/.gaia/project.json"
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (1 choice pending)" <<<"$output"
}

@test "a malformed project config counts no project id decided and exits 0" {
  write_features github-repository
  printf '{' > "$MAIN/.gaia/project.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (1 choice pending)" <<<"$output"
}

@test "the closing-line helper names the same owed ids the nudge counts" {
  write_features alpha github-repository gamma
  run bash -c ". '$MAIN/.gaia/statusline/setup-owed.sh' && gaia_setup_owed_ids '$MAIN'"
  [ "$status" -eq 0 ]
  [ "$output" = "github-repository" ]

  cache_admin true
  run bash -c ". '$MAIN/.gaia/statusline/setup-owed.sh' && gaia_setup_owed_ids '$MAIN'"
  [ "$output" = "github-repository gamma" ]

  cache_admin false
  run bash -c ". '$MAIN/.gaia/statusline/setup-owed.sh' && gaia_setup_owed_ids '$MAIN'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the other nudges keep rendering, after the setup nudge, in their existing order" {
  arm_other_nudges
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qE -- "⚙️ /setup-gaia \(2 choices pending\) │ 🚀 /update-gaia .* │ 📦 /update-deps .* │ 🐛 /gaia-debt " <<<"$output"
}

@test "the setup nudge is the last to shrink and has its own Medium and icon forms" {
  arm_other_nudges

  # Medium for setup while every lower-priority nudge is already at Small.
  render "$MAIN" 90
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2)" <<<"$output"
  grep -qF -- "🚀 /update-gaia" <<<"$output"
  grep -qF -- "9.9.9" <<<"$output" && return 1

  # Small for setup while lower-priority nudges have reached icons.
  render "$MAIN" 60
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  grep -qF -- "⚙️ /setup-gaia (" <<<"$output" && return 1
  grep -qF -- "📦 3" <<<"$output"

  # Icon form last, with the count.
  render "$MAIN" 30
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ 2" <<<"$output"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1
  return 0
}

@test "no list renders no setup slot and leaves the rest of the render unchanged" {
  arm_other_nudges
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  with_list="$output"

  rm -f "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  grep -qF -- "🚀 /update-gaia (9.9.9)" <<<"$output"
  grep -qF -- "📦 /update-deps (3 outdated)" <<<"$output"
  grep -qF -- "🐛 /gaia-debt (5 issues)" <<<"$output"
  [ "${output//[[:space:]]/}" = "$(sed -E 's/⚙️ \/setup-gaia \(2 choices pending\) │ //' <<<"$with_list" | tr -d '[:space:]')" ]
}

@test "a malformed list renders no setup slot, no Required segment, and exits 0" {
  arm_other_nudges
  printf '{' > "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  # The shared read still reported completion, so the other nudges render.
  grep -qF -- "📦 /update-deps" <<<"$output"
}

@test "a list with a non-array features value renders no setup slot and exits 0" {
  printf '{"version":1,"description":"x","features":"nope"}\n' > "$MAIN/.gaia/setup-features.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "an incomplete setup still renders ⚙️ /setup-gaia (Required) alone" {
  arm_other_nudges
  write_setup_state null
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (Required)" <<<"$output"
  grep -qF -- "setup choice" <<<"$output" && return 1
  grep -qF -- "🔧" <<<"$output" && return 1
  grep -qF -- "+" <<<"$output" && return 1
  grep -qF -- "🚀 /update-gaia" <<<"$output" && return 1
  return 0
}

@test "with no jq the render exits 0 and shows no setup choice slot" {
  local bin_directory="$BATS_TEST_TMPDIR/nojq-bin" command_name json
  mkdir -p "$bin_directory"
  for command_name in bash cat dirname git sed awk grep tr uname head mktemp rm env sh; do
    command -v "$command_name" > /dev/null && ln -sf "$(command -v "$command_name")" "$bin_directory/$command_name"
  done
  [ ! -e "$bin_directory/jq" ]

  json=$(status_payload "$MAIN")
  run env -i HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$bin_directory" "$bin_directory/bash" -c "printf '%s' '$json' | '$bin_directory/bash' '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "setup choice" <<<"$output" && return 1
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1

  # Positive control: the same fixture renders the slot once jq is on PATH.
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"
}

@test "a linked worktree shows no setup choice nudge, the main checkout does" {
  render "$MAIN"
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  render "$WORKTREE"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "the incomplete-setup segment still renders from a linked worktree" {
  write_setup_state null
  render "$WORKTREE"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (Required)" <<<"$output"
}

@test "the list adds no jq process to a render" {
  local shim_directory="$BATS_TEST_TMPDIR/shim-bin" log_file="$BATS_TEST_TMPDIR/jq-calls" real_jq json
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/bash\necho x >> "%s"\nexec "%s" "$@"\n' "$log_file" "$real_jq" > "$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  arm_other_nudges
  json=$(status_payload "$MAIN")

  : > "$log_file"
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$shim_directory:$PATH" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output"
  calls_with_list=$(wc -l < "$log_file" | tr -d ' ')

  rm -f "$MAIN/.gaia/setup-features.json"
  : > "$log_file"
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 PATH="$shim_directory:$PATH" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia" <<<"$output" && return 1
  calls_without_list=$(wc -l < "$log_file" | tr -d ' ')

  # The shim logged something, so an inert shim cannot pass this.
  [ "$calls_without_list" -gt 0 ]
  [ "$calls_with_list" -eq "$calls_without_list" ]
}

# --- GAIA's own source repo -------------------------------------------------
#
# The source repo never runs /setup-gaia, so neither setup segment applies to
# it. The discriminator is `.gaia/cli/src`, the one the mid-init exception
# uses: release-excluded, so no adopter has it. Every case above renders an
# adopter-shaped fixture, which lacks it.

# Remove every maintainer-only block from MAIN's entrypoint and the right side
# it sources, in place, and print the entrypoint's path: what an adopter runs.
# The same hand-kept model of the shipped parser (`stripMarkerBlocks` in
# `.gaia/cli/src/release/marker-strip.ts`) that statusline-worktree.bats
# carries; a change to one belongs in both.
stripped_copy() {
  local script stripped="$BATS_TEST_TMPDIR/stripped.sh"
  for script in "$MAIN/.gaia/statusline/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline-right.sh"; do
    awk -v start_marker='# gaia:maintainer-only:start' -v end_marker='# gaia:maintainer-only:end' '
      {
        has_start_marker = index($0, start_marker) > 0
        has_end_marker = index($0, end_marker) > 0
        if (!skip && has_start_marker) { if (!has_end_marker) skip = 1; next }
        if (skip) { if (has_end_marker) skip = 0; next }
        print
      }
    ' "$script" > "$stripped"
    cp "$stripped" "$script"
  done
  printf '%s' "$MAIN/.gaia/statusline/gaia-statusline.sh"
}

# Render the stripped copy from MAIN, colors stripped like render.
render_stripped() {
  local json script
  json=$(status_payload "$MAIN")
  script=$(stripped_copy)
  run env HOME="$TEMPORARY_HOME" COLUMNS=400 bash -c "printf '%s' '$json' | bash '$script' | sed \$'s/\\x1b\\\\[[0-9;]*m//g'"
}

@test "the source repo shows no pending-choices nudge" {
  # Positive control: the adopter-shaped fixture nudges.
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  mkdir -p "$MAIN/.gaia/cli/src"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "the source repo shows no Required segment and keeps its other nudges" {
  arm_other_nudges
  write_setup_state null
  mkdir -p "$MAIN/.gaia/cli/src"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "🚀 /update-gaia" <<<"$output"
  grep -qF -- "/setup-gaia" <<<"$output" && return 1

  # A clone that has never written a setup state reads the same.
  rm -f "$MAIN/.gaia/local/setup-state.json"
  render "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "🚀 /update-gaia" <<<"$output"
  grep -qF -- "/setup-gaia" <<<"$output" && return 1
  return 0
}

@test "an adopter's stripped copy keeps both setup segments with the marker dir present" {
  # The exception lives inside maintainer-only markers, so the tarball does not
  # carry it, and running the stripped script proves it is still valid bash.
  mkdir -p "$MAIN/.gaia/cli/src"
  render_stripped
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (2 choices pending)" <<<"$output"

  write_setup_state null
  render_stripped
  [ "$status" -eq 0 ]
  grep -qF -- "⚙️ /setup-gaia (Required)" <<<"$output"
}
