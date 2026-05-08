## Symptom

The triage workflow never fires on issues opened from the mobile app.

## Classification

class: other
evidence: GitHub Actions queue shows no run for issue #204.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
issue_number: 204
```

## Reproduction context

- `.github/workflows/forensics-triage.yml`
