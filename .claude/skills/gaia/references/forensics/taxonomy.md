# Taxonomy

The forensics classifier uses a closed set of eight classes. Every report carries exactly one class; the classifier never invents or extends this set at runtime.

## Classes

| class        | surface                                                          | signal phrases                                                       | state files                                                           |
| ------------ | ---------------------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| init         | `/gaia-init` scaffolding                                         | "init", "scaffold failed", "rename", "branding strip"                | `.gaia/manifest.json`, `.gaia/local/setup-state.json`, `package.json` |
| update       | `/update-gaia` merge                                             | "update", "merge conflict", "three-way"                              | `.gaia/manifest.json`, conflicting file path                          |
| wiki-sync    | `/gaia wiki sync`                                                | "wiki-sync", "sync", "wiki commit"                                   | `wiki/.state.json`, `wiki/log.md` last entry                          |
| quality-gate | `pnpm typecheck && pnpm lint` failure during a GAIA flow         | "quality gate", "typecheck", "lint failed"                           | `wiki/decisions/Quality Gate.md`, the failing command output verbatim |
| hook         | `.claude/hooks/*.sh` misfire                                     | "hook", "PreToolUse", "PostToolUse", "session-start", "session-stop" | `.claude/settings.json`, `.claude/hooks/<failing>.sh` filename only   |
| scaffold     | `new-component` / `new-route` / `new-hook` / `new-service` skill | "scaffold", "new-component", "skeleton", "template"                  | `.claude/skills/<failing>/SKILL.md`                                   |
| dev-server   | `pnpm dev` / Vite / SSR boot                                     | "dev server", "vite", "5173", "SSR error"                            | `vite.config.ts` filename, `package.json` `scripts.dev`               |
| other        | unknown / multi-class / novel                                    | (none — fallthrough)                                                 | (none — capture is the generic snapshot only)                         |

State files are advisory pointers to class-specific evidence. For per-class capture details and version-fetch primitives, see `capture.md` in this directory.

## Classification heuristic

The agent is the classifier. The table above is the contract; the procedure below shapes the agent's application of it.

1. Tokenize the user's problem description (and any prior-turn context if the user invoked the skill with no argument and answered the single clarifying question).
2. For each class in the table's declared order — `init`, `update`, `wiki-sync`, `quality-gate`, `hook`, `scaffold`, `dev-server`, `other` — check whether any signal phrase appears. Match is case-insensitive substring; no regex engine required.
3. If exactly one class matches: that is the class.
4. If multiple classes match: pick the **first** in the table's declared order. Cite all matched signal phrases in the evidence note.
5. If zero classes match: class is `other`. Evidence note: `no taxonomy class matched`.

No LLM weighting beyond the table. Classifier improvements happen by revising this file, not through prompt drift.

## Evidence cite shape

The `## Classification` section in every rendered report has this exact shape:

```
## Classification
class: <tag>
evidence: <verbatim user phrase> + <named state file>
```

Three sub-cases:

- **Phrase and state file both apply:** `evidence: "scaffold failed" + .claude/skills/new-component/SKILL.md`
- **Phrase only (no state file inspected):** `evidence: "merge conflict"`
- **State file only (no specific user phrase, but a captured file pointed at the class):** `evidence: (no user phrase) + wiki/.state.json`
- **`other`:** `evidence: no taxonomy class matched`

Both halves are present whenever both apply. Drop the half that does not apply rather than writing a blank.

## Diagnose branch

After classification, the agent decides whether the failure is a user-config issue or a probable bug. This determines whether remediation steps are printed and whether a GH issue offer is made.

| signal                                                                               | branch       | rationale                          |
| ------------------------------------------------------------------------------------ | ------------ | ---------------------------------- |
| wrong Node version (captured `node` field outside `.nvmrc` / `engines.node` range)   | user-config  | local environment, fixable by user |
| missing required env var (named in the surface's docs and absent from `process.env`) | user-config  | local environment                  |
| dirty working tree blocks the workflow (e.g. `/gaia wiki sync` refused to push)      | user-config  | git state, fixable by user         |
| any other failure pattern                                                            | probable bug | offer GH issue                     |
| classifier fell to `other`                                                           | probable bug | offer GH issue                     |

**User-config branch:** print the remediation steps inline. Do NOT offer to file a GH issue. Saving the local report still happens unconditionally.

**Probable-bug branch:** save locally, then offer the GH issue. Do NOT print user-config remediation — the problem is not the user's environment.

The two branches are mutually exclusive per invocation. If multiple signals fire (e.g. wrong Node version AND an unexpected crash), apply the user-config branch — the environment is the more likely root cause and the user can rerun after fixing it.

## Disjointness from other taxonomies

This forensics taxonomy is the only classifier the skill consults. A user-facing failure that does not fit one of the eight classes above is `other`; the correct action is to offer a GH issue, not to look elsewhere for a match.
