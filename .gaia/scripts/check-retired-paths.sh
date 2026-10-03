#!/usr/bin/env bash
# Retired-path gate. The React app and its frontend-only harness live under
# `frontend/`; the root no longer holds `app/`, `test/`, `public/`,
# `.playwright/`, `.storybook/`, the moved root config files, or the moved
# `.claude/` units. A hook, script, workflow, CLI string, rule glob, agent, or
# skill that still cites one of those at the root is a coupling the move missed:
# it resolves to nothing, and a guard that resolves to nothing fails silently.
# This gate fails on any such citation unless the line is named in the committed
# allowlist with a reason.
#
# Usage: check-retired-paths.sh [--root <dir>] [--allowlist <file>]
#
# Exit 0 clean. Exit 1 on a hit, a stale or malformed allowlist entry, or a
# tracked path under a retired root entry. Exit 2 on a usage error, a repo that
# cannot be listed, or an empty scan set (a scan of nothing never reports clean).
#
# Output lines:
#   RETIRED <file>:<line>: <text>   a retired-path citation with no allowlist entry
#   STALE-ALLOW <file> <needle>     an allowlist entry that matched no hit
#   BAD-ALLOW <line>: <why>         an allowlist row with no needle or no reason
#   TRACKED <path>                  git tracks a path under a retired root entry
#
# Scan set (tracked files only, read from `git ls-files -z`):
#   .claude/hooks/**, .gaia/scripts/** (not tests/ or fixtures/ directories),
#   .github/workflows/**, .github/actions/**, .github/**/*.sh,
#   .gaia/cli/src/** (not *.test.ts or __tests__/), .claude/agents/*.md,
#   .claude/skills/**/*.md, .claude/commands/*.md, and the frontmatter of
#   .claude/rules/*.md and .claude/rules/maintainers/*.md (the `paths:` globs;
#   rule bodies are prose and are not scanned). `frontend/.claude/**` is
#   package-relative by contract and is not scanned.
#
# The gate itself is not scanned: its patterns and its tracked-path table spell
# every retired name by design.
#
# Allowlist: `.gaia/retired-paths-allowlist.tsv` by default, columns
# `file<TAB>needle<TAB>reason`. A hit is allowed when its file equals `file`
# and its line contains `needle`. Blank lines and lines starting with `#` are
# skipped.
#
# Token-boundary tuning decisions, each made against the tracked tree:
#   - `app/`, `test/`, `public/` must not follow a letter, digit, `_`, `.`, `/`
#     or `-`. A `/` before the word means a longer path (`frontend/app/`,
#     `.gaia/cli/src/test/`, `$root/app/`), which is the package-relative or
#     nested form and not a root citation. Leaving `/` out of the boundary set
#     would flag every `frontend/app/` citation.
#   - `.playwright/` and `.storybook/` use the same rule minus the `.` (the dot
#     is part of the token). A backslash also blocks the match, so a regex that
#     escapes the dot (`^frontend/\.storybook/`) is read as the nested form.
#   - A config name must also end at a non-word boundary, so `Dockerfiles` and
#     `.env.examples` do not trip. `Dockerfile.dockerignore` is blanked first: it
#     is the package-side name, not a retired one.
#   - The moved root config names (`vite.config.ts`, `tsconfig.json`, ...) must
#     not follow a letter, digit, `_`, `.`, `/` or `-`, so `.gaia/cli/tsconfig.json`,
#     `frontend/vite.config.ts`, and `my.tsconfig.json` do not trip. `.dockerignore`
#     after `Dockerfile` (`Dockerfile.dockerignore`) does not trip for the same
#     reason: the dot token follows a letter.
#   - `public/internal`, `public/private`, `test/CI` and `test/describe` are English
#     (visibility, a test-or-CI pair, a test-or-describe pair) and are blanked
#     before matching.
#   - In code files (anything but Markdown) a comment-only line is skipped:
#     comments describe layouts package-relative by the repo convention, so they
#     cite `app/` without naming the root. Markdown has no comment form and is
#     scanned line by line. A code line carrying a trailing comment is scanned.
#   - The `.claude/` unit citations trip unless the text before them ends in
#     `frontend/` or a `<path>/` placeholder, so an absolute or variable-prefixed root citation
#     (`$root/.claude/skills/tailwind`) is caught while
#     `frontend/.claude/skills/tailwind` is not.
#
# Bash 3.2 compatible; BSD and GNU tools.
set -u

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root=""
allowlist=""

