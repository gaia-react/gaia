#!/usr/bin/env bash
# 10-gaia-scaffold-templates.sh
#
# Adopter-flow regression: runs all four `gaia scaffold <kind>` subcommands
# (component, hook, route, service) against a writable copy of the staged
# release tree, asserting real post-conditions rather than just exit 0.
#
# Why it exists: the scaffolders render from `.gaia/cli/templates/`, a
# tracked source directory `pnpm bundle` copies alongside the bundled
# binary (see .gaia/cli/package.json bundle:adopter). If release-exclude
# ever starts stripping any of it, `loadTemplate`/`renderTemplate` throw at
# runtime; Layers 0+1+2 stay green (they never invoke `gaia scaffold`) and
# only this scenario catches the drift.
#
# Asserts, per kind (post-conditions on the staged tree):
#   component  app/components/<Name>/index.tsx + tests/index.test.tsx +
#              tests/index.stories.tsx; each written and contains <Name>.
#   hook       app/hooks/<name>.ts + app/hooks/tests/<name>.test.ts;
#              each written and contains <name>.
#   route      app/routes/<group>/<name>.tsx + three files under
#              app/pages/<Group>/<Name>Page/(index.tsx|tests/*); each
#              written.
#   service    app/services/gaia/<name>/{parsers,types,requests,urls,index}.ts;
#              each written.
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); file-level transforms only, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for adopter-flow scaffold copy"

STAGING="$(mktemp -d -t gaia-dist-scaffold-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-scaffold-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Copy staging into a writable scaffold (the scaffolders write new files).
rsync -a "$STAGING"/ "$SCAFFOLD"/

GAIA="$SCAFFOLD/.gaia/cli/gaia"

# Pre-conditions on the staged tree: the shipped template source and the
# target directories the scaffolders write into. Each guarantees one of
# the subcommands has what it needs; a missing entry points at
# release-exclude drift rather than a confusing downstream failure.
[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }
for kind in component hook route service; do
  [ -d "$SCAFFOLD/.gaia/cli/templates/$kind" ] \
    || { fail "staged tree missing .gaia/cli/templates/$kind (scaffold template source)"; exit 1; }
done
[ -d "$SCAFFOLD/app/components" ] \
  || { fail "staged tree missing app/components (scaffold component target)"; exit 1; }
[ -d "$SCAFFOLD/app/hooks" ] \
  || { fail "staged tree missing app/hooks (scaffold hook target)"; exit 1; }
[ -d "$SCAFFOLD/app/routes/_public+" ] \
  || { fail "staged tree missing app/routes/_public+ (scaffold route target)"; exit 1; }

# Each invocation runs from inside $SCAFFOLD via a subshell so the CLI's
# `process.cwd()` (and the hook/route scaffolders' `git rev-parse
# --show-toplevel` fallback) resolves to the scaffold root without
# mutating the parent scenario's pwd.
run_scaffold() {
  local label="$1"; shift
  local stdout
  stdout="$(cd "$SCAFFOLD" && "$GAIA" scaffold "$@" 2>/dev/null)" || {
    log "gaia scaffold $* exited non-zero; rerunning with stderr:"
    ( cd "$SCAFFOLD" && "$GAIA" scaffold "$@" ) || :
    fail "gaia scaffold $* exited non-zero on staged tree (kind: $label)"
    exit 1
  }
  printf '%s' "$stdout"
}

assert_written() {
  local relPath="$1"
  local needle="$2"
  local absPath="$SCAFFOLD/$relPath"

  [ -f "$absPath" ] \
    || { fail "expected file not written: $relPath"; exit 1; }
  grep -q "$needle" "$absPath" \
    || { fail "$relPath missing expected content '$needle'"; exit 1; }
}

# --- component ---------------------------------------------------------
COMPONENT_NAME="GaiaDistScaffoldWidget"
run_scaffold "component" component "$COMPONENT_NAME" --json >/dev/null
assert_written "app/components/$COMPONENT_NAME/index.tsx" "$COMPONENT_NAME"
assert_written "app/components/$COMPONENT_NAME/tests/index.test.tsx" "$COMPONENT_NAME"
assert_written "app/components/$COMPONENT_NAME/tests/index.stories.tsx" "$COMPONENT_NAME"

# --- hook ----------------------------------------------------------------
HOOK_NAME="useGaiaDistScaffoldThing"
run_scaffold "hook" hook "$HOOK_NAME" --json >/dev/null
assert_written "app/hooks/$HOOK_NAME.ts" "$HOOK_NAME"
assert_written "app/hooks/tests/$HOOK_NAME.test.ts" "$HOOK_NAME"

# --- route -----------------------------------------------------------
# route.tsx contains {{pageName}} (via import + JSX), not the kebab route
# name itself: {{routeFile}} (the kebab name) only appears behind the
# `needsRouteType` section, which --loader/--action (both unset here) gate.
ROUTE_NAME="gaia-dist-scaffold"
PAGE_NAME="GaiaDistScaffoldPage"
run_scaffold "route" route "$ROUTE_NAME" --group "_public+" --json >/dev/null
assert_written "app/routes/_public+/$ROUTE_NAME.tsx" "$PAGE_NAME"
assert_written "app/pages/Public/$PAGE_NAME/index.tsx" "$PAGE_NAME"
assert_written "app/pages/Public/$PAGE_NAME/tests/index.test.tsx" "$PAGE_NAME"
assert_written "app/pages/Public/$PAGE_NAME/tests/index.stories.tsx" "$PAGE_NAME"

# --- service ---------------------------------------------------------
# Only urls.ts.tmpl embeds the raw {{name}}; the rest derive from
# {{singular}}/{{plural}}/{{Singular}}/{{Plural}}, so each file is checked
# against what it actually renders rather than the raw service name.
SERVICE_NAME="gaia-dist-scaffold-thing"
run_scaffold "service" service "$SERVICE_NAME" --endpoints "get" --schema "id:string" --json >/dev/null
assert_written "app/services/gaia/$SERVICE_NAME/parsers.ts" "Schema = z.object"
assert_written "app/services/gaia/$SERVICE_NAME/types.ts" "z.infer"
assert_written "app/services/gaia/$SERVICE_NAME/requests.ts" "export const getAll"
assert_written "app/services/gaia/$SERVICE_NAME/urls.ts" "$SERVICE_NAME"
assert_written "app/services/gaia/$SERVICE_NAME/index.ts" "export"

pass "gaia scaffold component/hook/route/service produced expected post-conditions on staged tree"
