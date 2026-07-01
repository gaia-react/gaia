/**
 * Detects which finding classes a promoted rule already covers.
 *
 * An approved policy-memory rule under `.claude/rules/` carries a provenance
 * marker naming the class it was promoted from:
 *
 *   <!-- gaia-harden: promoted from recurring finding_class <class>; ... -->
 *
 * v1 keys coverage on that marker alone: a class with a marker present is
 * already enforced, so the tally drops it. Reading rule bodies is cheap and the
 * marker is a single line, so this scans every `*.md` under the rules dir.
 */
import {readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {MARKER_PREFIX} from './marker.js';

const escapeRegExp = (value: string): string =>
  value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Prefix-bound / tail-agnostic on purpose: derived from the shared
// `MARKER_PREFIX` constant, then followed by the class-capture tail. It matches
// any copy that keeps the frozen prefix regardless of the trailing wording, so
// this binder never silently drifts from `/gaia-audit`'s full-text match.
const MARKER_RE = new RegExp(
  `${escapeRegExp(MARKER_PREFIX)}\\s+(\\S+?)\\s*(?:;|-->)`,
  'g'
);

export const coveredClassesFromRules = (rulesDir: string): Set<string> => {
  const covered = new Set<string>();

  let entries: string[];

  try {
    entries = readdirSync(rulesDir).filter((name) => name.endsWith('.md'));
  } catch {
    return covered;
  }

  for (const name of entries) {
    let body: string;

    try {
      body = readFileSync(path.join(rulesDir, name), 'utf8');
    } catch {
      continue;
    }

    for (const match of body.matchAll(MARKER_RE)) {
      const findingClass = match[1];

      if (findingClass !== undefined && findingClass.length > 0) {
        covered.add(findingClass);
      }
    }
  }

  return covered;
};
