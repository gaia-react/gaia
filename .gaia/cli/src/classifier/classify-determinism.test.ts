/**
 * Tests for the determinism classifier AST helper
 * (`.gaia/scripts/classifier/classify-determinism.mjs`).
 *
 * The helper labels a touched source file STRICT (deterministic; goes under the
 * RED gate) or EMERGENT (clock-/entropy-/I-O-bound or tree-dependent; advisory
 * audit only). Path scopes the candidate set; content decides. The bias is
 * deliberate: err EMERGENT. Over-strict is the worse failure.
 *
 * Maintainer-only by construction: `.gaia/scripts` is release-excluded, so the
 * helper and this test never ship to adopters.
 *
 * The helper resolves `typescript` from `node_modules`; this `.gaia/cli`
 * workspace carries its own `typescript` devDependency, so the test runner can
 * exec it. Synthetic fixtures are fed through `--stdin` (the path argument names
 * the file identity for path scoping and `.ts`-vs-`.tsx` script kind; stdin
 * supplies the bytes). The three named real fixtures are classified from disk by
 * repo-relative path.
 */
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {describe, expect, it} from 'vitest';

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
const HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/classifier/classify-determinism.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The CLI Tests CI job installs deps only in
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

// Classify a real file on disk by its repo-relative path.
const classifyFile = (repoRelPath: string): Classification => {
  const out = execFileSync('node', [HELPER, repoRelPath], {
    cwd: REPO_ROOT,
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
    cwd: REPO_ROOT,
    encoding: 'utf8',
    input: source,
    env: HELPER_ENV,
  });

  return JSON.parse(out) as Classification;
};

