// Chromatic snapshots every story once per mode. Each mode sets the `theme`
// global, which the Chromatic decorator applies as the `dark` class on <html>,
// and the 1280px desktop viewport. A story overrides a mode by key, for
// example `chromatic: {modes: {dark: {disable: true}}}` to snapshot light only,
// or `{dark: {viewport: 375}, light: {viewport: 375}}` for mobile width.
export const allModes = {
  dark: {theme: 'dark', viewport: 1280},
  light: {theme: 'light', viewport: 1280},
} as const;
