---
class: hook
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

A hook pasted compiler output that quotes a markdown heading:

```
Traceback (most recent call last):
## Error output
  File "hook.py", line 3
```

## Classification

class: hook
evidence: the hook aborts before writing its marker.

## Capture

gaia_version: 1.4.2
node: v22.0.0
pnpm: 9.0.0
claude_code: 1.0.0
branch: main
dirty: false
class_state_files: none

## Reproduction context

The failing doc quoted its own header:

## Notes from the report

- `.claude/hooks/x.sh`
