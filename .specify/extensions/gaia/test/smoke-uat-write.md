# `before_implement` UAT auto-write — manual smoke runbook

This runbook walks the full SPEC-003 `before_implement` hook surface and maps every step to the UAT it satisfies. Manual document, not an executable test. Use it as the basis for the evidence file feeding any future tag-time release check.

Companion to `test/smoke.md` (which covers `/gaia spec`). Both follow the same per-step shape: action, expected outcome, UATs covered.

## Prerequisites

- spec-kit installed at the version pinned in `.specify/extensions/gaia/extension.yml`.
- GAIA spec-kit extension loaded.
- `pnpm install` has run; `pnpm pw` resolves to Playwright.
- Working tree clean enough to spot accidental writes outside `.playwright/e2e/spec-NNN/` and `.gaia/local/cache/uat-write/`.
- Two helper paths to keep handy:
  - Renderer: `.specify/extensions/gaia/lib/uat-write.sh`
  - Cache: `.gaia/local/cache/uat-write/SPEC-NNN.json`

## Pre-flight setup

Drop the sandbox SPEC fixture (bottom of this file) into `.gaia/local/specs/SPEC-099.md`. Confirm it parses:

```bash
head -1 .gaia/local/specs/SPEC-099.md   # → ---
```

Snapshot the working tree so post-run audits diff cleanly:

```bash
git status --porcelain > /tmp/gaia-uat-write-tree-before.txt
```

---

## UAT-001 — N UATs render to N stable spec files

**Action.** With `SPEC-099` (3 concrete UATs) at `.gaia/local/specs/SPEC-099.md`, run:

```bash
bash .specify/extensions/gaia/lib/uat-write.sh .gaia/local/specs/SPEC-099.md
```

**Expected output (stdout, single line of JSON):**

```json
{"ok":true,"spec_id":"SPEC-099","spec_dir":".playwright/e2e/spec-099","framework":"playwright","summary":{"written":3,"rewritten":0,"deleted":0,"fixme":0,"unchanged":0},"details":[{"uat_id":"UAT-001","action":"written","path":".playwright/e2e/spec-099/uat-001.spec.ts","hash":"sha256:..."},{"uat_id":"UAT-002","action":"written","path":".playwright/e2e/spec-099/uat-002.spec.ts","hash":"sha256:..."},{"uat_id":"UAT-003","action":"written","path":".playwright/e2e/spec-099/uat-003.spec.ts","hash":"sha256:..."}]}
```

**Checks:**

1. `ls .playwright/e2e/spec-099/` lists exactly `uat-001.spec.ts`, `uat-002.spec.ts`, `uat-003.spec.ts`.
2. Each file's first non-comment line is `import {expect, test} from '@playwright/test';`.
3. Each file contains a `test('UAT-NNN — SPEC-099', async ({page}) => { ... })` call where `NNN` matches the filename — stable test name carrying the UAT ID.
4. Each file's header comment carries `// Given:`, `// When:`, `// Then:` lines reproducing the SPEC's prose.

**Pass signal.** Three files exist, JSON `summary.written == 3`, all three test names match `UAT-NNN — SPEC-099`.

**Fail signal.** Any missing file, mismatched test name, or `summary.written != 3`. Stop; fix renderer.

---

## UAT-002 — Red-state baseline fails as assertions, not parse errors

**Action.** Against the unimplemented SPEC, run the Playwright suite for the rendered directory:

```bash
pnpm pw .playwright/e2e/spec-099/
```

**Expected output (Playwright reporter, abbreviated):**

```
Running 3 tests using ...
  ✘  uat-001.spec.ts:NN  UAT-001 — SPEC-099
  ✘  uat-002.spec.ts:NN  UAT-002 — SPEC-099
  ✘  uat-003.spec.ts:NN  UAT-003 — SPEC-099

  Error: UAT-001 not yet implemented: <then-clause text>
  expect(received).toBe(expected) // boolean
  ...
```

