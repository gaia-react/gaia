---
type: decision
status: active
priority: 1
date: 2026-06-23
created: 2026-06-23
updated: 2026-06-23
tags: [decision, tdd, hooks, quality, classifier]
---

# Determinism Classifier

A per-file, statically-checkable AST signal that labels a touched source file **STRICT** (deterministic; goes under the [[TDD RED Verification]] gate) or **EMERGENT** (clock-, entropy-, or I/O-bound, or dependent on the rendered tree; advisory audit only, no RED proof required). Path scopes the candidate set; content decides. No LLM round-trip.

## Problem

Not every source file can honestly carry a RED proof. Code that reads the clock, draws entropy, performs real I/O, or depends on a live DOM or router tree has no stable failing-then-passing run to observe: forcing a RED onto it produces theatre that corrupts the RED-observation ledger. A deterministic mechanism is needed to decide, per file, whether the RED gate applies.

## Decision

The classifier emits one of two labels per file. **The bias is deliberate: err EMERGENT.** A missed RED is caught late by the advisory worthiness audit; an over-strict label forces RED theatre that is the worse failure. Ambiguous cases classify EMERGENT.

A file classifies **STRICT only when ALL of conditions 1 through 4 hold.** Failing any of conditions 2 through 4 classifies it EMERGENT regardless of path.

### Condition 1: path + hook/non-hook discriminator

The file path is in `app/utils/**`, `app/services/**`, `app/hooks/**`, or is a `.ts` (NOT `.tsx`) under `app/components/**`. Any other path classifies EMERGENT.

A file that exports a `use*` symbol is a hook (even under `app/utils/**`) and is judged by condition 3. Non-hook files skip condition 3.

### Condition 2: no module-reachable non-determinism

No `new Date()` / `Date.now()` / `Math.random()` / `crypto` usage and no top-level `await` reachable without an argument. "Module-reachable" is not limited to the module top level. It includes:

- **module top-level statements** (e.g. `const X = new Date()` at file scope),
- **default-parameter initializers** (e.g. `formatMY(d = new Date())`), and
- **class-field initializers** (e.g. `field = Math.random()`).

A default-parameter or class-field initializer evaluates per call or per instantiation when the caller supplies no argument, so it is as clock- or entropy-dependent as a top-level statement even though it sits syntactically inside a function signature or class body. Any of the three forms fails condition 2 and classifies the file EMERGENT. A `new Date(arg)` with an argument is deterministic and does not fail.

### Condition 3: hook call-surface rule (applies only to `use*` files)

A hook is EMERGENT if it calls a react-router runtime hook (`useFetchers` / `useRouteLoaderData` / `useNavigate` / …), a DOM-layout API (`getBoundingClientRect` / `ResizeObserver` / `IntersectionObserver` / a resize-or-scroll subscription), or a context read whose correctness depends on the rendered tree. Otherwise it is STRICT (`useState` / `useReducer` / `useMemo` / `useCallback`, timers behind fake timers, discrete DOM APIs such as `matchMedia`).

Condition 3 is **whole-hook by design**: one emergent call routes the entire hook EMERGENT. Over-loose on a mixed hook is the intended trade, not a gap, the alternative is splitting a hook's call surface, which the file-granular mechanism cannot do.

### Condition 4: no public async I/O export

No public (exported) async export wrapping real I/O: `fetch`, a Ky client call, or `setTimeout`-used-as-sleep. Condition 4 applies to non-hook files; a hook's I/O is judged by its call surface under condition 3.

The **`setTimeout` reconciling principle**: `setTimeout` is STRICT when timing is the unit under test and fake timers make it deterministic; it is EMERGENT when it models real elapsed I/O. A public async export that schedules `setTimeout` inside a returned or awaited Promise models elapsed time and is EMERGENT.

## Versioned DOM-API allowlist

The strict/emergent split for DOM APIs is an enumerable allowlist, not an inferable property. `matchMedia` and timers (deterministic behind fake timers) are STRICT; layout, observer, and router-runtime APIs are EMERGENT. **An unknown DOM API classifies EMERGENT** until the allowlist is updated.

The allowlist is a constant in the classifier with a version marker (`DOM_ALLOWLIST_VERSION`). The marker bumps whenever an entry is added or moved between buckets, so a consumer can pin against a known allowlist. A DOM-host receiver (`navigator`, `document`, `window`, `globalThis`, `screen`) calling a method absent from the allowlist is treated as an unknown DOM API and classifies the hook EMERGENT.

## a11y helpers are an emergent signal

The a11y-helper call names `expectNoA11yViolations` and `runAxe` (from `test/a11y.ts`) are members of the emergent-signal set. A static-markup a11y check is environment- and render-dependent, so a file calling either helper classifies EMERGENT regardless of whether it renders a component.

## File-granularity limitation

The classifier is **file-granular**: it labels a whole file STRICT or EMERGENT and **cannot split a pure export from an impure module constant in the same file.** A file with even one module-reachable non-deterministic constant classifies EMERGENT in full; its otherwise-pure exports cannot be independently RED-gated without first refactoring that constant behind a function. This is an honest limitation of the mechanism, not a verdict that those exports are untestable.

## Infrastructure

- `.gaia/scripts/classifier/classify-determinism.mjs`: Node ESM helper using the TypeScript compiler API. Takes a repo-relative source path (or `--stdin`, where the path argument names the file identity for path scoping and `.ts`-vs-`.tsx` script kind). Emits one JSON object: `{file, classification: "strict" | "emergent", reasons: [...]}`. Exits 0 on success; exits non-zero with a one-line stderr message on a missing argument, a missing `typescript`, an unreadable file, or a parse failure, so a bash caller can apply its own fail-open policy. Mirrors `extract-test-signals.mjs` (see [[TDD RED Verification]]).

## Consumers

- The RED carve-out at commit time scopes the RED demand to STRICT files; EMERGENT files commit without a RED proof.
- The worthiness audit and the merge presence gate scope to the EMERGENT surface (`app/components/**`, `.playwright/**`).

The `{file, classification, reasons}` output shape and the emergent-signal set are a stable contract these consumers depend on.
