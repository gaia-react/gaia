// The Node reader of the package registry and descriptors. One of three
// implementations of one contract: the bash twin is
// `.claude/hooks/lib/gaia-packages.sh`, the other is the CLI's TypeScript
// reader. A shared conformance corpus is the oracle all three must satisfy,
// error message text included, so a change to a reason string here changes it
// in the other two.
//
// WHAT IT READS. `.gaia/packages.json` lists the packages (name and repo-relative
// path); each package carries `<path>/gaia.package.json`, a descriptor of
// package-relative globs that harness guards use to recognise a package's own
// files instead of hard-coding `app/`. The harness root is implicit and never
// registered.
//
// FAIL-CLOSED. A registry that is absent is the built-in default (frontend at
// `frontend`), never "nothing in scope". A registry that is present and
// malformed, or a descriptor that is missing or invalid, returns an error and
// never a partial answer: callers refuse on it.
//
// GLOB DIALECT: `**/` is zero or more whole directories, a trailing `/**`
// is everything beneath, `*` is any run excluding `/`, `?` is one character
// excluding `/`, `{a,b}` is non-nested alternation, every other character is
// literal. The compiler is a fixed sequence of substitutions through private
// control-character sentinels so a single `*` is never re-read as half of `**`;
// descriptor strings carrying control characters are refused before compiling,
// which is what keeps those sentinels private.

import fs from 'node:fs';
import path from 'node:path';

export const BUILTIN_REGISTRY = Object.freeze([
  Object.freeze({name: 'frontend', path: 'frontend'}),
]);

export const BUILTIN_DESCRIPTOR = Object.freeze({
  schemaVersion: 1,
  name: 'frontend',
  globs: Object.freeze({
    tddUnitTests: Object.freeze(['app/**/*.test.ts', 'app/**/*.test.tsx']),
    tddStrictCandidates: Object.freeze([
      'app/utils/**',
      'app/services/**',
      'app/hooks/**',
      'app/components/**/*.ts',
    ]),
    emergentTests: Object.freeze([
      'app/components/**/*.test.ts',
      'app/components/**/*.test.tsx',
      '.playwright/**/*.spec.ts',
      '.playwright/**/*.spec.tsx',
      '.playwright/**/*.test.ts',
      '.playwright/**/*.test.tsx',
    ]),
    selfHealRefuse: Object.freeze([
      '.claude/**',
      'CLAUDE.md',
      'gaia.package.json',
      'test/**',
      '.playwright/**',
      '.storybook/**',
      'app/**/tests/**',
      'app/**/*.test.ts',
      'app/**/*.test.tsx',
      'app/**/*.stories.tsx',
      'package.json',
      'tsconfig*.json',
      '*.config.ts',
      '*.config.mts',
      '*.config.mjs',
      '*.config.cjs',
      '*.config.js',
      'Dockerfile',
      'Dockerfile.dockerignore',
      '.*',
    ]),
    preCommitSource: Object.freeze([
      'app/**',
      'test/**',
      '.storybook/**',
      '.playwright/**',
    ]),
    doctorConfigs: Object.freeze(['doctor.config.*', 'react-doctor.config.*']),
    dependencyManifests: Object.freeze(['package.json']),
  }),
  wiki: Object.freeze({
    sourcePaths: Object.freeze(['app/']),
    inventoryPaths: Object.freeze([
      'app/components/',
      'app/hooks/',
      'app/pages/',
      'app/services/',
    ]),
    flowPaths: Object.freeze([
      'app/middleware/',
      'app/routes.ts',
      'app/i18n.ts',
      'app/sessions.server/',
    ]),
  }),
});

const GLOB_KEYS = [
  'tddUnitTests',
  'tddStrictCandidates',
  'emergentTests',
  'selfHealRefuse',
  'preCommitSource',
  'doctorConfigs',
  'dependencyManifests',
];
const WIKI_KEYS = ['sourcePaths', 'inventoryPaths', 'flowPaths'];

