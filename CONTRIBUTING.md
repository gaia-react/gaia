# Contributing to GAIA React

GAIA is opinionated. The conventions, rules, and hooks aren't suggestions. They're the product. Pull requests that fight the opinions will be redirected, not merged. Pull requests that sharpen them are welcome.

## Before you contribute

- Read the [README](./README.md). The whole thing.
- Install with `npx create-gaia@latest my-app` and walk through `/gaia-init` so you understand what a fresh project looks like.
- Run the quality gate locally: `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm build`. All four green, no warnings.
- Browse the wiki under `wiki/`. That's where the project's reasoning lives.

## Filing issues

A good issue:

- A short title that names the surface (rule, hook, skill, command, wiki page).
- A reproduction. What you ran, what you expected, what happened.
- GAIA version (from your project's `package.json`, or `git log -1` from a clone of `gaia-react/gaia`).
- Node version, package manager, OS.

Issues that aren't bugs:

- Questions about how to use GAIA go to the docs site at [gaiareact.com](https://gaiareact.com), or open a GitHub Discussion if enabled.
- Security issues go to steven@gaiareact.com. Do not file public issues for vulnerabilities.

## Submitting pull requests

1. Fork. Branch from `main`. Name the branch by intent: `fix/`, `feat/`, `chore/`, `docs/`.
2. Commit messages follow conventional commits: `fix(scope): what`, `feat(scope): what`. Run `git log --oneline` for examples.
3. The quality gate must pass locally before you push: `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm build`. Zero warnings allowed. This is the project's distinguishing stance, not a starting position to negotiate.
4. The code-review audit will run on your PR. It dispatches React Patterns, TypeScript and Architecture, and Translation specialists in parallel against your diff. It blocks the merge until findings are resolved.
5. No `eslint-disable`, no `@ts-ignore`, no `eslint-disable-next-line`. If a rule is wrong for the case, open a separate PR to refine the rule. If the rule is right, fix the source.
6. Update `CHANGELOG.md` under `## [Unreleased]` if your change is user-visible.
7. PRs that lower the bar will be requested-changes back. PRs that raise it will be merged.

## Working with Claude Code in this repo

GAIA is itself written using GAIA conventions. If you use Claude to work on GAIA, the rules and hooks will guide you the same way they would in a downstream project. The merge audit applies to your PR regardless of who wrote the code.

If Claude generates a change that fights an existing rule, the rule wins. If you disagree with the rule, open an issue first.

## What we won't accept

- Refactors without a stated problem.
- Architectural changes without prior discussion.
- Removing or weakening the strict tooling.
- Framework swaps. The current stack is React Router 7, Tailwind, Vitest, Playwright, MSW, Conform, Zod. If you want to add support for Next.js, Astro, or TanStack Start, open an issue first. That's a roadmap conversation, not a PR.
- Cosmetic-only changes to working code.

## Code of conduct

By contributing, you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).

## License

By contributing, you license your contributions under the [MIT License](./LICENSE), matching the project.
