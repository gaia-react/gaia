# v2 sandbox validation

End-to-end validation of `feat/gaia-spec-v2` against a clean spec-kit v0.8.5 sandbox at `/tmp/specify-validate-001/`. Every check below passed against the manifest and preset shipped on this branch.

Test target: `.specify/extensions/gaia/` (extension) + `.specify/presets/gaia/` (preset).

## Sandbox setup

```bash
mkdir -p /tmp/specify-validate-001
(cd /tmp/specify-validate-001 && uvx --from git+https://github.com/github/spec-kit.git@v0.8.5 specify init --here --ai claude --force)
```

Result: clean spec-kit project with `.specify/`, `.claude/skills/speckit-*/`, bundled `git` extension already installed via init.

## Extension install

```bash
(cd /tmp/specify-validate-001 && uvx --from git+https://github.com/github/spec-kit.git@v0.8.5 specify extension add --dev /Users/stevensacks/Development/gaia-react/gaia/.specify/extensions/gaia)
```

```
✓ Extension installed successfully!

GAIA Socratic Discovery (v0.1.0)
Provided commands:
  • speckit.gaia.spec
  • speckit.gaia.constitution-check
  • speckit.gaia.lint
  • speckit.gaia.self-review
```

`.specify/extensions/.registry` after install (gaia entry, abbreviated):

```json
"gaia": {
  "version": "0.1.0",
  "source": "local",
  "enabled": true,
  "priority": 10,
  "registered_commands": {
    "claude": [
      "speckit.gaia.spec",
      "speckit.gaia.constitution-check",
      "speckit.gaia.lint",
      "speckit.gaia.self-review"
    ]
  }
}
```

All 4 commands rendered into `.claude/skills/`:

```
speckit-gaia-constitution-check/SKILL.md
speckit-gaia-lint/SKILL.md
speckit-gaia-self-review/SKILL.md
speckit-gaia-spec/SKILL.md
```

## Preset install

```bash
(cd /tmp/specify-validate-001 && uvx --from git+https://github.com/github/spec-kit.git@v0.8.5 specify preset add --dev /Users/stevensacks/Development/gaia-react/gaia/.specify/presets/gaia)
```

```
✓ Preset 'GAIA' v0.1.0 installed (priority 10)
```

Preset install path is `.specify/presets/<id>/`, confirmed by inspecting `/tmp/specify-validate-001/.specify/presets/gaia/` after install.

`.specify/presets/.registry`:

```json
"gaia": {
  "version": "0.1.0",
  "registered_commands": {"claude": ["speckit.specify"]},
  "registered_skills": ["speckit-specify"]
}
```

`specify preset info gaia` reports both templates:

```
Templates: 2
  - speckit.specify (command): wraps core
  - spec-template (template): GAIA frontmatter
```

## `{CORE_TEMPLATE}` substitution (preset wrap)

`strategy: wrap` on the `commands/speckit.specify.md` entry is required for `{CORE_TEMPLATE}` to substitute. Without it, the preset replaces but does not splice, the literal `{CORE_TEMPLATE}` token remains in the rendered SKILL.md and the agent never reaches core's Pre-Execution Checks, which is where hooks fire.

After fixing to `strategy: wrap`:

```bash
grep -F '{CORE_TEMPLATE}' /tmp/specify-validate-001/.claude/skills/speckit-specify/SKILL.md
# (no matches → substitution succeeded)

grep -E '^## Step|^## Pre-Execution Checks|^## Outline' /tmp/specify-validate-001/.claude/skills/speckit-specify/SKILL.md
```

```
18:## Step 0, GAIA pre-checks
27:## Step 1, core /speckit-specify
38:## Pre-Execution Checks
73:## Outline
349:## Step 2, relocate to .gaia/local/specs/SPEC-NNN/SPEC.md
382:## Step 3, return
```

The rendered SKILL.md is 393 lines: GAIA preamble (Steps 0–1), then core specify body verbatim (Pre-Execution Checks → Outline → Final Checklist), then GAIA post-step (Steps 2–3).

## Preset resolution stack

```bash
specify preset resolve spec-template
```

```
spec-template: /private/tmp/specify-validate-001/.specify/presets/gaia/templates/spec-template.md
  (top layer from: gaia v0.1.0)
```