**Checks:**

1. All three tests fail (exit non-zero from `pnpm pw`).
2. Each failure reason references its UAT ID and the unmet then-clause.
3. None of the failures are `SyntaxError`, `Cannot find module '@playwright/test'`, or `Test file is empty` — these would indicate a renderer bug, not a red-state baseline.

**Pass signal.** Three assertion failures, all with UAT-NNN-prefixed messages.

**Fail signal.** Any parse error, any missing-import error, or any test that passes (an unimplemented SPEC must not be green).

---

## UAT-003 — Idempotency + targeted rewrite on UAT change

### UAT-003a — Idempotent re-run on unchanged SPEC

**Action.** Re-run the renderer with no SPEC change:

```bash
bash .specify/extensions/gaia/lib/uat-write.sh .gaia/local/specs/SPEC-099.md
git status --porcelain .playwright/e2e/spec-099/
```

**Expected output (renderer stdout):**

```json
{"ok":true,"spec_id":"SPEC-099","spec_dir":".playwright/e2e/spec-099","framework":"playwright","summary":{"written":0,"rewritten":0,"deleted":0,"fixme":0,"unchanged":3},"details":[...]}
```

**Expected output (`git status` after second run):**

```
(empty)
```

**Pass signal.** `summary.unchanged == 3`, `git status` reports zero changes under `.playwright/e2e/spec-099/`. Confirms the sha256-canonical idempotency claim — the renderer strips the `// SPEC: ... | generated: ...` timestamp line before hashing, so re-runs on unchanged SPECs produce zero file diffs.

**Fail signal.** Any non-zero `summary.written` or `summary.rewritten`, or any change shown by `git status`. The hash strip is broken; re-firing on every implement would churn the diff.

### UAT-003b — Modify one UAT, re-run, only that file rewrites

**Action.** Edit `.gaia/local/specs/SPEC-099.md` and change UAT-002's `then:` line to a new (still concrete) value. Re-run the renderer:

```bash
bash .specify/extensions/gaia/lib/uat-write.sh .gaia/local/specs/SPEC-099.md
```

**Expected output:**

```json
{"ok":true,"spec_id":"SPEC-099",...,"summary":{"written":0,"rewritten":1,"deleted":0,"fixme":0,"unchanged":2},"details":[{"uat_id":"UAT-001","action":"unchanged",...},{"uat_id":"UAT-002","action":"rewritten",...},{"uat_id":"UAT-003","action":"unchanged",...}]}
```

**Checks:**

1. `summary.rewritten == 1` and `summary.unchanged == 2`.
2. `git status .playwright/e2e/spec-099/` shows only `uat-002.spec.ts` modified.
3. The modified file's `// Then:` comment matches the new SPEC value.

**Pass signal.** Exactly one file rewritten; the other two are byte-identical to their first-run state.

**Fail signal.** More than one file rewritten, or the wrong file rewritten — selective hash compare is broken.

---

## UAT-004 — Deleted UAT triggers hard-delete

**Action.** Edit `.gaia/local/specs/SPEC-099.md` and remove the UAT-003 entry from the `uats:` block entirely. Re-run the renderer:

```bash
bash .specify/extensions/gaia/lib/uat-write.sh .gaia/local/specs/SPEC-099.md
ls .playwright/e2e/spec-099/
```

**Expected output (renderer stdout):**

```json
{"ok":true,"spec_id":"SPEC-099",...,"summary":{"written":0,"rewritten":0,"deleted":1,"fixme":0,"unchanged":2},"details":[{"uat_id":"UAT-001","action":"unchanged",...},{"uat_id":"UAT-002","action":"unchanged",...},{"uat_id":"UAT-003","action":"deleted","path":".playwright/e2e/spec-099/uat-003.spec.ts"}]}
```

**Expected `ls` output:**

```
uat-001.spec.ts
uat-002.spec.ts
```

