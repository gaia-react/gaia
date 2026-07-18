#!/usr/bin/env bats
#
# Structural manifest-integrity guard for the GAIA spec-kit extension
# registry: asserts every commands/*.md file is registered under
# extension.yml's provides.commands list, and every registered `file:`
# value resolves to a real file on disk. Release-excluded (this dir does
# not ship); a regression guard, not a feature smoke harness -- it exists
# because commands/plan-close.md was once authored but left unregistered,
# caught only by manual audit (issue #651).
#
# Assertion style note (`.claude/rules/bats-assertions.md`): assertions
# use POSIX `[ ]` or an explicit `return 1`, never a bare mid-test `[[ ]]`,
# so a broken assertion fails correctly even under macOS's bash 3.2.

setup() {
  EXT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MANIFEST="$EXT_DIR/extension.yml"
}

# Echoes each `file:` value under provides.commands, one per line, e.g.
# "commands/spec.md". Scoped to the provides: block (stops at hooks:) so a
# future unrelated `file:` key elsewhere in the manifest can't leak in.
# No yq on this machine -- extracted with awk/grep/sed instead.
registered_files() {
  awk '/^provides:/{p=1} /^hooks:/{p=0} p' "$MANIFEST" \
    | grep -E '^[[:space:]]*file:[[:space:]]*"[^"]+"' \
    | sed -E 's/^[[:space:]]*file:[[:space:]]*"([^"]+)".*/\1/'
}

@test "every commands/*.md file is registered in extension.yml's provides.commands" {
  registered="$(registered_files)"
  missing=""
  for f in "$EXT_DIR"/commands/*.md; do
    rel="commands/$(basename "$f")"
    grep -qxF "$rel" <<<"$registered" || missing="$missing $rel"
  done
  if [ -n "$missing" ]; then
    echo "unregistered command file(s):$missing" >&2
    return 1
  fi
}

@test "every extension.yml provides.commands file: value resolves to an existing file" {
  registered="$(registered_files)"
  missing=""
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    [ -f "$EXT_DIR/$rel" ] || missing="$missing $rel"
  done <<<"$registered"
  if [ -n "$missing" ]; then
    echo "registered file(s) missing on disk:$missing" >&2
    return 1
  fi
}
