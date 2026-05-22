---
name: new-hook
description: Scaffold a new custom React hook with a Vitest test file. Use this skill whenever the user asks to "create a hook", "make a useFoo hook", "scaffold a custom React hook", "add a hook under app/hooks", or describes a piece of reusable React state/effect logic that warrants extraction into a named `use*` hook.
model: haiku
---

# new-hook

Trigger: user asks to create a custom React hook.

## Workflow

1. Confirm: name (use\*), params, return type.
2. Run: `gaia scaffold hook <useFoo> [--params "a:string,b:number"] [--returns "ReturnType"]`.
3. Verify: `pnpm typecheck` clean. Open and sanity-check.
