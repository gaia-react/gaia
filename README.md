# GAIA React

<img src="./app/assets/images/gaia-logo.svg" height="100" alt="GAIA"/>

[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/github/actions/workflow/status/gaia-react/gaia/tests.yml?event=pull_request&label=tests)](https://github.com/gaia-react/gaia/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/github/license/gaia-react/gaia)](./LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D22.19.0-brightgreen)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)

**The React workflow for Claude.** GAIA makes Claude trustworthy enough to own features end to end, and disciplined enough to do it at scale.

Every convention is enforced in code, not described in prose. Per-request token cost stays low because rules and wiki pages load on demand, not preloaded.

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

Then open Claude Code in the project folder and run `/init` to walk through the GAIA setup process.

[Documentation](https://gaiareact.com/)

## The two problems GAIA solves

Most setups treat Claude as a tool you hold. They bolt a `CLAUDE.md` onto the root and hope the model figures out the rest. GAIA treats Claude as an engineer you _manage_. That shift exposes two failure modes the bolt-on approach papers over.

### Trust

You can't manage an engineer you can't predict. Without enforceable conventions, Claude reverts to its training distribution: an average of every codebase on the internet, bad code and all. GAIA's codebase is what you actually want Claude matching. With GAIA, Claude writes code that follows best practices on day one, and can't ship code that doesn't.

### Token economics

Context bloat isn't just `CLAUDE.md` sprawl. Instructions get dropped into global memory, forgotten, and accumulate into redundancies and conflicts. That invisible cost compounds every session. GAIA keeps token usage minimal by design.

## How GAIA makes Claude trustworthy

- **Coding principles.** GAIA's coding rules embed [Karpathy's four coding principles](https://github.com/forrestchang/andrej-karpathy-skills/blob/main/CLAUDE.md) (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution), plus two of GAIA's own: Always Use TDD and Always Verify Your Work.
- **Best practices baked in.** Rules encode the conventions directly instead of hoping Claude infers them from whatever's already in the repo.
- **Guardrails against technical debt.** Rules block debt-accumulating patterns from being written in the first place: untyped exports, untested components, hardcoded strings, a11y gaps.
- **Consistently clean code.** 20+ ESLint plugins, strict TypeScript, and Prettier enforce style and correctness on every file Claude touches. No negotiation, no drift.
- **Test-driven development** via the bundled `tdd` skill. Red-green-refactor loop, tests before code, tailored for Vitest, React Testing Library, Storybook `composeStory`, and MSW.
- **Code-review audit before every merge.** A Claude subagent scans the branch diff for security, performance, code smells, and antipatterns. It blocks the merge until the issues are fixed and committed.
- **Quality gate before commit.** Typecheck, lint, tests, and build must all pass. Not "mostly clean." Actually clean.

## How GAIA keeps Claude token-efficient

- **Rules are scoped to activate only when needed.** Claude loads the ones that match what it's editing. Nothing else.
- **[Obsidian](https://obsidian.md) wiki, fetched on demand.** Project knowledge lives as focused, linked Markdown pages. Claude opens the one page it needs (_"How does dark mode wire through?"_) instead of preloading the whole manual.
- **Wiki behavior tailored to GAIA.** Session hooks keep Obsidian's workflow (ingest cadence, cache discipline, link hygiene) aligned with the project's conventions.
- **Periodic knowledge audit** sweeps memory, wiki, and autoloaded files for duplication, conflicts, and stale instructions before they start costing tokens.
- **Session continuity.** `/gaia handoff` + `/gaia pickup` replace re-briefing Claude from scratch at every session start.

## Tech Stack

Every piece of GAIA's [tech stack](https://gaiareact.com/#stack) is pre-configured and wired into the Claude layer.

- **20+ ESLint plugins** with [Prettier](https://prettier.io/) and [Stylelint](https://stylelint.io/) for clean, consistent code from the first commit
- **Pre-commit hooks** ([Husky](https://typicode.github.io/husky/) + [lint-staged](https://github.com/lint-staged/lint-staged)): typecheck, lint, and test before CI
- **Four testing layers sharing one mock layer**: [Vitest](https://vitest.dev) + [React Testing Library](https://testing-library.com/docs/react-testing-library/intro/) for unit/integration, [Playwright](https://playwright.dev/docs/intro) for E2E, [Chromatic](https://chromatic.com/) for visual regression
- **Internationalization** via [remix-i18next](https://github.com/sergiodxa/remix-i18next) with working examples
- **Form components with validation** using [Conform](https://conform.guide/) + [Zod](https://zod.dev/)
- **Dark mode end-to-end.** Context, session, CSS, and Storybook all in sync.
- **[Storybook](https://storybook.js.org/)** with React Router + i18n + dark mode + [MSW](https://mswjs.io/) integration
- **API mocking** with [Mock Service Worker](https://mswjs.io/) and [msw/data](https://github.com/mswjs/data), working handlers for tests and Storybook
- **Toast notifications** with [remix-toast](https://remix.run/resources/remix-toast) and [Sonner](https://sonner.emilkowal.ski/)
- Built on [React Router 7](https://reactrouter.com/), [Tailwind](https://tailwindcss.com/), and [FontAwesome](https://fontawesome.com/) icons

## How GAIA Compares

Opinionated starter templates solve different slices of the "day-zero engineering setup" problem. GAIA focuses on making Claude a first-class collaborator.

|                          |      GAIA      |   Epic Stack   | create-t3-app |     RedwoodJS     |
| ------------------------ | :------------: | :------------: | :-----------: | :---------------: |
| Routing                  | React Router 7 | React Router 7 |    Next.js    | @redwoodjs/router |
| TypeScript               |       ✅       |       ✅       |      ✅       |        ✅         |
| Tailwind                 |       ✅       |       ✅       |      ✅       |        ❌         |
| Unit / integration tests |       ✅       |       ✅       |      ❌       |        ✅         |
| E2E tests                |       ✅       |       ✅       |      ❌       |        ❌         |
| Storybook                |       ✅       |       ❌       |      ❌       |        ✅         |
| Visual regression tests  |       ✅       |       ❌       |      ❌       |        ❌         |
| Dark mode                |       ✅       |       ✅       |      ❌       |        ❌         |
| i18n                     |       ✅       |       ❌       |      ❌       |        ❌         |
| Mock API                 |       ✅       |       ❌       |      ❌       |        ❌         |
| Forms                    |       ✅       |       ❌       |      ❌       |        ❌         |
| Accessibility guardrails |       ✅       |       ❌       |      ❌       |        ❌         |
| Lint rules               |     1,592      |      748       |      637      |        626        |

Every lint rule is a check Claude has to clear. GAIA ships more than twice as many as any other starter, including 85 Stylelint rules none of the others have. The extras catch the patterns Claude drifts into first: complexity creep, architectural shortcuts, mismatched filenames, broken CSS.

### Built for Claude

Only GAIA ships with the Claude layer wired in: path-scoped rules, enforcement hooks, commands, skills, a code-review audit agent, and Obsidian wiki integration. GAIA was strict before Claude existed; that discipline is what keeps Claude's code clean now.

## Agentic Design

GAIA implements 12 of the 29 [canonical agentic design patterns](https://zeljkoavramovic.github.io/agentic-design-patterns/) structurally. Every load-bearing pattern is wired in through hooks, agents, rules, commands, or wiki conventions, so it runs the same way every session, every engineer, every model variant. The six below are the patterns with the clearest file-level evidence. The [features page](https://gaiareact.com/features/#agentic-design) breaks down all twelve.

| Pattern                         | How GAIA implements it                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **The Stop Hook**               | Pre-tool-use hooks intercept dangerous commands at the source. `block-main-destructive-git.sh` rejects commits and force-pushes against `main`; `block-bare-test.sh` blocks watch-mode `pnpm test`; `block-eslint-config-edit.sh` forces fixing source instead of silencing rules; `pr-merge-audit-check.sh` runs before `gh pr merge`; `block-rm-rf.sh` blocks destructive file removal; `block-env-write.sh` and `block-secrets-write.sh` block writes to env and credential files; `block-lockfile-edit.sh` blocks direct lockfile edits. All in `.claude/hooks/`, wired through `.claude/settings.json`. |
| **Resource-Aware Optimization** | Model tier follows task complexity. `/gaia audit` runs Stage 1 (research) and Stage 2 (mechanical apply) on Sonnet (`.claude/skills/gaia/references/audit.md`). `/gaia plan` defaults Opus for planning; the code-review audit declares `model: sonnet` in `.claude/agents/code-review-audit.md`.                                                                                                       |
| **Session Isolation**           | Sub-agents run in fresh contexts via the Agent tool. `/gaia plan` writes per-task docs into `.claude/plans/{slug}/`, each self-contained for a fresh-context sub-agent, and offers a git-worktree branch for filesystem-level isolation. `/gaia audit` splits research and apply across two isolated stages.                                                                                            |
| **Routing**                     | Path-scoped rules auto-load only when Claude is editing matching files. `.claude/rules/i18n.md` activates on `app/pages/**/*` and `app/components/**/*`; `.claude/rules/api-service.md` activates on `app/services/**/*`. Conditional `Bash` hooks in `.claude/settings.json` route commands to specific scripts based on command shape.                                                                |
| **Multi-Agent Collaboration**   | `code-review-audit` is a manager agent that dispatches React Patterns, TypeScript and Architecture, and Translation specialists in parallel from a single tool-call message, plus `react-doctor`. Extension files in `.claude/agents/code-review-audit/*.md` inject library-specific rules into the right subagent at runtime.                                                                          |
| **Guardrails & Safety**         | Filesystem deny list in `.claude/settings.json` covers `Read(.env)`, `Read(**/secrets/*)`, `Read(**/*credential*)`, `Read(**/*.pem)`, `Read(**/*.key)`. Tool allow list scopes Bash and Edit surfaces. Block hooks reject debt-accumulating patterns at the source. The audit's security dimension covers XSS, SSRF, IDOR, secret exposure, timing attacks, and dependency vulns.                       |

## One-Command Initialization

GAIA ships clean. `/gaia-init` finishes the last-mile setup:

- **Configures your project.** Prompts for a title, sets the package name, docs title, CODEOWNERS, and localized site titles.
- **Installs dependencies.** Bootstraps pnpm via `corepack` and runs `pnpm install` for you.
- **Configures i18n.** Prompts for your language set, scaffolds the matching language files, and updates the component and Storybook wiring.
- **Installs Claude skills and plugins.** [React Doctor](https://github.com/millionco/react-doctor), [Playwright CLI](https://github.com/microsoft/playwright-cli), `typescript-lsp`, and [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian).

After `/gaia-init` finishes, you have a clean app shell **and** a fully-configured Claude workflow ready to use.

## Claude Workflow

GAIA ships a complete, opinionated Claude Code workflow. Everything is wired in `.claude/` and visible in the repo.

### Commands

<table>
<thead><tr><th nowrap>Command</th><th>What it does</th></tr></thead>
<tbody>
<tr><td><code>/gaia plan</code></td><td>Plan a complex feature. Claude structures the work, you approve, then an orchestrator drives focused subagents through execution</td></tr>
<tr><td><code>/gaia audit</code></td><td>Audit memory, wiki, and auto-loaded files for duplication, conflicting instructions, and bloat</td></tr>
<tr><td><code>/gaia handoff</code></td><td>Generate a comprehensive session handoff document so you can clear the context with confidence that nothing will get lost</td></tr>
<tr><td><code>/gaia pickup</code></td><td>Restore context from handoff and continue work</td></tr>
</tbody>
</table>

### Rules, hooks, skills

- **Path-scoped rules** cover TypeScript, React, Tailwind, testing, i18n, accessibility, and state management. Ask Claude about any of them; they're in `.claude/rules/`.
- **Hooks** guard the quality gate and keep the wiki fresh. Ask Claude what they do.
- **Bundled skills** (`typescript`, `react-code`, `tailwind`, `skeleton-loaders`, `tdd`, `playwright-cli`, `eslint-fixes`) autoload for matching tasks. Scaffolding skills (`new-component`, `new-hook`, `new-route`, `new-service`) fire on natural-language asks.

### Code review before merge

Every merge runs through a code-review pass against the branch diff (security, performance, code smells, antipatterns), and blocks until the issues are fixed and committed.

### Staying up to date

GAIA keeps package dependencies and GAIA itself up to date. At session start, a background check runs; when updates are available, Claude will ask if you want to update now or later.

#### Dependencies

GAIA will update outdated packages, handle breaking-change migrations, and run the quality gate to make sure everything still works as expected.

#### GAIA Releases

When GAIA itself is updated, it will pull the latest version and perform three-way merges on affected files so any customizations or natural drift over the lifetime of a project survive.

### Wiki

GAIA ships with an [Obsidian](https://obsidian.md) wiki knowledge base (architecture, modules, dependencies, decisions, flows, concepts) committed to git and shared across the team. The [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) plugin (installed by `/gaia-init`) adds `/wiki-ingest`, `/wiki-query`, `/wiki-lint`, `/autoresearch`, and `/save` for working with the vault. Open `wiki/` in Obsidian for graph view, backlinks, and search.

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

Ask Claude to run, add, or debug tests. Vitest, Storybook + Chromatic, and Playwright are all wired up.

## Deployment

GAIA isn't prescriptive about hosting. Ask Claude to set up your deployment for the target you want: Vercel, Cloudflare, Fly, AWS, a bare Node host, a Docker container, anywhere React Router can run. Claude will wire up the build, environment variables, and any CI/CD you need.

## History

The GAIA Flash Framework was Flash's most popular framework. **Its killer feature was automation.** It collapsed repetitive Flash plumbing into a few declarative patterns so engineers could focus on the product, and was used on over 100,000 sites at every major digital agency worldwide.

GAIA React carries that automation philosophy into the AI-native era. Where the original automated Flash boilerplate, GAIA automates the Claude workflow (conventions, rules, hooks, gates, wiki) so you can ship features end-to-end without wiring the scaffolding every time.
