# /gaia forensics

Turn a GAIA workflow misfire into a redacted, classified, filing-ready bug report in one invocation. Read-only end-to-end: no remediation, no autofix, no state mutation.

## Hard constraints

These four rules are non-negotiable and apply to every code path:

1. **Read-only end-to-end.** The skill inspects state; it never modifies, installs, fetches, or remediates anything.
2. **Write surface allowlist.** Writes go to exactly two directories: `.gaia/local/forensics/` (the report) and `.gaia/local/telemetry/` (optional emit calls, failure non-blocking). No other path is writable.
3. **Uniform redaction.** Every output surface — the local file body and the GH issue body — passes through the same single redaction pass. The two bodies are byte-identical post-redaction. Never re-redact, never partially redact.
4. **Strict body schema.** Frontmatter fields, section headers, and section order are fixed. Phase-2 automation parses this without LLM fallback; any drift breaks downstream triage.

## Steps

### 1. Invocation

Parse `$ARGUMENTS`.

- **With an argument:** use the argument verbatim as the problem description. Do not ask a clarifying question.
- **Without an argument:** ask a single open-ended clarifying question such as "What went wrong? Describe what you were doing, what you expected, and what happened." Wait for the response before continuing. Ask at most one question.

Do NOT use `AskUserQuestion` here — plain prose question only.

### 2. Capture

Read `.claude/skills/gaia/references/forensics/capture.md` and apply it now.

Execute every command in the **Universal capture** table. Then, for the provisionally detected class (the class you expect based on the problem description — you will confirm in step 3), execute the corresponding **Class-specific state files** table. If the class is ambiguous at this point, capture the universal envelope and defer class-specific reads until after step 3.

Apply the exclusion rules in `capture.md` before assembling the snapshot. Never capture bodies from `app/` or `wiki/`; never capture Claude Code session JSONL paths; never capture `.env*` or `node_modules/`; truncate any entry exceeding ~80 lines or 4 KB.

### 3. Classify and cite evidence

Read `.claude/skills/gaia/references/forensics/taxonomy.md` and apply it now.

Walk the taxonomy table in declared order (`init`, `update`, `wiki-sync`, `quality-gate`, `hook`, `scaffold`, `dev-server`, `other`). Match signal phrases against the problem description using case-insensitive substring match.

- Exactly one match → that is the class.
- Multiple matches → use the first in declared order; cite all matched phrases.
- Zero matches → class is `other`; evidence note is `no taxonomy class matched`.

Cite the classification evidence in this exact shape:

```
class: <tag>
evidence: <verbatim user phrase> + <named state file>
```

If a class-specific read from step 2 was deferred because of ambiguity, complete it now for the confirmed class.

### 4. Diagnose

Apply the diagnose-branch table from `taxonomy.md`.

Decide whether the failure is a **user-config issue** or a **probable bug**:

- Wrong Node version, missing required env var, or dirty working tree blocking a workflow → **user-config**.
- Any other failure pattern → **probable bug**.
- Class is `other` → always **probable bug**.
- If multiple signals fire (e.g. wrong Node version AND an unexpected crash), apply the **user-config** branch — the environment is the more likely root cause.

Record the diagnosis. It gates the branch in step 8.

### 5. Redact

Read `.claude/skills/gaia/references/forensics/redaction.md` and apply it now.

Assemble the full report body (everything from `## Symptom` through `## Reproduction context`). Run the redaction algorithm once over this assembled body in declared order:

1. Path conversion — Rule A (project-root strip), then Rule B (machine-leak fallback).
2. Token regex set — patterns 1–7 in declared order.
3. Env-var value scrub.
4. Sanity recheck — re-run patterns 1–6; if any credential-shaped string survives, halt and report rather than emitting a partially-redacted body.

Do not pass frontmatter through redaction. Frontmatter is written after the body is clean.

### 6. Render

Emit the strict-schema body. The frontmatter wraps the local file only; the GH issue body is the post-frontmatter portion.

Local file layout (frontmatter + body):

```markdown
---
class: <init|update|wiki-sync|quality-gate|hook|scaffold|dev-server|other>
gaia_version: <semver>
created: <YYYY-MM-DD>
gh_issue_url?: <url>
---

## Symptom
<one-paragraph user description, redacted>

## Classification
class: <tag>
evidence: <verbatim user phrase> + <named state file>

## Capture
gaia_version: <semver>
node: <version>
pnpm: <version>
claude_code: <version>
branch: <name>
dirty: <true|false>
class_state_files:
  - <repo-relative path>: <one-line summary>

## Reproduction context
<plain prose: what the user was doing, what they expected, what happened>
```

