# Knip — Dead Code Detection

`pnpm knip` reports unused files, exports, types, and dependencies. Configured at `knip.config.ts`.

## When it runs automatically

Knip runs automatically pre-merge inside the `code-review-audit` agent (`.claude/agents/code-review-audit.md`), in the same parallel batch as `react-doctor`. Pre-merge is post-task by design — work is finished, audit fires, then merge — so the noise concern below does not apply at that point.

## When to suggest running manually

Outside the pre-merge audit, suggest `pnpm knip` after:

- A refactor that removes or restructures modules
- Deleting a feature, route, page, or component
- Removing or replacing a dependency
- Before opening a release-candidate PR

Do **not** run knip mid-task or as part of the Quality Gate (pre-commit) — in-progress work routinely flags exports that haven't been wired up yet, and the noise drowns the signal. The pre-merge auto-run inside `code-review-audit` is the only automated invocation; everything else is manual or suggestion-driven.

## Acting on output

Knip output falls into three buckets:

1. **Real dead code** — unused file/export/type that no longer has callers. Delete it.
2. **Library API exposed for downstream use** — intentionally exported even though this repo doesn't consume it. Add to `entry` globs in `knip.config.ts`.
3. **Implicit dependency** — package used via config plugin, CSS, or runtime resolution that knip can't trace. Add to `ignoreDependencies` in `knip.config.ts`.

Always confirm the bucket before acting. A "delete this export" suggestion is wrong if the export is intentional library surface — adjust the config instead.

## Reference

- Config: `knip.config.ts`
- Run: `pnpm knip`
- Knip docs: https://knip.dev
