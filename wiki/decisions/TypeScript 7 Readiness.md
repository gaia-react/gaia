---
type: decision
status: active
priority: 2
date: 2026-06-09
created: 2026-06-09
updated: 2026-06-24
tags: [decision, typescript, tooling]
---

# Decision: TypeScript 7 Readiness

`tsconfig.json` tracks the TypeScript 7 strict baseline ahead of the upgrade, so adopting the native compiler (`tsgo`) is a dependency swap rather than a config migration.

## Current posture

- `stableTypeOrdering: true` and `noUncheckedSideEffectImports: true` are enabled under TypeScript 6, matching TS7 defaults.
- No TS7-removed options are present: no `baseUrl`, no `downlevelIteration`, no `target: es5`, no `moduleResolution: node/classic`, and `esModuleInterop` stays `true`.
- Baseline is already TS7-shaped: `module: ESNext`, `moduleResolution: Bundler`, `target: ES2022`, `strict: true`, explicit `types`.
- `tsc` runs typecheck-only (`noEmit`); the bundler emits. TS7's not-yet-shipped emit, watch, and declaration features do not apply.

## What gates the upgrade

The lint stack is the only consumer of TypeScript's programmatic API, which its type-aware rules depend on. `typescript-eslint` is not a direct dependency in `package.json`; the type-aware rules reach the project transitively through [[gaia-lint]] (the sole import in `eslint.config.mjs`), which pulls the typescript-eslint toolchain in via its bundled plugin set. The gate therefore lives in that package's dependency graph rather than the consumer's `package.json`. TS7 stabilizes that API at 7.1, not 7.0. Until 7.1, the native compiler can only run alongside TypeScript 6 as a second toolchain, so the clean single-toolchain swap waits for 7.1.

## resolveJsonModule

Retained even though GAIA imports no JSON. GAIA is a foundation for [[React Router 7]] projects, JSON imports are a first-class Vite pattern, and the option is inert until an import exists. See [[TypeScript Language Files]].

## allowJs

Off. GAIA is strict-TS-first; type-checking JavaScript is an explicit adopter opt-in, not a clone default.
