// Server-renders three routes of a built frontend through React Router's own
// request handler and asserts the TanStack Query SSR contract:
//
//   1. seed route: its page writes a value into the provider's QueryClient
//      during render, and the HTML shows it;
//   2. read route, requested next in the same process: the HTML shows the
//      empty marker and not the seed value, so no client outlived request 1;
//   3. clientLoader route: the HTML is the HydrateFallback (its marker and its
//      <title>) and none of the query's rendered data, so the page and its
//      useSuspenseQuery never ran on the server.
//
// It runs the real `build/server/index.js` after `pnpm build`, so it proves
// what production does, not what a test renderer does.
//
// Usage:
//   node check-ssr-isolation.mjs --frontend <dir> --seed <path> --read <path>
//     --client-loader <path> --fallback-marker <text> --forbidden <text>
//     [--title <text>] [--seed-value <text>] [--empty-marker <text>]
//
// Exit 0 when every assertion holds, 1 when one fails, 2 on a usage error.
import {existsSync} from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';
import process from 'node:process';
import {pathToFileURL} from 'node:url';
import {parseArgs} from 'node:util';

const usage = (message) => {
  console.error(`check-ssr-isolation: ${message}`);
  process.exit(2);
};

let parsed;

try {
  parsed = parseArgs({
    options: {
      'client-loader': {type: 'string'},
      'empty-marker': {default: 'isolation-cache-empty', type: 'string'},
      'fallback-marker': {type: 'string'},
      forbidden: {type: 'string'},
      frontend: {type: 'string'},
      read: {type: 'string'},
      seed: {type: 'string'},
      'seed-value': {default: 'isolation-seed-value', type: 'string'},
      title: {type: 'string'},
    },
    strict: true,
  });
} catch (error) {
  usage(error.message);
}

const {values} = parsed;

for (const required of [
  'frontend',
  'seed',
  'read',
  'client-loader',
  'fallback-marker',
  'forbidden',
]) {
  if (!values[required]) usage(`--${required} is required`);
}

const frontendDirectory = path.resolve(values.frontend);
const serverBuildPath = path.join(
  frontendDirectory,
  'build',
  'server',
  'index.js'
);

if (!existsSync(serverBuildPath)) {
  usage(`no server build at ${serverBuildPath}; run pnpm build first`);
}

// env.server.ts parses these at import time; a real deployment supplies them.
const environmentDefaults = {
  API_URL: 'http://localhost:1',
  NODE_ENV: 'production',
  SESSION_SECRET: 'ssr-isolation-check-secret',
  SITE_URL: 'http://localhost',
  npm_package_version: '0.0.0',
};

for (const [key, value] of Object.entries(environmentDefaults)) {
  process.env[key] ??= value;
}

// Resolve react-router from the frontend, not from this script's folder, so
// the handler and the build share one module instance (its context classes
// are compared by identity).
const requireFromFrontend = createRequire(
  path.join(frontendDirectory, 'package.json')
);
const {createRequestHandler} = await import(
  pathToFileURL(requireFromFrontend.resolve('react-router')).href
);
const build = await import(pathToFileURL(serverBuildPath).href);
const handleRequest = createRequestHandler(build, 'production');

const render = async (routePath) => {
  const response = await handleRequest(
    new Request(new URL(routePath, 'http://localhost').href)
  );

  return {html: await response.text(), status: response.status};
};

const failures = [];

const check = (condition, message) => {
  if (!condition) failures.push(message);
};

const seed = await render(values.seed);

check(seed.status === 200, `seed ${values.seed}: status ${seed.status}`);
check(
  seed.html.includes(values['seed-value']),
  `seed ${values.seed}: HTML lacks the seed value "${values['seed-value']}"`
);

const read = await render(values.read);

check(read.status === 200, `read ${values.read}: status ${read.status}`);
check(
  read.html.includes(values['empty-marker']),
  `read ${values.read}: HTML lacks the empty marker "${values['empty-marker']}"`
);
check(
  !read.html.includes(values['seed-value']),
  `read ${values.read}: HTML contains the seed value "${values['seed-value']}", so a QueryClient outlived the seed request`
);

const clientLoader = await render(values['client-loader']);
const titleMatch = /<title>([^<]*)<\/title>/u.exec(clientLoader.html);

check(
  clientLoader.status === 200,
  `clientLoader ${values['client-loader']}: status ${clientLoader.status}`
);
check(
  clientLoader.html.includes(values['fallback-marker']),
  `clientLoader ${values['client-loader']}: HTML lacks the fallback marker "${values['fallback-marker']}"`
);
check(
  values.title === undefined ?
    titleMatch !== null && titleMatch[1].trim() !== ''
  : titleMatch?.[1] === values.title,
  `clientLoader ${values['client-loader']}: HTML lacks the fallback <title>${values.title === undefined ? '' : ` "${values.title}"`} (found: ${titleMatch ? `"${titleMatch[1]}"` : 'none'})`
);
check(
  !clientLoader.html.includes(values.forbidden),
  `clientLoader ${values['client-loader']}: HTML contains "${values.forbidden}", so the page rendered on the server`
);

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  process.exit(1);
}

console.log(
  `PASS seed ${values.seed}, read ${values.read}, clientLoader ${values['client-loader']}`
);
