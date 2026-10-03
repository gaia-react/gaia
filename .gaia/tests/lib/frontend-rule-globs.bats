#!/usr/bin/env bats
#
# Path globs in frontend/.claude/rules/*.md.
#
# A rule under frontend/.claude/rules anchors its `paths:` globs at frontend/,
# the directory that holds its .claude/, from a root launch and from a
# frontend launch alike. So a glob there is written package-relative
# ("app/**/*"); the repo-root form ("frontend/app/**/*") never matches in that
# directory and the rule silently never loads. The suite parses the
# frontmatter of every rule, rejects the repo-root form, and requires each glob
# to match at least one tracked file under frontend/ (a glob that matches
# nothing is a rule that never fires).
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULES_DIR="$REPO_ROOT_REAL/frontend/.claude/rules"
}

# Print each `paths:` glob of one rule file, one per line, quotes stripped.
rule_globs() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^paths:[[:space:]]*$/ { inpaths = 1; next }
    inpaths && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      gsub(/^["\047]|["\047]$/, "")
      print
      next
    }
    inpaths { inpaths = 0 }
  ' "$1"
}

# A glob is well-formed when it is package-relative: not the repo-root form,
# not absolute, not climbing out. Prints the reason on failure.
glob_form_problem() {
  case "$1" in
    frontend/* | '**/frontend/'*) echo "repo-root form, never matches under frontend/.claude/rules" ;;
    /* | ../*) echo "absolute or parent-relative" ;;
    '') echo "empty" ;;
    *) return 1 ;;
  esac
}

# Does the package-relative glob match at least one tracked file under frontend/?
glob_matches_tracked_file() {
  local first
  first="$(git -C "$REPO_ROOT_REAL" ls-files -z -- ":(glob)frontend/$1" | head -c 1 | wc -c | tr -d ' ')"
  [ "$first" -gt 0 ]
}

# Check every rule in a directory. Prints one line per violation; exits 1 when
# there is any. Rules with no `paths:` key are skipped (always loaded).
check_rules_dir() {
  local dir="$1" rule glob problem found=0
  for rule in "$dir"/*.md; do
    [ -e "$rule" ] || continue
    while IFS= read -r glob; do
      if problem="$(glob_form_problem "$glob")"; then
        echo "$(basename "$rule"): '$glob': $problem"
        found=1
      elif ! glob_matches_tracked_file "$glob"; then
        echo "$(basename "$rule"): '$glob': matches no tracked file under frontend/"
        found=1
      fi
    done < <(rule_globs "$rule")
  done
  [ "$found" -eq 0 ]
}

@test "every moved frontend rule is present (a short read of the directory fails)" {
  local name missing=""
  for name in accessibility api-service design-baseline i18n playwright react-router-docs routes state-pattern storybook tailwind; do
    [ -f "$RULES_DIR/$name.md" ] || missing="$missing $name"
  done
  [ -z "$missing" ] || { echo "missing rules:$missing" >&2; return 1; }
}

@test "every moved rule declares at least one paths glob" {
  local name globs bare=""
  for name in accessibility api-service design-baseline i18n playwright react-router-docs routes state-pattern storybook tailwind; do
    globs="$(rule_globs "$RULES_DIR/$name.md")"
    [ -n "$globs" ] || bare="$bare $name"
  done
  [ -z "$bare" ] || { echo "rules with no paths globs:$bare" >&2; return 1; }
}

@test "every glob in frontend/.claude/rules is package-relative and matches a tracked file" {
  run check_rules_dir "$RULES_DIR"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "react-buckets.md, when it carries paths, uses the same form" {
  local file="$REPO_ROOT_REAL/frontend/.claude/agents/code-audit-frontend/react-buckets.md" glob
  [ -f "$file" ] || return 1
  while IFS= read -r glob; do
    glob_form_problem "$glob" && return 1
  done < <(rule_globs "$file")
  true
}

@test "the check refuses a copy with one glob reverted to the repo-root form" {
  local copy="$BATS_TEST_TMPDIR/rules"
  mkdir -p "$copy"
  cp "$RULES_DIR"/*.md "$copy/"
  # Baseline: the untouched copy passes, so the failure below is the revert's.
  run check_rules_dir "$copy"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  sed "s#'app/components/\*\*/\*'#'frontend/app/components/**/*'#" "$RULES_DIR/accessibility.md" >"$copy/accessibility.md"
  cmp -s "$RULES_DIR/accessibility.md" "$copy/accessibility.md" && return 1
  run check_rules_dir "$copy"
  [ "$status" -ne 0 ] || return 1
  grep -qF -- "accessibility.md: 'frontend/app/components/**/*': repo-root form" <<<"$output"
}

@test "the check refuses a glob that matches no tracked file" {
  local copy="$BATS_TEST_TMPDIR/rules-dead"
  mkdir -p "$copy"
  cat >"$copy/dead.md" <<'EOF'
---
paths:
  - 'no-such-directory/**/*'
---

# Dead
EOF
  run check_rules_dir "$copy"
  [ "$status" -ne 0 ] || return 1
  grep -qF -- "matches no tracked file" <<<"$output"
}
