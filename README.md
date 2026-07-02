# GAIA React

<img src="./docs/assets/gaia-logo.svg" height="100" alt="GAIA"/>

[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/github/actions/workflow/status/gaia-react/gaia/tests.yml?event=pull_request&label=tests)](https://github.com/gaia-react/gaia/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/github/license/gaia-react/gaia)](./LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D22.22.0-brightgreen)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)

**Claude is raw power. [GAIA](https://gaiareact.com/) is order and focus.**

The foundation that keeps Claude-shipped code production-grade as your team scales. The React frontend is handled. You build the rest of your app on top. Every convention enforced in code. Every shortcut blocked at the source. Every merge audited before it lands.

**[Quick Start](#quick-start) · [What Breaks Claude](#what-breaks-claude-on-real-projects) · [Trust](#how-gaia-makes-claude-trustworthy) · [Token Economics](#how-gaia-keeps-claude-token-efficient) · [Tech Debt](#how-gaia-keeps-tech-debt-from-compounding) · [Tech Stack](#tech-stack) · [Claude Workflow](#claude-workflow) · [History](#history)**

## Who It's For

- Engineering teams whose AI output is outpacing their review process
- Engineering leads standardizing how Claude works across the org
- Teams adopting AI-assisted development who want production-grade defaults from the first commit
- Individuals building apps with Claude

## Quick Start

```bash
npx create-gaia@latest my-app
```

One command. GAIA handles the rest, then `/gaia-init` finishes the last-mile setup (below).

> [!NOTE]
> Start projects with `npx create-gaia@latest my-app` rather than cloning or forking. The CLI sets up your project for you, strips the GAIA branding and release tooling, etc. A clone leaves all of that in place and pointed at the wrong repo.

**Requirements:** [Node.js](https://nodejs.org/) >= 22.22.0 ([nvm](https://github.com/nvm-sh/nvm) recommended). macOS or Linux; on Windows, run inside [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) (the hooks and CLI need bash and POSIX file paths, and native Windows isn't exercised in CI). [uv](https://astral.sh/uv) is required for the Serena MCP server; GAIA installs it during setup if you don't already have it.

[Learn more about GAIA →](https://gaiareact.com/)

### Then: `/gaia-init`

GAIA ships clean. `/gaia-init` does the last-mile setup:

- **Configures the project.** Title, package name, docs title, CODEOWNERS, localized site titles.
- **Installs dependencies.** Bootstraps pnpm via `corepack`, runs `pnpm install`.
- **Configures i18n.** Prompts for your language set, scaffolds the matching language files, updates the component and Storybook wiring.
- **Installs Claude skills, plugins, and MCP servers.** [React Doctor](https://github.com/millionco/react-doctor), [Playwright CLI](https://github.com/microsoft/playwright-cli), `typescript-lsp`, [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian), and [Serena](https://github.com/oraios/serena) (LSP-backed symbol search and editing).
- **Initializes [spec-kit](https://github.com/github/spec-kit)** with the bundled GAIA extension and preset, so `/gaia-spec` and the spec-kit lifecycle hooks (constitution check, self-review, immutability lint, Playwright UAT auto-write, wiki-promote) are wired before your first feature.

You end up with a clean app shell and a fully-configured Claude workflow.

## What Breaks Claude on Real Projects

Most setups treat Claude as a tool you hold: bolt a `CLAUDE.md` onto the root and hope the model figures out the rest. GAIA treats Claude as an engineer you _manage_. That shift exposes three failure modes the bolt-on approach papers over.

**Trust.** You can't manage an engineer you can't predict. Without enforceable conventions, Claude reverts to its training distribution: an average of every codebase on the internet, bad code and all. GAIA's codebase is what you actually want Claude matching, and the rules make sure it can't ship code that doesn't.

**Token economics.** Context bloat isn't just `CLAUDE.md` sprawl. Instructions get dropped into global memory, forgotten, and accumulate into redundancies and conflicts that compound every session. GAIA keeps token usage minimal by design.

**Compounding tech debt.** Dependencies fall behind, vulnerabilities sit unpatched, dead code piles up, and the wiki drifts from the code while you ship features. Left alone, the project rots in the background. GAIA runs maintenance continuously so it doesn't.

## How GAIA Makes Claude Trustworthy

- **Coding principles, enforced.** GAIA embeds [Karpathy's four coding principles](https://github.com/forrestchang/andrej-karpathy-skills/blob/main/CLAUDE.md) (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution) plus two of GAIA's own: Always Use TDD and Always Verify Your Work.
- **Best practices baked in, debt blocked at the source.** Rules encode the conventions directly instead of hoping Claude infers them from whatever's already in the repo, and block debt-accumulating patterns from being written at all: untyped exports, untested components, hardcoded strings, a11y gaps.
- **Consistently clean code.** 1,450 lint rules, strict TypeScript, Prettier, and Knip enforce style, correctness, and dead-code detection on every file Claude touches. No negotiation, no drift.
- **Bundled skills wired in for write-time quality.** `typescript`, `react-code`, `tailwind`, `tdd`, `playwright-cli`, `skeleton-loaders`, `eslint-fixes`, and `a11y-fixes` load on demand when Claude edits matching files or a tool reports a fixable violation. The `tdd` skill drives a red-green-refactor loop tailored for Vitest, React Testing Library, Storybook `composeStory`, and MSW.
- **Specs that turn into tests, automatically.** `/gaia-spec` authors an immutable SPEC artifact through Socratic discovery. Before any source code is written, the SPEC's UATs render as red-state Playwright e2e specs. The implementer's first job is turning red green. The PO writes acceptance criteria in plain English, and the test harness is generated.
- **Code-review audit before every merge.** A manager agent scans the branch diff for security (XSS, SSRF, IDOR, secret exposure, timing attacks, dependency vulns), performance, architecture, code smells, and antipatterns. Three specialists (React Patterns & Accessibility, TypeScript & Architecture, Translation) run in parallel alongside `react-doctor` and `knip` (whose output is advisory and never blocks), with extension files in `.claude/agents/code-review-audit/` injecting library-specific rules at runtime. Findings are tiered **Critical**, **Important**, and **Suggestions**. The merge blocks until no Critical or Important issues remain. Runs locally by default, and in CI once you enable GAIA CI.
- **Quality gate before commit.** Typecheck, lint, tests, and build must all pass. Not "mostly clean." Actually clean.
- **Guardrails against destructive moves.** A filesystem deny list blocks reads of `.env`, `**/secrets/*`, `**/*credential*`, `**/*.pem`, and `**/*.key`. A tool allow list scopes Bash and Edit surfaces. Pre-tool-use hooks reject dangerous commands at the source: destructive git on `main`, watch-mode `pnpm test`, `eslint.config` edits, `rm -rf`, writes to env/secret/lockfile files, and `vitest/globals` in tsconfig. All in `.claude/hooks/`, wired through `.claude/settings.json`.

## How GAIA Keeps Claude Token-Efficient

- **Rules scoped to activate only when needed.** Claude loads the ones that match what it's editing. Nothing else.
- **Five tiers of memory, each scoped and self-maintaining.** Claude stops relearning the codebase every session:
  - **Wiki** (repo): architecture, modules, decisions, flows, concepts as focused, linked Markdown committed to git and shared across the team. Claude opens the one page it needs (_"How does dark mode wire through?"_) instead of preloading the whole manual. Session hooks fire wiki sync when it drifts from HEAD; SPEC outcomes drain in at PR merge; a redundancy and staleness pass runs whenever it grows. `/gaia-wiki` drives the full chain (sync, consolidate, lint) on demand, each step in a fresh subagent context. Open `wiki/` in [Obsidian](https://obsidian.md) for graph view, backlinks, and search; the [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) plugin adds `/wiki-ingest`, `/wiki-query`, `/wiki-lint`, `/autoresearch`, and `/save`.
  - **Hot cache** (session): `wiki/hot.md`, what Claude touched recently; primed at session start, fast and evictable.
  - **Handoff** (cross-session): compact session state written by `/gaia-handoff`, restored by `/gaia-pickup`. No re-briefing Claude from scratch.
  - **Agent memory** (per-agent): each subagent's scratchpad, persisted between runs.
  - **User memory** (global): your preferences, style, and defaults, carried across projects.
- **Periodic knowledge audit.** `/gaia-audit` sweeps memory, wiki, and autoloaded files for duplication, conflicting instructions, and stale content before they start costing tokens.
- **Task orchestration in clean subagent contexts.** `/gaia-plan` spawns each phase as a focused subagent with only the context it needs. No accumulated history, no stale assumptions. Spec discovery (`/gaia-spec`) runs in its own context too, separate from implementation; the immutable SPEC artifact is the handoff, not accumulated context.
- **Symbol-aware code intelligence over grep.** [Serena MCP](https://github.com/oraios/serena) gives Claude LSP-backed symbol search, references, and types. A symbol query returns the one definition, not every line that mentions the name.

## How GAIA Keeps Tech Debt From Compounding

The quality gate keeps each commit clean and Knip keeps dead code out (see [Tech Stack](#tech-stack)). The rest runs over the life of the project:

- **`/update-deps`.** An autonomous Dependabot: discovers every outdated package, audits version overrides, applies codemods and breaking-change migrations for major bumps, resolves conflicts between simultaneous upgrades, then runs the quality gate before reporting done. No prompts.
- **`/update-gaia`.** Pulls the latest GAIA release into the project without clobbering your work: a three-way merge per file (your version, the release baseline, the new release) governed by ownership classes in `.gaia/manifest.json`, prompting only where your changes and GAIA's collide. Both updates surface as passive statusline indicators at session start.
- **`/gaia-debt`.** The pre-merge audit may discover tech-debt outside the scope of what it's reviewing. Rather than let it slip, GAIA logs it as a tracked issue, and `/gaia-debt` works through that backlog one item at a time, most important first. A statusline indicator shows how much is waiting.
- **GAIA CI**, opt-in, set up by `/setup-gaia`. A GitHub Actions bot that runs maintenance against your Claude Code Pro/Max subscription or Anthropic API key, capped at $5 per run. Patch and minor dependency bumps get an auto-PR that auto-merges on green CI; major bumps and high or critical `pnpm audit` findings route to review-required PRs; app-code changes open a labeled wiki-sync PR (a run that rewrites more than 25% of the wiki holds for review); stale branches get cleaned up. If post-merge CI fails, the bot opens one revert PR. A second failure escalates to a priority issue and the bot stops.

## Tech Stack

Every piece of GAIA's [tech stack](https://gaiareact.com/#stack) is pre-configured and wired into the Claude layer.

- **1,450 lint rules** via ESLint, [Prettier](https://prettier.io/), and [Stylelint](https://stylelint.io/) that catch the patterns Claude drifts into first: complexity creep, architectural shortcuts, mismatched filenames, broken CSS. [Knip](https://knip.dev/) detects unused files, exports, and dependencies.
- **Pre-commit hooks** ([Husky](https://typicode.github.io/husky/) + [lint-staged](https://github.com/lint-staged/lint-staged)): typecheck, lint, and test before CI.
- **Testing** via [Vitest](https://vitest.dev) + [React Testing Library](https://testing-library.com/docs/react-testing-library/intro/) for unit and integration, [Playwright](https://playwright.dev/docs/intro) for E2E, and [Chromatic](https://chromatic.com/) for visual regression, all sharing one [MSW](https://mswjs.io/) mock layer.
- **[Storybook](https://storybook.js.org/)** with React Router + i18n + dark mode + [MSW](https://mswjs.io/) integration.
- **Internationalization** via [remix-i18next](https://github.com/sergiodxa/remix-i18next) with working examples.
- **Form components with validation** using [Conform](https://conform.guide/) + [Zod](https://zod.dev/).
- **Dark mode end-to-end.** Context, session, CSS, and Storybook all in sync.
- **API mocking** with [Mock Service Worker](https://mswjs.io/) and [msw/data](https://github.com/mswjs/data): working handlers for tests and Storybook.
- **Toast notifications** with [remix-toast](https://remix.run/resources/remix-toast) and [Sonner](https://sonner.emilkowal.ski/).
- Built with [React Router 8](https://reactrouter.com/), [Tailwind](https://tailwindcss.com/), and [react-icons](https://react-icons.github.io/react-icons/).

GAIA also wires agentic-design patterns into the project structure rather than the prompt, so they run the same way every session and every model variant: stop hooks, a blocking pre-merge audit, multi-agent review, spec-driven development, a committed knowledge base, a filesystem deny list, and more. The [features page](https://gaiareact.com/features/#agentic-design) walks through all twelve, grouped as workflow control, context engineering, and tooling and safety.

## Claude Workflow

GAIA ships a complete, opinionated Claude Code workflow. Everything is wired in `.claude/` and visible in the repo.

### Commands

<table>
<thead><tr><th nowrap>Command</th><th>What it does</th></tr></thead>
<tbody>
<tr><td><code>/gaia-spec</code></td><td>Author an immutable SPEC through Socratic discovery: two-gate ceremony, self-review pass, Playwright UATs auto-generated before implementation begins. Hands off to <code>/gaia-plan</code></td></tr>
<tr><td><code>/gaia-plan</code></td><td>Plan a complex feature. Claude structures the work, you approve, then an orchestrator drives focused subagents through execution</td></tr>
<tr><td><code>/gaia-handoff</code></td><td>Generate a comprehensive session handoff document so you can clear context with confidence that nothing gets lost</td></tr>
<tr><td><code>/gaia-pickup</code></td><td>Restore context from a handoff and continue work</td></tr>
<tr><td><code>/gaia-audit</code></td><td>Audit memory, wiki, and autoloaded files for duplication, conflicting instructions, and bloat</td></tr>
<tr><td><code>/gaia-wiki</code></td><td>Run the full wiki maintenance chain: sync new commits into wiki pages, consolidate redundant or superseded content, then lint for orphans, dead links, and drift</td></tr>
<tr><td><code>/gaia-forensics</code></td><td>When a GAIA workflow misfires, capture a redacted, classified, filing-ready report in one run. Self-diagnoses user-config issues inline; probable bugs file to GAIA's GitHub with one prompt</td></tr>
<tr><td><code>/gaia-fitness</code></td><td>Health-check and auto-heal the project's Claude integration: triage, heal, verify, then report an F-to-A+ grade</td></tr>
<tr><td><code>/gaia-react-perf</code></td><td>Diagnose React render performance. Drives a micro-interaction, captures real renders, and surfaces memo-defeating reference instability, then recommends a structural fix. Measure-only: it reports a ranked diagnosis, it never auto-fixes</td></tr>
<tr><td><code>/gaia-harden</code></td><td>Turn a recurring code-review-audit finding into the lowest-cost enforcement: a deterministic check, a skill, or a path-scoped rule. Human-gated, drafted into the working tree only on approval. Pass <code>list</code> to see candidates or <code>why &lt;finding_class&gt;</code> to explain one</td></tr>
<tr><td><code>/gaia-debt</code></td><td>Work through the tech-debt backlog one item at a time, most important first. Tech-debt discovered by the pre-merge audit outside the scope of the change is tracked here rather than lost. Pass <code>list</code> to see what's queued or <code>why &lt;issue-number&gt;</code> to explain the pick</td></tr>
<tr><td><code>/update-deps</code></td><td>Autonomous Dependabot: discover every outdated package, audit version overrides, apply codemods and breaking-change migrations for major bumps, resolve conflicts between simultaneous upgrades, then run the quality gate. No prompts</td></tr>
<tr><td><code>/update-gaia</code></td><td>Pull the latest GAIA release into the project without clobbering your work. Three-way merge per file (your version / release baseline / new release) governed by ownership classes in <code>.gaia/manifest.json</code>; prompts only where your changes and GAIA's collide</td></tr>
</tbody>
</table>

### Rules, Hooks, Skills

- **Path-scoped rules** cover TypeScript, React, Tailwind, testing, i18n, accessibility, and state management. They live in `.claude/rules/`; ask Claude about any of them.
- **Hooks** guard the quality gate and keep the wiki fresh. They live in `.claude/hooks/`.
- **Bundled skills** (`typescript`, `react-code`, `tailwind`, `tdd`, `playwright-cli`, `skeleton-loaders`, `eslint-fixes`, `a11y-fixes`) autoload for matching tasks. Scaffolding skills (`new-component`, `new-hook`, `new-route`, `new-service`) fire on natural-language asks.
- **MCP servers.** [Serena](https://github.com/oraios/serena) gives Claude LSP-backed code intelligence: symbol lookups, references, and types instead of grepping the codebase.

### Mentorship

GAIA includes an optional, local-only adaptive mentorship layer that observes your patterns through GAIA's structured event stream and adapts Claude's responses to you over time. Default off. Opt in during `/gaia-init` or any time afterward.

```bash
gaia mentorship enable      # turn on
gaia mentorship disable     # stop emit and adaptation
gaia mentorship status      # show state and file location
gaia mentorship purge       # delete all mentorship data
```

[Read more](https://gaiareact.com/mentorship/) about what it observes, what it never observes, where data lives, and how privacy is built into the design.

## Working in a GAIA Project

GAIA is driven through Claude. Ask for what you need.

**Build things:**

- _"Add a new route for settings."_ → triggers `/new-route`, applies routing + i18n + test rules.
- _"Add German as a supported language."_ → Claude walks the i18n setup.
- _"Add a zip-code field to the address form with validation."_ → Claude uses the form patterns from the wiki.

**Ask about the codebase:**

- _"How does dark mode wire through?"_ → Claude fetches the wiki page on demand.
- _"What state patterns do we use?"_ → one-page lookup, no context bloat.
- _"Explain the form-submit flow."_ → direct answer from the wiki.

**Test:** Ask Claude to run, add, or debug tests. Vitest, Storybook + Chromatic, and Playwright are wired up.

**Deploy:** GAIA isn't prescriptive about hosting. Ask Claude to set up deployment for your target (Vercel, Cloudflare, Fly, AWS, a bare Node host, a Docker container, anywhere React Router runs). Claude wires up the build, environment variables, and any CI/CD you need.

**Extend:** Rules, hooks, skills, and commands live in `.claude/`. Ask Claude to add, modify, or explain any of them.

## History

The GAIA Flash Framework was Flash's most popular framework. **Its killer feature was automation.** It collapsed repetitive Flash plumbing into a few declarative patterns so engineers could focus on the product, and was used on over 100,000 sites at every major digital agency worldwide.

GAIA React carries that automation philosophy into the AI-native era. Where the original automated Flash boilerplate, GAIA automates the Claude workflow (conventions, rules, hooks, gates, wiki) so you can ship features end-to-end without wiring the scaffolding every time.
