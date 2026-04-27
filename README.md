# GAIA React

<img src="./app/assets/images/gaia-logo.svg" height="100" alt="GAIA"/>

[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/github/actions/workflow/status/gaia-react/gaia/tests.yml?event=pull_request&label=tests)](https://github.com/gaia-react/gaia/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/github/license/gaia-react/gaia)](./LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D22.19.0-brightgreen)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)

**Claude as your senior engineer.** GAIA is the React workflow for Claude that makes Claude trustworthy enough to own features end-to-end, token-efficient enough to do it at scale, and grounded enough in the stack to answer how-do-I questions without re-reading the codebase.

Everything is configured _and_ documented for Claude in a way that keeps per-request costs down and output quality up.

## Who it's for

- Solo developers shipping Claude-built projects
- Product teams standardizing how Claude works across the org
- Agencies that want a templated starting point for client work

If Claude writes most of your code, GAIA is the substrate that makes it trustworthy.

## Quick Start

Make sure you have [Node.js](https://nodejs.org/en/) >= 22.19.0 installed, preferably via [nvm](https://github.com/nvm-sh/nvm).

```bash
npx create-gaia my-app
```

This pulls the latest tagged release (scrubbed of dev notes), sets up `.gaia/VERSION` for later `/gaia-update` runs, and `git init`s your project. Then open Claude Code in the project and run `/gaia-init` to configure i18n, strip GAIA branding, and install Claude plugins.

[Documentation](https://gaia-react.github.io/)

## The two problems GAIA solves

Most React setups treat Claude as a tool you hold — bolt a `CLAUDE.md` onto the root and hope the model figures out the rest. GAIA treats Claude as an engineer you _manage_. That shift exposes two failure modes the bolt-on approach papers over.

### Trust

You can't manage an engineer you can't predict. Without enforceable conventions, Claude reverts to its training distribution — an average of every codebase on the internet, bad code and all. GAIA's codebase is what you actually want Claude matching. With GAIA, Claude writes code that follows best practices on day one — and can't ship code that doesn't.

### Token economics

Context bloat isn't just `CLAUDE.md` sprawl. Instructions get dropped into global memory, forgotten, and accumulate into redundancies and conflicts — an invisible cost that compounds every session. GAIA keeps token usage minimal by design.

## How GAIA makes Claude trustworthy

- **Coding principles.** GAIA's coding rules embed [Karpathy's four coding principles](https://github.com/forrestchang/andrej-karpathy-skills/blob/main/CLAUDE.md) — Think Before Coding, Simplicity First, Surgical Changes, and Goal-Driven Execution — plus two of GAIA's own: Always Use TDD and Always Verify Your Work.
- **Best practices baked in.** Rules encode the conventions directly instead of hoping Claude infers them from whatever's already in the repo.
- **Guardrails against technical debt.** Rules block debt-accumulating patterns from being written in the first place — untyped exports, untested components, hardcoded strings, a11y gaps.
- **Consistently clean code.** 20+ ESLint plugins, strict TypeScript, and Prettier enforce style and correctness on every file Claude touches — no negotiation, no drift.
- **Test-driven development** via the bundled `tdd` skill. Red-green-refactor loop, tests before code — tailored for Vitest, React Testing Library, Storybook `composeStory`, and MSW.
- **Code-review audit before every merge.** A Claude subagent scans the branch diff for security, performance, code smells, and antipatterns — and blocks the merge until the issues are fixed and committed.
- **Quality gate before commit** — typecheck, lint, tests, and build must all pass. Not "mostly clean" — actually clean.

## How GAIA keeps Claude token-efficient

- **Rules are scoped to activate only when needed.** Claude loads the ones that match what it's editing — nothing else.
- **[Obsidian](https://obsidian.md) wiki, fetched on demand.** Project knowledge lives as focused, linked Markdown pages. Claude opens the one page it needs — _"How does dark mode wire through?"_ — instead of preloading the whole manual.
- **Wiki behavior tailored to GAIA.** Session hooks keep Obsidian's workflow (ingest cadence, cache discipline, link hygiene) aligned with the project's conventions.
- **Periodic knowledge audit** sweeps memory, wiki, and autoloaded files for duplication, conflicts, and stale instructions before they start costing tokens.
- **Session continuity.** `/handoff` + `/pickup` replace re-briefing Claude from scratch at every session start.

## Tech Stack

Every piece of GAIA's [tech stack](https://gaia-react.github.io/#stack) is pre-configured and wired into the Claude layer.

- **20+ ESLint plugins** with [Prettier](https://prettier.io/) and [Stylelint](https://stylelint.io/) for clean, consistent code from the first commit
- **Pre-commit hooks** ([Husky](https://typicode.github.io/husky/) + [lint-staged](https://github.com/lint-staged/lint-staged)) — typecheck, lint, and test before CI
- **Four testing layers sharing one mock layer** — [Vitest](https://vitest.dev) + [React Testing Library](https://testing-library.com/docs/react-testing-library/intro/) for unit/integration, [Playwright](https://playwright.dev/docs/intro) for E2E, [Chromatic](https://chromatic.com/) for visual regression
- **Internationalization** via [remix-i18next](https://github.com/sergiodxa/remix-i18next) with working examples
- **Form components with validation** using [Conform](https://conform.guide/) + [Zod](https://zod.dev/)
- **Dark mode end-to-end** — context, session, CSS, and Storybook all in sync
- **[Storybook](https://storybook.js.org/)** with React Router + i18n + dark mode + [MSW](https://mswjs.io/) integration
- **API mocking** with [Mock Service Worker](https://mswjs.io/) and [msw/data](https://github.com/mswjs/data), working handlers for tests and Storybook
- **Toast notifications** with [remix-toast](https://remix.run/resources/remix-toast) and [Sonner](https://sonner.emilkowal.ski/)
- Built on [React Router 7](https://reactrouter.com/), [Tailwind](https://tailwindcss.com/), and [FontAwesome](https://fontawesome.com/) icons

## How GAIA Compares

Opinionated starter templates solve different slices of the "day-zero engineering setup" problem. GAIA focuses on making Claude a first-class collaborator.

### Foundation

|                          |         GAIA          |   Epic Stack   | create-t3-app |     RedwoodJS     |
| ------------------------ | :-------------------: | :------------: | :-----------: | :---------------: |
| TypeScript               |          ✅           |       ✅       |      ✅       |        ✅         |
| Routing                  |    React Router 7     | React Router 7 |    Next.js    | @redwoodjs/router |
| Tailwind                 |          ✅           |       ✅       |      ✅       |        ❌         |
| Dark mode                |          ✅           |       ✅       |      ❌       |        ❌         |
| i18n                     |          ✅           |       ❌       |      ❌       |        ❌         |
| Unit / integration tests |        Vitest         |     Vitest     |      ❌       |       Jest        |
| Component testing        | Storybook + Chromatic |       ❌       |      ❌       |     Storybook     |
| E2E tests                |      Playwright       |   Playwright   |      ❌       |        ❌         |
| Mock API                 |          MSW          |       ❌       |      ❌       |        ❌         |
| Forms                    |     Conform + Zod     |       ❌       |      ❌       |        ❌         |
| Accessibility guardrails |          ✅           |       ❌       |      ❌       |        ❌         |

### Claude-native

Only GAIA comes with Claude tooling built-in. It includes path-scoped rules, enforcement hooks, useful commands and skills, a code-review audit agent, and Obsidian wiki integration.

## Agentic Design

Agentic design is the discipline of building AI systems that act autonomously toward goals rather than passively responding to prompts. The canonical patterns — Reflection, ReAct, Planning, and Multi-Agent collaboration — are all first-class in GAIA.

| Pattern         | How GAIA implements it                                                                                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Reflection**  | Code-review audit evaluates every branch diff for security, performance, and antipatterns; quality gate enforces clean output before every commit                                                 |
| **ReAct**       | Claude consults the Obsidian wiki before acting, uses ESLint / Vitest / Playwright as observation tools, and iterates until gates pass                                                            |
| **Planning**    | For complex features, Claude plans before it codes — then an orchestrator drives focused subagents through each phase, keeping context tight and nothing running without your sign-off            |
| **Multi-Agent** | Code-review audit spawns three specialist subagents in parallel (React Patterns, TypeScript & Architecture, Translation); the orchestrator pattern dispatches implementation agents across phases |

Principles including Autonomy, Tool Use, Memory & Context, and Exception Handling & Recovery are each enforced structurally. Scoped rules bound Claude's decision space; ESLint, Vitest, Playwright, and MSW are Claude's tool layer; the Obsidian wiki and `/handoff` + `/pickup` provide persistent memory; and the quality gate plus code-review audit are mandatory checkpoints before commits and merges.

## One-Command Initialization

GAIA ships clean. `/init` finishes the last-mile setup:

- **Configures your project** — prompts for a title, sets the package name, docs title, CODEOWNERS, and localized site titles
- **Installs dependencies** — bootstraps pnpm via `corepack` and runs `pnpm install` for you
- **Configures i18n** — prompts for your language set, scaffolds the matching language files, and updates the component and Storybook wiring
- **Installs Claude skills and plugins** — [React Doctor](https://github.com/millionco/react-doctor), [Playwright CLI](https://github.com/microsoft/playwright-cli), `typescript-lsp`, and [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian)

After `/init` finishes, you have a clean app shell **and** a fully-configured Claude workflow ready to use.

## Claude Workflow

GAIA ships a complete, opinionated Claude Code workflow. Everything is wired in `.claude/` and visible in the repo.

### Commands

<table>
<thead><tr><th nowrap>Command</th><th>What it does</th></tr></thead>
<tbody>
<tr><td><code>/init</code></td><td>Full project initialization (see above)</td></tr>
<tr><td><code>/orchestrate</code></td><td>Plan a complex feature. Claude structures the work, you approve, then an orchestrator drives focused subagents through execution</td></tr>
<tr><td><code>/gaia-update</code></td><td>Merges the latest GAIA release without overwriting your customizations</td></tr>
<tr><td><code>/update-deps</code></td><td>Upgrades outdated packages and handles any necessary code changes - a superpowered Dependabot</td></tr>
<tr><td><code>/audit-knowledge</code></td><td>Audit memory, wiki, and auto-loaded files for duplication, conflicting instructions, and bloat</td></tr>
<tr><td><code>/handoff</code></td><td>Generate a comprehensive session handoff document so you can clear the context with confidence that nothing will get lost</td></tr>
<tr><td><code>/pickup</code></td><td>Restore context from handoff and continue work</td></tr>
</tbody>
</table>

### Rules, hooks, skills

- **Path-scoped rules** cover TypeScript, React, Tailwind, testing, i18n, accessibility, and state management. Ask Claude about any of them — they're in `.claude/rules/`.
- **Hooks** guard the quality gate and keep the wiki fresh. Ask Claude what they do.
- **Bundled skills** (`typescript`, `react-code`, `tailwind`, `skeleton-loaders`, `tdd`, `playwright-cli`) autoload for matching tasks.

### Code review before merge

Every merge runs through a code-review pass against the branch diff — security, performance, code smells, antipatterns — and blocks until the issues are fixed and committed.

### Wiki

GAIA ships with an [Obsidian](https://obsidian.md) wiki knowledge base — architecture, modules, dependencies, decisions, flows, concepts — committed to git and shared across the team. The [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) plugin (installed by `/init`) adds `/wiki-ingest`, `/wiki-query`, `/wiki-lint`, `/autoresearch`, and `/save` for working with the vault. Open `wiki/` in Obsidian for graph view, backlinks, and search.

## Development

GAIA is driven through Claude. Ask for what you need.

**Build things:**

- _"Add a new route for settings."_ → triggers `/new-route`, applies routing + i18n + test rules.
- _"Add German as a supported language."_ → Claude walks the i18n setup.
- _"Add a zip-code field to the address form with validation."_ → Claude uses the form patterns from the wiki.

**Ask about the codebase:**

- _"How does dark mode wire through?"_ → Claude fetches the wiki page on demand.
- _"What state patterns do we use?"_ → one-page lookup, no context bloat.
- _"Explain the form-submit flow."_ → direct answer from the wiki.

**Extend:**

- Rules, hooks, skills, and commands live in `.claude/`. Ask Claude to add, modify, or explain any of them.

## Testing

Ask Claude to run, add, or debug tests — Vitest, Storybook + Chromatic, and Playwright are all wired up.

## Deployment

GAIA isn't prescriptive about hosting. Ask Claude to set up your deployment for the target you want — Vercel, Cloudflare, Fly, AWS, a bare Node host, a Docker container, anywhere React Router can run. Claude will wire up the build, environment variables, and any CI/CD you need.

## History

The GAIA Flash Framework was Flash's most popular framework — **its killer feature was automation**. It collapsed repetitive Flash plumbing into a few declarative patterns so engineers could focus on the product, and was used on over 100,000 sites at every major digital agency worldwide.

GAIA React carries that automation philosophy into the AI-native era. Where the original automated Flash boilerplate, GAIA automates the Claude workflow — conventions, rules, hooks, gates, wiki — so you can ship features end-to-end without wiring the scaffolding every time.
