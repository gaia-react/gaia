# Redaction

Lazy-loaded by the forensics runbook at the redact step. Apply this algorithm verbatim to the assembled report body before writing or filing. No external lookups — this fragment is self-contained.

The redaction contract is authoritative; it is defined in the SPEC for the `/gaia forensics` skill. Any discrepancy between this fragment and the SPEC is a defect in this fragment.

---

## Inputs

The assembled report body, pre-frontmatter. This is the markdown string beginning at `## Symptom` and ending after `## Reproduction context`. Frontmatter is written separately after redaction; do not pass frontmatter through this algorithm.

---

## Path conversion

**Project root:** compute once via `git rev-parse --show-toplevel`. Call the result `$ROOT`.

**Rule A — under project root.** Any absolute path that begins with `$ROOT/` is replaced by its suffix (the portion after `$ROOT/`). The suffix is already repo-relative.

```
Before: /Users/jane/Development/my-project/app/i18n.ts
After:  app/i18n.ts
(project root is /Users/jane/Development/my-project)
```

**Rule B — outside project root (machine-leak fallback).** Any remaining absolute path that begins with `/Users/<name>/` or `/home/<name>/` (and did NOT match Rule A) is collapsed to its trailing component only — the filename, preserving no directory structure.

```
Before: /Users/jane/.config/some-other-tool.json
After:  some-other-tool.json
```

**Rule B regex** (applied after Rule A):

```
Pattern:  /(?:\/Users\/[^/]+|\/home\/[^/]+)(?:\/[^/\s]+)*\/([^/\s]+)/g
Replace:  $1
```

Apply path conversion before token scanning. Token patterns may otherwise match path components that look like hex strings.

---

## Token patterns

Applied in the exact order listed. Order is load-bearing: more specific prefixes precede more general ones. Each match replaces the entire token-shaped value with `<redacted>`.

### 1. GitHub tokens

```
Pattern:  \b(gho|ghp|ghs|ghr|ghu)_[A-Za-z0-9]{20,}\b
Replace:  <redacted>
```

Covers all GitHub token prefixes (OAuth, PAT, server, refresh, user). Example placeholder for mental dry-run: `<github-token-shaped-string>` (prefix `gho_` followed by twenty or more alphanumerics).

### 2. Anthropic API key

```
Pattern:  \bsk-ant-[A-Za-z0-9_-]{20,}\b
Replace:  <redacted>
```

Must precede the OpenAI pattern below because `sk-ant-` begins with `sk-`.

### 3. OpenAI API key

```
Pattern:  \bsk-[A-Za-z0-9]{20,}\b
Replace:  <redacted>
```

Matches only after the `sk-ant-` pattern has already consumed Anthropic keys.

### 4. GitLab personal access token

```
Pattern:  \bglpat-[A-Za-z0-9_-]{20,}\b
Replace:  <redacted>
```

Example placeholder: `<gitlab-pat-shaped-string>` (prefix `glpat-` followed by twenty or more alphanumerics).

### 5. Slack token

```
Pattern:  \bxox[baprs]-[A-Za-z0-9\-]{10,}\b
Replace:  <redacted>
```

Covers bot (`xoxb`), app (`xoxa`), PAT (`xoxp`), refresh (`xoxr`), and service (`xoxs`) prefixes.

### 6. AWS access key ID

```
Pattern:  \b[A-Z]{4}[0-9A-Z]{16}\b
Replace:  <redacted>
```

Written as a structural regex; do not embed a literal 20-character key-shaped string as an example. The pattern captures the `AKIA`-prefix form and similar service-key prefixes (all begin with a four-letter uppercase sequence). Example placeholder for mental dry-run: `<aws-access-key-id-shaped-string>` (four uppercase letters followed by sixteen uppercase alphanumerics).

### 7. Generic high-entropy fallback (last resort)

```
Pattern:  (?i)(token|key|secret)[\s=:]+["']?[A-Za-z0-9+/=_-]{40,}["']?
Replace:  \1=<redacted>
           (preserve the label: "token=", "key:", "secret=" etc.)
```

This pattern is the most likely false-positive source. It fires only on values 40+ characters long adjacent to the keywords `token`, `key`, or `secret`. Any captured `.gaia/manifest.json` content (which contains hex-like SHAs and checksums) must be excluded from the redaction pass at the **capture layer**, not here. Do not pass `.gaia/manifest.json` raw content through redaction.

---

## Env-var policy

Captured env-var **values** are always replaced with `<redacted>`. Variable **names** are preserved (`HOME`, `PATH`, `ANTHROPIC_API_KEY`, etc. — name kept, value scrubbed).

```
Before: ANTHROPIC_API_KEY=<value-shaped-string>
After:  ANTHROPIC_API_KEY=<redacted>
```

This rule runs as step 3 (after path conversion and token patterns) as belt-and-suspenders: even if an env-var value was not caught by a token pattern, the env-var policy scrubs it. The capture step never reads `.env` files; this rule covers env-var blocks included via shell `env` or `printenv` output.

**Env-var value regex:**

```
Pattern:  ^([A-Za-z_][A-Za-z0-9_]*)=(.+)$   (multiline, per-line)
Replace:  \1=<redacted>
```

---

## Audit table

The following examples demonstrate the complete algorithm. All values are illustrative placeholders; no real credential appears in this file.

| Input (before redaction) | Output (after redaction) | Rule applied |
|---|---|---|
| `/Users/jane/Development/my-project/app/i18n.ts` | `app/i18n.ts` | Path Rule A (under project root `/Users/jane/Development/my-project`) |
| `/Users/jane/.config/some-other-tool.json` | `some-other-tool.json` | Path Rule B (outside project root, filename only) |
| `<github-token-shaped-string>` | `<redacted>` | Token pattern 1 (GitHub token; prefix `gho_` + 20 alphanumerics) |
| `ANTHROPIC_API_KEY=<value-shaped-string>` | `ANTHROPIC_API_KEY=<redacted>` | Env-var policy (value scrubbed; name kept) |
| `<aws-access-key-id-shaped-string>` | `<redacted>` | Token pattern 6 (AWS access key; four uppercase + sixteen alphanumerics) |

---

## Order of operations

1. **Path conversion** — Rule A (project-root strip), then Rule B (machine-leak fallback).
2. **Token regex set** — patterns 1–7 in declared order (GitHub → Anthropic → OpenAI → GitLab → Slack → AWS → generic fallback).
3. **Env-var value scrub** — scrub all env-var values regardless of whether pattern scan already caught them.
4. **Sanity recheck** — re-run patterns 1–6 over the redacted output. Any survivor is a redaction bug; flag it and halt rather than emitting a partially-redacted body.

---

## Idempotency

Running this algorithm twice on already-redacted text is a no-op. `<redacted>` does not match any token pattern, does not look like a credential prefix, and does not satisfy the generic-fallback length threshold. Path conversion on an already-repo-relative path leaves it unchanged (the path begins with a directory component, not `/Users/` or `/home/`).

The harness verifies idempotency: it applies redaction to the output of a prior redaction run and asserts the two outputs are byte-identical.
