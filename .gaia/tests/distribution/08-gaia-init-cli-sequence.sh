#!/usr/bin/env bash
# 08-gaia-init-cli-sequence.sh
#
# Adopter-flow regression: runs the full deterministic sequence behind
# `/gaia-init` Step 3 against a writable copy of the staged release tree.
# Extends 07's pattern (single-step regression for `strip-branding`) by
# exercising every CLI surface the slash command dispatches to:
#
#   gaia init strip-branding   --title "Test Project"
#   gaia init configure-i18n   --locales "en,es" --strip false
#   gaia init rename           --title "Test Project" --kebab "test-project"
#   gaia init wire-statusline  --mode project
#   gaia init finalize
#
# Why it exists: 07 catches release-exclude drift on strip-branding's
# template/deletion/edit targets. This scenario catches the same class of
# drift on the four remaining CLI surfaces; any of them silently
# no-ops if its target file is missing from the staged tree (existsSync
# guards), so a missing target ships green from 07 but breaks the adopter
# flow at the matching `/gaia-init` step.
#
# Asserts (post-conditions per CLI step):
#
#   strip-branding  README.md created at scaffold root with title; sets
#                   the tree up for the remaining steps. Same surface as
#                   07; no new assertions added here.
#
#   configure-i18n  app/languages/index.ts contains both 'en' and 'es'
#                   imports + a LANGUAGES list with both codes;
#                   app/i18n.ts has fallbackLng: 'en'.
#
#   rename          package.json "name" == "test-project"; CLAUDE.md
#                   first H1 line == "# Test Project";
#                   app/languages/en/common.ts has siteName: 'Test
#                   Project'; app/languages/en/pages/_index.ts has
#                   title/heroTitle: 'Test Project'.
#
#   wire-statusline .claude/settings.json contains the canonical GAIA
#                   statusline command. --mode project so the test never
#                   touches the host's ~/.claude/settings.json.
#
#   finalize        .claude/hooks/intercept-init.sh removed;
#                   .claude/commands/gaia-init.md removed;
#                   .claude/settings.json no longer references
#                   intercept-init.sh.
#
# Layer 0.5: runs on the host or runner, no Docker, no Claude OAuth
# token. Cheap (~few seconds after build-staging); file-level transforms
# only, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for adopter-flow scaffold copy"

STAGING="$(mktemp -d -t gaia-dist-init-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-init-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Copy staging into a writable scaffold (the CLI subcommands mutate files).
rsync -a "$STAGING"/ "$SCAFFOLD"/