describe('classify-determinism', () => {
  it('emits the {file, classification, reasons} contract shape', () => {
    const result = classifySource(
      'app/utils/example.ts',
      'export const add = (a: number, b: number): number => a + b;\n'
    );

    expect(result.file).toBe('app/utils/example.ts');
    expect(result.classification).toBe('strict');
    expect(Array.isArray(result.reasons)).toBe(true);
  });

  describe('condition 1: path scoping', () => {
    it('classifies a pure file outside the candidate paths EMERGENT', () => {
      const result = classifySource(
        'app/routes/_index.tsx',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/path/i);
    });

    it('classifies a .tsx file under app/components EMERGENT', () => {
      const result = classifySource(
        'app/components/Foo/utils.tsx',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a pure .ts file under app/components STRICT', () => {
      const result = classifySource(
        'app/components/Foo/utils.ts',
        'export const add = (a: number, b: number): number => a + b;\n'
      );

      expect(result.classification).toBe('strict');
    });

    it('classifies a pure file under app/services STRICT', () => {
      const result = classifySource(
        'app/services/example/parse.ts',
        'export const toUpper = (s: string): string => s.toUpperCase();\n'
      );

      expect(result.classification).toBe('strict');
    });
  });

  describe('condition 2: module-reachable non-determinism', () => {
    it('classifies a default-parameter new Date() EMERGENT (the FI-3 fix)', () => {
      const result = classifySource(
        'app/utils/date.ts',
        "import {format} from 'date-fns';\n" +
          "export const formatMY = (date = new Date()): string => format(date, 'MM/yy');\n"
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/new Date/);
    });

    it('classifies a module-level new Date() constant EMERGENT', () => {
      const result = classifySource(
        'app/utils/clock.ts',
        'const TODAY = new Date();\nexport const year = (): number => TODAY.getFullYear();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a class-field Math.random() initializer EMERGENT', () => {
      const result = classifySource(
        'app/utils/id.ts',
        'export class Id {\n  value = Math.random();\n}\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/Math\.random/);
    });

    it('classifies a Date.now() call EMERGENT', () => {
      const result = classifySource(
        'app/utils/now.ts',
        'export const stamp = (): number => Date.now();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a crypto usage EMERGENT', () => {
      const result = classifySource(
        'app/utils/token.ts',
        'export const token = (): string => crypto.randomUUID();\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a top-level await EMERGENT', () => {
      const result = classifySource(
        'app/utils/config.ts',
        "const data = await import('./other');\nexport const value = data;\n"
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('condition 3: hook call-surface rule', () => {
    it('classifies a hook reading a react-router runtime hook EMERGENT', () => {
      const result = classifySource(
        'app/hooks/useThing.ts',
        "import {useNavigate} from 'react-router';\n" +
          'export const useThing = () => {\n  const navigate = useNavigate();\n  return navigate;\n};\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/useNavigate/);
    });

    it('classifies a hook calling a DOM-layout API EMERGENT', () => {
      const result = classifySource(
        'app/hooks/useSize.ts',
        'export const useSize = (el: HTMLElement) => {\n' +
          '  return el.getBoundingClientRect();\n};\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a useState/useMemo-only hook STRICT', () => {
      const result = classifySource(
        'app/hooks/useToggle.ts',
        "import {useState, useCallback} from 'react';\n" +
          'export const useToggle = () => {\n' +
          '  const [on, setOn] = useState(false);\n' +
          '  const toggle = useCallback(() => setOn((v) => !v), []);\n' +
          '  return {on, toggle};\n};\n'
      );

      expect(result.classification).toBe('strict');
    });

    it('classifies a hook using only the allowlisted matchMedia STRICT', () => {
      const result = classifySource(
        'app/hooks/useMedia.ts',
        "import {useState} from 'react';\n" +
          'export const useMedia = (q: string) => {\n' +
          '  const [match] = useState(() => globalThis.matchMedia(q).matches);\n' +
          '  return match;\n};\n'
      );

      expect(result.classification).toBe('strict');
    });

    it('routes a use* export under app/utils through condition 3, not 2/4', () => {
      // A hook is a hook even under app/utils/**: it is judged by its call
      // surface (condition 3), and a plain useState hook is STRICT.
      const result = classifySource(
        'app/utils/useCounter.ts',
        "import {useState} from 'react';\n" +
          'export const useCounter = () => {\n' +
          '  const [n, setN] = useState(0);\n' +
          '  return {n, inc: () => setN((v) => v + 1)};\n};\n'
      );

      expect(result.classification).toBe('strict');
    });
  });

  describe('condition 4: no public async I/O export', () => {
    it('classifies a public async export wrapping fetch EMERGENT', () => {
      const result = classifySource(
        'app/services/example/load.ts',
        'export const load = async (url: string): Promise<Response> =>\n' +
          '  fetch(url);\n'
      );

      expect(result.classification).toBe('emergent');
    });

    it('classifies a public async setTimeout-as-sleep export EMERGENT', () => {
      const result = classifySource(
        'app/services/example/sleep.ts',
        'export const sleep = async (ms: number): Promise<void> =>\n' +
          '  new Promise((resolve) => setTimeout(resolve, ms));\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('versioned DOM-API allowlist + unknown-API default', () => {
    it('classifies a hook calling a DOM API absent from the allowlist EMERGENT', () => {
      const result = classifySource(
        'app/hooks/useBattery.ts',
        'export const useBattery = () => {\n' +
          '  return globalThis.navigator.getBattery();\n};\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/unknown DOM API|allowlist/i);
    });
  });

  describe('a11y helpers are an emergent signal', () => {
    it('classifies a file calling expectNoA11yViolations EMERGENT', () => {
      const result = classifySource(
        'app/components/Foo/utils.ts',
        "import {expectNoA11yViolations} from 'test/a11y';\n" +
          'export const checkMarkup = async (el: Element): Promise<void> =>\n' +
          '  expectNoA11yViolations(el);\n'
      );

      expect(result.classification).toBe('emergent');
      expect(result.reasons.join(' ')).toMatch(/expectNoA11yViolations|a11y/i);
    });

    it('classifies a file calling runAxe EMERGENT', () => {
      const result = classifySource(
        'app/components/Foo/axe.ts',
        "import {runAxe} from 'test/a11y';\n" +
          'export const audit = async (el: Element) => runAxe(el);\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('file-granularity limitation', () => {
    it('classifies a mixed pure-export/impure-constant file whole-file EMERGENT', () => {
      const result = classifySource(
        'app/utils/mixed.ts',
        'const SEED = Math.random();\n' +
          'export const pure = (a: number, b: number): number => a + b;\n' +
          'export const tainted = (): number => SEED;\n'
      );

      expect(result.classification).toBe('emergent');
    });
  });

  describe('named regression fixtures (real files on disk)', () => {
    it('classifies app/utils/date.ts EMERGENT (default-param new Date())', () => {
      const result = classifyFile('app/utils/date.ts');

      expect(result.classification).toBe('emergent');
    });

    it('classifies app/components/Form/YearMonthDay/utils.ts EMERGENT (module-level TODAY)', () => {
      const result = classifyFile('app/components/Form/YearMonthDay/utils.ts');

      expect(result.classification).toBe('emergent');
    });

    it('classifies app/components/Toast/ToastNotification/utils.ts STRICT (pure parsePayload)', () => {
      const result = classifyFile(
        'app/components/Toast/ToastNotification/utils.ts'
      );

      expect(result.classification).toBe('strict');
    });
  });
});
