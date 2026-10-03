---
type: dependency
status: active
package: react-doctor
role: react-quality-scanner
created: 2026-06-23
updated: 2026-10-03
tags: [dependency, quality, ci]
---

# react-doctor

Deterministic scanner for React security, performance, correctness, and accessibility issues. Scores the codebase 0-100 and emits per-rule diagnostics. Devtime/CI-only, advisory.

## Conventions

- Config: `frontend/doctor.config.ts`. GAIA ships exactly one config file (see Single config below).
- Run: `npx react-doctor@latest .`. react-doctor is not a project dependency; it is always invoked at latest via `npx`. The config therefore stays a plain `export default` and does not import react-doctor's config type.
- Install (`/gaia-init`, `/setup-gaia`): `npx -y react-doctor@latest install --yes` installs the skill for every agent it detects. The Claude Code skill lands project-local at `.claude/skills/react-doctor/` (gitignored, kept per-machine, never committed). For any non-Claude agent it detects it also writes a `.agents/skills/react-doctor/` copy; GAIA strips that copy along with the installer's standalone GitHub Actions workflow, commit-hook block, `doctor` package script, and pinned `react-doctor` devDependency, so the Claude Code skill remains the sole trigger point.
- Runs automatically pre-merge inside the [[Code Review Audit Agent]] (alongside [[knip]] and [[pnpm-audit]]). Findings are advisory and never block the audit marker.
- Not part of the [[Quality Gate]] (pre-commit).

## Installer verification record

Verified against react-doctor 0.9.14, running `install --yes` from the root of the two-package pnpm workspace. The installer writes the paths below. Each maps to one strip step, in the same order, in `.claude/commands/gaia-init.md` and `.claude/commands/setup-gaia.md`:

| Path the installer writes | Strip step |
|---|---|
| `.claude/skills/react-doctor/` | kept: the Claude Code skill is the sole trigger point |
| `.github/workflows/react-doctor.yml` | `rm -f .github/workflows/react-doctor.yml` |
| `.agents/skills/react-doctor/` | `rm -rf .agents/skills/react-doctor`, then `rmdir` of the empty parents |
| root `package.json` devDependency `react-doctor`, and `pnpm-lock.yaml` | `pnpm remove react-doctor --config.ignore-scripts=true` (root package, no `-w` needed) |
| root `package.json` script `doctor` | `pnpm pkg delete scripts.doctor 'scripts["react-doctor"]'` |
| block between `# react-doctor hook start` and `# react-doctor hook end` in the file `core.hooksPath` names (`.githooks/pre-commit`) | an `awk` pass deletes the block in place, then `git config core.hooksPath .githooks` re-arms the hook path |

Verdicts:

- The installer targets the root `package.json`, not `frontend/package.json`, so every strip step runs from the repo root.
- `pnpm remove` at the workspace root works without `-w` on GAIA's pinned pnpm.
- The installer writes the CI workflow even under `--yes`.
- GAIA never passes `--agent-hooks`. Without that flag `--yes` installs no agent hooks. With it the installer adds a Stop hook to `.claude/settings.json`, `.claude/hooks/react-doctor.mjs`, and Cursor hook files.
- The `.agents/skills/` copy is written for many agents (Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode, Pi, Warp, and others), not only Copilot and Warp.
- Known extra: when Factory Droid is installed the installer also writes `.factory/skills/react-doctor/`. GAIA has no strip step for it and leaves it in place; it appears only on a machine with Droid.
- The audit invocation uses `--scope changed`; `--diff` is a deprecated hidden alias for it. The command lives in `.claude/agents/code-audit-frontend.md`.

## Single config, highest precedence

react-doctor resolves config in extension-precedence order (`.ts > .mts > .cts > .js > .mjs > .cjs > .json > .jsonc`) and uses the first file it finds, silently ignoring the rest. Two config files means the lower-precedence one is shadowed with no warning.

The canonical config is `frontend/doctor.config.ts`:

- `.ts` matches the repo's `*.config.ts` convention (vite/knip/playwright/react-router), so it lives where config is expected and is found.
- `.ts` is the highest-precedence extension, so a stray `doctor.config.json`/`.jsonc` cannot shadow it.
- Comments are native, carrying the evidence for each suppression.

### Duplicate-config guard

A deterministic check fails when more than one `doctor.config.*` or `react-doctor.config.*` file exists, because react-doctor itself gives no warning: `.githooks/pre-commit` ([[Pre-commit Hooks]]) fails the commit before a duplicate lands.

## Acting on output

Findings fall into three buckets:

1. **Real issue**: fix the code. Security and correctness rules take priority over performance and a11y.
2. **Domain mismatch**: a rule that does not apply to a path (e.g. a web-input rule firing on Node CLI tooling, or a generated artifact). Add a scoped `ignore.overrides` entry naming the rule and files, or `ignore.files` for output that should never be scanned (e.g. `build/**`).
3. **Tool overlap**: dead-code analysis (`deslop`) duplicates [[knip]], the single dead-code authority. `deadCode: false` disables it.

Suppress with the narrowest control: prefer a per-path `ignore.overrides` entry over a blanket rule-off. Every suppression carries a comment with the evidence so it can be re-evaluated when the ruleset changes (rules also drift between versions, since the scan runs at `npx ...@latest`).

See [[Quality Gate]], [[Code Review Audit Agent]].
