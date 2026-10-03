/**
 * Exercises the determinism classifier AST helper
 * (`.gaia/scripts/classifier/classify-determinism.mjs`), which labels a
 * touched source file STRICT (deterministic; goes under the RED gate) or
 * EMERGENT (clock-/entropy-/I-O-bound or tree-dependent; advisory audit
 * only). Path scopes the candidate set; content decides. The bias is
 * deliberate: err EMERGENT. Over-strict is the worse failure.
 *
 * Maintainer-only by construction: `.gaia/scripts` is release-excluded, so
 * the helper and this test never ship to adopters.
 *
 * The helper resolves `typescript` from `node_modules`; this `.gaia/cli`
 * workspace carries its own `typescript` devDependency, so the test runner
 * can exec it. Synthetic fixtures are fed through `--stdin` (the path
 * argument names the file identity for path scoping and `.ts`-vs-`.tsx`
 * script kind; stdin supplies the bytes). The three named real fixtures are
 * classified from disk by repo-relative path.
 */
import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import {execFileSync, spawnSync} from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/classifier/classify-determinism.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The GAIA: CLI Tests workflow installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd helper resolves
// typescript whether or not the repo root is installed.
const HELPER_ENV = {
  ...process.env,
  NODE_PATH: path.join(REPO_ROOT, '.gaia/cli/node_modules'),
};

type Classification = {
  classification: 'emergent' | 'strict';
  file: string;
  reasons: string[];
};

// The classifier reads the package registry from its working directory, so the
// suite runs it from a scratch tree with no `.gaia/packages.json`: the built-in
// default (the app at `frontend/`), the 2.0.0 layout, whatever shape the real
// checkout is in. The three named real files are copied in under `frontend/`.
let FIXTURE_ROOT = '';

