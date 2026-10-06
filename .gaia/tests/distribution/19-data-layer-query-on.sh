#!/usr/bin/env bash
# 19-data-layer-query-on.sh
# distribution-runner: exclusive
#
# Adopter-flow regression for the opt-in TanStack Query data layer. The
# template ships without Query and without any example service or route, so
# every Query-on and generated-code behavior is proven here, in a staged
# release tree, by the adopter's own gate:
#
#   1. `gaia init configure-data-layer --casing snake --query true` opts the
#      domain layer into snake_case, writes the pinned dependency and the
#      runtime files, and leaves `app/root.tsx` and
#      `react-router.config.ts` byte-identical (UAT-002, UAT-003).
#   2. A non-frozen `pnpm install` (the lockfile gains Query), then two reruns
#      (`--query true`, `--query false`) change nothing: every file under
#      `frontend/` and the root lockfile stays byte-identical (UAT-003).
#   3. `scaffold service items --mocks` writes `queries.ts`, and four routes
#      bound to it cover every wiring variant with an action: the Query list
#      and detail pair, plus a server-loader list and a clientLoader list that
#      import the same request function (UAT-007, UAT-010, UAT-014).
#   4. A clientLoader combined with the meta-loader flag is refused and writes
#      nothing (UAT-010).
#   5. The fixtures under `fixtures/data-layer/` are copied in (SSR isolation
#      routes, accessor tests, the list-detail-redirect flow test, the service
#      tests, and the story-isolation pair), then typecheck, lint, test:ci,
#      and build all exit 0, and every generated page story collects tests
#      (UAT-002, UAT-006, UAT-008, UAT-009, UAT-010, UAT-011, UAT-013).
#   6. The built server renders the SSR fixtures and the scaffolded `/items`
#      route in one process with no cache crossing requests, and `/items`
#      server-renders its HydrateFallback only (UAT-008).
#
# Layer 0: needs host pnpm and network access for the install and Chromium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"

require_command pnpm "pnpm required for the data-layer Query-on scenario (Layer 0)"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command node "node required to read the CLI's JSON output"

SECONDS=0
FIXTURES="$HERE/fixtures/data-layer"
stage_adopter_tree query-on

# --- 1. Query on -------------------------------------------------------------

ROUTER_CONFIG_HASH="$(hash_file "$FRONTEND/react-router.config.ts")"
ROOT_HASH="$(hash_file "$FRONTEND/app/root.tsx")"

QUERY_ON_JSON="$(gaia_json "query on" init configure-data-layer --casing snake --query true)"
for expected_path in frontend/package.json frontend/app/query-client.ts frontend/app/state/index.tsx frontend/app/services/gaia/api.ts; do
  [ "$(json_get "$QUERY_ON_JSON" "parsed.changed.includes('$expected_path')")" = "true" ] \
    || { fail "configure-data-layer --casing snake --query true did not list $expected_path in changed (got: $QUERY_ON_JSON)"; exit 1; }
done
grep -q 'isSnakeCaseEnabled: true' "$FRONTEND/app/services/gaia/api.ts" \
  || { fail "configure-data-layer --casing snake did not set isSnakeCaseEnabled: true in app/services/gaia/api.ts"; exit 1; }
[ "$(json_get "$QUERY_ON_JSON" "parsed.next.includes('pnpm install')")" = "true" ] \
  || { fail "configure-data-layer --query true did not list pnpm install in next (got: $QUERY_ON_JSON)"; exit 1; }

log "pnpm install (--no-frozen-lockfile: CI defaults to frozen, and the lockfile gains TanStack Query)"
run_logged "pnpm install" "$WORK/install.log" pnpm -C "$SCAFFOLD" install --no-frozen-lockfile

QUERY_VERSION="$(node -e '
  const manifest = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write((manifest.dependencies || {})["@tanstack/react-query"] || "");
' "$FRONTEND/package.json")"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$QUERY_VERSION" \
  || { fail "@tanstack/react-query is not an exact-pinned dependency (got: '${QUERY_VERSION:-<absent>}')"; exit 1; }
grep -q 'staleTime: 30_000' "$FRONTEND/app/query-client.ts" \
  || { fail "app/query-client.ts does not set staleTime: 30_000"; exit 1; }
grep -q '<QueryProvider>' "$FRONTEND/app/state/index.tsx" \
  || { fail "app/state/index.tsx does not render QueryProvider"; exit 1; }
grep -q '<QueryClientProvider' "$FRONTEND/app/state/query-provider.tsx" \
  || { fail "app/state/query-provider.tsx does not render QueryClientProvider"; exit 1; }
[ "$(hash_file "$FRONTEND/react-router.config.ts")" = "$ROUTER_CONFIG_HASH" ] \
  || { fail "configure-data-layer --query true changed react-router.config.ts"; exit 1; }
