---
class: dev-server
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

Dev server crashes when env var is `<redacted>`.

## Classification

class: dev-server
evidence: stack trace points at config loader at `<repo-relative-paths>`.

## Capture

```
gaia_version: 1.4.2
api_key: <redacted>
config_path: <repo-relative-paths>
git_branch: feature/<redacted>-fix
```

## Reproduction context

- `<repo-relative-paths>`
- file at `<repo-relative-paths>` referencing `<redacted>`