const REGISTRY_FILE = '.gaia/packages.json';
const DESCRIPTOR_NAME = 'gaia.package.json';
const NAME_PATTERN = /^[a-z][a-z0-9-]*$/;
const PATH_PATTERN = /^(\.|[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)*)$/;
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/;

const registryError = (reason) => ({
  ok: false,
  code: 'REGISTRY_MALFORMED',
  message: `gaia-packages: ${REGISTRY_FILE} is malformed${reason === '' ? '' : `: ${reason}`}. Next step: fix ${REGISTRY_FILE} so it is a JSON array of {"name","path"} entries, or delete it to use the built-in default.`,
});

const descriptorError = (file, state, reason) => {
  const nextStep =
    state === 'missing' ?
      `restore ${file} from the GAIA release, or correct the path in ${REGISTRY_FILE}`
    : `restore ${file} from the GAIA release, or correct the field it names`;
  const status = state === 'invalid' ? `invalid: ${reason}` : state;

  return {
    ok: false,
    code: 'DESCRIPTOR_INVALID',
    message: `gaia-packages: ${file} is ${status}. Next step: ${nextStep}.`,
  };
};

const isPlainObject = (value) =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const isCleanString = (value) =>
  typeof value === 'string' && value !== '' && !CONTROL_CHARACTER.test(value);

const descriptorFileFor = (packagePath) =>
  packagePath === '.' ? DESCRIPTOR_NAME : `${packagePath}/${DESCRIPTOR_NAME}`;

// Returns the reason a parsed registry is malformed, or null when it is sound.
const registryReason = (value) => {
  if (!Array.isArray(value)) {
    return 'not a JSON array';
  }
  for (const [index, entry] of value.entries()) {
    if (!isPlainObject(entry)) {
      return `entry ${index} is not an object`;
    }
    if (typeof entry.name !== 'string' || !NAME_PATTERN.test(entry.name)) {
      return `entry ${index} name is invalid`;
    }
    if (typeof entry.path !== 'string' || !PATH_PATTERN.test(entry.path)) {
      return `entry ${index} path is invalid`;
    }
  }
  const names = new Set();
  const paths = new Set();
  for (const [index, entry] of value.entries()) {
    if (names.has(entry.name)) {
      return `entry ${index} name is a duplicate`;
    }
    if (paths.has(entry.path)) {
      return `entry ${index} path is a duplicate`;
    }
    names.add(entry.name);
    paths.add(entry.path);
  }

  return null;
};

// Returns the reason a parsed descriptor is invalid, or null when it is sound.
const descriptorReason = (value, expectedName) => {
  if (!isPlainObject(value)) {
    return 'not a JSON object';
  }
  if (value.schemaVersion !== 1) {
    return 'schemaVersion must be 1';
  }
  if (value.name !== expectedName) {
    return `name must be "${expectedName}"`;
  }
  if (!isPlainObject(value.globs)) {
    return 'globs must be an object';
  }
  for (const key of GLOB_KEYS) {
    const list = value.globs[key];
    if (
      !Array.isArray(list) ||
      list.length === 0 ||
      !list.every(isCleanString)
    ) {
      return `globs.${key} must be a non-empty array of non-empty strings without control characters`;
    }
  }
  if (!isPlainObject(value.wiki)) {
    return 'wiki must be an object';
  }
  for (const key of WIKI_KEYS) {
    const list = value.wiki[key];
    if (!Array.isArray(list) || !list.every(isCleanString)) {
      return `wiki.${key} must be an array of strings without control characters`;
    }
  }

  return null;
};

// 'absent' | 'unreadable' | {text}. A dangling symlink counts as present and
// unreadable, never as absent, so a broken link cannot select the default.
const readFileState = (file) => {
  try {
    fs.lstatSync(file);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return 'absent';
    }

    return 'unreadable';
  }
  try {
    return {text: fs.readFileSync(file, 'utf8')};
  } catch {
    return 'unreadable';
  }
};