[ "$(hash_file "$FRONTEND/app/root.tsx")" = "$ROOT_HASH" ] \
  || { fail "configure-data-layer --query true changed app/root.tsx"; exit 1; }

# --- 2. Reruns are no-ops ----------------------------------------------------

hash_frontend "$SCAFFOLD" > "$WORK/after-query-on.sha256"
for rerun_query in true false; do
  RERUN_JSON="$(gaia_json "rerun --query $rerun_query" init configure-data-layer --casing snake --query "$rerun_query")"
  [ "$(json_get "$RERUN_JSON" "parsed.changed.length")" = "0" ] \
    || { fail "configure-data-layer rerun with --query $rerun_query reported changes (got: $RERUN_JSON)"; exit 1; }
  assert_frontend_unchanged "configure-data-layer rerun with --query $rerun_query" "$WORK/after-query-on.sha256"
done

# --- 3. Scaffold the service and the four routes -----------------------------

log "playwright install chromium"
run_logged "playwright install chromium" "$WORK/chromium.log" install_chromium "$SCAFFOLD"

gaia_json "scaffold service" scaffold service items \
  --endpoints get,post,put,delete --schema "id:string,displayName:string" --mocks >/dev/null
[ -f "$FRONTEND/app/services/gaia/items/queries.ts" ] \
  || { fail "scaffold service with Query installed wrote no queries.ts"; exit 1; }

gaia_json "route items list" scaffold route items --group _public \
  --data query --service items --shape list --action >/dev/null
gaia_json "route items detail" scaffold route items --group _public \
  --data query --service items --shape detail --action >/dev/null
gaia_json "route items-server" scaffold route items-server --group _public \
  --data server --service items --shape list --action >/dev/null
gaia_json "route items-client" scaffold route items-client --group _public \
  --data client --service items --shape list --action >/dev/null

ROUTES="$FRONTEND/app/routes"
PAGES="$FRONTEND/app/pages"

assert_contains() {
  grep -Eq -- "$2" "$1" \
    || { fail "${1#"$SCAFFOLD"/} does not match /$2/ ($3)"; exit 1; }
}
assert_lacks() {
  if grep -Eq -- "$2" "$1"; then
    fail "${1#"$SCAFFOLD"/} matches /$2/ ($3)"
    exit 1
  fi
}

ONE_LINE_RENDER='^const [A-Za-z]+Route = \(\) => <[A-Za-z]+Page />;$'
for route in "_public.items.tsx" "_public.items_.\$id.tsx" "_public.items-server.tsx" "_public.items-client.tsx"; do
  assert_contains "$ROUTES/$route" "$ONE_LINE_RENDER" "default export renders the page in one line"
  assert_lacks "$ROUTES/$route" '(^|[^A-Za-z])use[A-Z][A-Za-z]*\(' "no hooks in a route module"
done

assert_contains "$ROUTES/_public.items-server.tsx" '^export const loader = ' "server variant exports loader"
assert_contains "$ROUTES/_public.items-server.tsx" '^export const action = ' "server variant exports action"
assert_lacks "$ROUTES/_public.items-server.tsx" '^export const clientLoader' "server variant exports no clientLoader"
assert_contains "$PAGES/items-server/page.tsx" 'useLoaderData<LoaderData>\(\)' "server page reads useLoaderData"

assert_contains "$ROUTES/_public.items-client.tsx" '^export const clientLoader = ' "client variant exports clientLoader"
assert_contains "$ROUTES/_public.items-client.tsx" '^export const HydrateFallback = ' "client variant exports HydrateFallback"
assert_contains "$ROUTES/_public.items-client.tsx" '^export const action = ' "client variant keeps a server action"
assert_lacks "$ROUTES/_public.items-client.tsx" '^export const loader' "client variant exports no server loader"
assert_contains "$PAGES/items-client/page.tsx" 'useLoaderData<LoaderData>\(\)' "client page reads useLoaderData"

for route in "_public.items.tsx" "_public.items_.\$id.tsx"; do
  assert_contains "$ROUTES/$route" '^export const clientLoader = ' "query variant exports clientLoader"
  assert_contains "$ROUTES/$route" 'await getQueryClient\(\)\.query\(' "query clientLoader awaits queryClient.query"
  assert_contains "$ROUTES/$route" '^export const HydrateFallback = ' "query variant exports HydrateFallback"
  assert_contains "$ROUTES/$route" '^export const clientAction = ' "query variant exports clientAction"
  assert_contains "$ROUTES/$route" 'await getQueryClient\(\)\.invalidateQueries\(' "query clientAction awaits invalidateQueries"
  assert_lacks "$ROUTES/$route" '^export const loader' "query variant exports no server loader"
  assert_contains "$ROUTES/$route" 'parseWithZod\(await request\.formData\(\), \{' "action validates with parseWithZod"
  assert_contains "$ROUTES/$route" 'schema: itemInputSchema' "action validates against itemInputSchema"
