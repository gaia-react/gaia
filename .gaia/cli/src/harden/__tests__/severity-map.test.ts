import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {SEVERITIES} from '../parse-findings-block.js';
import {SEVERITY_BY_GRADING} from '../severity-map.js';

/**
 * UAT-035's divergence test. Every `code-audit-*.md` agent file carries one
 * machine-readable declaration of the gradings it can emit (README FC-7):
 *
 *   <!-- gaia-audit:gradings: Critical, Important, Suggestion -->
 *
 * This checks each file's declaration against `SEVERITY_BY_GRADING`, and the
 * map against `SEVERITIES`, the parser's own accepted set. It does NOT prove
 * an agent's prose only ever grades what it declared, that would need prose
 * parsing, exactly the fragility the declaration exists to avoid. The
 * invariant is narrower: a member that learns a fourth grading must edit its
 * declaration, and the moment it does, this test fails until the map and the
 * parser learn it too.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded
 * wholesale (`.gaia/release-exclude:92`), so this suite never ships to, or
 * runs on, an adopter clone. The "at least four" assertion below therefore
 * needs no adopter-clone gate the way `audit-template-dogfood.test.ts` gates
 * its byte-identical check: there is no context in which this file runs with
 * only the two adopter-scope agents on disk.
 */

const GRADINGS_MARKER = '<!-- gaia-audit:gradings:';

// Index-based scan (no regex) rather than a `\s*...\s*...-->` pattern: the
// declaration format is frozen (README FC-7) to one exact shape, so a
// backtracking-prone regex would buy flexibility nothing here needs.
const extractGradings = (fileContent: string): null | string[] => {
  const start = fileContent.indexOf(GRADINGS_MARKER);

  if (start === -1) return null;

  const afterMarker = start + GRADINGS_MARKER.length;
  const end = fileContent.indexOf('-->', afterMarker);

  if (end === -1) return null;

  return fileContent
    .slice(afterMarker, end)
    .split(',')
    .map((grading) => grading.trim());
};

type ValidationResult = {ok: false; reason: string} | {ok: true};

// The divergence check itself: a file passes when it declares its gradings
// and every declared grading is a key of SEVERITY_BY_GRADING whose mapped
// value is in the parser's accepted set. Returning a structured result
// (rather than asserting inline) lets the fixture tests below prove the
// check actually fails on the inputs it exists to catch.
const validateAgentFile = (fileContent: string): ValidationResult => {
  const gradings = extractGradings(fileContent);

  if (gradings === null) {
    return {ok: false, reason: 'no gaia-audit:gradings declaration'};
  }

  for (const grading of gradings) {
    if (!Object.hasOwn(SEVERITY_BY_GRADING, grading)) {
      return {
        ok: false,
        reason: `declares grading "${grading}", absent from SEVERITY_BY_GRADING`,
      };
    }

    const severity =
      SEVERITY_BY_GRADING[grading as keyof typeof SEVERITY_BY_GRADING];

    if (!SEVERITIES.has(severity)) {
      return {
        ok: false,
        reason: `grading "${grading}" maps to "${severity}", absent from SEVERITIES`,
      };
    }
  }

  return {ok: true};
};

const resolveRepoRoot = (): string => {
  // Walk up from this file's location to find the repo root (contains .git).
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

const repoRoot = resolveRepoRoot();
const agentsDir = path.join(repoRoot, '.claude', 'agents');
const agentFiles = readdirSync(agentsDir).filter((name) =>
  /^code-audit-.+\.md$/u.test(name)
);

describe('severity vocabulary divergence guard', () => {
  test('finds at least four code-audit-*.md agent files', () => {
    // A filter that silently matches zero would pass every assertion below
    // and test nothing: this is the single most likely way for the suite to
    // rot into a no-op.
    expect(agentFiles.length).toBeGreaterThanOrEqual(4);
  });

  test.each(agentFiles)('%s passes the divergence check', (name) => {
    const content = readFileSync(path.join(agentsDir, name), 'utf8');

    expect(validateAgentFile(content)).toEqual({ok: true});
  });

  test('the check fails a fixture declaring a grading absent from the map', () => {
    const fixture = [
      '# fixture',
      '<!-- gaia-audit:gradings: Critical, Blocker -->',
    ].join('\n');

    expect(validateAgentFile(fixture)).toEqual({
      ok: false,
      reason: 'declares grading "Blocker", absent from SEVERITY_BY_GRADING',
    });
  });

  test('the check fails a fixture agent file carrying no declaration line', () => {
    const fixture = '# fixture with no declaration line';

    expect(validateAgentFile(fixture)).toEqual({
      ok: false,
      reason: 'no gaia-audit:gradings declaration',
    });
  });
});
