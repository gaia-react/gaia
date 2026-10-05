#!/usr/bin/env bats

# The test-identity extractor over the committed CSF fixture stories: which
# stories it emits, and which edits move a story's signal. The comparison with
# Storybook's own reporter, which needs Chromium, lives in
# extract-test-signals-stories-reporter.bats.
#
# The fixtures are two files because a meta-level play is inherited by every
# story in its file: the render-only story cannot share a file with it.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  EXTRACTOR="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  SHAPES_PATH="frontend/app/utils/tests/csf-shapes.stories.tsx"
  META_PLAY_PATH="frontend/app/utils/tests/csf-meta-play.stories.tsx"
}

# Extractor output for a repo-relative path read from the checkout.
signals_of_path() {
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "$1" )
}

# Extractor output for edited source fed on stdin under the original path, so
# an edit on a scratch copy is judged as an edit to the real file.
signals_of_source() {
  local relative_path="$1" source_file="$2"
  ( cd "$HOME_ROOT" && node "$EXTRACTOR" "$relative_path" --stdin < "$source_file" )
}

# The signal recorded for one story name in an NDJSON stream.
signal_for() {
  local ndjson="$1" story_name="$2"
  jq -r --arg n "$story_name" 'select(.fullName == $n) | .signal' <<<"$ndjson"
}

# A scratch copy of the shapes fixture with the first occurrence of OLD
# replaced by NEW; fails when OLD is absent, so a rotation case cannot pass on
# an edit that never happened.
edited_shapes_copy() {
  local old="$1" new="$2" source edited copy="$BATS_TEST_TMPDIR/edited-shapes.stories.tsx"
  source=$(cat "$HOME_ROOT/$SHAPES_PATH")
  [[ "$source" == *"$old"* ]] || { echo "fixture no longer contains: $old" >&2; return 1; }
  edited="${source/"$old"/"$new"}"
  printf '%s\n' "$edited" > "$copy"
  printf '%s' "$copy"
}

@test "the shapes fixture yields one entry per story with an effective play and none for the render-only story" {
  local output_ndjson count exported render_only_exports
  output_ndjson=$(signals_of_path "$SHAPES_PATH")
  count=$(grep -c . <<<"$output_ndjson")
  exported=$(grep -c '^export const ' "$HOME_ROOT/$SHAPES_PATH")
  render_only_exports=$(grep -c '^export const RenderOnly' "$HOME_ROOT/$SHAPES_PATH")
  [ "$render_only_exports" -eq 1 ]
  [ "$count" -eq "$((exported - render_only_exports))" ]

  for story_name in "Multi Word Object Play" "Custom Display Name" "Assigned Play" "Shared Play First" "Shared Play Second" "Factory Built" "Spread Story"; do
    [ -n "$(signal_for "$output_ndjson" "$story_name")" ] || { echo "no entry for $story_name" >&2; return 1; }
  done
  [ -z "$(signal_for "$output_ndjson" "Render Only")" ]
  jq -e 'select(.signal | test("^sha256:[0-9a-f]{64}$")) | .kind == "runtime"' <<<"$output_ndjson" >/dev/null
}

@test "a name override replaces the export-derived name" {
  local output_ndjson
  output_ndjson=$(signals_of_path "$SHAPES_PATH")
  [ -n "$(signal_for "$output_ndjson" "Custom Display Name")" ]
  [ -z "$(signal_for "$output_ndjson" "Renamed Story")" ]
}

@test "the meta-play fixture yields its inherited-play story" {
  local output_ndjson
  output_ndjson=$(signals_of_path "$META_PLAY_PATH")
  [ "$(grep -c . <<<"$output_ndjson")" -eq 1 ]
  [ -n "$(signal_for "$output_ndjson" "Inherits Meta Play")" ]
}

@test "source fed on stdin under the original path reproduces the file's signals (the rotation cases compare like with like)" {
  local from_path from_stdin
  from_path=$(signals_of_path "$SHAPES_PATH")
  from_stdin=$(signals_of_source "$SHAPES_PATH" "$HOME_ROOT/$SHAPES_PATH")
  [ "$from_path" = "$from_stdin" ]
}

@test "editing the shared play body changes every story that shares it and no unrelated story" {
  local before after copy story_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy 'await expectMarkerOnce(canvasElement, args.text);' 'await expectMarkerOnce(canvasElement, args.text.trim());')
  after=$(signals_of_source "$SHAPES_PATH" "$copy")

  for story_name in "Shared Play First" "Shared Play Second" "Spread Story"; do
    [ "$(signal_for "$before" "$story_name")" != "$(signal_for "$after" "$story_name")" ] || { echo "signal unchanged for $story_name" >&2; return 1; }
  done
  for story_name in "Multi Word Object Play" "Custom Display Name" "Assigned Play" "Factory Built"; do
    [ "$(signal_for "$before" "$story_name")" = "$(signal_for "$after" "$story_name")" ] || { echo "signal moved for $story_name" >&2; return 1; }
  done
}

@test "editing the meta args changes every story signal in the file" {
  local before after copy story_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy "args: {text: 'default marker'}," "args: {text: 'edited default marker'},")
  after=$(signals_of_source "$SHAPES_PATH" "$copy")
  [ "$(grep -c . <<<"$before")" -eq "$(grep -c . <<<"$after")" ]

  while IFS= read -r story_name; do
    [ -n "$story_name" ] || continue
    [ "$(signal_for "$before" "$story_name")" != "$(signal_for "$after" "$story_name")" ] || { echo "signal unchanged for $story_name" >&2; return 1; }
  done < <(jq -r '.fullName' <<<"$before")
}

@test "editing one story's own play changes that story's signal only" {
  local before after copy story_name
  before=$(signals_of_path "$SHAPES_PATH")
  copy=$(edited_shapes_copy "'object property marker');
  }," "'object property marker');
    await expect(true).toBe(true);
  },")
  after=$(signals_of_source "$SHAPES_PATH" "$copy")
  [ "$(signal_for "$before" "Multi Word Object Play")" != "$(signal_for "$after" "Multi Word Object Play")" ]
  for story_name in "Custom Display Name" "Assigned Play" "Shared Play First" "Factory Built"; do
    [ "$(signal_for "$before" "$story_name")" = "$(signal_for "$after" "$story_name")" ] || { echo "signal moved for $story_name" >&2; return 1; }
  done
}

@test "a story whose play is an imported identifier exits 7 with the refusal line and no stdout" {
  local source="$BATS_TEST_TMPDIR/imported.stories.tsx"
  printf '%s\n' \
    "import {sharedPlay} from './shared-play';" \
    "const meta = {title: 'Internal/Imported'};" \
    "export default meta;" \
    "export const UsesImportedPlay = {play: sharedPlay};" > "$source"
  run bash -c 'cd "$1" && node "$2" "$3" --stdin < "$4" 2>"$5"' _ "$HOME_ROOT" "$EXTRACTOR" "frontend/app/utils/tests/imported.stories.tsx" "$source" "$BATS_TEST_TMPDIR/stderr.txt"
  [ "$status" -eq 7 ]
  [ -z "$output" ]
  grep -qF -- "unsupported story shape in frontend/app/utils/tests/imported.stories.tsx: UsesImportedPlay" "$BATS_TEST_TMPDIR/stderr.txt"
}
