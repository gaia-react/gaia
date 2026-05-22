/**
 * Install / remove / assert operations for the mentorship-display rule's
 * projection into per-machine user memory.
 *
 * Targets `<home>/.claude/projects/<slug>/memory/`:
 *   - `feedback_mentorship_display.md` — the rule body (frontmatter + content).
 *   - `MEMORY.md` — index file. We add or remove a single pointer line.
 *
 * The bundled `display-rule.ts` module is the source of truth; these
 * helpers read from it so the file always reflects the binary's text.
 *
 * `install` is idempotent: it overwrites the body file (so accidental
 * edits self-heal on re-install) and adds the index line only if absent.
 * `remove` is idempotent: it deletes the body file if present and drops
 * the index line if present, leaving sibling lines untouched.
 *
 * `MEMORY.md` is treated as plain text. The index line is identified by
 * exact match against `DISPLAY_RULE_INDEX_LINE`.
 */
import {existsSync, mkdirSync, readFileSync, unlinkSync} from 'node:fs';
import path from 'node:path';
import type {StorageRoots} from '../storage/index.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  DISPLAY_RULE_BODY,
  DISPLAY_RULE_FILE_NAME,
  DISPLAY_RULE_INDEX_LINE,
} from './display-rule.js';

const MEMORY_INDEX_FILE = 'MEMORY.md';

const ensureMemoryDirectory = (memoryDirectory: string): void => {
  if (existsSync(memoryDirectory)) return;
  mkdirSync(memoryDirectory, {mode: 0o755, recursive: true});
};

const readIndex = (indexPath: string): string => {
  if (!existsSync(indexPath)) return '';

  return readFileSync(indexPath, 'utf8');
};

const indexContainsLine = (indexBody: string, line: string): boolean => {
  if (indexBody === '') return false;
  const lines = indexBody.split('\n');

  return lines.includes(line);
};

const appendIndexLine = (indexBody: string, line: string): string => {
  if (indexBody === '') return `${line}\n`;
  // Ensure the existing body ends with exactly one newline before appending.
  const trimmedTrailing = indexBody.replace(/\n+$/u, '');

  return `${trimmedTrailing}\n${line}\n`;
};

const removeIndexLine = (indexBody: string, line: string): string => {
  if (indexBody === '') return '';
  const lines = indexBody.split('\n');
  const filtered = lines.filter((current) => current !== line);
  // Preserve the trailing newline pattern of the original — if the file
  // ended in a newline, keep the trailing empty element; if not, drop it.
  if (filtered.join('\n') === indexBody) return indexBody;

  // Rebuild with a single trailing newline if the original had any.
  const hadTrailingNewline = indexBody.endsWith('\n');
  const rebuilt = filtered
    .filter((current, index, all) => {
      // Drop the empty trailing element so we can re-add a single newline.
      if (index === all.length - 1 && current === '') return false;

      return true;
    })
    .join('\n');

  if (rebuilt === '') return '';

  return hadTrailingNewline ? `${rebuilt}\n` : rebuilt;
};

/**
 * Write the mentorship-display rule into user memory. Idempotent.
 *
 * Always overwrites `feedback_mentorship_display.md` with the bundled
 * canonical text (so manual edits to the file self-heal). Only adds the
 * `MEMORY.md` pointer line if absent.
 */
export const installDisplayRule = (roots: StorageRoots): void => {
  ensureMemoryDirectory(roots.memoryDir);

  const bodyPath = path.join(roots.memoryDir, DISPLAY_RULE_FILE_NAME);
  atomicWriteFileSync(bodyPath, DISPLAY_RULE_BODY);

  const indexPath = path.join(roots.memoryDir, MEMORY_INDEX_FILE);
  const indexBody = readIndex(indexPath);

  if (indexContainsLine(indexBody, DISPLAY_RULE_INDEX_LINE)) return;

  const next = appendIndexLine(indexBody, DISPLAY_RULE_INDEX_LINE);
  atomicWriteFileSync(indexPath, next);
};

/**
 * Remove the mentorship-display rule from user memory. Idempotent.
 *
 * Deletes `feedback_mentorship_display.md` if present. Drops the
 * `MEMORY.md` pointer line if present, preserving sibling lines.
 */
export const removeDisplayRule = (roots: StorageRoots): void => {
  if (!existsSync(roots.memoryDir)) return;

  const bodyPath = path.join(roots.memoryDir, DISPLAY_RULE_FILE_NAME);

  if (existsSync(bodyPath)) {
    unlinkSync(bodyPath);
  }

  const indexPath = path.join(roots.memoryDir, MEMORY_INDEX_FILE);

  if (!existsSync(indexPath)) return;

  const indexBody = readFileSync(indexPath, 'utf8');

  if (!indexContainsLine(indexBody, DISPLAY_RULE_INDEX_LINE)) return;

  const next = removeIndexLine(indexBody, DISPLAY_RULE_INDEX_LINE);

  if (next === '') {
    unlinkSync(indexPath);

    return;
  }

  atomicWriteFileSync(indexPath, next);
};

/**
 * Result of an `assertDisplayRule` invocation.
 *
 * Useful for the session-start hook to log whether self-heal kicked in.
 */
export type AssertDisplayRuleOutcome = {
  body_written: boolean;
  index_line_added: boolean;
};

/**
 * Re-assert the rule's presence in memory. Returns flags describing what
 * was changed so callers can log whether self-heal kicked in.
 *
 * Always overwrites the body file (cheap, deterministic). Only writes
 * `MEMORY.md` if the line is missing.
 */
export const assertDisplayRule = (
  roots: StorageRoots
): AssertDisplayRuleOutcome => {
  ensureMemoryDirectory(roots.memoryDir);

  const bodyPath = path.join(roots.memoryDir, DISPLAY_RULE_FILE_NAME);
  const previousBody =
    existsSync(bodyPath) ? readFileSync(bodyPath, 'utf8') : null;
  const bodyChanged = previousBody !== DISPLAY_RULE_BODY;

  if (bodyChanged) {
    atomicWriteFileSync(bodyPath, DISPLAY_RULE_BODY);
  }

  const indexPath = path.join(roots.memoryDir, MEMORY_INDEX_FILE);
  const indexBody = readIndex(indexPath);
  const lineMissing = !indexContainsLine(indexBody, DISPLAY_RULE_INDEX_LINE);

  if (lineMissing) {
    const next = appendIndexLine(indexBody, DISPLAY_RULE_INDEX_LINE);
    atomicWriteFileSync(indexPath, next);
  }

  return {
    body_written: bodyChanged,
    index_line_added: lineMissing,
  };
};
