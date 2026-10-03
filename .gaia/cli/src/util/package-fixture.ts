/**
 * Test fixtures that pin a temp tree to the transitional layout (the app at
 * the repo root) with a literal registry and descriptor. Written from the
 * built-in descriptor, never copied from the live files.
 */
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {BUILTIN_DESCRIPTOR} from './packages.js';

/** Register the frontend package at `packagePath` with the built-in descriptor. */
export const writeFrontendRegistry = (
  root: string,
  packagePath = '.'
): void => {
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'packages.json'),
    JSON.stringify([{name: 'frontend', path: packagePath}])
  );
  const descriptorDir =
    packagePath === '.' ? root : path.join(root, packagePath);

  mkdirSync(descriptorDir, {recursive: true});
  writeFileSync(
    path.join(descriptorDir, 'gaia.package.json'),
    JSON.stringify(BUILTIN_DESCRIPTOR)
  );
};
