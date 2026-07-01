---
class: dev-server
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/205
---

## Symptom

Dev server crashes when reading the user's API key from `<redacted>`; the
config loader at `.gaia/cli/src/config/load.ts` then logs the resolved path
`.gaia/cli/src/config/load.ts` before exiting non-zero.

## Classification

class: dev-server
evidence: the loader rethrows on missing env; the reporter's machine has the
env var set to `<redacted>` (phase-1 redacted), so the loader should treat it
as present.

## Capture

```
gaia_version: 1.4.2
node: v22.19.0
pnpm: 10.33.0
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:
  - vite.config.ts: present
  - package.json: scripts.dev "vite"
api_key: <redacted>
config_path: .gaia/cli/src/config/load.ts
```

## Reproduction context

- `.gaia/cli/src/config/load.ts`
- entry derived from `<redacted>` referencing `.gaia/cli/src/config/load.ts`
