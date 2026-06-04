/* eslint-disable no-bitwise -- RFC 4122 §4.4 UUIDv4 variant nibble derivation
   uses bitwise OR/AND on hex nibbles; no readable alternative. */
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import type {StorageRoots} from './paths.js';

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

/**
 * Format 16 hex bytes as a UUIDv4 string with the proper version (4) and
 * variant (RFC 4122) bits set per RFC 4122 §4.4.
 */
const formatAsUuidV4 = (hex32: string): string => {
  // Force version nibble to 4 (offset 12).
  // Force variant nibble to 8/9/a/b (offset 16).
  const version = '4';
  const variantMask = 0x8;
  const variantBits = Number.parseInt(hex32.charAt(16), 16) & 0x3;
  const variant = (variantMask | variantBits).toString(16);

  return `${hex32.slice(0, 8)}-${hex32.slice(8, 12)}-${version}${hex32.slice(13, 16)}-${variant}${hex32.slice(17, 20)}-${hex32.slice(20, 32)}`;
};

const deriveProjectId = (repoRootPath: string): string => {
  const hash = createHash('sha256').update(repoRootPath).digest('hex');

  return formatAsUuidV4(hash.slice(0, 32));
};

/**
 * Recover the repo root from a `projectIdPath`. The path always has the
 * shape `<repoRoot>/.gaia/local/.project-id`, so the root is three
 * directory levels up. `path.dirname` handles both `/` and `\` separators,
 * so this is cross-platform (a regex on `/` would break on Windows).
 */
export const repoRootFromProjectIdPath = (projectIdPath: string): string =>
  path.dirname(path.dirname(path.dirname(projectIdPath)));

/**
 * Read or generate `.gaia/local/.project-id` at the repo root.
 * UUIDv4 derived from sha256(repo_root_path); take first 16 bytes; format per RFC 4122.
 * Mode 644.
 * Idempotent: subsequent reads return the existing line.
 */
export const readOrCreateProjectId = (roots: StorageRoots): string => {
  const filePath = roots.projectIdPath;

  if (existsSync(filePath)) {
    const existing = readFileSync(filePath, 'utf8').trim();

    if (UUID_RE.test(existing)) {
      return existing;
    }
    // Malformed: regenerate from canonical derivation.
  }

  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  // The repoRoot the projectIdPath was resolved from is the only stable input
  // for the derivation. Recover it from the path; projectIdPath ends in
  // `<repoRoot>/.gaia/local/.project-id`, so the root is three levels up.
  const repoRoot = repoRootFromProjectIdPath(filePath);
  const id = deriveProjectId(repoRoot);
  writeFileSync(filePath, `${id}\n`, {mode: 0o644});

  return id;
};
