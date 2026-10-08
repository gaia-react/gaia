#!/usr/bin/env bats
#
# Frontmatter limits for every skill and command GAIA authors.
#
# Claude Code puts each model-invocable skill's and command's `name` and
# `description` into a listing that loads in every session, and Anthropic's
# Agent Skills rules cap both fields: `name` at 64 lowercase letters, digits
# and hyphens with no reserved word, `description` non-empty, at most 1,024
# characters, with no XML tags. A description is also a plain YAML scalar, so
# ": " or " #" inside an unquoted one silently changes what the parser reads.
#
# Vendored skills (the targets `.gaia/vendor/*.json` pins) keep their upstream
# frontmatter and are excluded; installer-managed skills are untracked, so the
# tracked-file derivation never sees them.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
}

# Prints the repo-relative path of every GAIA-authored skill and command file.
authored_files() {
  local root="$1" vendored_targets
  vendored_targets="$(jq -r '.target // empty' "$root"/.gaia/vendor/*.json 2>/dev/null)"
  git -C "$root" ls-files -- '.claude/skills/*/SKILL.md' 'frontend/.claude/skills/*/SKILL.md' '.claude/commands/*.md' |
    while IFS= read -r relative_path; do
      local target excluded=0
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        case "$relative_path" in "$target"/*) excluded=1 ;; esac
      done <<<"$vendored_targets"
      [ "$excluded" = 1 ] || printf '%s\n' "$relative_path"
    done
}

# Prints the value of one top-level frontmatter key, quotes stripped.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  ' "$1"
}

frontmatter_ok() {
  local file_path="$1" name description unquoted
  [ "$(head -n 1 "$file_path")" = "---" ] || { echo "$file_path: no frontmatter" >&2; return 1; }
  name="$(frontmatter_value "$file_path" name)"
  if [ -n "$name" ]; then
    printf '%s' "$name" | grep -qE '^[a-z0-9-]{1,64}$' || { echo "$file_path: name '$name' breaks the 64-character lowercase-hyphen rule" >&2; return 1; }
    printf '%s' "$name" | grep -qE 'claude|anthropic' && { echo "$file_path: name '$name' carries a reserved word" >&2; return 1; }
  fi
  description="$(frontmatter_value "$file_path" description)"
  [ -n "$description" ] || { echo "$file_path: empty or missing description" >&2; return 1; }
  case "$description" in
    "'"*"'" | '"'*'"') unquoted="${description:1:${#description}-2}" ;;
    *)
      unquoted="$description"
      case "$description" in *': '* | *' #'*) echo "$file_path: unquoted description carries ': ' or ' #'" >&2; return 1 ;; esac
      ;;
  esac
  [ "$(printf '%s' "$unquoted" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -le 1024 ] || { echo "$file_path: description over 1,024 characters" >&2; return 1; }
  printf '%s' "$unquoted" | grep -qE '</?[A-Za-z][^>]*>' && { echo "$file_path: description carries an XML tag" >&2; return 1; }
  return 0
}

scratch_copy() {
  cp "$1" "$BATS_TEST_TMPDIR/$2"
  printf '%s\n' "$BATS_TEST_TMPDIR/$2"
}

@test "the derived set covers all three locations and leaves out the vendored skill" {
  local files
  files="$(authored_files "$REPO_ROOT")"
  grep -qE '^\.claude/skills/' <<<"$files"
  grep -qE '^frontend/\.claude/skills/' <<<"$files"
  grep -qE '^\.claude/commands/' <<<"$files"
  grep -qF 'playwright-cli' <<<"$files" && return 1
  git -C "$REPO_ROOT" ls-files -- 'frontend/.claude/skills/playwright-cli/SKILL.md' | grep -qF 'playwright-cli'
}

@test "every GAIA-authored skill and command meets the name and description limits" {
  local relative_path checked=0 failed=0 expected files
  files="$(authored_files "$REPO_ROOT")"
  expected="$(printf '%s\n' "$files" | grep -c .)"
  [ "$expected" -gt 0 ]
  while IFS= read -r relative_path; do
    checked=$((checked + 1))
    frontmatter_ok "$REPO_ROOT/$relative_path" || failed=$((failed + 1))
  done <<<"$files"
  [ "$checked" -eq "$expected" ]
  [ "$failed" -eq 0 ]
}

@test "red twin: a 1,025-character description fails" {
  local copy long
  copy="$(scratch_copy "$REPO_ROOT/.claude/skills/tdd/SKILL.md" long.md)"
  long="$(head -c 1025 /dev/zero | tr '\0' a)"
  awk -v replacement="description: $long" '/^description:/ && !done { print replacement; done = 1; next } { print }' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  awk -v replacement="description: ${long:1}" '/^description:/ && !done { print replacement; done = 1; next } { print }' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  frontmatter_ok "$copy"
}

@test "red twin: an XML tag in a description fails" {
  local copy
  copy="$(scratch_copy "$REPO_ROOT/.claude/skills/tdd/SKILL.md" xml.md)"
  sed 's/^description: /description: Wraps <example>text<\/example> and /' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  true
}

@test "red twin: a reserved word or an over-long name fails" {
  local copy
  copy="$(scratch_copy "$REPO_ROOT/.claude/skills/tdd/SKILL.md" reserved.md)"
  sed 's/^name: tdd$/name: claude-tdd/' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  grep -qx 'name: claude-tdd' "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  sed "s/^name: claude-tdd\$/name: $(head -c 65 /dev/zero | tr '\0' a)/" "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  true
}

@test "red twin: an empty description and an unquoted ': ' each fail" {
  local copy
  copy="$(scratch_copy "$REPO_ROOT/.claude/skills/tdd/SKILL.md" empty.md)"
  sed 's/^description: .*/description: /' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  copy="$(scratch_copy "$REPO_ROOT/.claude/skills/tdd/SKILL.md" colon.md)"
  sed 's/^description: /description: Note: /' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  if frontmatter_ok "$copy"; then return 1; fi
  true
}
