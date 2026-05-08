---
class: hook
gaia_version: 1.4.2
created: 2026-05-08
---

## Classification

class: hook
evidence: PostToolUse hook script returns exit 1 on every file edit.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
hook_exit: 1
```

## Reproduction context

- `.claude/hooks/post-tool.sh`
