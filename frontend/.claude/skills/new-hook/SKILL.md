---
name: new-hook
description: Scaffold a new custom React hook with a Vitest browser-mode test file. Use this skill whenever the user asks to "create a hook", "make a useFoo hook", "scaffold a custom React hook", "add a hook under app/hooks", or describes a piece of reusable React state/effect logic that warrants extraction into a named `use*` hook.
model: haiku
---

# new-hook

Trigger: user asks to create a custom React hook.

## Workflow

1. Confirm: name (`use-kebab` or `useCamel`), params, return type.
2. Run from the repo root: `./.gaia/cli/gaia scaffold hook <useFoo> [--params "a:string,b:number"] [--returns "ReturnType"]`.
3. Verify: `pnpm typecheck` clean. Open and sanity-check.

The scaffold writes `app/hooks/use-<kebab>.ts` (named export `useCamel`) and `app/hooks/tests/use-<kebab>.test.ts`, which renders the hook with async `renderHook` from `vitest-browser-react` and runs in the `browser` Vitest project (real Chromium; run `pnpm install:browsers` once). A bare stub declares a `void` return.
