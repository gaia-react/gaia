## Symptom

The /gaia-init skill failed while running the rename step. I was trying to scaffold a new project called "my-app" and the process stopped partway through. The rename did not complete and the project directory still has the old GAIA branding in README.md and in the package.json name field. Running it again shows the same failure.

## Classification

class: init
evidence: "init" + .gaia/manifest.json

## Capture

gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:

- .gaia/manifest.json: present, version 1.2.0
- .gaia/local/setup-state.json: present, lastStep "rename"
- package.json: present, name "gaia" (rename incomplete)

## Reproduction context

The user ran /gaia-init on a fresh clone of the GAIA React template. They provided the project name "my-app". The rename step started but did not complete — the process appeared to hang and then exit without an error message. After the failure, the project still references "gaia" in package.json and README.md.