const parseJson = (text) => {
  try {
    return {value: JSON.parse(text)};
  } catch {
    return null;
  }
};

export function loadPackages(repoRoot) {
  const registryRead = readFileState(path.join(repoRoot, REGISTRY_FILE));
  let source = 'registry';
  let entries;
  if (registryRead === 'absent') {
    source = 'builtin';
    entries = BUILTIN_REGISTRY;
  } else {
    const parsed =
      registryRead === 'unreadable' ? null : parseJson(registryRead.text);
    if (parsed === null) {
      return registryError('');
    }
    const reason = registryReason(parsed.value);
    if (reason !== null) {
      return registryError(reason);
    }
    entries = parsed.value;
  }

  const packages = [];
  for (const entry of entries) {
    if (source === 'builtin') {
      packages.push({
        name: entry.name,
        path: entry.path,
        descriptor: BUILTIN_DESCRIPTOR,
      });
      continue;
    }
    const file = descriptorFileFor(entry.path);
    const read = readFileState(path.join(repoRoot, file));
    if (read === 'absent') {
      return descriptorError(file, 'missing', '');
    }
    const parsed = read === 'unreadable' ? null : parseJson(read.text);
    if (parsed === null) {
      return descriptorError(file, 'malformed', '');
    }
    const reason = descriptorReason(parsed.value, entry.name);
    if (reason !== null) {
      return descriptorError(file, 'invalid', reason);
    }
    packages.push({
      name: entry.name,
      path: entry.path,
      descriptor: parsed.value,
    });
  }

  return {ok: true, source, packages};
}

// The ERE-grammar body of a glob (no anchors). Sentinels: \u0001 `**/`,
// \u0002 `**`, \u0003 `*`, \u0004 `?`, \u0005 and \u0006 a brace group's
// parentheses, \u0007 its alternation bar.
export function globToBody(glob) {
  return glob
    .replace(/[\\.+^$()[\]|]/g, String.raw`\$&`)
    .replaceAll('**/', '\u0001')
    .replaceAll('**', '\u0002')
    .replaceAll('*', '\u0003')
    .replaceAll('?', '\u0004')
    .replace(
      /\{([^{}]+)\}/g,
      (_match, inner) => `\u0005${inner.replaceAll(',', '\u0007')}\u0006`
    )
    .replace(/[{}]/g, String.raw`\$&`)
    .replaceAll('\u0001', '(.*/)?')
    .replaceAll('\u0002', '.*')
    .replaceAll('\u0003', '[^/]*')
    .replaceAll('\u0004', '[^/]')
    .replaceAll('\u0005', '(')
    .replaceAll('\u0006', ')')
    .replaceAll('\u0007', '|');
}

export function globToRegExp(glob) {
  return new RegExp(`^${globToBody(glob)}$`);
}

export function joinGlob(packagePath, glob) {
  return packagePath === '.' ? glob : `${packagePath}/${glob}`;
}

export function repoRegExps(packages, key) {
  return packages.flatMap((entry) =>
    (entry.descriptor.globs[key] ?? []).map((glob) =>
      globToRegExp(joinGlob(entry.path, glob))
    )
  );
}

// The package whose directory is the longest prefix of the path; a package at
// `.` owns every path no deeper package claims.
export function packageForPath(packages, repoRelativePath) {
  let best = null;
  let bestLength = -1;
  for (const entry of packages) {
    const prefixLength = entry.path === '.' ? 0 : entry.path.length;
    const owns =
      entry.path === '.' ||
      repoRelativePath === entry.path ||
      repoRelativePath.startsWith(`${entry.path}/`);
    if (owns && prefixLength > bestLength) {
      best = entry;
      bestLength = prefixLength;
    }
  }

  return best;
}
