/**
 * Workflow YAML render pipeline: partial resolver + per-tool renderer.
 *
 * The four `gaia-ci-<tool>.yml.tmpl` files include shared partials via a
 * mustache-style `{{> partials/<name> }}` token. This module resolves
 * those includes (recursion depth one; partials may not include other
 * partials), then hands the resulting string to the scaffold engine's
 * `substituteVars` core for variable / section / each substitution.
 *
 * Keeping the partial resolver in `automation/` rather than extending
 * `scaffold/template.ts` keeps the scaffolder engine minimal and confines
 * the workflow-specific syntax to one file.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {substituteVars} from '../scaffold/template.js';
import type {TemplateVars} from '../scaffold/template.js';
import type {WorkflowTemplateVars} from './workflow-vars.js';

// Negative lookbehind on `$` keeps GitHub Actions expressions like
// `${{ secrets.X }}` intact (the scaffold engine's scalar regex applies
// the same guard). Partials are never written with a `$` prefix, so the
// constraint costs us nothing.
const PARTIAL_PATTERN = /(?<!\$)\{\{>\s*partials\/([\w-]+)\s*\}\}/gu;

const readPartialBody = (partialsDir: string, name: string): string => {
  const partialPath = path.join(partialsDir, `${name}.yml.tmpl`);

  try {
    return readFileSync(partialPath, 'utf8');
  } catch (error) {
    const cause = error instanceof Error ? error.message : String(error);

    throw new Error(
      `partial '${name}' could not be read at ${partialPath}: ${cause}`
    );
  }
};

/**
 * Replace each `{{> partials/<name> }}` token in `raw` with the contents
 * of `<partialsDir>/<name>.yml.tmpl`. Recursion depth is one; partials
 * may not include other partials. Throws a structured error if a partial
 * body contains a `{{>` token (even non-matching forms) so accidental
 * recursion is caught at render time, and if a partial cannot be read.
 */
export const resolvePartials = (raw: string, partialsDir: string): string =>
  raw.replaceAll(PARTIAL_PATTERN, (_match, name: string) => {
    const body = readPartialBody(partialsDir, name);

    if (body.includes('{{>')) {
      throw new Error(
        `partial '${name}' contains '{{>'; partials may not include other partials`
      );
    }

    return body;
  });

/**
 * Render one workflow template against `vars`, resolving partials from
 * `partialsDir`. The returned string is the full YAML body; callers are
 * responsible for writing it to disk.
 */
export const renderWorkflowTemplate = (
  templatePath: string,
  partialsDir: string,
  vars: WorkflowTemplateVars
): string => {
  const raw = readFileSync(templatePath, 'utf8');
  const resolved = resolvePartials(raw, partialsDir);

  // WorkflowTemplateVars is a strict subset of TemplateVars (string |
  // boolean | number); the engine accepts string|boolean|string[]. Numbers
  // are stringified by the substitution core as expected, but we widen to
  // satisfy the engine's looser type.
  const engineVars: TemplateVars = {};

  for (const [key, value] of Object.entries(vars)) {
    engineVars[key] = typeof value === 'number' ? String(value) : value;
  }

  return substituteVars(resolved, engineVars);
};
