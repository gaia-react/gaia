#!/usr/bin/env bash
# 14-shell-member-content.sh
#
# Proves the shell audit member, its shell testing stack reference, the shell
# wiki page and the shipped bats assertion rule are present, self-consistent
# and free of maintainer-only content in the release-scrubbed ADOPTER bundle.
#
# Assertions, in order:
#   1. The bundle ships .claude/agents/code-audit-shell.md with the
#      correctness core, a hook lens scoped to hooks, a bats lens scoped to
#      .bats files, a settings lens scoped to .claude/settings.json, and none
#      of the maintainer shell member's wildcard remit globs, its
#      declarative-surface lens or its triage threshold.
#   2. Every path and wikilink the member definition, the shell stack
#      reference and the shell wiki page cite exists in the bundle (the
#      citation extraction is documented at check_citations), and none of the
#      three mentions a maintainer-only tool or path.
#   3. The shipped bats assertion rule exists, applies to .bats files, cites
#      only paths the bundle has, and carries none of the maintainer
#      tooling the source copy once named.
#   4. Pointers: the tdd skill's stack list links the shell stack reference,
#      and the stack reference and the member definition each cite the shell
#      wiki page.
#   5. Guard can fail: a scratch copy of the member definition with a planted
#      citation of a nonexistent path fails the citation check, and one with a
#      planted maintainer-only tool name fails the denylist check, and one
#      without the settings lens heading fails the settings lens check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command rsync "rsync required for staging build"

STAGING="$(mktemp -d -t gaia-dist-shell-content-XXXXXX)"
SCRATCH="$(mktemp -d -t gaia-dist-shell-content-scratch-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCRATCH"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

DEFINITION=".claude/agents/code-audit-shell.md"
STACK_REFERENCE=".claude/skills/tdd/references/tests-shell.md"
WIKI_PAGE="wiki/concepts/Shell Testing and CI.md"
ASSERTION_RULE=".claude/rules/bats-assertions.md"
TDD_SKILL=".claude/skills/tdd/SKILL.md"

for shipped in "$DEFINITION" "$STACK_REFERENCE" "$WIKI_PAGE" "$ASSERTION_RULE" "$TDD_SKILL"; do
  [ -s "$STAGING/$shipped" ] || { fail "the staged bundle lacks $shipped"; exit 1; }
done

