# Template-Distributed File Paths

Files under `.claude/instructions/`, `.claude/commands/`, `.claude/skills/`, `.claude/agents/`, and `.claude/rules/` ship inside the GAIA template and get installed onto end-user machines via the scaffold. Any path baked into them must be portable.

## Rule

**All paths in template-distributed Claude files must be repo-relative.** Use `app/i18n.ts`, not `/Users/<name>/.../app/i18n.ts`. The executing agent's working directory is always the project root, so repo-relative paths resolve correctly on every machine.

## Why

The maintainer authoring these files works on `/Users/<maintainer>/...`. End users running `/gaia-init` (or any descendant skill that dispatches to these files) work on `~/projects/<their-project>` or wherever they cloned. An absolute path embedded in a runbook, command, or skill fails everywhere except the maintainer's machine.

## How to apply

When authoring or editing any file under `.claude/`:

- File references in prose: `app/i18n.ts`, `.gaia/manifest.json`, `.claude/rules/i18n.md`.
- Cross-file dispatches in a skill or command: ``Read `.claude/instructions/add-locale.md` ``.
- Shell commands (`rm`, `grep`, `find`): repo-relative paths — they resolve from the agent's pwd which is the project root.
- Self-delete steps: `rm .claude/instructions/<file>.md`.
- Verification commands: prefer the package-script form (`pnpm typecheck`, `pnpm lint`) over `pnpm -C <path>` because `-C` requires an absolute path.
- Discovery `grep` commands: paths like `app`, `test`, `wiki`, `.claude` — no leading slash.

If a path absolutely must be unambiguous (rare), derive root dynamically:

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
```

…and reference paths as `${PROJECT_ROOT}/app/i18n.ts`.

## Audit

Before merging changes to any file under `.claude/`:

```bash
grep -rn "/Users/\|/home/" .claude/
```

Any match outside this rule's prose (where `/Users/<name>/...` is shown as a counter-example) is a bug.
