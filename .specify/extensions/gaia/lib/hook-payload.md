# GAIA spec-kit extension — hook payload contract

Every hook script registered by the GAIA extension receives a JSON payload on **stdin** (and equivalently in the `SPECKIT_HOOK_PAYLOAD` env var). Hooks return their decision via stdout JSON plus a process exit code. This document is the frozen contract — the same shape applies to all six hooks (`before_specify`, `after_specify`, `after_clarify`, `before_implement`, `after_implement`, `on_save`).

## Payload shape

```json
{
  "hook_event": "before_specify | after_specify | after_clarify | before_implement | after_implement | on_save",
  "spec_id": "SPEC-NNN | null",
  "spec_path": ".gaia/local/specs/SPEC-NNN.md | null",
  "draft_path": ".specify/cache/draft.md | null",
  "branch": "<git branch>",
  "cwd": "<absolute repo root>",
  "speckit_version": "vX.Y.Z",
  "extension_id": "gaia"
}
```

### Field semantics

| Field             | Type             | Notes                                                                                                                  |
|-------------------|------------------|------------------------------------------------------------------------------------------------------------------------|
| `hook_event`      | string (enum)    | One of the six hook event names. Hooks should validate this matches the event they were registered for.               |
| `spec_id`         | string \| null   | `null` for `before_specify` on a fresh session; populated once a SPEC has been allocated.                              |
| `spec_path`       | string \| null   | Repo-relative path to the saved SPEC. `null` until the SPEC artifact is persisted to `.gaia/local/specs/`.             |
| `draft_path`      | string \| null   | Repo-relative path to the in-flight draft inside `.specify/cache/`. Populated during `/speckit.specify` and `/speckit.clarify`. |
| `branch`          | string           | Current `git rev-parse --abbrev-ref HEAD` value at hook fire time.                                                     |
| `cwd`             | string           | Absolute path to the repo root (the wrapper sets this before invoking the hook).                                       |
| `speckit_version` | string           | Resolved spec-kit version at runtime (must match the `requires.speckit_version` pin in `extension.yml`).               |
| `extension_id`    | string           | Always `"gaia"` for hooks registered by this extension; used by spec-kit's hook bus for routing.                       |

## Return semantics

Hooks signal back to spec-kit through **process exit code + stdout JSON**:

| Exit code | stdout JSON                                                              | Effect                                                  |
|-----------|--------------------------------------------------------------------------|---------------------------------------------------------|
| 0         | `{"action": "proceed"}`                                                  | Continue lifecycle.                                     |
| 0         | `{"action": "block", "reason": "<message>"}`                             | Halt with `<message>` surfaced to the user.             |
| 0         | `{"action": "prompt", "prompt": "<text>", "default": "<default>"}`       | Wrapper surfaces the prompt to the user before continuing. |
| non-zero  | (any; stderr captured)                                                   | Treated as `block`; stderr becomes the reason string.   |

### Conventions

- All paths in payloads and return JSON are **repo-relative** unless explicitly absolute (only `cwd` is absolute).
- Hooks must not write outside the wrapper write-surface allowlist: `.gaia/local/specs/**`, `.specify/**`, `.gaia/local/cache/**`, `.gaia/local/telemetry/**`.
- Hooks receive the payload on stdin so they can be invoked the same way under `uvx`, in CI, and inside the extension test harness. The `SPECKIT_HOOK_PAYLOAD` env var is provided as a fallback for shells that cannot read stdin reliably.

## Worked examples

### Example 1 — `before_specify` on a fresh session

Fired when the user invokes `/gaia spec [description]` and no in-progress SPEC exists. `spec_id`, `spec_path`, and `draft_path` are all `null` because nothing has been allocated yet.

```json
{
  "hook_event": "before_specify",
  "spec_id": null,
  "spec_path": null,
  "draft_path": null,
  "branch": "feat/gaia-spec",
  "cwd": "/Users/stevensacks/Development/gaia-react/gaia",
  "speckit_version": "v0.8.5",
  "extension_id": "gaia"
}
```

A typical response that detects an unpopulated constitution:

```json
{"action": "block", "reason": "spec-kit constitution at .specify/memory/constitution.md still contains placeholder values. Run /speckit.constitution and re-invoke /gaia spec."}
```

### Example 2 — `after_specify` with populated paths

Fired after the SPEC has been drafted and the artifact is sitting in the cache awaiting save. Both `spec_id` (allocated by `lib/spec-allocator.sh`) and `draft_path` are populated; `spec_path` is the prospective save target.

```json
{
  "hook_event": "after_specify",
  "spec_id": "SPEC-002",
  "spec_path": ".gaia/local/specs/SPEC-002.md",
  "draft_path": ".specify/cache/draft.md",
  "branch": "feat/gaia-spec",
  "cwd": "/Users/stevensacks/Development/gaia-react/gaia",
  "speckit_version": "v0.8.5",
  "extension_id": "gaia"
}
```

A successful immutability-lint response:

```json
{"action": "proceed"}
```

A failing-lint response (e.g. placeholder text detected):

```json
{"action": "block", "reason": "Lint failure: 2 placeholder strings detected (\"<TBD>\" at uats[1].then; \"FIXME\" at success_criteria[0]). Resolve before save."}
```

### Example 3 — `on_save` with persisted SPEC

Fired immediately after the SPEC artifact has been written to disk. `spec_path` points at the persisted file; `draft_path` may still be present until the cache is cleared.

```json
{
  "hook_event": "on_save",
  "spec_id": "SPEC-002",
  "spec_path": ".gaia/local/specs/SPEC-002.md",
  "draft_path": ".specify/cache/draft.md",
  "branch": "feat/gaia-spec",
  "cwd": "/Users/stevensacks/Development/gaia-react/gaia",
  "speckit_version": "v0.8.5",
  "extension_id": "gaia"
}
```

A typical chain-trigger response (default yes; the user can defer):

```json
{"action": "prompt", "prompt": "SPEC-002 saved. Trigger /gaia plan now?", "default": "yes"}
```
