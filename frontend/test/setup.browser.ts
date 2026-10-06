// Browser tests assert through `expect.element`, which needs no jest-dom matchers.

// Mirrors `.storybook/preview-head.html`: a story module that builds an MSW
// handler URL at load time reads `process.env`, so a browser test importing
// stories needs the same empty seed Storybook gives them.
const processHolder = globalThis as {process?: {env: Record<string, unknown>}};

processHolder.process ??= {env: {}};

export {};
