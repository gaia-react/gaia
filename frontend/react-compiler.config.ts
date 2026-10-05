import babel from '@rolldown/plugin-babel';
import {reactCompilerPreset} from '@vitejs/plugin-react';
import type {PluginOption} from 'vite';
import {appendFileSync, closeSync, mkdirSync, openSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

// Flipping this to `false` removes the compiler from every pipeline: the app
// build and dev server, Storybook, and Vitest.
export const isReactCompilerEnabled = true;

const packageDirectory = fileURLToPath(new URL('.', import.meta.url));
const reportPath = process.env.GAIA_REACT_COMPILER_REPORT;

type CompilerEvent = {
  data?: string;
  detail?: {reason?: string};
  fnName?: null | string;
  kind: string;
  reason?: string;
};

const reportedKinds = new Set([
  'CompileError',
  'CompileSkip',
  'CompileSuccess',
  'PipelineError',
]);

const describeEvent = (event: CompilerEvent): string =>
  event.fnName ?? event.reason ?? event.detail?.reason ?? event.data ?? '';

// With the report variable set, the file exists even when no event is written.
// Events append across runs, so point the variable at a fresh path per run.
const createReportLogger = (reportFile: string) => {
  mkdirSync(path.dirname(reportFile), {recursive: true});
  closeSync(openSync(reportFile, 'a'));

  return {
    logEvent: (filename: null | string, event: CompilerEvent) => {
      if (!reportedKinds.has(event.kind)) return;

      // The Babel plugin receives the raw Vite module id, so a `?query`
      // suffix can ride along with the path.
      const [filePath = ''] = (filename ?? '').split('?');
      const file = path.relative(packageDirectory, filePath);

      appendFileSync(
        reportFile,
        `${JSON.stringify({
          detail: describeEvent(event),
          file,
          kind: event.kind,
        })}\n`
      );
    },
  };
};

export const reactCompilerOptions = {
  compilationMode: 'infer',
  panicThreshold: 'none',
  target: '19',
  ...(reportPath ? {logger: createReportLogger(reportPath)} : {}),
} as const;

// The switch is a literal, so the lint rule reads this condition as constant.
export const reactCompiler: PluginOption =
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
  isReactCompilerEnabled ?
    babel({presets: [reactCompilerPreset(reactCompilerOptions)]})
  : false;