The GAIA preset's spec-template overrides the bundled core; downstream commands that invoke `specify preset resolve spec-template` (or that read through the resolver) will see the GAIA-shaped artifact skeleton.

## Hook registration in `.specify/extensions.yml`

```yaml
hooks:
  before_specify:
    - extension: gaia
      command: speckit.gaia.constitution-check
      enabled: true
      optional: false
      ...
  after_specify:
    - extension: gaia
      command: speckit.gaia.lint
      enabled: true
      optional: false
      ...
  after_clarify:
    - extension: gaia
      command: speckit.gaia.self-review
      enabled: true
      optional: false
      ...
```

`on_save` is absent from the file, confirms the `/gaia-plan` handoff lives inline in the GAIA wrapper command, not in the hook bus.

## Hook message rendering, `HookExecutor.format_hook_message`

Probed via direct call into spec-kit v0.8.5's source against the live sandbox (the agent receives this exact text in its reasoning context when a core skill fires the hook event):

### `before_specify`

```
**Automatic Hook**: gaia
Executing: `/speckit-gaia-constitution-check`
EXECUTE_COMMAND: speckit.gaia.constitution-check
EXECUTE_COMMAND_INVOCATION: /speckit-gaia-constitution-check
```

### `after_specify`

```
**Automatic Hook**: gaia
Executing: `/speckit-gaia-lint`
EXECUTE_COMMAND: speckit.gaia.lint
EXECUTE_COMMAND_INVOCATION: /speckit-gaia-lint
```

### `after_clarify`

```
**Automatic Hook**: gaia
Executing: `/speckit-gaia-self-review`
EXECUTE_COMMAND: speckit.gaia.self-review
EXECUTE_COMMAND_INVOCATION: /speckit-gaia-self-review
```

### `on_save`

```
(no hooks)
```

## Lib helper smoke tests (unrelated to spec-kit install state)

Both helpers run pure CLI args; no stdin payload:

```bash
$ bash .specify/extensions/gaia/lib/lint.sh .gaia/local/specs/SPEC-001/SPEC.md
{"ok":true,"findings":[]}

$ bash .specify/extensions/gaia/lib/spec-allocator.sh next /Users/stevensacks/Development/gaia-react/gaia
SPEC-003

$ bash .specify/extensions/gaia/lib/version-check.sh /Users/stevensacks/Development/gaia-react/gaia
spec-kit version check failed: could not determine installed version.
  Pinned:    >=0.8.5,<0.10.0 (from .../extension.yml)
  Installed: <unresolved>
```

`version-check.sh` exits 1 outside a uvx-with-spec-kit runtime, expected. Inside the sandbox where `specify` is on PATH (e.g. when fired from a `before_specify` hook during a uvx-driven `/speckit-specify` invocation), it will resolve and pass. Drift detection is verified via the manifest pin format (`>=X.Y.Z,<X.Y.Z+1.0`) which `lib/version-check.sh` parses correctly.

## Deviations from the refit-decision plan

- **`strategy: wrap` is required on the preset's `command`-type template entry.** SPEC-001-revised-contracts.md §7 implied `{CORE_TEMPLATE}` substitution was automatic; empirically it requires the explicit strategy field. Default strategy is `replace`, which silently leaves the literal token in the rendered skill and breaks the hook bus path.
- **`specify preset remove` has no `--force` flag in v0.8.5.** Use `yes | specify preset remove <id>` to skip the interactive confirmation.
- **Avoid mentioning the literal `{CORE_TEMPLATE}` token in preset body prose.** Every occurrence is substituted, including ones inside backticks. Preamble explanations of the wrap mechanism must paraphrase.

## Conclusion

The extension and preset install cleanly against a stock spec-kit v0.8.5 sandbox. All four GAIA skills are rendered to `.claude/skills/`. All three GAIA hooks fire `EXECUTE_COMMAND` directives in the correct lifecycle events. The `speckit-specify` SKILL.md is the GAIA wrap with core spliced in (hooks intact, GAIA preamble + post-step in place). The fictional `on_save` event is absent. The `/gaia-plan` handoff lives inline at the end of the `/gaia-spec` wrapper (`.claude/skills/gaia/references/spec.md` Step 11), not in any hook.

Branch is ready for the v2 PR.
