/**
 * Every path the app submits a fetcher to.
 *
 * React Router derives each of these from its route file's name, so a copy of
 * one at a call site goes stale the moment that file is renamed, and every way
 * it then fails is silent: the submission 404s, an optimistic update stops
 * applying while the POST still succeeds, or a story renders the router's error
 * boundary in place of the component. The app and the router test stub both
 * read these values, and a test asserts each one still resolves to a real
 * route. Completeness here is a convention, not a check: nothing stops a new
 * call site writing its own literal, and a path that never lands in this object
 * is one neither that test nor the stub knows about.
 */
export const ACTION_PATHS = {
  setLanguage: '/actions/set-language',
  themeSwitch: '/resources/theme-switch',
} as const;