**Checks:**

1. `uat-003.spec.ts` is gone from disk (NOT moved to `_archived/` or any other directory).
2. No `_archived/` directory exists under `.playwright/e2e/spec-099/`.
3. `summary.deleted == 1`.

**Pass signal.** File hard-deleted, `summary.deleted == 1`, no archive directory.

**Fail signal.** The file still exists, or a `_archived/` directory was created — resolution #3 (hard-delete) is violated.

---

## UAT-005 — Manifest declarations + EXECUTE_COMMAND directive

**Action.** Inspect the GAIA manifest and confirm the SPEC-003 rows:

```bash
grep -n 'speckit.gaia.uat-write' .specify/extensions/gaia/extension.yml
grep -n 'before_implement' .specify/extensions/gaia/extension.yml
```

**Expected output:**

```
.../extension.yml:NN:    - name: "speckit.gaia.uat-write"
.../extension.yml:NN:      file: "commands/uat-write.md"
.../extension.yml:NN:  before_implement:
.../extension.yml:NN:    command: "speckit.gaia.uat-write"
```

**Checks:**

1. `provides.commands[]` contains `speckit.gaia.uat-write` pointing at `commands/uat-write.md`.
2. `hooks.before_implement.command` is `speckit.gaia.uat-write`.
3. `hooks.before_implement.optional` is `false`.

**End-to-end check.** Run `/speckit-implement` against an active in-progress SPEC. The agent's pre-execution hook scan must surface a directive of the form:

```
EXECUTE_COMMAND: speckit.gaia.uat-write
```

…and auto-invoke the `/speckit-gaia-uat-write` slash command (dot-to-hyphen-rendered per SPEC-001-revised-contracts §4) before any source edit.

**Pass signal.** Manifest rows present and matching, `EXECUTE_COMMAND` directive emitted on `/speckit-implement` invocation.

**Fail signal.** Either manifest row missing, or `/speckit-implement` runs source edits without firing the hook.

---

## UAT-006 — SPEC resolution algorithm (4 steps)

The renderer's slash-command body resolves the active SPEC via this priority order. Verify each step independently. The `feature.json` cross-walk that an earlier draft proposed was dropped post-probe — `.specify/feature.json` carries no SPEC backreference, so the algorithm has 4 steps, not 5.

### Step 1 — Explicit `$ARGUMENTS` (SPEC-NNN id or absolute path)

**Action.** With multiple in-progress SPECs in `.gaia/local/specs/`, invoke `/speckit-gaia-uat-write SPEC-099`. Alternatively pass an absolute path: `/speckit-gaia-uat-write /path/to/SPEC-099.md`.

**Expected outcome.** Resolution short-circuits at step 1; the renderer runs against the explicitly-named SPEC regardless of mtime or how many other SPECs are in-progress. No `AskUserQuestion` is surfaced.

**Pass signal.** Renderer stdout has `"spec_id":"SPEC-099"` and the rendered files land under `.playwright/e2e/spec-099/`.

### Step 2 — Most-recent in-progress SPEC, modified within the last 30 minutes

**Action.** Ensure `SPEC-099.md` was just-touched (e.g. `touch .gaia/local/specs/SPEC-099.md` followed immediately by the hook fire). Also leave at least one other SPEC at `status: in-progress` whose mtime is older. Invoke `/speckit-gaia-uat-write` with no arguments.

**Expected outcome.** The renderer picks `SPEC-099` because it is the most recent in-progress SPEC modified inside the 30-minute window. This step covers the natural `/speckit-specify` → `/gaia plan` → `/speckit-implement` chain — the GAIA preset's `speckit.specify.md` relocates and stamps the SPEC immediately after authoring.

**Pass signal.** Renderer resolves to `SPEC-099` without any `AskUserQuestion` prompt.

**Fail signal.** Renderer prompts the user, or resolves to an older in-progress SPEC.

### Step 3 — Single in-progress SPEC fallback

