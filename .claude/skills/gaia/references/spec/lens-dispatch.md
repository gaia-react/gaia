# Lens dispatch

How one adversarial audit lens is dispatched and how its output is trusted. Read whole by `/gaia-spec` step 7 and `/gaia-plan` step 4.6 before dispatching lenses. The caller's playbook owns lens selection, refutation, and disposition; this file owns only the preamble every lens receives, the file it writes, and the classification that stops a silent lens from passing as clean.

Contents: `## Caller slots`, `## Shared preamble`, `## Write and return`, `## Findings file schema`, `## Pre-clear, classify, re-dispatch`.

## Caller slots

Each caller fills the `<...>` placeholders of the shared preamble from its own column.

| Slot | Spec audit | Plan audit |
| --- | --- | --- |
| Artifact under audit (`<ARTIFACT>`) | the working draft at `<DRAFT_PATH>` (spec `<spec_id>`) | the plan in `<PLAN_DIR>`: `<PLAN_DIR>/README.md` plus every `<PLAN_DIR>/task-*.md` |
| First Read | `<DRAFT_PATH>` | `<PLAN_DIR>/README.md` (the task graph and frozen interface contracts), then every `<PLAN_DIR>/task-*.md` |
| Defect target | a flawed plan or implementation downstream | a broken or conflicting orchestrator result |
| Evidence form | SPEC section or UAT id, plus `file:line` | task doc plus `file:line` |
| `location` meaning | SPEC section or UAT id | task doc or README section |
| Findings directory (`<FINDINGS_DIR>`) | `.gaia/local/cache/audit-<spec_id>/findings/` | `<PLAN_DIR>/audit/` |
| Write tool | the ordinary write tools | `Bash`, see below |
| `blocker` | the SPEC is factually wrong or will produce broken or misleading work | the plan is factually wrong or will produce broken or conflicting work |
| `high` | a significant gap or ambiguity a planner is forced to guess on | a gap or hidden dependency the orchestrator is forced to guess on |

Plan write tool: `<PLAN_DIR>` is a main-anchored absolute path. When the session runs in a linked worktree, the harness refuses `Edit` and `Write` at that path, so the lens agent, and the main thread's inline fallback, write the findings file with `Bash` at the main-checkout path and read it back to confirm both its content and its location before it is classified. Keep the fallback to the findings files: a `Bash` redirect is never the way to write into another checkout where the edit tools already work.

## Shared preamble

Send this to every lens, interpolating the slots. The caller appends a `LENS: <name> (id prefix <ID>)` line and the lens's focus text from its own playbook.

> You are an ADVERSARIAL auditor of <ARTIFACT>. Repo root is `<repo_root>`; you may read any file under it, including `node_modules`. Your job is to find DEFECTS that would cause <defect target>, not to praise the artifact.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit (<first Read>), and you emit your structured result before any prose.
>
> - Verify EVERY checkable claim against the actual repository and `node_modules`. Do not take the artifact's assertions on faith; when a claim names code, a file, an export, or a signature, open it and confirm it resolves.
> - Cite evidence: <evidence form> for any ground-truth check.
> - Severity: `blocker` = <blocker meaning>; `high` = <high meaning>; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding a verifier can refute by reading one file is a good finding; vague "could be clearer" is not.
> - **Write** your full findings to `<FINDINGS_DIR><LENS>.json` (the fully qualified path) under the file schema, using <write tool>. Write the file even if your findings array is empty.
> - **Return** only the thin digest, no finding bodies.

## Write and return

The agent writes its full findings to `<FINDINGS_DIR><LENS>.json`, always the fully qualified path, never a bare relative one, and writes the file even when the array is empty. The file on disk is what the caller trusts; the reply is a digest of it.

The reply is the thin digest and nothing else. It lists every finding, material and low, as `{ id, severity, title }`:

    { "dimension": "<lens>", "counts": { "blocker": <int>, "high": <int>, "medium": <int>, "low": <int> },
      "findings": [ { "id": "<lens>-NNN", "severity": "...", "title": "..." } ] }

Whether the main thread later reads a finding body is the caller's rule: the spec audit keeps bodies out of the main thread, and the plan audit's main thread reads the files to apply fixes.

## Findings file schema

What each agent writes to `<LENS>.json`. This is not a return contract; the thin digest above is what flows back.

    {
      "dimension": "<lens name>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "blocker" | "high" | "medium" | "low",
          "title": "<short>",
          "location": "<per the caller's location slot>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or artifact quote actually checked>",
          "recommendation": "<one sentence: the fix>"
        }
      ]
    }

## Pre-clear, classify, re-dispatch

An absent report reads as "the lens found nothing", the conclusion a silent lens must not earn. The rule is `.claude/rules/subagent-dispatch.md`; the steps for a lens:

1. Before dispatch, clear the file of every lens about to be dispatched. Spell the commands repo-relative so the existing allow patterns match, never with the absolute `<PLAN_DIR>` spelling:
   - Spec: `rm -f .gaia/local/cache/audit-<spec_id>/findings/<LENS>.json`
   - Plan: `rm -rf .gaia/local/plans/<PLAN-NNN>/audit`, then `mkdir -p .gaia/local/plans/<PLAN-NNN>/audit`
2. Dispatch every lens in one message, one Agent call per lens.
3. After each agent's completion notification, never at the moment the dispatch call returns (that call reports dispatch metadata before the agent has run), classify its file:

   ```bash
   bash .gaia/scripts/audit-noop-detect.sh --shape agent-report-file --path <findings file> --report-key findings
   ```

   Exit 0 is real (an empty `findings` array is real), 1 is a no-op, 2 is a usage error: a caller bug, so stop and surface it.
4. On a no-op, re-clear that lens's file and re-dispatch that lens exactly once.
5. On a second consecutive no-op, run that lens inline on the main thread and write its file yourself, then continue. Say in one line which lens ran inline.
