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

## Wiki sync system

GAIA's wiki is a living knowledge layer. Adopters scaffold from a release tarball and inherit whatever wiki state the tarball ships. So the maintainer-side discipline is: **the wiki must be in sync with HEAD before every release.** The system below enforces it.

### How it works (quick tour)

Three Claude Code hooks keep Claude informed about wiki state:

- `wiki-drift-check.sh`: UserPromptSubmit, once per session. Compares `wiki/.state.json` to HEAD; nudges if drifted.
- `wiki-commit-nudge.sh`: PostToolUse on Bash. Injects diff summary + drift count after each `git commit`.
- `wiki-session-stop.sh`: Stop hook. Two reminders share one git/jq pass: nudge to refresh `wiki/hot.md` if wiki/ files were modified this session, and a safety-net nag at session end if commits landed but `wiki/.state.json` didn't advance.

The workhorse is `/gaia-wiki sync`. It's the only thing that writes `wiki/.state.json`. Hooks are read-only consumers.

`/gaia-release` will refuse to bump version if `wiki/.state.json` SHA != HEAD. There is no opt-out.

For the full design, see `wiki/concepts/Wiki Sync.md`.

### Running the tests

#### Hook tests (free, every commit)

```bash
bats .gaia/tests/hooks/
```

Requires `bats-core` (`brew install bats-core`). Tests are deterministic, run in tmp git repos, take a few seconds total. Add to your local commit hook if you want them on every commit.

These cover the bulk of the system: drift math, marker file behavior, hook input parsing, edge cases (missing state, unreachable SHA, malformed JSON).

#### Smoke tests (manual, billable)

```bash
bash .gaia/tests/smoke/run-all.sh
```

Requires `claude` CLI on PATH and a working subscription / `ANTHROPIC_API_KEY`. Costs ~$0.10 per full run on Sonnet. Tests Claude's judgment in real scenarios:

- 01: meaningful change → wiki updated
- 02: typo-only commit → SKIP, no wiki edits
- 03: multi-commit catch-up
- 04: non-Claude merge detected at next session

Run before every release. See `.gaia/tests/smoke/README.md` for individual scenario commands and cost discipline.

### Pre-release checklist

Before running `/gaia-release`, you should have:

- [ ] `pnpm typecheck` clean
- [ ] `pnpm lint` clean
- [ ] `pnpm test:ci` clean
- [ ] `bats .gaia/tests/hooks/` clean
- [ ] `/gaia-wiki sync` run, with all returned WORTHY commits resulting in defensible wiki edits
- [ ] (Recommended) `bash .gaia/tests/smoke/run-all.sh` clean
- [ ] Working tree clean

If `/gaia-wiki sync` reports drift but you decide a commit doesn't warrant a wiki update, it logs that as a SKIP entry in `wiki/log.md`. State still advances. That's the convergence: wiki is "in sync" once every commit has been classified as either WORTHY (and the page updated) or SKIP (and the reason logged).

### What ships, what doesn't

| Path                                       | Ships to adopters?                                      |
| ------------------------------------------ | ------------------------------------------------------- |
| `.claude/hooks/wiki-*.sh`                  | Yes                                                     |
| `.claude/skills/gaia/references/wiki/*.md` | Yes                                                     |
| `wiki/.state.json`                         | Yes (committed)                                         |
| `wiki/concepts/Wiki Sync.md`               | Yes                                                     |
| `.gaia/tests/`                             | **No**: `.gaia/release-exclude` excludes the whole tree |
| `.claude/wiki-{drift,safety}-checked`      | **No**: gitignored, never committed                     |

### Troubleshooting

- **Drift check is too noisy.** It only fires on the first prompt of each session. If you're seeing it more often, check `.claude/wiki-drift-checked`; the marker file should match your current `session_id`. If a hook is failing to write the marker, that's the bug.
- **`/gaia-wiki sync` reports zero drift but you know there were commits.** Check `wiki/.state.json`'s `last_evaluated_sha`; it may already match HEAD if a prior sync ran. Or the SHA may be unreachable (rebase) and the hook silently skipped.
- **Smoke tests are failing in CI.** They shouldn't be; smoke tests are MANUAL only. CI should run only `bats .gaia/tests/hooks/`. If a CI workflow is invoking smoke, that's a misconfiguration; remove it.

## Code of conduct

By contributing, you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).

## License

By contributing, you license your contributions under the [MIT License](./LICENSE), matching the project.
