# `.github/forensics/`

Supporting scripts for the SPEC-002 forensics triage workflow
(`.github/workflows/forensics-triage.yml`). The workflow itself is on the
canonical denylist and never self-modifies; the helpers here are pure-shell,
unit-testable primitives the workflow shells out to.

## Scripts

| Script                                                                                                  | Purpose                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bootstrap-labels.sh`                                                                                   | Maintainer-run, idempotent. Asserts the SPEC-002 phase-2 label vocabulary on the upstream repo; creates any missing labels with frozen colors/descriptions. |
| `check-scope.sh`                                                                                        | Default-deny path-policy primitive. Classifies candidate paths against the SPEC-002 allowlist/denylist. JSON to stdout.                                     |
| _additional helpers ship with later SPEC-002 phases (body-parser, classifier prompt, action handlers)._ |

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
