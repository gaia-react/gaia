---
type: dependency
status: active
package: '@playwright/cli'
role: browser-automation-cli
created: 2026-10-03
updated: 2026-10-03
tags: [dependency, testing, claude]
---

# playwright-cli

Command-line browser automation for Claude: open a page, snapshot it, click, fill, and capture traces or video. It drives the same Playwright engine as [[Playwright]], the test framework, but it is a separate tool for exploring and debugging a page interactively, not for the committed e2e suite.

## Conventions

- **Install the global binary.** GAIA expects `playwright-cli` on `PATH`: `npm install -g @playwright/cli@latest`. `/update-deps` reports the installed version against npm's latest and offers the upgrade interactively; it does not install without asking.
- **Without the global binary,** use the scoped package: `npx -y @playwright/cli`.
- **Never use the unscoped name.** `npx playwright-cli` resolves to the deprecated `playwright-cli` npm package, which is not this tool. The scoped `@playwright/cli` is the only correct package.
- **GAIA's invocation wins over upstream's suggestion.** The vendored `SKILL.md` prefers a local `npx playwright cli` when a project-local Playwright is present. In GAIA, use the global `playwright-cli` binary, or `npx -y @playwright/cli` without it. Run the e2e suite with `pnpm pw`, not `npx playwright test`.

## The vendored skill

The skill under `frontend/.claude/skills/playwright-cli/` is upstream's published folder, copied verbatim and never edited, so anything GAIA wants to say about it lives here. See [[Vendored Third-Party Skills]] for the convention. The vendored version is recorded in `.gaia/vendor/playwright-cli.json`; read it there.

<!-- gaia:maintainer-only:start -->
A maintainer-only `/update-deps` phase re-vendors the skill when upstream publishes a new version, and a maintainer-only offline check fails on any drift from the recorded marker.
<!-- gaia:maintainer-only:end -->