# Pre-conditions on the staged tree. Each guarantees one of the CLI
# subcommands has its target file. configure-i18n / rename / finalize all
# use `existsSync` guards, so a missing target produces a silent no-op
# rather than an error; the assertion would then fail downstream with a
# confusing message. Failing pre-flight here points the maintainer at
# release-exclude.
[ -x "$SCAFFOLD/.gaia/cli/gaia" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

# strip-branding targets (covered by 07; re-checked here so 08 can run
# standalone if 07 is skipped or rerun-after-edit).
[ -f "$SCAFFOLD/.gaia/templates/README.md" ] \
  || { fail "staged tree missing .gaia/templates/README.md (strip-branding template source)"; exit 1; }
[ -d "$SCAFFOLD/app/components/GaiaLogo" ] \
  || { fail "staged tree missing app/components/GaiaLogo/ (strip-branding deletion target)"; exit 1; }

# configure-i18n targets.
[ -f "$SCAFFOLD/app/languages/index.ts" ] \
  || { fail "staged tree missing app/languages/index.ts (configure-i18n target)"; exit 1; }
[ -f "$SCAFFOLD/app/i18n.ts" ] \
  || { fail "staged tree missing app/i18n.ts (configure-i18n fallbackLng target)"; exit 1; }

# rename targets.
[ -f "$SCAFFOLD/package.json" ] \
  || { fail "staged tree missing package.json (rename target)"; exit 1; }
[ -f "$SCAFFOLD/CLAUDE.md" ] \
  || { fail "staged tree missing CLAUDE.md (rename H1 target)"; exit 1; }
[ -f "$SCAFFOLD/app/languages/en/common.ts" ] \
  || { fail "staged tree missing app/languages/en/common.ts (rename siteName target)"; exit 1; }
[ -f "$SCAFFOLD/app/languages/en/pages/_index.ts" ] \
  || { fail "staged tree missing app/languages/en/pages/_index.ts (rename heroTitle/title target)"; exit 1; }

# finalize targets; the staged tree must ship both the interceptor hook
# script and the command file so finalize has something to delete, and
# the settings file must contain a UserPromptExpansion entry for the
# prune to fire.
[ -f "$SCAFFOLD/.claude/hooks/intercept-init.sh" ] \
  || { fail "staged tree missing .claude/hooks/intercept-init.sh (finalize deletion target)"; exit 1; }
[ -f "$SCAFFOLD/.claude/commands/gaia-init.md" ] \
  || { fail "staged tree missing .claude/commands/gaia-init.md (finalize deletion target)"; exit 1; }
[ -f "$SCAFFOLD/.claude/settings.json" ] \
  || { fail "staged tree missing .claude/settings.json (finalize prune target)"; exit 1; }
grep -q "intercept-init.sh" "$SCAFFOLD/.claude/settings.json" \
  || { fail "staged .claude/settings.json has no intercept-init.sh entry; finalize would no-op silently"; exit 1; }

TITLE="Test Project"
KEBAB="test-project"
GAIA="$SCAFFOLD/.gaia/cli/gaia"

# Each invocation runs from inside $SCAFFOLD via a subshell so the CLI's
# `process.cwd()` resolves to the scaffold root without mutating the
# parent scenario's pwd.
run_step() {
  local label="$1"; shift
  local stdout
  stdout="$(cd "$SCAFFOLD" && "$GAIA" "$@" 2>/dev/null)" || {
    # Re-run with stderr unsuppressed for diagnosis. The `fail; exit 1`
    # below runs unconditionally; the diagnostic re-run's exit code is
    # intentionally ignored (`|| :`).
    log "gaia $* exited non-zero; rerunning with stderr:"
    ( cd "$SCAFFOLD" && "$GAIA" "$@" ) || :
    fail "gaia $* exited non-zero on staged tree (step: $label)"
    exit 1
  }
  if [ -n "$stdout" ]; then
    log "unexpected stdout from gaia $* (contract: no stdout on success):"
    printf '%s\n' "$stdout" >&2
    fail "gaia $* wrote to stdout (contract violation, step: $label)"
    exit 1
  fi
}

# Step 1; strip-branding. Sets up the tree for the remaining steps;
# post-conditions are covered by 07.
run_step "strip-branding" \
  init strip-branding --title "$TITLE"

# Step 2; configure-i18n. --strip false keeps the i18n surface and
# rewrites the locale list; --strip true would delete the surface
# entirely (covered by a separate scenario in a follow-up PR).
run_step "configure-i18n" \
  init configure-i18n --locales "en,es" --strip false

LANGUAGES_INDEX="$SCAFFOLD/app/languages/index.ts"
grep -q "^import en from './en';" "$LANGUAGES_INDEX" \
  || { fail "configure-i18n did not write 'en' import to app/languages/index.ts"; exit 1; }
grep -q "^import es from './es';" "$LANGUAGES_INDEX" \
  || { fail "configure-i18n did not write 'es' import to app/languages/index.ts"; exit 1; }
grep -q "LANGUAGES = \['en', 'es'\]" "$LANGUAGES_INDEX" \
  || { fail "configure-i18n did not set LANGUAGES = ['en', 'es']"; exit 1; }
grep -q "fallbackLng: 'en'" "$SCAFFOLD/app/i18n.ts" \
  || { fail "configure-i18n did not set fallbackLng: 'en' in app/i18n.ts"; exit 1; }

# Step 3; rename. Touches package.json, CLAUDE.md H1, and two seeded
# language files.
run_step "rename" \
  init rename --title "$TITLE" --kebab "$KEBAB"

# package.json "name"; JSON-aware grep avoids matching a "name" key
# inside dependencies.
grep -qE '^\s*"name":\s*"test-project"\s*,?\s*$' "$SCAFFOLD/package.json" \
  || { fail "rename did not set package.json name to 'test-project'"; exit 1; }
# First H1 of CLAUDE.md.
first_h1="$(grep -m1 '^# ' "$SCAFFOLD/CLAUDE.md" || true)"
[ "$first_h1" = "# $TITLE" ] \
  || { fail "rename did not rewrite CLAUDE.md first H1 to '# $TITLE' (got: '$first_h1')"; exit 1; }
# common.ts siteName.
grep -qE "siteName:\s*['\"]Test Project['\"]" "$SCAFFOLD/app/languages/en/common.ts" \
  || { fail "rename did not set siteName: 'Test Project' in en/common.ts"; exit 1; }
# _index.ts heroTitle + title (both rewritten globally, including nested
# meta.title; see rename.ts replaceStringPropertyAll).
grep -qE "heroTitle:\s*['\"]Test Project['\"]" "$SCAFFOLD/app/languages/en/pages/_index.ts" \
  || { fail "rename did not set heroTitle: 'Test Project' in en/pages/_index.ts"; exit 1; }
grep -qE "title:\s*['\"]Test Project['\"]" "$SCAFFOLD/app/languages/en/pages/_index.ts" \
  || { fail "rename did not set title: 'Test Project' in en/pages/_index.ts"; exit 1; }

# Step 4; wire-statusline. --mode project so the merge writes to the
# scaffold's .claude/settings.json; never the host's ~/.claude.
run_step "wire-statusline" \
  init wire-statusline --mode project

SETTINGS="$SCAFFOLD/.claude/settings.json"
[ -f "$SETTINGS" ] \
  || { fail "wire-statusline did not produce .claude/settings.json"; exit 1; }
# JSON validity; wire-statusline does an atomic temp+rename, so a
# parse failure here points at the merge logic, not a torn write.
node -e "JSON.parse(require('node:fs').readFileSync('$SETTINGS','utf8'))" 2>/dev/null \
  || { fail "wire-statusline produced invalid JSON in .claude/settings.json"; exit 1; }
grep -q '"command": "bash .gaia/statusline/gaia-statusline.sh"' "$SETTINGS" \
  || { fail "wire-statusline did not insert canonical statusline command"; exit 1; }
grep -q '"statusLine":' "$SETTINGS" \
  || { fail "wire-statusline did not insert statusLine key"; exit 1; }

# Step 5; finalize. Removes the interceptor hook + command file, prunes
# the matching UserPromptExpansion entry from settings.json.
run_step "finalize" \
  init finalize

[ ! -f "$SCAFFOLD/.claude/hooks/intercept-init.sh" ] \
  || { fail "finalize did not remove .claude/hooks/intercept-init.sh"; exit 1; }
[ ! -f "$SCAFFOLD/.claude/commands/gaia-init.md" ] \
  || { fail "finalize did not remove .claude/commands/gaia-init.md"; exit 1; }
if grep -q "intercept-init.sh" "$SETTINGS"; then
  fail "finalize did not prune intercept-init.sh entry from .claude/settings.json"
  exit 1
fi
# Settings JSON still parses after the prune.
node -e "JSON.parse(require('node:fs').readFileSync('$SETTINGS','utf8'))" 2>/dev/null \
  || { fail "finalize produced invalid JSON in .claude/settings.json"; exit 1; }

pass "gaia init full sequence (strip-branding → configure-i18n → rename → wire-statusline → finalize) produced expected post-conditions on staged tree"
