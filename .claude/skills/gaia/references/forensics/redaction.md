# Redaction

Lazy-loaded by the forensics runbook at the redact step. Apply this algorithm verbatim to the assembled report body before writing or filing. No external lookups, this fragment is self-contained.

This fragment is the authoritative redaction contract for `/gaia-forensics`.

<!-- gaia:maintainer-only:start -->
The shell mirror at `.gaia/tests/forensics/lib/redact.sh` must track it exactly; any divergence is a defect in the mirror.
<!-- gaia:maintainer-only:end -->

---

## Inputs

The assembled report body, pre-frontmatter. This is the markdown string beginning at `## Symptom` and ending after `## Reproduction context`. Frontmatter is written separately after redaction; do not pass frontmatter through this algorithm.

---

## Path conversion

**Project root:** compute once via `git rev-parse --show-toplevel`. Call the result `$ROOT`.

**Rule A, under project root.** Any absolute path that begins with `$ROOT/` is replaced by its suffix (the portion after `$ROOT/`). The suffix is already repo-relative.

```
Before: <home>/Development/my-project/app/i18n.ts
After:  app/i18n.ts
(project root is <home>/Development/my-project)
```

**Rule B, outside project root (machine-leak fallback).** Any remaining absolute path that begins with `/Users/<name>/`, `/home/<name>/`, or `/root/` (and did NOT match Rule A) is collapsed to its trailing component only, the filename, preserving no directory structure. Then a **bare** home dir with no trailing component (`/Users/<name>`, `/home/<name>`, or `/root` alone) is collapsed to the literal `<home>`, so the OS username never leaks even when no file path follows it.

```
Before: <home>/.config/some-other-tool.json
After:  some-other-tool.json

Before: /Users/<name>            (bare, no trailing component)
After:  <home>
```

**Rule B regex** (applied after Rule A, in this order):

```
Trailing-component collapse:
  Pattern:  /(?:\/Users\/[^/]+|\/home\/[^/]+|\/root)(?:\/[^/\s]+)*\/([^/\s]+)/g
  Replace:  $1

Bare-home collapse (run only after the trailing-component collapse):
  Pattern:  /(?:\/Users\/[^/\s]+|\/home\/[^/\s]+|\/root)/g
  Replace:  <home>
```

`/root` has no `<name>` component (it is itself the home dir), so its collapse starts at `/root` directly. Apply path conversion before token scanning. Token patterns may otherwise match path components that look like hex strings.

---

## Token patterns

Applied in the exact order listed. Order is load-bearing: more specific prefixes precede more general ones. Each match replaces the entire token-shaped value with `<redacted>`.

### 1. GitHub tokens

```
Pattern:  \b(gho|ghp|ghs|ghr|ghu)_[A-Za-z0-9]{20,}\b
          \bgithub_pat_[A-Za-z0-9_]{20,}\b
Replace:  <redacted>
```

Covers all classic GitHub token prefixes (OAuth, PAT, server, refresh, user) and the fine-grained PAT form `github_pat_` (underscores are legal inside its body). Example placeholder for mental dry-run: `<github-token-shaped-string>` (prefix `gho_` followed by twenty or more alphanumerics).

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
          \bxapp-[A-Za-z0-9\-]{10,}\b
