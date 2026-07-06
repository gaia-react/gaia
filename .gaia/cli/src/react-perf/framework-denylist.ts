/**
 * Framework / library component name denylist for the reduce filter.
 *
 * v1 is a NAME heuristic, NOT a source-path check: bippy records carry
 * `componentName` + `kind` but no source module path, so "is this framework
 * or app code?" is decided by name alone. This is the SETTLED v1 boundary
 * (handoff §5, fixloop-validation §2); a path-based boundary (`/node_modules/`
 * vs `app/`) is explicitly deferred and is a prerequisite for any future
 * auto-fix. The limitation: a hostile or unusual component name can slip
 * through, and an app component that happened to share a framework name would
 * be filtered as noise. No app component currently collides with this cohort.
 *
 * The cohort below is the React Router v7 / Remix internal set plus the
 * react-icons base, drawn from the fixloop noisy-capture (`RenderedRoute`,
 * `WithComponentProps2`, `Form`, `fetcher.Form`, `IconBase`, `Outlet`,
 * `Router`, `Links`, `Link`, `Scripts`, `ScrollRestoration`,
 * `HydratedRouter`, `DataRoutes2`, ...). Individual react-icons exports
 * (`FaGithub`, `IoDesktopOutline`, ...) are matched by the pack-prefix regex.
 */

const FRAMEWORK_NAMES: ReadonlySet<string> = new Set([
  // React Router v7 / Remix internals.
  'DataRoutes2',
  'fetcher.Form',
  // React Router form primitives (no app component renders as `Form`).
  'Form',
  'HydratedRouter',
  // react-icons shared base wrapper.
  'IconBase',
  'Link',
  'Links',
  'Outlet',
  'RemixErrorBoundary',
  'RenderedRoute',
  'RenderErrorBoundary',
  'Router',
  'RouterProvider',
  'RouterProvider2',
  'Scripts',
  'ScrollRestoration',
  'WithComponentProps2',
]);

/**
 * react-icons exports are named `<PackPrefix><IconName>` where the prefix is
 * a known 2-3 letter pack code (Fa, Io, Md, ...) followed by an uppercase
 * letter. Matching the pack prefix filters the whole icon cohort without
 * enumerating thousands of icon names.
 */
const REACT_ICONS_PREFIX =
  /^(Ai|Bi|Bs|Cg|Ci|Di|Fa|Fc|Fi|Gi|Go|Gr|Hi|Im|Io|Lia|Lu|Md|Pi|Ri|Rx|Si|Sl|Tb|Tfi|Ti|Vsc|Wi)[A-Z]/;

/**
 * True when `componentName` belongs to the framework/library cohort and
 * should be dropped from the app-owned re-render metric. Pure.
 */
export const isFrameworkComponent = (componentName: string): boolean =>
  FRAMEWORK_NAMES.has(componentName) || REACT_ICONS_PREFIX.test(componentName);
