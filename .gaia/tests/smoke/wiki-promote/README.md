# Wiki-promote smoke

Static structural smoke for the `after_implement` wiki-promote feature. Verifies the manifest + command files + revised-contracts amendment landed and parse cleanly.

## Scope

What this smoke covers:

- `.specify/extensions/gaia/extension.yml` parses as valid YAML (when `python3` is available).
- The manifest declares `speckit.gaia.wiki-promote` in `provides.commands[]` and registers it under `hooks.after_implement`.
- `.specify/extensions/gaia/commands/wiki-promote.md` exists and has the seven `## Step N` sections (1–7) the command body contract requires.
- `.specify/extensions/gaia/commands/spec-close.md` exists.
- `.gaia/local/specs/SPEC-001-revised-contracts.md` contains the `wiki_promote_targets` sub-section.
- If `specify` is on `PATH`, `specify extension list` succeeds against the extension dir (schema validation).

What this smoke does NOT cover:

- Live `/speckit-implement` hook fire — that requires a real spec-kit invocation against a synthetic SPEC + branch + PR, which is out of scope for the smoke layer.
- Full wiki-page render (frontmatter values, body sections, sibling cross-links). Hand-verify post-merge against a real promotion run.
- The `/wiki-sync` handoff. Covered by the `wiki-sync` smokes under `../wiki-sync/`.

## Run

```bash
bash .gaia/tests/smoke/wiki-promote/run.sh
```

Exits 0 when every artifact is present and the manifest parses; non-zero on the first missing file or parse failure. Prints a pass/fail summary.

## Files

- `run.sh` — the harness. Checks file existence + manifest content + revised-contracts amendment.
- `fixture/SPEC-999.md` — a synthetic SPEC frontmatter sample (`wiki_promote_default: yes`, `wiki_promote_targets: [decisions, concepts]`). Reference shape; not consumed by the harness today.
- `fixture/pr-body.txt` — synthetic PR body text. Reference shape; not consumed by the harness today.

The fixtures exist for downstream tasks that exercise the live render path; the structural smoke only inspects repo state.
