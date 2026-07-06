import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for the worthiness-audit ledger writer
 * (`.gaia/scripts/audit-ledger/append-worthiness.mjs`).
 *
 * The writer appends one JSON Lines record per judged test to the append-only
 * worthiness ledger. Its identity field (`signal`) is the SAME
 * sha256-of-normalized-test-call the RED ledger computes via
 * `.gaia/scripts/red-ledger/extract-test-signals.mjs`; the writer reuses that
 * helper so the two signals byte-match and the merge presence gate's recompute
 * lines up. A non-keep verdict carries a machine-checkable `artifact`.
 *
 * Maintainer-only by construction: `.gaia/scripts` is release-excluded, so the
 * writer and this test never ship to adopters.
 *
 * The writer resolves its sibling signal helper, which resolves `typescript`
 * from `node_modules`; this `.gaia/cli` workspace carries its own `typescript`
 * devDependency, so the test runner can exec it.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const resolveRepoRoot = (): string => {
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

const REPO_ROOT = resolveRepoRoot();
const WRITER = path.join(
  REPO_ROOT,
  '.gaia/scripts/audit-ledger/append-worthiness.mjs'
);
const SIGNAL_HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/red-ledger/extract-test-signals.mjs'
);

// The helper (and the signal helper the writer spawns) resolves `typescript`
// by walking up from its own location to the repo-root node_modules. The CLI
// Tests CI job installs deps only in `.gaia/cli`, so typescript lives there,
// not at the (uninstalled) repo root. Expose `.gaia/cli/node_modules` via
// NODE_PATH so the exec'd scripts resolve typescript whether or not the repo
// root is installed. The writer inherits this env when it spawns the signal
// helper, so the path propagates transitively.
const CLI_NODE_MODULES = path.join(REPO_ROOT, '.gaia/cli/node_modules');

type LedgerLine = {
  artifact?: string;
  auditedAt: string;
  file: string;
  fullName: string;
  schema: number;
  signal: string;
  verdict: 'delete' | 'fix' | 'keep';
};

// A small test file whose single test has a known fullName.
const TEST_FILE_REL = 'app/components/PriceTag/tests/index.test.tsx';
const TEST_SOURCE = [
  "import {test, expect} from 'vitest';",
  "test('renders formatted price', () => {",
  '  expect(1 + 1).toBe(2);',
  '});',
  '',
].join('\n');

let workDir: string;
let ledgerPath: string;
let testFileAbs: string;

// Recompute the RED-ledger signal for the fixture's single test, so the
// assertion checks byte-equality against the canonical primitive.
const redSignalFor = (fullName: string): string => {
  const out = execFileSync('node', [SIGNAL_HELPER, TEST_FILE_REL, '--stdin'], {
    cwd: workDir,
    encoding: 'utf8',
    env: {...process.env, NODE_PATH: CLI_NODE_MODULES},
    input: TEST_SOURCE,
  });
  const line = out
    .trim()
    .split('\n')
    .map((rawLine) => JSON.parse(rawLine) as {fullName: string; signal: string})
    .find((entry) => entry.fullName === fullName);

  if (!line) throw new Error(`no signal for ${fullName}`);

  return line.signal;
};

const runWriter = (args: string[]): void => {
  execFileSync('node', [WRITER, ...args], {
    cwd: workDir,
    encoding: 'utf8',
    env: {
      ...process.env,
      NODE_PATH: CLI_NODE_MODULES,
      WORTHINESS_LEDGER_PATH: ledgerPath,
    },
  });
};

const readLedger = (): LedgerLine[] =>
  readFileSync(ledgerPath, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((rawLine) => JSON.parse(rawLine) as LedgerLine);

beforeEach(() => {
  // Each test gets a private working tree so the writer's on-disk read of the
  // fixture file and its ledger append never touch the real repo ledger.
  workDir = mkdtempSync(path.join(tmpdir(), 'worthiness-ledger-'));
  const fileDir = path.join(workDir, path.dirname(TEST_FILE_REL));
  testFileAbs = path.join(workDir, TEST_FILE_REL);
  execFileSync('mkdir', ['-p', fileDir]);
  writeFileSync(testFileAbs, TEST_SOURCE, 'utf8');
  ledgerPath = path.join(workDir, 'worthiness.jsonl');
});

afterEach(() => {
  rmSync(workDir, {force: true, recursive: true});
});

describe('append-worthiness', () => {
  test('appends a keep line whose signal byte-matches the RED-ledger signal', () => {
    runWriter([TEST_FILE_REL, 'renders formatted price', 'keep']);

    const lines = readLedger();
    expect(lines).toHaveLength(1);

    const [line] = lines;
    expect(line.schema).toBe(1);
    expect(line.file).toBe(TEST_FILE_REL);
    expect(line.fullName).toBe('renders formatted price');
    expect(line.verdict).toBe('keep');
    expect(line.signal).toBe(redSignalFor('renders formatted price'));
    expect(typeof line.auditedAt).toBe('string');
    expect(line.auditedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  test('carries the machine-checkable artifact for a non-keep verdict', () => {
    runWriter([
      TEST_FILE_REL,
      'renders formatted price',
      'delete',
      'redundant-with: PriceTag › renders formatted price',
    ]);

    const [line] = readLedger();
    expect(line.verdict).toBe('delete');
    expect(line.artifact).toBe(
      'redundant-with: PriceTag › renders formatted price'
    );
  });

  test('appends rather than truncates across runs', () => {
    runWriter([TEST_FILE_REL, 'renders formatted price', 'keep']);
    runWriter([
      TEST_FILE_REL,
      'renders formatted price',
      'fix',
      'no-interaction-assertions',
    ]);

    const lines = readLedger();
    expect(lines).toHaveLength(2);
    expect(lines.map((ledgerLine) => ledgerLine.verdict)).toEqual([
      'keep',
      'fix',
    ]);
  });

  test('rejects an unknown verdict', () => {
    expect(() =>
      runWriter([TEST_FILE_REL, 'renders formatted price', 'maybe'])
    ).toThrow(/verdict/i);
  });

  test('rejects a non-keep verdict with no artifact', () => {
    expect(() =>
      runWriter([TEST_FILE_REL, 'renders formatted price', 'delete'])
    ).toThrow(/artifact/i);
  });

  test('fails when the named test is not found in the file', () => {
    expect(() => runWriter([TEST_FILE_REL, 'no such test', 'keep'])).toThrow(
      /no such test/i
    );
  });
});
