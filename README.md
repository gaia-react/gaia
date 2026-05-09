# GAIA React

<img src="./app/assets/images/gaia-logo.svg" height="100" alt="GAIA"/>

[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/github/actions/workflow/status/gaia-react/gaia/tests.yml?event=pull_request&label=tests)](https://github.com/gaia-react/gaia/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/github/license/gaia-react/gaia)](./LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D22.19.0-brightgreen)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)

**Claude is raw power. GAIA is order and focus.**

The React workflow that keeps Claude-shipped code production-grade as your team scales. Every convention enforced in code. Every shortcut blocked at the source. Every merge audited before it lands.

## Who it's for

- Engineering teams whose AI output is outpacing their review process
- Engineering leads standardizing how Claude works across the org
- Solo developers and agencies who want production-grade defaults from day one

## Quick Start

**Supported platforms:** macOS and Linux. Windows users should run GAIA inside [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) — the hooks and CLI rely on bash and POSIX file paths, and native Windows is not exercised in CI.

Make sure you have [Node.js](https://nodejs.org/en/) >= 22.19.0 installed, preferably via [nvm](https://github.com/nvm-sh/nvm), and [uv](https://astral.sh/uv) (required for the Serena MCP server — install with `curl -LsSf https://astral.sh/uv/install.sh | sh`).

```bash
npx create-gaia@latest my-app
```

One simple command. GAIA takes care of the rest.

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
- **Consistently clean code.** 20+ ESLint plugins, strict TypeScript, Prettier, and Knip enforce style, correctness, and dead-code detection on every file Claude touches. No negotiation, no drift.
- **Bundled skills wired in for write-time quality.** `react-code`, `typescript`, `tdd`, `tailwind`, `playwright-cli`, `skeleton-loaders`, and `eslint-fixes` load on demand when Claude edits matching files. They apply project conventions without re-deriving them every session.
- **Test-driven development** via the bundled `tdd` skill. Red-green-refactor loop, tests before code, tailored for Vitest, React Testing Library, Storybook `composeStory`, and MSW.
- **Specs that turn into tests, automatically.** `/gaia spec` authors an immutable SPEC artifact through a Socratic discovery process. Before any source code is written, GAIA renders the SPEC's UATs into red-state Playwright e2e specs. The implementer's first job is making real tests green from the start. PO authors acceptance criteria in plain English; the test harness is generated.
- **Code-review audit before every merge.** A manager agent scans the branch diff for security, performance, architecture, code smells, and antipatterns. Three specialists (React Patterns & Accessibility, TypeScript & Architecture, Translation) run in parallel alongside `react-doctor` and `knip`, with extension files in `.claude/agents/code-review-audit/` injecting library-specific rules at runtime. Findings are tiered as **Critical**, **Important**, and **Suggestions**; the merge blocks until no Critical or Important issues remain. Runs locally and in CI.
- **Quality gate before commit.** Typecheck, lint, tests, and build must all pass. Not "mostly clean." Actually clean.

## How GAIA keeps Claude token-efficient

- **Rules are scoped to activate only when needed.** Claude loads the ones that match what it's editing. Nothing else.
- **[Obsidian](https://obsidian.md) wiki, fetched on demand.** Project knowledge lives as focused, linked Markdown pages. Claude opens the one page it needs (_"How does dark mode wire through?"_) instead of preloading the whole manual.
- **Wiki behavior tailored to GAIA.** Session hooks keep Obsidian's workflow (ingest cadence, cache discipline, link hygiene) aligned with the project's conventions.
- **Periodic knowledge audit** sweeps memory, wiki, and autoloaded files for duplication, conflicts, and stale instructions before they start costing tokens.
- **Session continuity.** `/gaia handoff` + `/gaia pickup` replace re-briefing Claude from scratch at every session start.
- **Task orchestration in clean subagent contexts.** `/gaia plan` spawns each phase as a focused subagent with only the context it needs. No accumulated history, no stale assumptions. Each agent starts fresh and stays cheap.
- **Spec discovery in isolated context.** `/gaia spec` runs in its own context, separate from implementation. The Socratic layer wraps [spec-kit](https://github.com/github/spec-kit): one question at a time, an immutable SPEC artifact, then a chain into `/gaia plan`. The artifact is the handoff between sessions, not accumulated context.
- **Symbol-aware code intelligence over grep.** [Serena MCP](https://github.com/oraios/serena) gives Claude LSP-backed symbol search, references, and types. A symbol query returns the one definition, not every line that mentions the name. The grep-and-read tax disappears.

## Tech Stack

Every piece of GAIA's [tech stack](https://gaiareact.com/#stack) is pre-configured and wired into the Claude layer.

- **1,592 lint rules** across 20+ ESLint plugins, [Prettier](https://prettier.io/), and [Stylelint](https://stylelint.io/), including 85 Stylelint rules that catch the patterns Claude drifts into first: complexity creep, architectural shortcuts, mismatched filenames, broken CSS. [Knip](https://knip.dev/) detects unused files, exports, and dependencies.
- **Pre-commit hooks** ([Husky](https://typicode.github.io/husky/) + [lint-staged](https://github.com/lint-staged/lint-staged)): typecheck, lint, and test before CI
- **Four testing layers sharing one mock layer**: [Vitest](https://vitest.dev) + [React Testing Library](https://testing-library.com/docs/react-testing-library/intro/) for unit/integration, [Playwright](https://playwright.dev/docs/intro) for E2E, [Chromatic](https://chromatic.com/) for visual regression
- **Internationalization** via [remix-i18next](https://github.com/sergiodxa/remix-i18next) with working examples
- **Form components with validation** using [Conform](https://conform.guide/) + [Zod](https://zod.dev/)
- **Dark mode end-to-end.** Context, session, CSS, and Storybook all in sync.
- **[Storybook](https://storybook.js.org/)** with React Router + i18n + dark mode + [MSW](https://mswjs.io/) integration
- **API mocking** with [Mock Service Worker](https://mswjs.io/) and [msw/data](https://github.com/mswjs/data), working handlers for tests and Storybook
- **Toast notifications** with [remix-toast](https://remix.run/resources/remix-toast) and [Sonner](https://sonner.emilkowal.ski/)
- Built with [React Router 7](https://reactrouter.com/), [Tailwind](https://tailwindcss.com/), and [react-icons](https://react-icons.github.io/react-icons/)

## Design patterns Claude doesn't have to remember

GAIA wires the patterns into the project itself, not the prompt. They run the same way every session, every engineer, every model variant, because the project is shaped that way, not because the prompt asked nicely. The six below have the clearest file-level evidence. The [features page](https://gaiareact.com/features/#agentic-design) covers ten more across quality enforcement, workflow control, context engineering, and tooling and safety.

| Pattern                              | How GAIA implements it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **The Stop Hook**                    | Pre-tool-use hooks intercept dangerous commands at the source. `block-main-destructive-git.sh` rejects commits and force-pushes against `main`; `block-bare-test.sh` blocks watch-mode `pnpm test`; `block-eslint-config-edit.sh` forces fixing source instead of silencing rules; `pr-merge-audit-check.sh` runs before `gh pr merge`; `block-rm-rf.sh` blocks destructive file removal; `block-env-write.sh` and `block-secrets-write.sh` block writes to env and credential files; `block-lockfile-edit.sh` blocks direct lockfile edits; `block-vitest-globals-tsconfig.sh` blocks adding `vitest/globals` to tsconfig (explicit imports required). All in `.claude/hooks/`, wired through `.claude/settings.json`. |
| **Reflection**                       | Two blocking review layers before merge. The Quality Gate (`.husky/pre-commit`) runs typecheck, lint, and tests on every commit. The code-review audit (`.claude/agents/code-review-audit.md`) tiers findings as **Critical**, **Important**, and **Suggestions**, and writes its clean-merge marker only when no Critical or Important issues remain. `pr-merge-audit-check.sh` blocks `gh pr merge` until that marker exists; advisory output from `react-doctor` and `knip` never blocks.                                                                                                                 |
| **Multi-Agent Collaboration**        | `code-review-audit` is a manager agent that dispatches React Patterns, TypeScript and Architecture, and Translation specialists in parallel from a single tool-call message, alongside `react-doctor` and `knip`. Extension files in `.claude/agents/code-review-audit/*.md` inject library-specific rules into the right subagent at runtime via the `subagents:` frontmatter field.                                                                                                                                                                                                                       |
| **Specification-Driven Development** | `/gaia spec` writes an immutable SPEC artifact to `.gaia/local/specs/SPEC-NNN.md` through Socratic discovery. Before any source code is written, the SPEC's UATs render as red-state Playwright e2e specs — the implementer's first job is turning red green. Wired through [spec-kit](https://github.com/github/spec-kit) lifecycle hooks installed by `/gaia-init`: constitution check, self-review, immutability lint, Playwright UAT auto-write, and wiki-promote on PR merge.                                                                                                                          |
| **Memory & Knowledge Base**          | The Obsidian wiki at `wiki/` (architecture, modules, decisions, flows, concepts) holds long-term project knowledge committed to git. `wiki/hot.md` autoloads at session start as a recent-context cache. `/gaia handoff` writes session snapshots; `/gaia pickup` restores them. SPEC outcomes drain into the wiki at PR merge; `/gaia audit` sweeps memory, wiki, and autoloaded files for duplication, conflicts, and orphans before they compound.                                                                                                                                                       |
| **Guardrails & Safety**              | Filesystem deny list in `.claude/settings.json` covers `Read(.env)`, `Read(**/secrets/*)`, `Read(**/*credential*)`, `Read(**/*.pem)`, `Read(**/*.key)`. Tool allow list scopes Bash and Edit surfaces. Block hooks reject debt-accumulating patterns at the source. The audit's security dimension covers XSS, SSRF, IDOR, secret exposure, timing attacks, and dependency vulns.                                                                                                                                                                                                                            |

## One-Command Initialization

GAIA ships clean. `/gaia-init` finishes the last-mile setup:

- **Configures your project.** Prompts for a title, sets the package name, docs title, CODEOWNERS, and localized site titles.
- **Installs dependencies.** Bootstraps pnpm via `corepack` and runs `pnpm install` for you.
- **Configures i18n.** Prompts for your language set, scaffolds the matching language files, and updates the component and Storybook wiring.
- **Installs Claude skills and plugins.** [React Doctor](https://github.com/millionco/react-doctor), [Playwright CLI](https://github.com/microsoft/playwright-cli), `typescript-lsp`, [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian), and the [Serena](https://github.com/oraios/serena) MCP server (LSP-backed symbol search and editing).
- **Initializes [spec-kit](https://github.com/github/spec-kit)** with the bundled GAIA extension and preset, so `/gaia spec` and the spec-kit lifecycle hooks (constitution check, self-review, immutability lint, Playwright UAT auto-write, wiki-promote) are wired before your first feature.

After `/gaia-init` finishes, you have a clean app shell **and** a fully-configured Claude workflow ready to use.

## Claude Workflow

GAIA ships a complete, opinionated Claude Code workflow. Everything is wired in `.claude/` and visible in the repo.

### Commands

<table>
<thead><tr><th nowrap>Command</th><th>What it does</th></tr></thead>
<tbody>
<tr><td><code>/gaia spec</code></td><td>Author an immutable SPEC through Socratic discovery: two-gate ceremony, self-review pass, Playwright UATs auto-generated before implementation begins. Chains into <code>/gaia plan</code></td></tr>
<tr><td><code>/gaia plan</code></td><td>Plan a complex feature. Claude structures the work, you approve, then an orchestrator drives focused subagents through execution</td></tr>
<tr><td><code>/gaia audit</code></td><td>Audit memory, wiki, and autoloaded files for duplication, conflicting instructions, and bloat</td></tr>
<tr><td><code>/gaia wiki</code></td><td>Run the full wiki maintenance chain: sync new commits into wiki pages, consolidate redundant or superseded content, then lint for orphans, dead links, and drift</td></tr>
<tr><td><code>/gaia handoff</code></td><td>Generate a comprehensive session handoff document so you can clear the context with confidence that nothing will get lost</td></tr>
<tr><td><code>/gaia pickup</code></td><td>Restore context from handoff and continue work</td></tr>
<tr><td><code>/gaia forensics</code></td><td>When a GAIA workflow misfires, capture a redacted, classified, filing-ready report in one run. Self-diagnoses user-config issues inline. Probable bugs file to GAIA's GitHub with one prompt</td></tr>
</tbody>
</table>

### Rules, hooks, skills

- **Path-scoped rules** cover TypeScript, React, Tailwind, testing, i18n, accessibility, and state management. Ask Claude about any of them; they're in `.claude/rules/`.
- **Hooks** guard the quality gate and keep the wiki fresh. Ask Claude what they do.
- **Bundled skills** (`typescript`, `react-code`, `tailwind`, `skeleton-loaders`, `tdd`, `playwright-cli`, `eslint-fixes`) autoload for matching tasks. Scaffolding skills (`new-component`, `new-hook`, `new-route`, `new-service`) fire on natural-language asks.
- **MCP servers.** [Serena](https://github.com/oraios/serena) gives Claude LSP-backed code intelligence. Symbol lookups, references, and types instead of grepping the codebase.

### Code review before merge

Every merge runs through a code-review pass against the branch diff (security, performance, code smells, antipatterns), and blocks until the issues are fixed and committed.

### Staying up to date

GAIA keeps package dependencies and GAIA itself up to date. At session start, a background check runs; when updates are available, Claude will ask if you want to update now or later.

#### Dependencies

GAIA will update outdated packages, handle breaking-change migrations, and run the quality gate to make sure everything still works as expected.

#### GAIA Releases

When GAIA itself is updated, it will pull the latest version and perform three-way merges on affected files so any customizations or natural drift over the lifetime of a project survive.

### Wiki

GAIA keeps the wiki current and pruned as the project grows. Session hooks fire wiki sync when the wiki drifts from HEAD; SPEC outcomes drain into the wiki at PR merge; a redundancy and staleness pass runs automatically whenever the wiki grows. Run `/gaia wiki` to drive the full chain manually — sync, then consolidate, then lint — when you want to update on demand. Each step runs in a fresh subagent context, so large diffs and page walks stay out of your session. The result: the knowledge base reflects the actual codebase, not the state it was in six months ago.

GAIA ships with an [Obsidian](https://obsidian.md) wiki knowledge base (architecture, modules, dependencies, decisions, flows, concepts) committed to git and shared across the team. The [`claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) plugin (installed by `/gaia-init`) adds `/wiki-ingest`, `/wiki-query`, `/wiki-lint`, `/autoresearch`, and `/save` for working with the vault. Open `wiki/` in Obsidian for graph view, backlinks, and search.

### Mentorship

GAIA includes an optional, local-only adaptive mentorship layer that observes your patterns through GAIA's structured event stream and adapts Claude's responses to you over time. Default off. Opt in during `/gaia-init` or any time afterward.

```bash
gaia mentorship enable      # turn on
gaia mentorship disable     # stop emit and adaptation
gaia mentorship status      # show state and file location
gaia mentorship purge       # delete all mentorship data
```

[Read more](https://gaiareact.com/mentorship/) about what it observes, what it never observes, where data lives, and how privacy is built into the design.

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