usage() {
  printf 'usage: check-retired-paths.sh [--root <dir>] [--allowlist <file>]\n' >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage
      root="$2"
      shift 2
      ;;
    --allowlist)
      [ "$#" -ge 2 ] || usage
      allowlist="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$root" ] || root="$(cd "$script_directory/../.." && pwd)"
[ -d "$root" ] || {
  printf 'check-retired-paths: --root %s is not a directory\n' "$root" >&2
  exit 2
}
root="$(cd "$root" && pwd)"
[ -n "$allowlist" ] || allowlist="$root/.gaia/retired-paths-allowlist.tsv"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/check-retired-paths.XXXXXX")" || {
  printf 'check-retired-paths: cannot create a temporary directory\n' >&2
  exit 2
}
trap 'rm -rf "$temporary_directory"' EXIT

tracked_list="$temporary_directory/tracked"
if ! git -C "$root" -c core.quotepath=false ls-files -z >"$tracked_list" 2>"$temporary_directory/git-error"; then
  printf 'check-retired-paths: git could not list the tracked files in %s: %s\n' "$root" "$(cat "$temporary_directory/git-error")" >&2
  exit 2
fi

scan_list="$temporary_directory/scan"
: >"$scan_list"
tracked_hits="$temporary_directory/tracked-hits"
: >"$tracked_hits"

