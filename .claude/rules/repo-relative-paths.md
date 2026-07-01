---
paths:
  - '.gaia/**'
  - '.specify/**'
  - 'app/**'
  - 'test/**'
  - 'scripts/**'
  - 'docs/**'
---

# Repo-Relative Paths (repo-wide)

**Standing policy: no hardcoded machine-specific absolute paths anywhere in the repo.** Not in source, tests, docs, runbooks, comments, or config. A path pinned to one maintainer's checkout (`/Users/<name>/…`, `/home/<name>/…`) resolves nowhere else, so it breaks the moment another maintainer forks `gaia-react/gaia` onto their own machine, or an adopter scaffolds from the template.

Files under `.claude/` carry a stricter, template-distribution-specific portability rule ([`instruction-files.md`](instruction-files.md)) because they ship onto adopter machines verbatim. This rule is the repo-wide superset: the same repo-relative requirement, applied to `.gaia/`, `.specify/`, `app/`, `test/`, `scripts/`, `docs/`, and everywhere else.

## Rule

Use a repo-relative path when the command or reference runs from the repo root (the executing agent's working directory always is):

- `app/i18n.ts`, `.gaia/manifest.json`, `.specify/extensions/gaia` — never `/Users/<name>/…/app/i18n.ts`.

When an absolute path is genuinely required (a command that first `cd`s elsewhere, or a subshell that inherits the value), derive the root once and interpolate it:

```bash
GAIA_ROOT="$(git rev-parse --show-toplevel)"
# …then reference "$GAIA_ROOT/.specify/extensions/gaia"
```

Illustrative comment / test / doc examples that must *show* an absolute path use a neutral placeholder, never a real machine path: `/Users/you/projects/my-app`, `/Users/username/…`, `<repo-root>`, `foo` / `bar`.

## Exceptions

Two, and only two, kinds of literal home paths are legitimate:

1. **Forensics redaction tests and fixtures** where a home path *is the subject under test* — the redaction assertions break if it changes. These live under `.gaia/tests/forensics/` (e.g. `01-redaction-roundtrip.bats`, `fixtures/input-with-secrets.txt`) and deliberately embed `/Users/testuser`, `/home/runner`, `/Users/alice`, and similar.
2. **Generic placeholder examples** in illustrative prose, tests, or stories: `/Users/you`, `/Users/username`, `/home/bar`, `foo`, `bar`. They name no real machine.

Anything else that pins a real maintainer path is a bug.

## Audit

Before merging changes to any in-scope path, and as a standing repo-wide check. `git grep` searches tracked files only, so gitignored surfaces (`node_modules/`, `.gaia/local/`, `coverage/`, `dist/`, `storybook-static/`, `.claude/settings.local.json`) are skipped automatically:

```bash
# Any literal copy of the CURRENT machine's home dir is a bug. $HOME makes this
# portable: it flags a leak on whatever machine runs it, maintainer or adopter.
git grep -nIF "$HOME" -- ':!.gaia/tests/forensics/'

# Broader sweep: any /Users/<name> or /home/<name>. Triage each hit against the
# two exceptions above (forensics redaction fixtures; generic placeholders).
git grep -nIE "/Users/[A-Za-z]|/home/[A-Za-z]" -- ':!.gaia/tests/forensics/'
```

A clean tree returns zero hits from the first command. The second is a triage aid: the forensics fixtures (excluded above) and generic placeholders are the only allowed matches.

See [`instruction-files.md`](instruction-files.md) for the `.claude/`-specific portability rule this one generalizes.
