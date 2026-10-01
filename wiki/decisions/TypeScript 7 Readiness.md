---
type: decision
status: active
priority: 2
date: 2026-06-09
created: 2026-06-09
updated: 2026-10-01
tags: [decision, typescript, tooling]
---

# Decision: TypeScript 7 Readiness

GAIA ships a `tsconfig.json` that tracks the TypeScript 7 strict baseline ahead of the upgrade, so adopting the native compiler (`tsgo`) is a dependency swap rather than a config migration. A project that keeps that posture when it edits its own `tsconfig.json` keeps the swap cheap.

## The shipped posture

- `stableTypeOrdering: true` and `noUncheckedSideEffectImports: true` are enabled under TypeScript 6, matching TS7 defaults.
- GAIA's `tsconfig.json` sets none of the options TS7 removes: `baseUrl`, `downlevelIteration`, `target: es5`, and `moduleResolution: node/classic` are absent, and `esModuleInterop` is `true`. Adding any of them back reintroduces a migration step.
- The baseline is TS7-shaped: `module: ESNext`, `moduleResolution: Bundler`, `target: ES2022`, `strict: true`, explicit `types`.
- `tsc` runs typecheck-only (`noEmit`); the bundler emits. TS7's not-yet-shipped emit, watch, and declaration features do not apply.

## What gates the upgrade

The lint stack is the consumer of TypeScript's programmatic API that gates the upgrade, because its type-aware rules depend on the type checker. GAIA's `package.json` does not list `typescript-eslint` directly: the type-aware rules arrive transitively through [[gaia-lint]], which pulls the typescript-eslint toolchain in via its bundled plugin set. The gate therefore lives in that package's dependency graph rather than the consumer's `package.json`. TS7 stabilizes that API at 7.1, not 7.0. Until 7.1, the native compiler can only run alongside TypeScript 6 as a second toolchain, so the clean single-toolchain swap waits for 7.1.

The lint stack is not the only consumer. GAIA tooling that reads source through the parser imports `typescript` directly, and those readers depend on the same programmatic API, so the 7.1 gate covers them too. `git grep -lE "require\('typescript'\)|from 'typescript'" -- '*.ts' '*.mjs'` lists them.

## Enforcement

GAIA ships `gaia.updateDepsHold` in `package.json` as `{"typescript": "6.0"}`, so the `/update-deps` skill caps discovery at the 6.0 line: patches on that line still land, and 6.1, 7.0, and anything higher are never offered. The hold is committed rather than a local snooze, so it applies in CI runs too. It holds until someone removes or raises it in the project's `package.json`.

The ceiling pins two segments rather than one because 6.1 is out of range independent of the 7.1 API question: typescript-eslint declares a peer range that stops below 6.1, so a `"6"` ceiling would offer a TypeScript minor the lint stack does not support. That gives the hold two independent lift triggers, whichever comes first: the typescript-eslint peer range widening past 6.1, or TypeScript 7.1 shipping with the stabilized programmatic API the type-aware rules in [[gaia-lint]] depend on.

`typescript` resolves to its own singleton update group, not a companion group with `@types/node`. A compiler bump and an ambient Node type-definition bump have independent migration guides and independent blast radius, so a hold on one must not stall the other.

## resolveJsonModule

GAIA enables it even though its shipped app imports no JSON. GAIA is a foundation for [[React Router]] projects, JSON imports are a first-class Vite pattern, and the option is inert until an import exists. See [[TypeScript Language Files]].

## allowJs

Off in GAIA's shipped config. GAIA is strict-TS-first; type-checking JavaScript is an explicit opt-in for a project that wants it, not a default.
