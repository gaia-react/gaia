---
type: decision
status: active
priority: 1
date: 2026-10-05
created: 2026-10-05
updated: 2026-10-05
tags: [decision, react, compiler, build, performance]
---

# Decision: React Compiler

React Compiler 1.x runs by default in the app build, the dev server, Vitest and Storybook. One shared module, `frontend/react-compiler.config.ts`, owns the compiler options, the on/off switch and the opt-in compile report. It compiles client code only; SSR output stays uncompiled because it renders once.

## Setup and options

- **Options:** `compilationMode: 'infer'`, `panicThreshold: 'none'` (a bailout skips that function instead of failing the build), `target: '19'`, no gating.
- **Wiring rule:** the shared plugin sits after `reactRouter()` in `frontend/vite.config.ts`, which never calls `react()` (a second `react()` double-runs Fast Refresh). Vitest and Storybook add the same export from the shared module; no consumer passes its own options.
- **Babel is the only supported path.** A native compiler path is not yet usable in React Router framework mode.
- **Compile report:** `GAIA_REACT_COMPILER_REPORT=<path>` writes per-file compile events as JSON Lines. Unset, nothing is written and nothing is logged per function.

## Correctness gate

The react-hooks lint rules, at error or at warn under `--max-warnings=0`, are the correctness gate: code that passes them is code the compiler can reason about. The compile report makes files the compiler skipped visible.

## Guidance

Memoization policy and its two escape cases live in `frontend/.claude/skills/react-code/SKILL.md` (`## Memoization: compiler-first`).

## Cost thresholds and verdicts

Each metric fails when the compiler-on median exceeds the compiler-off median by more than its threshold.

| Metric | Threshold | Delta | Verdict |
| --- | --- | --- | --- |
| Production build time | 20 percent of the off median (about 369 ms) | +343 ms | PASS |
| Cold dev start | 1.0 s | +845 ms | PASS |
| HMR latency (median) | 100 ms | -2 ms | PASS |

Method: a script interleaved the off and on configurations, ten runs each, compared medians (with the interquartile range recorded), and flipped the switch on the same tree. Cold dev start samples one route.

## Benefit

Update-phase renders on theme switching fall from 1240 to 680, a 45.2 percent reduction, well past the 20 percent materiality bar, so the benefit is material and not only future-proofing.

## Compile coverage

Every GAIA-owned component and hook the client build loads compiles in the build; the few the build never loads (used only by tests or stories) are proven through the Storybook or Vitest compile. No file needs a `"use no memo"` opt-out.

## Adopters

Preconditions: React 19 or later, `@vitejs/plugin-react` 6.x, and no `react()` call in your app config.

1. Install the dev dependencies at the versions GAIA pins: `pnpm --dir frontend add -D babel-plugin-react-compiler@1.0.0 @rolldown/plugin-babel@0.2.4 @babel/core@7.29.7`.
2. Grep your code for react-hooks `eslint-disable` comments and rule overrides. The compiler can change behavior for code that evades those rules.
3. Run `pnpm lint`.
4. Run the build once with `GAIA_REACT_COMPILER_REPORT` set and review skipped or failed files.
5. Run the full test and E2E suites.
6. Add `"use no memo"` with a reason comment to any file that misbehaves.

## Rollback

Set `isReactCompilerEnabled` to `false` in `frontend/react-compiler.config.ts`. Builds and the suite stay green because the compiler-dependent tests read the same switch.

The shared module is a GAIA-owned file, so an `/update-gaia` that overwrites it re-enables the compiler. Re-apply the switch after such an update, or opt individual files out with `"use no memo"` and a reason comment.
