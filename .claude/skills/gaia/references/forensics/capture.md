# Capture

Read this fragment at the capture step. Execute every command listed; apply exclusion rules before assembling the snapshot.

## Universal capture

Always-included envelope, regardless of class:

| field          | source                                | command                                                                                                 |
| -------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `gaia_version` | `.gaia/manifest.json` `version` field | `jq -r '.version' .gaia/manifest.json 2>/dev/null \|\| cat .gaia/VERSION 2>/dev/null \|\| echo unknown` |
| `node`         | local Node                            | `node --version 2>/dev/null \|\| echo unknown`                                                          |
| `pnpm`         | local pnpm                            | `pnpm --version 2>/dev/null \|\| echo unknown`                                                          |
| `claude_code`  | Claude Code CLI                       | `command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null \|\| echo unknown`                   |
| `branch`       | git                                   | `git rev-parse --abbrev-ref HEAD 2>/dev/null \|\| echo unknown`                                         |
| `dirty`        | git                                   | `[[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo true \|\| echo false`                         |

Every command is wrapped so a missing tool or failing exit yields `unknown` rather than a hard failure. No command writes, installs, fetches, or shells out to any script that mutates state.

## Class-specific state files

For the detected class, read only the files listed below. Record filename + one-line summary; never capture the full file body.

### init

| path                           | one-line summary rule                                            |
| ------------------------------ | ---------------------------------------------------------------- |
| `.gaia/manifest.json`          | presence + `version` field value                                 |
| `.gaia/local/setup-state.json` | presence + value of the `lastStep` field if present              |
| `package.json`                 | presence + value of the `name` field (confirms rename completed) |

### update

| path                  | one-line summary rule                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------- |
| `.gaia/manifest.json` | presence + `version` field value                                                                        |
| _(conflicted paths)_  | output of `git diff --name-only --diff-filter=U`, list of repo-relative conflicted paths, one per line |

### wiki-sync

| path               | one-line summary rule                           |
| ------------------ | ----------------------------------------------- |
| `wiki/.state.json` | presence + value of `lastSync` field if present |
| `wiki/log.md`      | presence + first line of the last entry only    |

### quality-gate

The verbatim failing command output stays in `## Symptom` (user-supplied). The `## Capture` section records `user-supplied verbatim output` as the evidence entry for `class_state_files`. No additional state-file reads required.

### hook

| path                    | one-line summary rule                                                       |
| ----------------------- | --------------------------------------------------------------------------- |
| `.claude/settings.json` | presence + top-level keys of the `hooks` object (key names only, no values) |
| _(failing hook)_        | filename only if the user named it, never the script body                  |

### scaffold

| path                         | one-line summary rule                      |
| ---------------------------- | ------------------------------------------ |
| _(failing skill's SKILL.md)_ | filename + first heading line (`# <name>`) |

### dev-server

| path             | one-line summary rule        |
| ---------------- | ---------------------------- |
| `vite.config.ts` | presence (filename only)     |
| `package.json`   | value of `scripts.dev` field |

### other

Universal envelope only. No class-specific reads.

## Exclusions

The following are never captured, not even filenames in some cases:

- **Bodies of files under `app/` and `wiki/`.** Filenames from these directories are allowed in state summaries; full file contents are never read or included.
- **Claude Code session JSONL contents.** Files matching `~/.claude/projects/*/session-*.jsonl` are entirely excluded in phase 1. Filenames from this path are also excluded.
- **`.env*` files.** Always excluded, not even filenames appear in the snapshot.
- **`node_modules/`.** Any path under `node_modules/` is excluded in full.
- **`git log` body beyond one line.** Only the most recent commit's subject line is ever included; the full log body is excluded.
- **Outputs exceeding ~80 lines or 4 KB.** If a captured snapshot entry exceeds either threshold, truncate and append `... (truncated)`.

## Read-only guarantees

Every command in this fragment is read-only. The capture step:

- Does not run `pnpm install`, `npm install`, or any package manager install command.
- Does not run `git fetch`, `git pull`, `git stash`, or any command that mutates git state.
- Does not invoke `gh` in any form.
- Does not shell out to any GAIA skill, hook, or script that writes to disk.

The working-tree mtimes across `app/`, `wiki/`, `.gaia/cli/`, `.claude/`, and `.specify/` do not change across the capture step. This is verifiable by snapshotting mtimes before and after invocation.

## Output format

The capture step emits the following YAML-ish block, ready to embed verbatim into the `## Capture` section of the report body. Keys appear in this declared order:

```yaml
gaia_version: <semver>
node: <version>
pnpm: <version>
claude_code: <version>
branch: <name>
dirty: <true|false>
class_state_files:
  - <repo-relative path>: <one-line summary>
  - <repo-relative path>: <one-line summary>
```

`class_state_files` is a YAML-style list of `<repo-relative path>: <one-line summary>` entries, one entry per file inspected for the detected class, in the order listed in the class-specific table above. For `quality-gate`, the single entry is `user-supplied output: <verbatim output>`. For `other`, `class_state_files` is an empty list (`[]`).

If a file is absent, its entry is `<repo-relative path>: absent`. If a field cannot be read, its entry is `<repo-relative path>: unreadable`.