# check_citations FILE: succeeds when every path and wikilink FILE cites exists
# in the staged bundle. A cited path is a backticked token that contains a `/`
# or ends in .sh, .md or .bats, minus what is not a path to a bundle file:
# tokens with `<`, `*`, `$`, `>` or a space (placeholders, globs, redirects), a
# bare extension (`.bats`), a leading `/` (a system path or slash command), the
# `holistic/` finding-class names, and the paths an adopter creates (the
# suite directory and the worked-example files under it, the project config the
# CLI writes on first use, plus the member's runtime scratch directory under the
# gitignored local state).
check_citations() {
  local file="$1" token missing=0 title
  # shellcheck disable=SC2016 # the backticks are literal Markdown code-span delimiters
  while IFS= read -r token; do
    case "$token" in
      *'<'* | *'*'* | *'$'* | *'>'* | *' '*) continue ;;
      /* | holistic/*) continue ;;
      .sh | .md | .bats) continue ;;
      tests/shell | tests/shell/ | tests/shell/*.bats | scripts/slugify.sh) continue ;;
      .gaia/project.json | .gaia/local/cache/mutation-scratch/) continue ;;
    esac
    if [ ! -e "$STAGING/$token" ]; then
      log "cited path missing from the bundle: $token (in $file)"
      missing=1
    fi
  done < <(grep -o '`[^`]*`' "$file" | tr -d '`' | grep -E '/|\.(sh|md|bats)$' | sort -u || true)
  while IFS= read -r title; do
    if [ -z "$(find "$STAGING/wiki" -type f -name "$title.md" -print -quit)" ]; then
      log "wikilink target missing from the bundle: [[$title]] (in $file)"
      missing=1
    fi
  done < <(grep -o '\[\[[A-Z][^]|]*\]\]' "$file" | sed -e 's/^\[\[//' -e 's/\]\]$//' | sort -u || true)
  [ "$missing" -eq 0 ]
}

# check_denylist FILE TERM...: succeeds when FILE mentions none of the terms.
check_denylist() {
  local file="$1" term found=0
  shift
  for term in "$@"; do
    if grep -qF -- "$term" "$file"; then
      log "forbidden maintainer-only term '$term' in $file"
      found=1
    fi
  done
  [ "$found" -eq 0 ]
}

SHELL_DENYLIST=(bats5 install-bats shell-lint.sh verify-harness code-audit-maintainer-shell '.gaia/tests/')
RULE_DENYLIST=(bats5 'guard below' verify-harness whole-tree '.gaia/tests/' 'change selector' gaia-lint-ignore)

# --- Assertion 1: the member definition content ------------------------------
member="$STAGING/$DEFINITION"
for topic in 'Quoting' 'set -euo pipefail' 'Fail-open vs. fail-closed' 'Bash 3.2' 'BSD-vs-GNU'; do
  grep -qF -- "$topic" "$member" || { fail "member definition lacks correctness-core topic: $topic"; exit 1; }
done
grep -qE '^## Conditional hook-contract lens' "$member" \
  || { fail "member definition lacks the hook-contract lens heading"; exit 1; }
grep -qF 'This lens activates only for hook scripts' "$member" \
  || { fail "the hook lens is not scoped to hook scripts"; exit 1; }
grep -qE '^## Conditional bats-suite lens' "$member" \
  || { fail "member definition lacks the bats-suite lens heading"; exit 1; }
# shellcheck disable=SC2016 # the backticks are literal Markdown
grep -qF 'This lens activates only for `.bats` files' "$member" \
  || { fail "the bats lens is not scoped to .bats files"; exit 1; }
# shellcheck disable=SC2016 # the backticks are literal Markdown
check_settings_lens() {
  grep -qE '^## Conditional settings lens' "$1" && grep -qxF 'This lens activates only for `.claude/settings.json`.' "$1"
}
check_settings_lens "$member" \
  || { fail "member definition lacks the settings lens heading or its activation sentence"; exit 1; }
for forbidden in 'Conditional declarative-surface lens' 'Triage threshold' 'harness-triage-threshold'; do
  if grep -qF -- "$forbidden" "$member"; then
    fail "member definition carries maintainer-only content: $forbidden"; exit 1
  fi
done

# The maintainer shell member's wildcard remit globs, read from the source
# definition, must not appear in the adopter definition. Literal file names and
# the hook glob the hook lens legitimately names are not wildcard remit globs.
maintainer_globs="$(awk '
  $0 == "<!-- gaia:audit-remit:start -->" { flag = 1; next }
  $0 == "<!-- gaia:audit-remit:end -->" { flag = 0 }
  flag && /^- `/ { print }
' "$PROJECT_ROOT/.claude/agents/code-audit-maintainer-shell.md" | sed -e 's/^- `//' -e 's/`$//' \
  | grep -F '*' | grep -vE '^\.(claude|githooks)/' || true)"
[ -n "$maintainer_globs" ] \
  || { fail "no maintainer remit globs were derived, so the glob-absence check would be vacuous"; exit 1; }
while IFS= read -r glob; do
  if grep -qF -- "$glob" "$member"; then
    fail "member definition names the maintainer remit glob: $glob"; exit 1
  fi
done <<<"$maintainer_globs"

# --- Assertion 2: citations and denylist across the three documents ---------
for document in "$DEFINITION" "$STACK_REFERENCE" "$WIKI_PAGE"; do
  check_citations "$STAGING/$document" \
    || { fail "$document cites a path or wikilink the staged bundle lacks"; exit 1; }
  check_denylist "$STAGING/$document" ${SHELL_DENYLIST[@]+"${SHELL_DENYLIST[@]}"} \
    || { fail "$document mentions a maintainer-only tool or path"; exit 1; }
done

# --- Assertion 3: the shipped bats assertion rule ----------------------------
rule="$STAGING/$ASSERTION_RULE"
rule_frontmatter="$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside' "$rule")"
grep -qxF "  - '**/*.bats'" <<<"$rule_frontmatter" \
  || { fail "the bats assertion rule's frontmatter paths do not list '**/*.bats'"; exit 1; }
check_citations "$rule" \
  || { fail "the bats assertion rule cites a path the staged bundle lacks"; exit 1; }
check_denylist "$rule" ${RULE_DENYLIST[@]+"${RULE_DENYLIST[@]}"} \
  || { fail "the bats assertion rule carries maintainer-only content"; exit 1; }

# --- Assertion 4: pointers ----------------------------------------------------
tdd_skill_bullets="$(grep -E '^- ' "$STAGING/$TDD_SKILL" || true)"
grep -qF "\`$STACK_REFERENCE\`" <<<"$tdd_skill_bullets" \
  || { fail "the tdd skill's stack list has no bullet pointing at $STACK_REFERENCE"; exit 1; }
for citing in "$STACK_REFERENCE" "$DEFINITION"; do
  grep -qF "$WIKI_PAGE" "$STAGING/$citing" \
    || { fail "$citing does not cite $WIKI_PAGE"; exit 1; }
done

# --- Assertion 5: both guards can fail --------------------------------------
planted="$SCRATCH/planted-citation.md"
cp "$member" "$planted"
# shellcheck disable=SC2016 # the backticks are literal Markdown
printf '\nSee `.claude/hooks/lib/no-such-helper.sh` for details.\n' >> "$planted"
if (check_citations "$planted") 2>/dev/null; then
  fail "guard-can-fail: the citation check accepted a planted nonexistent path"; exit 1
fi
planted="$SCRATCH/planted-denylist.md"
cp "$member" "$planted"
printf '\nRun the suite with bats5 first.\n' >> "$planted"
if (check_denylist "$planted" ${SHELL_DENYLIST[@]+"${SHELL_DENYLIST[@]}"}) 2>/dev/null; then
  fail "guard-can-fail: the denylist check accepted a planted maintainer-only tool name"; exit 1
fi

planted="$SCRATCH/planted-no-settings-lens.md"
grep -vE '^## Conditional settings lens' "$member" > "$planted" || true
if (check_settings_lens "$planted") 2>/dev/null; then
  fail "guard-can-fail: the settings lens check accepted a definition without the lens heading"; exit 1
fi

pass "shell member, stack reference, wiki page and assertion rule are consistent and adopter-clean in the staged bundle"
