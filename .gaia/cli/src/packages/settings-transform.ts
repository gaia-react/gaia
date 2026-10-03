/**
 * The pure half of `gaia packages sync-settings` (SPEC-092 contract C8): turn
 * the root `.claude/settings.json` plus an optional package overlay into the
 * complete settings file a session launched in the package directory needs.
 *
 * Claude Code reads settings only from the launch directory, so the generated
 * file must carry every hook and deny the root file carries, with each path
 * rule re-anchored so it names the same repository path from the package
 * directory. Nothing here touches the filesystem.
 */

const PATH_RULE = /^(Edit|MultiEdit|NotebookEdit|Read|Write)\((.*)\)$/s;
const SAFE_PATH = /^[\w./*{},~@+-]+$/;
const PERMISSION_LISTS = ['allow', 'ask', 'deny'] as const;
const OVERLAY_PERMISSION_KEYS = new Set<string>(PERMISSION_LISTS);
const OVERLAY_KEYS = new Set(['env', 'permissions']);

export type JsonObject = Record<string, unknown>;

/** A generation refusal: the message names the cause and the next step. */
export class SettingsGenerationError extends Error {}

const isObject = (value: unknown): value is JsonObject =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const stringList = (value: unknown, label: string): string[] => {
  if (
    !Array.isArray(value) ||
    !value.every((entry) => typeof entry === 'string')
  ) {
    throw new SettingsGenerationError(
      `${label} must be an array of strings. Next step: fix the file and re-run.`
    );
  }

  return value;
};

const requireSafePath = (spec: string, label: string): void => {
  if (!SAFE_PATH.test(spec)) {
    throw new SettingsGenerationError(
      `${label} path "${spec}" has characters outside [A-Za-z0-9._/*{},~@+-]. Next step: rewrite the rule with a plain path.`
    );
  }
};

/**
 * Re-anchor one path spec. A spec beginning `**` + `/`, `//`, or `~/` is
 * unchanged; any other spec gets `prefix` prepended, after one leading `./` or
 * `/` is dropped.
 */
export const reanchorSpec = (spec: string, prefix: string): string => {
  if (/^(\*\*\/|\/\/|~\/)/.test(spec)) {
    return spec;
  }

  return `${prefix}${spec.replace(/^(\.\/|\/)/, '')}`;
};

/** Re-anchor a permission rule. Rules that carry no path copy unchanged. */
export const reanchorRule = (
  rule: string,
  prefix: string,
  label: string
): string => {
  const parts = PATH_RULE.exec(rule);

  if (parts === null) {
    return rule;
  }
  const [, tool = '', spec = ''] = parts;
  const anchored = reanchorSpec(spec, prefix);

  requireSafePath(anchored, label);

  return `${tool}(${anchored})`;
};

const reanchorPermissionList = (
  list: unknown,
  prefix: string,
  label: string
): string[] =>
  stringList(list, label).map((rule) => reanchorRule(rule, prefix, label));

const unique = (entries: readonly string[]): string[] => [...new Set(entries)];

const reanchorSandbox = (sandbox: unknown, prefix: string): unknown => {
  if (!isObject(sandbox) || !isObject(sandbox.filesystem)) {
    return sandbox;
  }
  const filesystem: JsonObject = {};

  for (const [key, entries] of Object.entries(sandbox.filesystem)) {
    const label = `sandbox.filesystem.${key}`;

    filesystem[key] = stringList(entries, label).map((entry) => {
      const anchored = reanchorSpec(entry, prefix);

      requireSafePath(anchored, label);

      return anchored;
    });
  }

  return {...sandbox, filesystem};
};

type Overlay = {
  env: Record<string, string>;
  permissions: Record<(typeof PERMISSION_LISTS)[number], string[]>;
};

const emptyOverlay = (): Overlay => ({
  env: {},
  permissions: {allow: [], ask: [], deny: []},
});

const parseOverlayPermissions = (
  permissions: unknown
): Overlay['permissions'] => {
  const parsed = emptyOverlay().permissions;

  if (!isObject(permissions)) {
    throw new SettingsGenerationError(
      'the overlay permissions must be an object. Next step: fix the overlay file.'
    );
  }

  for (const key of Object.keys(permissions)) {
    if (!OVERLAY_PERMISSION_KEYS.has(key)) {
      throw new SettingsGenerationError(
        `the overlay key "permissions.${key}" is not allowed: only allow, deny, and ask may be added. Next step: remove "permissions.${key}" from the overlay.`
      );
    }
  }

  for (const list of PERMISSION_LISTS) {
    const label = `the overlay permissions.${list}`;

    parsed[list] = stringList(permissions[list] ?? [], label);

    for (const rule of parsed[list]) {
      const spec = PATH_RULE.exec(rule)?.[2];

      if (spec !== undefined) {
        requireSafePath(spec, label);
      }
    }
  }

  return parsed;
};

/** Validate the union-only overlay and return its additions. */
export const parseOverlay = (overlay: unknown): Overlay => {
  if (!isObject(overlay)) {
    throw new SettingsGenerationError(
      'the overlay must be a JSON object. Next step: fix the overlay file.'
    );
  }

  for (const key of Object.keys(overlay)) {
    if (!OVERLAY_KEYS.has(key)) {
      throw new SettingsGenerationError(
        `the overlay key "${key}" is not allowed: an overlay is union-only and may add only permissions.allow, permissions.deny, permissions.ask, and env keys. Next step: remove "${key}" from the overlay.`
      );
    }
  }
  const parsed = emptyOverlay();

  if (overlay.permissions !== undefined) {
    parsed.permissions = parseOverlayPermissions(overlay.permissions);
  }

  if (overlay.env !== undefined) {
    if (
      !isObject(overlay.env) ||
      !Object.values(overlay.env).every((value) => typeof value === 'string')
    ) {
      throw new SettingsGenerationError(
        'the overlay env must be an object of string values. Next step: fix the overlay file.'
      );
    }
    parsed.env = overlay.env as Record<string, string>;
  }

  return parsed;
};

const mergeEnvironment = (
  rootEnvironment: unknown,
  additions: Record<string, string>
): JsonObject => {
  const merged: JsonObject =
    isObject(rootEnvironment) ? {...rootEnvironment} : {};

  for (const [key, value] of Object.entries(additions)) {
    if (Object.hasOwn(merged, key) && merged[key] !== value) {
      throw new SettingsGenerationError(
        `the overlay env key "${key}" would change a value the root settings set. Next step: remove it from the overlay.`
      );
    }
    merged[key] = value;
  }

  return merged;
};

/** Root permissions re-anchored, then the overlay's additions unioned in. */
const buildPermissions = (
  rootPermissions: JsonObject,
  overlay: Overlay,
  prefix: string
): JsonObject => {
  const permissions: JsonObject = {};

  for (const [key, value] of Object.entries(rootPermissions)) {
    permissions[key] =
      PERMISSION_LISTS.includes(key) ?
        reanchorPermissionList(value, prefix, `permissions.${key}`)
      : value;
  }
  const rootDeny = stringList(rootPermissions.deny ?? [], 'permissions.deny');
  const forbidden = new Set([
    ...rootDeny,
    ...rootDeny.map((rule) => reanchorRule(rule, prefix, 'permissions.deny')),
  ]);

  for (const list of PERMISSION_LISTS) {
    const additions = overlay.permissions[list];
    const attempt =
      list === 'deny' ? undefined : (
        additions.find((rule) => forbidden.has(rule))
      );

    if (attempt !== undefined) {
      throw new SettingsGenerationError(
        `the overlay permissions.${list} entry "${attempt}" equals a root permissions.deny entry and would re-open what the root denies. Next step: remove it from the overlay.`
      );
    }

    if (additions.length > 0) {
      permissions[list] = unique([
        ...stringList(permissions[list] ?? [], `permissions.${list}`),
        ...additions,
      ]);
    }
  }

  return permissions;
};

/**
 * Settings for the package at `packagePath` (never `.`). Key order follows the
 * root file; `additionalDirectories` is appended last inside `permissions`.
 */
export const generateSettings = (
  rootSettings: JsonObject,
  overlayInput: unknown,
  packagePath: string
): JsonObject => {
  const depth = packagePath.split('/').length;
  const prefix = '../'.repeat(depth);
  const overlay = parseOverlay(overlayInput);
  const rootPermissions =
    isObject(rootSettings.permissions) ? rootSettings.permissions : {};
  const permissions = buildPermissions(rootPermissions, overlay, prefix);

  permissions.additionalDirectories = unique([
    ...reanchorPermissionList(
      rootPermissions.additionalDirectories ?? [],
      prefix,
      'permissions.additionalDirectories'
    ),
    `${'../'.repeat(depth - 1)}..`,
  ]);
  const output: JsonObject = {};

  for (const [key, value] of Object.entries(rootSettings)) {
    if (key === 'sandbox') {
      output[key] = reanchorSandbox(value, prefix);
    } else if (key === 'env') {
      output[key] = mergeEnvironment(value, overlay.env);
    } else {
      output[key] = value;
    }
  }
  output.permissions = permissions;

  if (!Object.hasOwn(output, 'env') && Object.keys(overlay.env).length > 0) {
    output.env = mergeEnvironment(undefined, overlay.env);
  }

  return output;
};

/** The stable on-disk form: two-space JSON, trailing newline. */
export const serializeSettings = (settings: JsonObject): string =>
  `${JSON.stringify(settings, null, 2)}\n`;
