#!/usr/bin/env bash
# 20-data-layer-query-off.sh
# distribution-runner: exclusive
#
# Adopter-flow regression for the Automatic-defaults data layer (snake_case,
# no TanStack Query) in a staged release tree:
#
#   1. Runs `/gaia-init` Step 3's CLI sequence as `.claude/commands/gaia-init.md`
#      writes it, through `configure-data-layer`, with the placeholders filled
#      from that page's Automatic defaults. `configure-data-layer` reports no
#      change and leaves every file under `frontend/` byte-identical; the domain
#      layer's `create()` keeps no `useSnakeCase`; no Query dependency appears
#      (UAT-003, UAT-017).
#   2. A frozen install, then typecheck, lint, test:ci, and build on the
#      untouched Automatic tree (UAT-017).
#   3. `scaffold service items --mocks` writes no `queries.ts` (UAT-009), and a
#      clientLoader list route bound to it scaffolds cleanly.
#   4. `scaffold route --data query` is refused, writes nothing, and names the
#      Query-on init command (UAT-010).
#   5. The local lint rule reports each imperative Query fetch, and the
#      inherited `no-restricted-properties` and `no-restricted-syntax` entries
#      still fire (UAT-012).
#   6. Storybook keeps the MSW loader and no Query decorator, and the worker
#      script ships (UAT-013).
#   7. typecheck, lint, and test:ci pass again with the scaffolded service and
#      its clientLoader page story in the tree.
#
# Layer 0: needs host pnpm and network access for the install and Chromium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"

require_command pnpm "pnpm required for the data-layer Query-off scenario (Layer 0)"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command node "node required to read the CLI's JSON output"

SECONDS=0
FIXTURES="$HERE/fixtures/data-layer"
stage_adopter_tree query-off
INIT_COMMAND_DOC="$SCAFFOLD/.claude/commands/gaia-init.md"

# --- 1. Step 3, sourced from the shipped command doc -------------------------

