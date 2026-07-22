// Static `import.meta.env.<KEY>` access is required: Vite's `define` replaces
// the literal text, so a computed `import.meta.env[key]` lookup is never
// substituted and reads undefined. `Record` over clientSchema's own key union
// makes every key mandatory here, so this literal must name exactly the keys
// that schema allows in a browser: no more, no fewer.
window.process.env = {
  API_URL: import.meta.env.API_URL,
  COMMIT_SHA: import.meta.env.COMMIT_SHA,
  MSW_ENABLED: import.meta.env.MSW_ENABLED,
  NODE_ENV: import.meta.env.NODE_ENV,
  npm_package_version: import.meta.env.npm_package_version,
} satisfies Record<keyof Window['process']['env'], unknown>;