// Where a real app file lives in this checkout: under `frontend/` once the app
// has moved, at the repo root before.
const realAppFile = (frontendRelativePath: string): string => {
  const moved = path.join(REPO_ROOT, frontendRelativePath);

  return existsSync(moved) ? moved : (
      path.join(REPO_ROOT, frontendRelativePath.replace(/^frontend\//, ''))
    );
};

beforeAll(() => {
  FIXTURE_ROOT = mkdtempSync(path.join(os.tmpdir(), 'classify-determinism-'));

  for (const file of [
    'frontend/app/utils/date.ts',
    'frontend/app/components/Form/YearMonthDay/utils.ts',
    'frontend/app/components/Toast/ToastNotification/utils.ts',
  ]) {
    mkdirSync(path.join(FIXTURE_ROOT, path.dirname(file)), {recursive: true});
    copyFileSync(realAppFile(file), path.join(FIXTURE_ROOT, file));
  }
});

afterAll(() => {
  rmSync(FIXTURE_ROOT, {force: true, recursive: true});
});

// Classify a real file on disk by its repo-relative path.
const classifyFile = (repoRelativePath: string): Classification => {
  const out = execFileSync('node', [HELPER, repoRelativePath], {
    cwd: FIXTURE_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
  });

  return JSON.parse(out) as Classification;
};

// Classify synthetic source bytes fed through stdin. `fileIdentity` is the
// repo-relative path used for path scoping and script-kind selection.
const classifySource = (
  fileIdentity: string,
  source: string
): Classification => {
  const out = execFileSync('node', [HELPER, fileIdentity, '--stdin'], {
    cwd: FIXTURE_ROOT,
    encoding: 'utf8',
    env: HELPER_ENV,
    input: source,
  });

  return JSON.parse(out) as Classification;
};

// Run the classifier in a scratch tree carrying its own registry and
// descriptor files, written as literals so the case outlives the registry
// flip in the real checkout.
const withTree = <T>(
  files: Record<string, string>,
  run: (cwd: string) => T
): T => {
  const tree = mkdtempSync(path.join(os.tmpdir(), 'classify-packages-'));

  try {
    for (const [relative, content] of Object.entries(files)) {
      mkdirSync(path.join(tree, path.dirname(relative)), {recursive: true});
      writeFileSync(path.join(tree, relative), content);
    }

    return run(tree);
  } finally {
    rmSync(tree, {force: true, recursive: true});
  }
};

const descriptor = (strict: string[]): string =>
  JSON.stringify({
    globs: {
      dependencyManifests: ['package.json'],
      doctorConfigs: ['doctor.config.*'],
      emergentTests: ['app/**/*.test.ts'],
      preCommitSource: ['app/**'],
      selfHealRefuse: ['.claude/**'],
      tddStrictCandidates: strict,
      tddUnitTests: ['app/**/*.test.ts'],
    },
    name: 'frontend',
    schemaVersion: 1,
    wiki: {
      flowPaths: ['app/'],
      inventoryPaths: ['app/'],
      sourcePaths: ['app/'],
    },
  });

describe('classify-determinism', () => {
  test('emits the {file, classification, reasons} contract shape', () => {
    const result = classifySource(
      'frontend/app/utils/example.ts',
      'export const add = (a: number, b: number): number => a + b;\n'
    );

    expect(result.file).toBe('frontend/app/utils/example.ts');
    expect(result.classification).toBe('strict');
    expect(Array.isArray(result.reasons)).toBe(true);
  });

  describe('condition 1: path scoping', () => {
    test('classifies a pure file outside the candidate paths EMERGENT', () => {
      const result = classifySource(
        'frontend/app/routes/_index.tsx',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/path/i);
    });

    test('classifies a .tsx file under app/components EMERGENT', () => {
      const result = classifySource(
        'frontend/app/components/Foo/utils.tsx',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a pure .ts file under app/components STRICT', () => {
      const result = classifySource(
        'frontend/app/components/Foo/utils.ts',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('strict');
    });

    test('classifies a pure file under app/services STRICT', () => {
      const result = classifySource(
        'frontend/app/services/example/parse.ts',
        'export const toUpper = (s: string): string => s.toUpperCase();\n'
      );

      expect(result.classification).toBe('strict');
    });
  });

  describe('condition 2: module-reachable non-determinism', () => {
    test('classifies a default-parameter new Date() EMERGENT (the FI-3 fix)', () => {
      const result = classifySource(
        'frontend/app/utils/date.ts',
        "import {format} from 'date-fns';\n" +
          "export const formatMY = (date = new Date()): string => format(date, 'MM/yy');\n"
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/new Date/);
    });

    test('classifies a module-level new Date() constant EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/clock.ts',
        'const TODAY = new Date();\nexport const year = (): number => TODAY.getFullYear();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a class-field Math.random() initializer EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/id.ts',
        'export class Id {\n  value = Math.random();\n}\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/Math\.random/);
    });

    test('classifies a Date.now() call EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/now.ts',
        'export const stamp = (): number => Date.now();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a crypto usage EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/token.ts',
        'export const token = (): string => crypto.randomUUID();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a top-level await EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/config.ts',
        "const data = await import('./other');\nexport const value = data;\n"
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('condition 3: hook call-surface rule', () => {
    test('classifies a hook reading a react-router runtime hook EMERGENT', () => {
      const result = classifySource(
        'frontend/app/hooks/useThing.ts',
        "import {useNavigate} from 'react-router';\n" +
          'export const useThing = () => {\n  const navigate = useNavigate();\n  return navigate;\n};\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/useNavigate/);
    });

    test('classifies a hook calling a DOM-layout API EMERGENT', () => {
      const result = classifySource(
        'frontend/app/hooks/useSize.ts',
        'export const useSize = (el: HTMLElement) => {\n' +
          '  return el.getBoundingClientRect();\n};\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a useState/useMemo-only hook STRICT', () => {
      const result = classifySource(
        'frontend/app/hooks/useToggle.ts',
        "import {useState, useCallback} from 'react';\n" +
          'export const useToggle = () => {\n' +
          '  const [on, setOn] = useState(false);\n' +
          '  const toggle = useCallback(() => setOn((v) => !v), []);\n' +
          '  return {on, toggle};\n};\n'
      );

      expect(result.classification).toBe('strict');
    });

    test('classifies a hook using only the allowlisted matchMedia STRICT', () => {
      const result = classifySource(
        'frontend/app/hooks/useMedia.ts',
        "import {useState} from 'react';\n" +
          'export const useMedia = (q: string) => {\n' +
          '  const [match] = useState(() => globalThis.matchMedia(q).matches);\n' +
          '  return match;\n};\n'
      );

      expect(result.classification).toBe('strict');
    });

    test('routes a use* export under app/utils through condition 3, not 2/4', () => {
      // A hook is a hook even under app/utils/**: it is judged by its call
      // surface (condition 3), and a plain useState hook is STRICT.
      const result = classifySource(
        'frontend/app/utils/useCounter.ts',
        "import {useState} from 'react';\n" +
          'export const useCounter = () => {\n' +
          '  const [n, setN] = useState(0);\n' +
          '  return {n, inc: () => setN((v) => v + 1)};\n};\n'
      );

      expect(result.classification).toBe('strict');
    });
  });

  describe('condition 4: no public async I/O export', () => {
    test('classifies a public async export wrapping fetch EMERGENT', () => {
      const result = classifySource(
        'frontend/app/services/example/load.ts',
        'export const load = async (url: string): Promise<Response> =>\n' +
          '  fetch(url);\n'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies a public async setTimeout-as-sleep export EMERGENT', () => {
      const result = classifySource(
        'frontend/app/services/example/sleep.ts',
        'export const sleep = async (ms: number): Promise<void> =>\n' +
          '  new Promise((resolve) => setTimeout(resolve, ms));\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('versioned DOM-API allowlist + unknown-API default', () => {
    test('classifies a hook calling a DOM API absent from the allowlist EMERGENT', () => {
      const result = classifySource(
        'frontend/app/hooks/useBattery.ts',
        'export const useBattery = () => {\n' +
          '  return globalThis.navigator.getBattery();\n};\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/unknown DOM API|allowlist/i);
    });
  });

  describe('a11y helpers are an emergent signal', () => {
    test('classifies a file calling expectNoA11yViolations EMERGENT', () => {
      const result = classifySource(
        'frontend/app/components/Foo/utils.ts',
        "import {expectNoA11yViolations} from 'test/a11y';\n" +
          'export const checkMarkup = async (el: Element): Promise<void> =>\n' +
          '  expectNoA11yViolations(el);\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/expectNoA11yViolations|a11y/i);
    });

    test('classifies a file calling runAxe EMERGENT', () => {
      const result = classifySource(
        'frontend/app/components/Foo/axe.ts',
        "import {runAxe} from 'test/a11y';\n" +
          'export const audit = async (el: Element) => runAxe(el);\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('file-granularity limitation', () => {
    test('classifies a mixed pure-export/impure-constant file whole-file EMERGENT', () => {
      const result = classifySource(
        'frontend/app/utils/mixed.ts',
        'const SEED = Math.random();\n' +
          'export const pure = (a: number, b: number): number => a + b;\n' +
          'export const tainted = (): number => SEED;\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('named regression fixtures (real files on disk)', () => {
    test('classifies frontend/app/utils/date.ts EMERGENT (default-param new Date())', () => {
      const result = classifyFile('frontend/app/utils/date.ts');

      expect(result.classification).toBe('emergent');
    });

    test('classifies frontend/app/components/Form/YearMonthDay/utils.ts EMERGENT (module-level TODAY)', () => {
      const result = classifyFile(
        'frontend/app/components/Form/YearMonthDay/utils.ts'
      );

      expect(result.classification).toBe('emergent');
    });

    test('classifies frontend/app/components/Toast/ToastNotification/utils.ts STRICT (pure parsePayload)', () => {
      const result = classifyFile(
        'frontend/app/components/Toast/ToastNotification/utils.ts'
      );

      expect(result.classification).toBe('strict');
    });
  });

  describe('package scope (descriptor-driven candidate globs)', () => {
    const PURE =
      'export const add = (a: number, b: number): number => a + b;\n';

    test('classifies the same pure file at the unmoved root path EMERGENT, naming the descriptor prefixes', () => {
      const result = classifySource('app/utils/example.ts', PURE);

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toContain(
        'path not in frontend/app/utils/**'
      );
      expect(result.reasons.join(' ')).not.toContain('path not in app/utils');
    });

    const run = (cwd: string, target: string) =>
      spawnSync('node', [HELPER, target, '--stdin'], {
        cwd,
        encoding: 'utf8',
        env: HELPER_ENV,
        input: PURE,
      });

    test("a literal path-'.' registry keeps today's layout: root app/utils is strict", () => {
      withTree(
        {
          '.gaia/packages.json': '[{"name":"frontend","path":"."}]',
          'gaia.package.json': descriptor(['app/utils/**']),
        },
        (cwd) => {
          const result = run(cwd, 'app/utils/x.ts');

          expect(result.status).toBe(0);
          expect(JSON.parse(result.stdout).classification).toBe('strict');
        }
      );
    });

    test('a descriptor whose strict globs match nothing classifies the same file emergent (the guard can fail)', () => {
      withTree(
        {
          '.gaia/packages.json': '[{"name":"frontend","path":"frontend"}]',
          'frontend/gaia.package.json': descriptor(['nomatch/**']),
        },
        (cwd) => {
          const result = run(cwd, 'frontend/app/utils/x.ts');

          expect(result.status).toBe(0);
          const parsed = JSON.parse(result.stdout);

          expect(parsed.classification).toBe('emergent');
          expect(parsed.reasons.join(' ')).toContain(
            'path not in frontend/nomatch/**'
          );
        }
      );
    });

    test('an unparseable registry exits 7 with {"error"} on stdout and classifies nothing', () => {
      withTree({'.gaia/packages.json': '{'}, (cwd) => {
        const result = run(cwd, 'frontend/app/utils/x.ts');

        expect(result.status).toBe(7);
        const parsed = JSON.parse(result.stdout);

        expect(parsed.error).toMatch(
          /^gaia-packages: \.gaia\/packages\.json is malformed/
        );
        expect(parsed.classification).toBeUndefined();
      });
    });

    test('a registered package with no descriptor exits 7 with {"error"} naming the descriptor', () => {
      withTree(
        {'.gaia/packages.json': '[{"name":"frontend","path":"frontend"}]'},
        (cwd) => {
          const result = run(cwd, 'frontend/app/utils/x.ts');

          expect(result.status).toBe(7);
          expect(JSON.parse(result.stdout).error).toContain(
            'frontend/gaia.package.json is missing'
          );
        }
      );
    });
  });
});