# The Automatic apply-defaults bullets name each Step 3 variable they set
# (`STRIP_I18N=false`, `CASING=snake`, `QUERY=false`).
automatic_default() {
  local value
  value="$(grep -oE "\`$1=[a-z]+\`" "$INIT_COMMAND_DOC" | head -n 1 | sed -E "s/^\`$1=([a-z]+)\`$/\\1/")"
  [ -n "$value" ] \
    || { fail "gaia-init.md names no Automatic default for $1"; exit 1; }
  printf '%s' "$value"
}
STRIP_I18N="$(automatic_default STRIP_I18N)"
CASING="$(automatic_default CASING)"
QUERY="$(automatic_default QUERY)"
[ "$CASING" = "snake" ] && [ "$QUERY" = "false" ] \
  || { fail "gaia-init.md Automatic defaults are CASING=$CASING QUERY=$QUERY, expected snake and false"; exit 1; }

# Step 3's command block: the first fenced bash block under "## Step 3".
awk '
  /^## Step 3:/ { in_step = 1; next }
  in_step && /^## / { exit }
  in_step && /^```bash$/ { in_block = 1; next }
  in_block && /^```$/ { exit }
  in_block { print }
' "$INIT_COMMAND_DOC" > "$WORK/step3.txt"

# Free-text identity values are the user's in every mode; these stand in.
sed -e 's/<Project Title>/Test Project/g' \
  -e 's/<comma-separated locale list>/en/g' \
  -e 's/<kebab-slug>/test-project/g' \
  -e "s/<STRIP_I18N>/$STRIP_I18N/g" \
  -e "s/<CASING>/$CASING/g" \
  -e "s/<QUERY>/$QUERY/g" \
  "$WORK/step3.txt" > "$WORK/step3-filled.txt"

if grep -q '<[A-Za-z_ -]*>' "$WORK/step3-filled.txt"; then
  fail "gaia-init.md Step 3 has a placeholder this scenario does not fill: $(grep -o '<[A-Za-z_ -]*>' "$WORK/step3-filled.txt" | head -n 1)"
  exit 1
fi
grep -q 'init configure-data-layer ' "$WORK/step3-filled.txt" \
  || { fail "gaia-init.md Step 3 does not run init configure-data-layer"; exit 1; }

DATA_LAYER_JSON=""
while IFS= read -r command_line; do
  [ -n "$command_line" ] || continue
  # Doc text is split by the shell's own quoting below, so refuse anything
  # beyond a plain `gaia init` call with quoted arguments.
  grep -Eq '^\.gaia/cli/gaia init [a-z0-9-]+( [-A-Za-z0-9 ",.]*)?$' <<<"$command_line" \
    || { fail "unexpected Step 3 line in gaia-init.md: $command_line"; exit 1; }
  eval "set -- ${command_line#.gaia/cli/gaia }"
  if [ "$2" = "configure-data-layer" ]; then
    hash_frontend "$SCAFFOLD" > "$WORK/before-data-layer.sha256"
    DATA_LAYER_JSON="$(gaia_json "configure-data-layer" "$@")"
    break
  fi
  gaia_json "$2" "$@" > /dev/null
done < "$WORK/step3-filled.txt"

[ "$(json_get "$DATA_LAYER_JSON" "parsed.changed.length")" = "0" ] \
  || { fail "configure-data-layer with the Automatic defaults changed files (got: $DATA_LAYER_JSON)"; exit 1; }
assert_frontend_unchanged "configure-data-layer with the Automatic defaults" "$WORK/before-data-layer.sha256"
if grep -q 'useSnakeCase' "$FRONTEND/app/services/gaia/api.ts"; then
  fail "the Automatic tree's create() call carries a useSnakeCase argument"
  exit 1
fi
if grep -q '@tanstack/react-query' "$FRONTEND/package.json"; then
  fail "the Automatic tree has a @tanstack/react-query dependency"
  exit 1
fi

# --- 2. Gate the Automatic tree ----------------------------------------------

log "pnpm install --frozen-lockfile"
run_logged "pnpm install --frozen-lockfile" "$WORK/install.log" pnpm -C "$SCAFFOLD" install --frozen-lockfile
log "playwright install chromium"
run_logged "playwright install chromium" "$WORK/chromium.log" install_chromium "$SCAFFOLD"

run_pnpm_steps automatic- "Automatic tree" typecheck lint test:ci build

# --- 3. Scaffold without Query -----------------------------------------------

gaia_json "scaffold service" scaffold service items \
  --endpoints get,post,put,delete --schema "id:string,displayName:string" --mocks >/dev/null
if [ -e "$FRONTEND/app/services/gaia/items/queries.ts" ]; then
  fail "scaffold service wrote queries.ts with no TanStack Query installed"
  exit 1
fi
gaia_json "route items client" scaffold route items --group _public \
  --data client --service items --shape list --action >/dev/null
[ -f "$FRONTEND/app/pages/items/tests/page.stories.tsx" ] \
  || { fail "route scaffold wrote no app/pages/items/tests/page.stories.tsx"; exit 1; }

# --- 4. The Query variant is refused -----------------------------------------

assert_scaffold_refused "scaffold route --data query" \
  "$FRONTEND/app/routes"/*items-q* "$FRONTEND/app/pages/items-q" -- \
  scaffold route items-q --group _public --data query --service items --shape list --action
grep -qF 'init configure-data-layer --query true' "$WORK/refusal-stderr.txt" \
  || { fail "the --data query refusal does not name the Query-on init command (stderr: $(cat "$WORK/refusal-stderr.txt"))"; exit 1; }

# --- 5. Lint ban and the inherited entries -----------------------------------

lint_rule_count() {
  # Counts messages from one rule in one probe's file, optionally only those
  # containing a phrase.
  node -e '
    const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const phrase = process.argv[4] || "";
    const count = report
      .filter((file) => file.filePath.endsWith("/app/" + process.argv[2]))
      .flatMap((file) => file.messages)
      .filter((message) => message.ruleId === process.argv[3] && message.message.includes(phrase))
      .length;
    process.stdout.write(String(count));
  ' "$@"
}

for probe in imperative-query-probe.ts restricted-properties-probe.ts restricted-syntax-probe.tsx; do
  cp "$FIXTURES/lint-probes/$probe" "$FRONTEND/app/$probe"
done
lint_probe_status=0
pnpm -C "$FRONTEND" exec eslint --no-cache --format json \
  app/imperative-query-probe.ts app/restricted-properties-probe.ts app/restricted-syntax-probe.tsx > "$WORK/lint-probes.json" 2> "$WORK/lint-probes.stderr" \
  || lint_probe_status=$?
for probe in imperative-query-probe.ts restricted-properties-probe.ts restricted-syntax-probe.tsx; do
  rm -f "$FRONTEND/app/$probe"
done
[ "$lint_probe_status" -ne 0 ] \
  || { fail "eslint passed the lint probes; each must fail"; exit 1; }

[ "$(lint_rule_count "$WORK/lint-probes.json" imperative-query-probe.ts local/no-imperative-query-fetch 'queryClient.query')" = "4" ] \
  || { fail "local/no-imperative-query-fetch did not report each of the four imperative fetches naming queryClient.query"; exit 1; }
[ "$(lint_rule_count "$WORK/lint-probes.json" restricted-properties-probe.ts no-restricted-properties)" -ge 1 ] \
  || { fail "Math.pow no longer fails the inherited no-restricted-properties entry"; exit 1; }
[ "$(lint_rule_count "$WORK/lint-probes.json" restricted-syntax-probe.tsx no-restricted-syntax)" -ge 1 ] \
  || { fail "a ternary rendering null no longer fails the inherited no-restricted-syntax entry"; exit 1; }

# --- 6. Storybook wiring -----------------------------------------------------

PREVIEW="$FRONTEND/.storybook/preview.ts"
grep -Eq "^import \\{mswLoader\\} from 'msw-storybook-addon/csf3';$" "$PREVIEW" \
  || { fail ".storybook/preview.ts does not import mswLoader from msw-storybook-addon/csf3"; exit 1; }
grep -q 'mswLoader()' "$PREVIEW" \
  || { fail ".storybook/preview.ts does not register mswLoader()"; exit 1; }
if grep -q 'QueryClientDecorator' "$PREVIEW"; then
  fail ".storybook/preview.ts registers a Query decorator with Query off"
  exit 1
fi
grep -q "'msw-storybook-addon'" "$FRONTEND/.storybook/main.ts" \
  || { fail ".storybook/main.ts does not list msw-storybook-addon in addons"; exit 1; }
[ -f "$FRONTEND/public/mockServiceWorker.js" ] \
  || { fail "public/mockServiceWorker.js is missing"; exit 1; }

# --- 7. Gate the scaffolded tree ---------------------------------------------

run_pnpm_steps scaffolded- "scaffolded tree" typecheck lint
run_test_ci_with_report scaffolded- "scaffolded tree" "$WORK/scaffolded-test-ci-report.json"
log "count tests in the generated clientLoader page story"
assert_stories_collect "$WORK/scaffolded-test-ci-report.json" app/pages/items/tests/page.stories.tsx

pass "Query-off data layer: Automatic init no-op, gate, scaffolds, refusal, lint ban, and Storybook wiring all green (${SECONDS}s)"