The body posted to the GH issue is the post-frontmatter portion (`## Symptom` through the end), byte-identical to the local file body.

### 7. Save

Write the rendered report to `.gaia/local/forensics/<timestamp>-<class>.md` where `<timestamp>` is `YYYYMMDDTHHMMSSZ` (ISO-8601 compact UTC, e.g. `20260508T143022Z`).

Create `.gaia/local/forensics/` if it does not exist.

Print the saved path immediately after writing:

```
Report saved: .gaia/local/forensics/<timestamp>-<class>.md
```

### 8. Branch on diagnosis

#### User-config branch

Print the diagnosed remediation steps inline. Do NOT offer GitHub issue creation. Exit zero.

The local report is already saved (step 7). No `gh` invocation occurs.

#### Probable-bug branch

First, check whether `gh` is installed:

```bash
command -v gh
```

- **`gh` not installed (non-zero exit):** print one line — `` `gh` not installed; report saved locally at .gaia/local/forensics/<timestamp>-<class>.md `` — and exit zero. Never reach the `gh issue create` invocation.

- **`gh` installed:** offer issue creation via `AskUserQuestion`:
  - question: `"File a GitHub issue for this report?"`
  - options:
    - `{ label: "Yes, file the issue (Recommended)", description: "Creates an issue on gaia-react/gaia with the gaia-forensics label." }`
    - `{ label: "No, save locally only", description: "The report is already saved locally; no issue will be filed." }`

  - **On `No`:** exit zero. Print the local path. Do not invoke `gh`.

  - **On `Yes`:** write the post-frontmatter body to a temp file, then invoke:

    ```bash
    gh issue create \
      --repo gaia-react/gaia \
      --label gaia-forensics \
      --title "forensics: <class> — <one-line user description>" \
      --body-file <tempfile>
    ```

    Use `--body-file` so multiline bodies survive shell escaping intact.

    - On success: capture the issue URL printed by `gh`. Record it in the frontmatter `gh_issue_url` field of the already-saved local file (update the file in place). Continue to step 9.
    - On non-zero `gh` exit: surface `gh`'s stderr verbatim. Leave the local report in place. Exit non-zero. Do not retry or partially file.

    Do NOT pre-check `gh auth status`. Do NOT pre-check label existence. Rely on `gh`'s native error for both conditions.

### 9. Confirm

On any successful exit, print a single confirmation line:

- If GH issue was filed: `Report: .gaia/local/forensics/<timestamp>-<class>.md | Issue: <issue URL>`
- If locally saved only: `Report: .gaia/local/forensics/<timestamp>-<class>.md`

Exit read-only. No git operations, no cleanup beyond the temp file.

## Output schema (load-bearing)

Phase-2 automation parses this schema without LLM fallback. Any deviation — field names, section headers, header order, frontmatter field names — breaks downstream triage. Do not drift.

```markdown
---
class: <init|update|wiki-sync|quality-gate|hook|scaffold|dev-server|other>
gaia_version: <semver>
created: <YYYY-MM-DD>
gh_issue_url?: <url>
---

## Symptom
<one-paragraph user description, redacted>

## Classification
class: <tag>
evidence: <verbatim user phrase> + <named state file>

## Capture
gaia_version: <semver>
node: <version>
pnpm: <version>
claude_code: <version>
branch: <name>
dirty: <true|false>
class_state_files:
  - <repo-relative path>: <one-line summary>

## Reproduction context
<plain prose: what the user was doing, what they expected, what happened>
```

The local file carries the frontmatter block. The GH issue body is the post-frontmatter portion only — from `## Symptom` through the end — byte-identical to the local file body.

## Hardcoded constants

These values are baked in and must not be derived at runtime:

- **Issue target repo:** `gaia-react/gaia` — literal in the `--repo` flag. Never derived from `git remote`.
- **Issue label:** `gaia-forensics` — must pre-exist on the upstream repo. The skill never auto-creates it.
- **Issue title format:** `forensics: <class> — <one-line user description>`
- **Local save path:** `.gaia/local/forensics/<timestamp>-<class>.md` where `<timestamp>` is `YYYYMMDDTHHMMSSZ`.

## Required reading

- `.claude/skills/gaia/references/forensics/capture.md` — read at step 2. Per-class state-file lists, universal capture commands, exclusion rules, output format.
- `.claude/skills/gaia/references/forensics/taxonomy.md` — read at step 3. Eight classes, classification heuristics, evidence-cite shape, diagnose-branch table.
- `.claude/skills/gaia/references/forensics/redaction.md` — read at step 5. Path conversion rules, token patterns, env-var policy, order of operations, idempotency guarantee.
