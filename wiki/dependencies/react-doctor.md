---
type: dependency
status: active
package: react-doctor
version: latest (npx, not a project dependency)
role: react-quality-scanner
created: 2026-06-23
updated: 2026-06-23
tags: [dependency, quality, ci]
---

# react-doctor

Deterministic scanner for React security, performance, correctness, and accessibility issues. Scores the codebase 0-100 and emits per-rule diagnostics. Devtime/CI-only, advisory.

## Conventions

- Config: `doctor.config.ts` (repo root). Exactly one config file exists (see Single config below).
- Run: `npx react-doctor@latest .`. react-doctor is not a project dependency; it is always invoked at latest via `npx`. The config therefore stays a plain `export default` and does not import react-doctor's config type.
- Runs automatically pre-merge inside the [[Code Review Audit Agent]] (alongside [[knip]] and [[pnpm-audit]]). Findings are advisory and never block the audit marker.
- Not part of the [[Quality Gate]] (pre-commit).

## Single config, highest precedence

react-doctor resolves config in extension-precedence order (`.ts > .mts > .cts > .js > .mjs > .cjs > .json > .jsonc`) and uses the first file it finds, silently ignoring the rest. Two config files means the lower-precedence one is shadowed with no warning.

The canonical config is `doctor.config.ts`:

- `.ts` matches the repo's `*.config.ts` convention (vite/knip/playwright/react-router), so it lives where config is expected and is found.
- `.ts` is the highest-precedence extension, so a stray `doctor.config.json`/`.jsonc` cannot shadow it.
- Comments are native, carrying the evidence for each suppression.

### Duplicate-config guard

A deterministic check fails when more than one `doctor.config.*` or `react-doctor.config.*` file exists, because react-doctor itself gives no warning:

- `.husky/pre-commit` ([[Pre-commit Hooks]]) fails the commit before a duplicate lands.
- `.github/workflows/config-guard.yml` is the un-gated CI backstop (job name: `Single react-doctor config`).

The CI job runs on every pull request but is advisory until it is a branch-protection required check. **Add `Single react-doctor config` to the required checks for `main` to make it blocking.** See [[Code Review Audit CI]] for how required checks gate merges.

## Acting on output

Findings fall into three buckets:

1. **Real issue**: fix the code. Security and correctness rules take priority over performance and a11y.
2. **Domain mismatch**: a rule that does not apply to a path (e.g. a web-input rule firing on maintainer CLI tooling, or a generated artifact). Add a scoped `ignore.overrides` entry naming the rule and files, or `ignore.files` for output that should never be scanned (e.g. `build/**`).
3. **Tool overlap**: dead-code analysis (`deslop`) duplicates [[knip]], the single dead-code authority. `deadCode: false` disables it.

Suppress with the narrowest control: prefer a per-path `ignore.overrides` entry over a blanket rule-off. Every suppression carries a comment with the evidence so it can be re-evaluated when the ruleset changes (rules also drift between versions, since the scan runs at `npx ...@latest`).

See [[Quality Gate]], [[Code Review Audit Agent]].
