import type {Page} from '@playwright/test';
import ts from 'typescript';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {requireDevPorts} from '../dev-ports';
import type {Theme} from './theme';
import {forceDarkBeforeLoad} from './theme';

export type StoryEntry = {id: string; title: string; type: string};

const packageDirectory = fileURLToPath(new URL('..', import.meta.url));

export const storybookUrl = `http://127.0.0.1:${requireDevPorts(packageDirectory).storybookPort}`;

const indexPath = path.join(packageDirectory, 'storybook-static/index.json');

const findStoryFiles = (directory: string): string[] =>
  fs.readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return findStoryFiles(entryPath);

    return entry.name.endsWith('.stories.tsx') ? [entryPath] : [];
  });

const isNamedExport = (node: ts.Node): boolean => {
  const modifiers = ts.canHaveModifiers(node) ? ts.getModifiers(node) : [];
  const kinds = new Set((modifiers ?? []).map((modifier) => modifier.kind));

  return (
    kinds.has(ts.SyntaxKind.ExportKeyword) &&
    !kinds.has(ts.SyntaxKind.DefaultKeyword)
  );
};

const countNamedExports = (filePath: string): number => {
  const source = ts.createSourceFile(
    filePath,
    fs.readFileSync(filePath, 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  );
  let count = 0;

  for (const statement of source.statements) {
    if (ts.isVariableStatement(statement) && isNamedExport(statement)) {
      count += statement.declarationList.declarations.length;
    } else if (
      (ts.isFunctionDeclaration(statement) ||
        ts.isClassDeclaration(statement)) &&
      isNamedExport(statement)
    ) {
      count += 1;
    } else if (
      ts.isExportDeclaration(statement) &&
      !statement.isTypeOnly &&
      statement.exportClause &&
      ts.isNamedExports(statement.exportClause)
    ) {
      count += statement.exportClause.elements.filter(
        (element) => !element.isTypeOnly && element.name.text !== 'default'
      ).length;
    }
  }

  return count;
};

/** Named, non-default exports across every `*.stories.tsx` under `app/`: what Storybook indexes. */
export const countStoriesInSource = (): number =>
  findStoryFiles(path.join(packageDirectory, 'app')).reduce(
    (total, file) => total + countNamedExports(file),
    0
  );

/** The story entries of the built Storybook; throws, never skips, when it is not built. */
export const readStoryIndex = (): StoryEntry[] => {
  if (!fs.existsSync(indexPath)) {
    throw new Error(
      'storybook-static/index.json is missing: run `pnpm build-storybook` before `pnpm pw` so the story a11y scan has stories to scan'
    );
  }
  const {entries} = JSON.parse(fs.readFileSync(indexPath, 'utf8')) as {
    entries: Record<string, StoryEntry>;
  };

  return Object.values(entries).filter((entry) => entry.type === 'story');
};

type StoryPreview = {currentRender?: {phase?: string}};

/** Loads one story's iframe in one theme; each load scans exactly one theme. */
export const loadStory = async (
  page: Page,
  id: string,
  theme: Theme
): Promise<void> => {
  if (theme === 'dark') await forceDarkBeforeLoad(page);
  // React Router's route stub (stories that render a Document) asks for a
  // module path that exists only inside the stub; answer it empty so the
  // console-error guard still catches every other failed request.
  await page.route('**/build/stub-path-to-module.js', async (route) =>
    route.fulfill({body: '', contentType: 'text/javascript', status: 200})
  );
  await page.goto(`${storybookUrl}/iframe.html?id=${id}&viewMode=story`);
};

/** Resolves with the render phase once the story and its play function end. */
export const waitForRender = async (page: Page): Promise<string> => {
  const handle = await page.waitForFunction(() => {
    const preview = Reflect.get(globalThis, '__STORYBOOK_PREVIEW__') as
      StoryPreview | undefined;
    const phase = preview?.currentRender?.phase;

    return phase === 'finished' || phase === 'errored' || phase === 'aborted' ?
        phase
      : false;
  });

  return (await handle.jsonValue()) as string;
};
