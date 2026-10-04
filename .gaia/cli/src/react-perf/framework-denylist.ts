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
 * The cohort below is the React Router v7 / Remix internal set, drawn from the
 * fixloop noisy-capture (`RenderedRoute`, `WithComponentProps2`, `Form`,
 * `fetcher.Form`, `Outlet`, `Router`, `Links`, `Link`, `Scripts`,
 * `ScrollRestoration`, `HydratedRouter`, `DataRoutes2`, ...), plus every bare
 * `ForwardRef` record (see `isFrameworkComponent`).
 */

const FRAMEWORK_NAMES: ReadonlySet<string> = new Set([
  // React Router v7 / Remix internals.
  'DataRoutes2',
  'fetcher.Form',
  // React Router form primitives (no app component renders as `Form`).
  'Form',
  'HydratedRouter',
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
 * lucide-react renders each icon as two `ForwardRef` records: a wrapper named
 * with the plain PascalCase icon name (`Sun`, `X`, `Copy`) and a shared base
 * `Icon` with no display name at all (recorded as `Unknown`). A prefix regex
 * cannot select plain names, and a name list would collide with an app
 * component that happens to be called `Sun` or `Copy`, so the cohort is
 * selected by record `kind` instead: a bare `ForwardRef` is dropped.
 *
 * Trade-off: an app component declared with `forwardRef` is filtered as noise
 * too, so it can never surface as an over-budget finding. It is never lost as a
 * memo defeat, because `memo(forwardRef(...))` records as `Memo`, not
 * `ForwardRef`. GAIA components take `ref` as a plain prop (React 19), so app
 * code seldom produces this kind.
 */
const FRAMEWORK_KIND = 'ForwardRef';

/**
 * True when a render record belongs to the framework/library cohort and should
 * be dropped from the app-owned re-render metric. `kind` is optional because
 * legacy dumps carry no `kind` field. Pure.
 */
export const isFrameworkComponent = (
  componentName: string,
  kind?: string
): boolean => FRAMEWORK_NAMES.has(componentName) || kind === FRAMEWORK_KIND;
