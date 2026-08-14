/**
 * Workflow YAML render pipeline: partial resolver + workflow renderer.
 *
 * The `gaia-ci-<tool>.yml.tmpl` files and the `gaia-ci.yml.tmpl` scheduler
 * include shared partials via a mustache-style `{{> partials/<name> }}`
 * token. This module resolves those includes (recursion depth one; partials
 * may not include other partials), then hands the resulting string to the
 * scaffold engine's `substituteVars` core for variable / section / each
 * substitution.
 *
 * Keeping the partial resolver in `automation/` rather than extending
 * `scaffold/template.ts` keeps the scaffolder engine minimal and confines
 * the workflow-specific syntax to one file.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {substituteVars} from '../scaffold/template.js';
import type {TemplateVars} from '../scaffold/template.js';
import type {AutomationConfig, ToolId} from '../schemas/automation-config.js';
import {
  SCHEDULER_WORKFLOW_FILENAME,
  workflowPartialsDirectory,
  workflowSchedulerTemplatePath,
  workflowTemplatePath,
} from './paths.js';
import {buildSchedulerVars, buildWorkflowVars} from './workflow-vars.js';
import type {
  SchedulerTemplateVars,
  WorkflowTemplateVars,
} from './workflow-vars.js';

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
  vars: SchedulerTemplateVars | WorkflowTemplateVars
): string => {
  const raw = readFileSync(templatePath, 'utf8');
  const resolved = resolvePartials(raw, partialsDir);

  // Every field of both vars types is already a TemplateVars value
  // (string | boolean | string[]); the annotation is only needed because
  // `Object.entries` widens a union parameter's values to `any`.
  const engineVars: TemplateVars = Object.fromEntries(
    Object.entries<TemplateVars[string]>(vars)
  );

  return substituteVars(resolved, engineVars);
};

/** Which workflow to render: one tool's, or the scheduler that calls them. */
export type RenderTarget = {kind: 'scheduler'} | {kind: 'tool'; tool: ToolId};

/** The filename a rendered target is written to under `.github/workflows`. */
export const renderedWorkflowFilename = (target: RenderTarget): string =>
  target.kind === 'scheduler' ?
    SCHEDULER_WORKFLOW_FILENAME
  : `gaia-ci-${target.tool}.yml`;

/**
 * Render one target's workflow YAML, or `null` when the config disables it:
 * a tool whose mode is not `ci`, or a scheduler with no CI-mode tool to
 * schedule.
 *
 * The single place that pairs a target with its template, its vars, and the
 * partials directory. `render-workflows` writes what this returns and
 * `setup-ci check-drift` byte-compares against it, so the two cannot come to
 * different conclusions about what a fresh render is. A drift checker that
 * re-implemented the pipeline would report `in_sync` against a render the
 * writer would never produce, and `/setup-gaia` would skip a re-render that
 * was genuinely needed.
 */
export const renderWorkflowFor = (
  config: AutomationConfig,
  target: RenderTarget
): null | string => {
  const vars =
    target.kind === 'scheduler' ?
      buildSchedulerVars(config)
    : buildWorkflowVars(config, target.tool);

  if (vars === null) return null;

  const templatePath =
    target.kind === 'scheduler' ?
      workflowSchedulerTemplatePath()
    : workflowTemplatePath(target.tool);

  return renderWorkflowTemplate(
    templatePath,
    workflowPartialsDirectory(),
    vars
  );
};
