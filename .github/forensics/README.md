# `.github/forensics/`

Supporting scripts for the forensics triage workflow
(`.github/workflows/forensics-triage.yml`). The workflow itself is on the
canonical denylist and never self-modifies; the helpers here are pure-shell,
unit-testable primitives the workflow shells out to.

## Scripts

| Script                 | Purpose                                                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bootstrap-labels.sh`  | Maintainer-run, idempotent. Asserts the forensics triage label vocabulary on the upstream repo; creates any missing labels with frozen colors/descriptions. |
| `check-scope.sh`       | Default-deny path-policy primitive. Classifies candidate paths against the forensics allowlist/denylist. JSON to stdout.                          |
| `parse-issue-body.sh`  | Deterministic issue-body parser. JSON to stdout.                                                                                                  |
| `parse-verdict.sh`     | Extracts the classifier verdict + proposed paths. JSON to stdout.                                                                                 |
| `render-prompt.sh`     | Literal single-pass prompt-template renderer.                                                                                                     |
| `run-quality-gate.sh`  | Runs the Quality Gate on the auto-fix branch; JSON summary.                                                                                       |
| `handlers/`            | Per-verdict action handlers (non-issue, needs-human, auto-fixable, malformed-body, already-triaged).                                              |

## Run-once: bootstrap labels

Before the triage workflow ships, the maintainer runs:

```sh
.github/forensics/bootstrap-labels.sh --dry-run            # preview
.github/forensics/bootstrap-labels.sh                      # apply
```

Defaults to `--repo gaia-react/gaia`. Override with `--repo <owner>/<name>`
when bootstrapping a fork or test repo.

Prerequisites: `gh` authenticated against the target repo with `repo` scope,
`jq` on PATH.

The script is operator-wins: existing labels with drifted color/description
are reported via `::notice::` lines and left untouched. CI never invokes
this script.