**Action.** Mark every other SPEC under `.gaia/local/specs/` to `status: completed` (or remove them) so that exactly one SPEC has `status: in-progress`. Force the SPEC's mtime older than 30 minutes (`touch -t 202501010000 .gaia/local/specs/SPEC-099.md`) so step 2 cannot fire. Invoke the slash command with no arguments.

**Expected outcome.** The renderer picks the single in-progress SPEC. No `AskUserQuestion`. This step covers the common single-feature project case.

**Pass signal.** Renderer resolves to the lone in-progress SPEC silently.

### Step 4 — `AskUserQuestion` fallback for ambiguity

**Action.** Restore at least two SPECs to `status: in-progress`, both with mtimes older than 30 minutes. Invoke the slash command with no arguments.

**Expected outcome.** The slash command surfaces `AskUserQuestion` listing every in-progress SPEC by id and asks the user to pick one. The hook does NOT guess.

**Pass signal.** A user prompt appears with all in-progress SPEC ids as options. After the user picks, the renderer runs against that SPEC.

**Fail signal.** The hook auto-picks one without asking, or fails opaquely.

**UATs covered.** UAT-006 (all four resolution steps).

---

## UAT-007 — Too-abstract UAT renders as `test.fixme()` with structured blocker

**Action.** Edit `.gaia/local/specs/SPEC-099.md` and change UAT-001's `then:` to a deliberately-abstract sentence with no quoted UI surface and no URL/path fragment, e.g.:

```yaml
    then: The system feels right and the user is delighted.
```

Re-run the renderer:

```bash
bash .specify/extensions/gaia/lib/uat-write.sh .gaia/local/specs/SPEC-099.md
```

**Expected output (renderer stdout):**

```json
{"ok":true,...,"summary":{"written":0,"rewritten":1,"deleted":0,"fixme":1,"unchanged":1},...}
```

**Expected output (`uat-001.spec.ts` body):** uses `test.fixme(...)` instead of `test(...)`, and contains a comment block:

```ts
test.fixme('UAT-001 — SPEC-099', async () => {
  // Abstraction blocker: then-clause has no quoted UI surface and no URL/path fragment; refine UAT to reference a concrete element or route
  // Original UAT:
  //   Given: ...
  //   When:  ...
  //   Then:  The system feels right and the user is delighted.
  ...
});
```

**Checks:**

1. The file exists; nothing was silently dropped.
2. `test.fixme` is used (not `test`); Playwright reports the test as skipped, not failed.
3. The blocker comment names the abstraction reason in plain English.

**Pass signal.** `summary.fixme == 1`, file body uses `test.fixme()`, blocker comment present.

**Fail signal.** UAT-001 either disappears, runs as a normal `test()`, or the blocker comment is missing.

---

## UAT-008 — Cache file mirrors stdout JSON

**Action.** After any successful renderer run on `SPEC-099`, inspect the cache file:

```bash
cat .gaia/local/cache/uat-write/SPEC-099.json
```

**Checks:**

1. The file exists at `.gaia/local/cache/uat-write/SPEC-099.json` (uppercase `SPEC-099` in the filename; spec output dir under `.playwright/e2e/spec-099/` is lowercase — the case asymmetry is intentional, locked by the renderer interface contract).
2. Its contents are byte-identical to the renderer's stdout from the same run (modulo a trailing newline).
3. The `summary` block matches the count of files actually on disk under `.playwright/e2e/spec-099/`.
4. The cache file is gitignored (it lives under `.gaia/local/`, which is in `.gitignore`).

**Pass signal.** Cache file present, contents match stdout, summary counts match disk reality, file is not staged for commit.

**Fail signal.** Cache missing, contents diverge from stdout, or the file shows up in `git status` (gitignore broken).

---

## Renderer parser caveat