while IFS= read -r -d '' tracked_path; do
  case "$tracked_path" in
    app/* | test/* | public/* | .playwright/* | .storybook/* | \
      vite.config.ts | vitest.config.ts | playwright.config.ts | react-router.config.ts | \
      stylelint.config.mjs | knip.config.ts | doctor.config.ts | tsconfig.json | Dockerfile | \
      .env.example | eslint.config.mjs | .lintstagedrc.json | .dockerignore | \
      .claude/skills/a11y-fixes/* | .claude/skills/eslint-fixes/* | .claude/skills/gaia-react-perf/* | \
      .claude/skills/new-component/* | .claude/skills/new-hook/* | .claude/skills/new-route/* | \
      .claude/skills/new-service/* | .claude/skills/playwright-cli/* | .claude/skills/react-code/* | \
      .claude/skills/skeleton-loaders/* | .claude/skills/tailwind/* | .claude/skills/typescript/* | \
      .claude/rules/accessibility.md | .claude/rules/api-service.md | .claude/rules/design-baseline.md | \
      .claude/rules/i18n.md | .claude/rules/playwright.md | .claude/rules/react-router-docs.md | \
      .claude/rules/routes.md | .claude/rules/state-pattern.md | .claude/rules/storybook.md | \
      .claude/rules/tailwind.md | .claude/instructions/add-locale.md | .claude/instructions/remove-i18n.md | \
      .claude/agents/code-audit-frontend/*)
      printf 'TRACKED %s\n' "$tracked_path" >>"$tracked_hits"
      ;;
  esac
  case "$tracked_path" in
    .gaia/scripts/check-retired-paths.sh | .gaia/scripts/tests/* | .gaia/scripts/*/tests/* | .gaia/scripts/fixtures/* | .gaia/scripts/*/fixtures/*) continue ;;
    .gaia/cli/src/*.test.ts | .gaia/cli/src/*/__tests__/* | .gaia/cli/src/__tests__/*) continue ;;
  esac
  case "$tracked_path" in
    .claude/hooks/* | .gaia/scripts/* | .github/workflows/* | .github/actions/* | .github/*.sh | \
      .gaia/cli/src/* | .claude/rules/*.md | .claude/agents/*.md | .claude/skills/*.md | .claude/commands/*.md)
      printf '%s\n' "$tracked_path" >>"$scan_list"
      ;;
  esac
done <"$tracked_list"

if [ ! -s "$scan_list" ]; then
  printf 'check-retired-paths: the scan set is empty under %s; nothing was checked\n' "$root" >&2
  exit 2
fi

awk_program='
function trim_text(text) {
  gsub(/^[ \t]+|[ \t]+$/, "", text)
  return text
}
function hit_kind(line,    rest, offset, before, lead) {
  gsub(/public\/(internal|private)|test\/(CI|describe)|Dockerfile\.dockerignore/, "", line)
  if (line ~ /(^|[^A-Za-z0-9_.\\\/-])(app|test|public)\//) return 1
  if (line ~ /(^|[^A-Za-z0-9_\\\/-])\.(playwright|storybook)\//) return 1
  if (line ~ /(^|[^A-Za-z0-9_.\\\/-])((vite|vitest|playwright|react-router|knip|stylelint|doctor)\.config\.[a-z]+|tsconfig\.json|\.lintstagedrc\.json|eslint\.config\.mjs|Dockerfile|\.dockerignore|\.env\.example)([^A-Za-z0-9_-]|$)/) return 1
  rest = line
  offset = 0
  while (match(rest, /\.claude\/(skills\/(a11y-fixes|eslint-fixes|gaia-react-perf|new-component|new-hook|new-route|new-service|playwright-cli|react-code|skeleton-loaders|tailwind|typescript)|rules\/(accessibility|api-service|design-baseline|i18n|playwright|react-router-docs|routes|state-pattern|storybook|tailwind)\.md|instructions\/(add-locale|remove-i18n)\.md|agents\/code-audit-frontend\/)/)) {
    before = substr(line, 1, offset + RSTART - 1)
    if (before !~ /(frontend|<path>)\/$/) return 1
    offset += RSTART + RLENGTH - 1
    rest = substr(line, offset + 1)
  }
  return 0
}
BEGIN {
  FS = "\t"
  allow_count = 0
  bad = 0
  row = 0
  while ((getline entry < allowlist) > 0) {
    row++
    if (entry ~ /^[ \t]*$/ || entry ~ /^#/) continue
    count = split(entry, field, "\t")
    allow_file[allow_count] = field[1]
    allow_needle[allow_count] = field[2]
    reason = (count >= 3) ? field[3] : ""
    if (field[1] == "" || field[2] == "") {
      printf "BAD-ALLOW %d: a row needs a file and a needle\n", row
      bad = 1
    } else if (trim_text(reason) == "") {
      printf "BAD-ALLOW %d: the entry for %s has no reason\n", row, field[1]
      bad = 1
    }
    allow_used[allow_count] = 0
    allow_count++
  }
  close(allowlist)
  hits = 0
  while ((getline path < scan_list) > 0) {
    is_rule = (path ~ /^\.claude\/rules\/(maintainers\/)?[^\/]+\.md$/)
    is_markdown = (path ~ /\.md$/)
    in_front = 0
    seen_open = 0
    line_number = 0
    while ((getline line < path) > 0) {
      line_number++
      if (is_rule) {
        if (line_number == 1) {
          if (line == "---") { in_front = 1; seen_open = 1 }
          continue
        }
        if (!in_front) continue
        if (line == "---") { in_front = 0; continue }
      }
      if (!is_markdown && line ~ /^[ \t]*(#|\/\/|\*|\/\*)/) continue
      if (!hit_kind(line)) continue
      allowed = 0
      for (i = 0; i < allow_count; i++) {
        if (allow_file[i] == path && allow_needle[i] != "" && index(line, allow_needle[i]) > 0) {
          allowed = 1
          allow_used[i] = 1
        }
      }
      if (!allowed) {
        printf "RETIRED %s:%d: %s\n", path, line_number, line
        hits++
      }
    }
    close(path)
  }
  for (i = 0; i < allow_count; i++) {
    if (!allow_used[i] && allow_file[i] != "" && allow_needle[i] != "") {
      printf "STALE-ALLOW %s %s\n", allow_file[i], allow_needle[i]
      hits++
    }
  }
  if (hits > 0 || bad) exit 1
  exit 0
}
'

: >"$temporary_directory/allowlist-empty"
effective_allowlist="$allowlist"
[ -f "$effective_allowlist" ] || effective_allowlist="$temporary_directory/allowlist-empty"

status=0
(cd "$root" && awk -v allowlist="$effective_allowlist" -v scan_list="$scan_list" "$awk_program" </dev/null) || status=1

if [ -s "$tracked_hits" ]; then
  LC_ALL=C sort "$tracked_hits"
  status=1
fi

if [ "$status" -eq 0 ]; then
  printf 'check-retired-paths: clean (%s files scanned)\n' "$(wc -l <"$scan_list" | tr -d ' ')"
fi
exit "$status"