Replace:  <redacted>
```

Covers bot (`xoxb`), app (`xoxa`), PAT (`xoxp`), refresh (`xoxr`), and service (`xoxs`) prefixes, plus the app-level token (`xapp-`).

### 6. JWT (JSON Web Token)

```
Pattern:  eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+
Replace:  <redacted>
```

Three base64url segments (`header.payload.signature`) joined by literal dots. The `eyJ` prefix is base64 of `{"`, the opening of every JWT header, so it is distinctive without a `\b`. The whole three-segment token is replaced.

### 7. Bearer token

```
Pattern:  Bearer[[:space:]]+[A-Za-z0-9._-]{10,}
Replace:  Bearer <redacted>
```

Preserves the `Bearer ` label and redacts the credential that follows (mirrors the generic fallback keeping its keyword). Catches `Authorization: Bearer <token>` regardless of the token's internal shape.

### 8. Connection-string credentials

```
Pattern:  ://[^/@:[:space:]]+:[^/@:[:space:]]+@
Replace:  ://<redacted>@
```

Redacts the `user:password` pair embedded in a URI authority (`scheme://user:pass@host`) while preserving the scheme and host. The env-var scrub is line-anchored (`^…=…$`) and misses a connection string that appears mid-line, so this dedicated pattern is required.

### 9. AWS access key ID

```
Pattern:  \b[A-Z]{4}[0-9A-Z]{16}\b
Replace:  <redacted>
```

Written as a structural regex; do not embed a literal 20-character key-shaped string as an example. The pattern captures the `AKIA`-prefix form and similar service-key prefixes (all begin with a four-letter uppercase sequence). Example placeholder for mental dry-run: `<aws-access-key-id-shaped-string>` (four uppercase letters followed by sixteen uppercase alphanumerics).

### 10. Generic high-entropy fallback (last resort)

```
Pattern:  (?i)(token|key|secret)[\s=:]+["']?[A-Za-z0-9+/=_-]{40,}["']?
Replace:  \1=<redacted>
           (preserve the label: "token=", "key:", "secret=" etc.)
```

This pattern is the most likely false-positive source. It fires only on values 40+ characters long adjacent to the keywords `token`, `key`, or `secret`. Any captured `.gaia/manifest.json` content (which contains hex-like SHAs and checksums) must be excluded from the redaction pass at the **capture layer**, not here. Do not pass `.gaia/manifest.json` raw content through redaction.

---

## Boundary anchors (shell mirror)

The regexes above use `\b` word boundaries.

<!-- gaia:maintainer-only:start -->
The shell mirror at `.gaia/tests/forensics/lib/redact.sh` runs on BSD sed (macOS) and GNU sed (CI); BSD sed does not support `\b`. The mirror drops `\b` and relies instead on each pattern's distinctive literal prefix (`gho_`, `github_pat_`, `sk-ant-`, `sk-`, `glpat-`, `xox`, `xapp-`, `eyJ`, `Bearer `, `://`) as the leading boundary, and on the greedy quantifier consuming to the first out-of-class character as the trailing boundary. For every prefixed pattern this is exactly equivalent to the `\b`-anchored form here.
<!-- gaia:maintainer-only:end -->

The one pattern with no literal prefix is the AWS access key ID (`[A-Z]{4}[0-9A-Z]{16}`). Here the mirror and this fragment diverge **by design**: a 20-character uppercase run embedded inside a longer mixed-case token is left intact by the `\b`-anchored form here, but is redacted by the mirror, which has no boundary to stop it. This divergence is accepted because it fails safe: the mirror only ever redacts *more*, never less, so it cannot leak. No other pattern diverges. The bare `/root` collapse in Rule B has the same fail-safe property: lacking a `<name>` component it has no trailing boundary, so it may over-collapse a path like `/rootfs`, never under-collapse.

---

## Env-var policy

Captured env-var **values** are always replaced with `<redacted>`. Variable **names** are preserved (`HOME`, `PATH`, `ANTHROPIC_API_KEY`, etc., name kept, value scrubbed).

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

| Input (before redaction)                    | Output (after redaction)       | Rule applied                                                             |
| ------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------ |
| `<home>/Development/my-project/app/i18n.ts` | `app/i18n.ts`                  | Path Rule A (under project root `<home>/Development/my-project`)         |
| `<home>/.config/some-other-tool.json`       | `some-other-tool.json`         | Path Rule B (outside project root, filename only)                        |
| `<github-token-shaped-string>`              | `<redacted>`                   | Token pattern 1 (GitHub token; prefix `gho_` + 20 alphanumerics)         |
| `ANTHROPIC_API_KEY=<value-shaped-string>`   | `ANTHROPIC_API_KEY=<redacted>` | Env-var policy (value scrubbed; name kept)                               |
| `<aws-access-key-id-shaped-string>`         | `<redacted>`                   | Token pattern 9 (AWS access key; four uppercase + sixteen alphanumerics) |

---

## Order of operations

1. **Path conversion**: Rule A (project-root strip), then Rule B (machine-leak fallback: trailing-component collapse for `/Users`, `/home`, `/root`, then bare-home collapse to `<home>`).
2. **Token regex set**: patterns 1–10 in declared order (GitHub → Anthropic → OpenAI → GitLab → Slack → JWT → Bearer → connection-string → AWS → generic fallback).
3. **Env-var value scrub**: scrub all env-var values regardless of whether pattern scan already caught them.
4. **Sanity recheck**: re-run patterns 1–9 over the redacted output (the generic fallback, pattern 10, is not rechecked). Any survivor is a redaction bug; flag it and halt rather than emitting a partially-redacted body.

---

## Idempotency

Running this algorithm twice on already-redacted text is a no-op. `<redacted>` and `<home>` do not match any token pattern, do not look like a credential prefix, and do not satisfy the generic-fallback length threshold. `<home>` contains no `/Users/`, `/home/`, or `/root` segment, so Rule B leaves it unchanged. Path conversion on an already-repo-relative path leaves it unchanged (the path begins with a directory component, not `/Users/`, `/home/`, or `/root`).

The harness verifies idempotency: it applies redaction to the output of a prior redaction run and asserts the two outputs are byte-identical.