The renderer awk-parses YAML directly — there is no `yq` dependency. Only single-line `given:` / `when:` / `then:` values are supported. YAML block-scalar markers (`|` and `>`) are NOT honored; lines beyond the first are folded with a leading space into the same field.

When authoring a SPEC for smoke purposes, keep each given/when/then on one line. If a smoke run produces a UAT whose then-clause is mangled (lines concatenated with stray indentation), the cause is a block-scalar marker in the SPEC, not a renderer bug.

---

## UAT coverage matrix

| UAT     | Smoke section                              |
| ------- | ------------------------------------------ |
| UAT-001 | UAT-001 (N UATs render to N stable files)  |
| UAT-002 | UAT-002 (red-state baseline as assertions) |
| UAT-003 | UAT-003a + UAT-003b (idempotency + rewrite)|
| UAT-004 | UAT-004 (hard-delete on UAT removal)       |
| UAT-005 | UAT-005 (manifest + EXECUTE_COMMAND)       |
| UAT-006 | UAT-006 (4-step SPEC resolution)           |
| UAT-007 | UAT-007 (abstract UAT → test.fixme)        |
| UAT-008 | UAT-008 (cache mirrors stdout)             |

---

## Sandbox SPEC fixture — `.gaia/local/specs/SPEC-099.md`

Paste this verbatim into `.gaia/local/specs/SPEC-099.md` to seed the smoke run. All three UATs are deliberately concrete (each `then:` carries either a quoted UI surface or a URL fragment) so the abstraction heuristic does NOT fire on the baseline run. UAT-007's smoke step asks you to mutate one of these into an abstract form on purpose.

```markdown
---
spec_id: SPEC-099
type: feature
status: in-progress
immutable: false
intent: |
  Sandbox SPEC for smoke-testing the before_implement UAT-write hook. Not a real
  feature; deliberately tiny so the renderer can be exercised end-to-end without
  contaminating the real SPEC archive. Three concrete UATs, one per renderer
  branch (write / rewrite / delete).
success_criteria:
  - The renderer writes one Playwright spec file per UAT under .playwright/e2e/spec-099/.
  - All three rendered tests fail as assertions (not parse errors) when run against an unimplemented codebase.
  - Re-running the renderer on this SPEC unchanged produces zero file diffs.
uats:
  - uat_id: UAT-001
    given: The user is on the home page at "/".
    when: The user clicks the "Sign in" button.
    then: The page navigates to "/sign-in" and a heading reading "Sign in" is visible.
  - uat_id: UAT-002
    given: A signed-in user on the dashboard at "/dashboard".
    when: The user clicks the "Log out" link in the header.
    then: The page navigates to "/" and the "Sign in" button is visible again.
  - uat_id: UAT-003
    given: A user on the help page at "/help".
    when: The user types "billing" into the search box and presses Enter.
    then: A results list appears containing a link with text "Billing FAQ".
open_questions: []
dependencies:
  - Sandbox only; depends on nothing real.
---

# Sandbox SPEC for smoke testing

This SPEC exists solely to exercise the `before_implement` UAT-write hook
during the SPEC-003 smoke runbook. It is not a real product feature. Delete
or relocate after smoke verification completes.

The three UATs cover the basic write/rewrite/delete cycle:

- UAT-001 — concrete URL + quoted button text → renders normally
- UAT-002 — same shape; used as the "rewrite" target in UAT-003b
- UAT-003 — same shape; used as the "delete" target in UAT-004

To exercise the abstraction heuristic for UAT-007, mutate UAT-001's `then:`
clause to remove all quoted strings and URL fragments — see the UAT-007
smoke step.
```

---

## Cleanup

After smoke verification:

```bash
rm -rf .playwright/e2e/spec-099/
rm -f .gaia/local/cache/uat-write/SPEC-099.json
rm -f .gaia/local/specs/SPEC-099.md
git status --porcelain
```

Tree should match `/tmp/gaia-uat-write-tree-before.txt`. Anything else is leftover smoke artifacts; clean before committing.
