/**
 * Minimal mustache-style template engine for the scaffolder family.
 *
 * Supported forms:
 *   {{var}}                 — scalar substitution (string or stringified bool/array).
 *   {{#flag}}...{{/flag}}   — boolean section. Body is included iff `flag` is truthy
 *                             (true, non-empty string, non-empty array). Bodies do
 *                             not nest sub-sections in this implementation.
 *   {{#each items}}...{{/each}} — iterates an array. Inside, `{{this}}` is the
 *                                 current scalar. Bodies do not nest sub-sections.
 *
 * Intentional minimalism: the four scaffolder tasks each ship one template file
 * with simple variable substitution and a couple of boolean flags. If a future
 * template needs nested sections, simplify the template instead of growing the
 * engine. See task-scaffold-shared.md ("Template engine").
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export type TemplateVars = Record<string, boolean | string | string[]>;

const TEMPLATES_DIRECTORY_NAME = 'templates';
const VAR_PATTERN = /\{\{\s*([\w.]+)\s*\}\}/gu;
const SECTION_PATTERN =
  /\{\{#\s*(\w+)\s*\}\}([\s\S]*?)\{\{\/\s*\1\s*\}\}/gu;
const EACH_PATTERN =
  /\{\{#each\s+(\w+)\s*\}\}([\s\S]*?)\{\{\/each\s*\}\}/gu;
const THIS_PATTERN = /\{\{\s*this\s*\}\}/gu;

const isTruthy = (value: boolean | string | string[] | undefined): boolean => {
  if (value === undefined || value === false) return false;
  if (value === true) return true;
  if (typeof value === 'string') return value.length > 0;

  return Array.isArray(value) && value.length > 0;
};

const renderEachBlocks = (template: string, vars: TemplateVars): string =>
  template.replaceAll(EACH_PATTERN, (_match, name: string, body: string) => {
    const value = vars[name];

    if (!Array.isArray(value)) return '';

    return value
      .map((item) => body.replaceAll(THIS_PATTERN, String(item)))
      .join('');
  });

const renderBooleanSections = (
  template: string,
  vars: TemplateVars
): string =>
  template.replaceAll(SECTION_PATTERN, (_match, name: string, body: string) => {
    if (name === 'each') return _match as string;

    return isTruthy(vars[name]) ? body : '';
  });

const renderScalars = (template: string, vars: TemplateVars): string =>
  template.replaceAll(VAR_PATTERN, (_match, name: string) => {
    if (name === 'this') return _match as string;
    const value = vars[name];

    if (value === undefined) return '';
    if (Array.isArray(value)) return value.join(',');
    if (typeof value === 'boolean') return value ? 'true' : 'false';

    return value;
  });

/**
 * Render `template` against `vars`. Sections are resolved before scalars so
 * that omitted sections never leak unfilled `{{var}}` placeholders.
 */
export const renderTemplate = (
  templatePath: string,
  vars: TemplateVars
): string => {
  const raw = readFileSync(templatePath, 'utf8');
  const eached = renderEachBlocks(raw, vars);
  const sectioned = renderBooleanSections(eached, vars);

  return renderScalars(sectioned, vars);
};

const resolveTemplatesDirectory = (): string => {
  const here = fileURLToPath(import.meta.url);

  return path.join(path.dirname(here), TEMPLATES_DIRECTORY_NAME);
};

/**
 * Resolve a template path under the scaffold templates directory, then read
 * its contents. Always reads from disk; the four scaffolder tasks are
 * responsible for shipping the template files.
 */
export const loadTemplate = (name: string): string => {
  const fullPath = path.join(resolveTemplatesDirectory(), name);

  return readFileSync(fullPath, 'utf8');
};
