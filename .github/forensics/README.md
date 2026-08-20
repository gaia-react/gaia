# `.github/forensics/`

Supporting scripts for the forensics triage workflow
(`.github/workflows/forensics-triage.yml`). The workflow itself is on the
canonical denylist and never self-modifies; the helpers here are pure-shell,
unit-testable primitives the workflow shells out to.

## Scripts

| Script                 | Purpose                                                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check-scope.sh`       | Default-deny path-policy primitive. Classifies candidate paths against the forensics allowlist/denylist. JSON to stdout.                          |
| `parse-issue-body.sh`  | Deterministic issue-body parser. JSON to stdout.                                                                                                  |
| `parse-verdict.sh`     | Extracts the classifier verdict + proposed paths. JSON to stdout.                                                                                 |
| `render-prompt.sh`     | Literal single-pass prompt-template renderer.                                                                                                     |
| `run-quality-gate.sh`  | Runs the Quality Gate on the auto-fix branch; JSON summary.                                                                                       |
| `handlers/`            | Per-verdict action handlers (non-issue, needs-human, auto-fixable, malformed-body, already-triaged).                                              |

## Label vocabulary

`.gaia/cli/gaia labels sync` reconciles the forensics triage labels from
`.gaia/labels.json`; see `wiki/concepts/GitHub Labels.md` for the full registry.