done
assert_contains "$PAGES/items/page.tsx" 'useSuspenseQuery\(itemsQuery\(\)\)' "query list page reads useSuspenseQuery"
assert_contains "$PAGES/items/id/page.tsx" 'useSuspenseQuery\(itemQuery\(' "query detail page reads useSuspenseQuery"
# shellcheck disable=SC2016 # a literal template-string regex, not a shell expansion
assert_contains "$PAGES/items/page.tsx" 'to=\{`/items/\$\{item\.id\}`\}' "list page links each item to its detail route"

# The server loader and the clientLoader import one request function.
SHARED_IMPORT="^import \\{([^}]*[ ,])?getAllItems([ ,][^}]*)?\\} from '~/services/gaia/items/requests';$"
assert_contains "$ROUTES/_public.items-server.tsx" "$SHARED_IMPORT" "server loader imports getAllItems from the service"
assert_contains "$ROUTES/_public.items-client.tsx" "$SHARED_IMPORT" "clientLoader imports getAllItems from the service"

# Wire casing: the mock handlers read JSON bodies.
assert_contains "$FRONTEND/test/mocks/items/post.ts" 'await request\.json\(\)' "post handler reads the JSON body"
assert_contains "$FRONTEND/test/mocks/items/put.ts" 'await request\.json\(\)' "put handler reads the JSON body"

GENERATED_STORIES=(
  "app/pages/items/tests/page.stories.tsx"
  "app/pages/items/id/tests/page.stories.tsx"
  "app/pages/items-server/tests/page.stories.tsx"
  "app/pages/items-client/tests/page.stories.tsx"
)
for story in ${GENERATED_STORIES[@]+"${GENERATED_STORIES[@]}"}; do
  [ -f "$FRONTEND/$story" ] || { fail "route scaffold wrote no $story"; exit 1; }
done

# --- 4. clientLoader with the meta-loader flag is refused --------------------

assert_scaffold_refused "scaffold route --data client --loader" \
  "$ROUTES"/*items-m* "$PAGES/items-m" -- \
  scaffold route items-m --group _public --data client --service items --shape list --loader

# --- 5. Fixtures and the gate ------------------------------------------------

cp "$FIXTURES"/ssr/routes/*.tsx "$FRONTEND/app/routes/"
for fixture_page in ssr-seed ssr-read ssr-query; do
  mkdir -p "$PAGES/$fixture_page"
  cp "$FIXTURES/ssr/pages/$fixture_page/"* "$PAGES/$fixture_page/"
done
cp "$FIXTURES/query-client/query-client.test.ts" \
  "$FIXTURES/query-client/query-client.browser.test.tsx" \
  "$FIXTURES/service/items-service.test.ts" \
  "$FIXTURES/service/items-base-url.test.tsx" \
  "$FIXTURES/flow/items-flow.test.tsx" \
  "$FRONTEND/test/"
mkdir -p "$FRONTEND/app/components/item-names/tests"
cp "$FIXTURES/story-isolation/item-names/index.tsx" "$FRONTEND/app/components/item-names/"
cp "$FIXTURES/story-isolation/item-names/tests/"*.stories.tsx "$FRONTEND/app/components/item-names/tests/"

index_server_files="$(find "$FRONTEND/app/services" -name 'index.server.ts')"
if [ -n "$index_server_files" ]; then
  fail "an index.server.ts exists under app/services"
  exit 1
fi

run_pnpm_steps "" "" typecheck lint
run_test_ci_with_report "" "" "$WORK/test-ci-report.json"
run_pnpm_steps "" "" build

log "count tests per generated page story"
assert_stories_collect "$WORK/test-ci-report.json" ${GENERATED_STORIES[@]+"${GENERATED_STORIES[@]}"}

# --- 6. Server render isolation ----------------------------------------------

SSR_CHECK="$FIXTURES/ssr/check-ssr-isolation.mjs"
run_logged "SSR isolation (fixture routes)" "$WORK/ssr-fixtures.log" \
  node "$SSR_CHECK" --frontend "$FRONTEND" \
  --seed /ssr-seed --read /ssr-read --client-loader /ssr-query \
  --fallback-marker hydrate-fallback-rendered --forbidden query-data-rendered \
  --title 'Query probe loading'
# The scaffolded Query route: its HydrateFallback carries the `Loading` status
# and the `Items` title; the field label renders only in the page itself.
run_logged "SSR isolation (scaffolded /items)" "$WORK/ssr-items.log" \
  node "$SSR_CHECK" --frontend "$FRONTEND" \
  --seed /ssr-seed --read /ssr-read --client-loader /items \
  --fallback-marker Loading --forbidden 'Display name' --title Items

pass "Query-on data layer: init, reruns, service and route scaffolds, refusal, gate, and SSR isolation all green (${SECONDS}s)"
