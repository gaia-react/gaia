# SPEC-002 forensics-triage; integration checklist (layer C)

Prose checklist the maintainer runs once after merge, and again when amending SPEC-002. Each section names: the fixture body, the expected workflow outcome, and the verification command. Layer C is human-driven because GitHub Actions itself can't be cleanly mocked.

## Preconditions

- The triage workflow is merged to `main` at `.github/workflows/forensics-triage.yml`.
- All six labels exist on `gaia-react/gaia`: `gaia-forensics`, `gaia-triaged`, `non-issue`, `needs-human`, `auto-fixable`, `gaia-bug-confirmed`. (Run `.github/forensics/bootstrap-labels.sh` once if missing.)
- Repository secret `ANTHROPIC_API_KEY` is set.
- Branch protection on `main`: required reviews >= 1, required status checks present.
- `gh` CLI authenticated with `repo` scope on `gaia-react/gaia`.

Each step uses these env vars to keep the commands copy-pasteable:

```bash
REPO=gaia-react/gaia
FIXTURE_DIR=.gaia/tests/forensics/fixtures
```

To open a fixture as an issue:

```bash
gh issue create -R "$REPO" \
  --title "[forensics-uat-NNN] <fixture-name>" \
  --body-file "$FIXTURE_DIR/<fixture-name>.md" \
  --label gaia-forensics
```

Capture the issue number returned by `gh issue create` as `ISS=...`; later steps reference it.

To watch the run:

```bash
gh run list -R "$REPO" --workflow forensics-triage.yml --limit 5
gh run watch -R "$REPO" <run-id>
```

To inspect terminal state:

```bash
gh issue view -R "$REPO" "$ISS" --json state,labels,comments
gh pr list -R "$REPO" --head "forensics/${ISS}-*"
```

---

## UAT-001; every triaged issue receives `gaia-triaged` + classification comment

- **Fixture**: `non-issue-config.md` (any conformant body works; this UAT is the lowest-common-denominator).
- **Expected outcome**: The `gaia-triaged` label appears on the issue, and a comment names one of `non-issue` / `needs-human` / `auto-fixable` and cites the parsed `## Classification` section as evidence.
- **Verify**:
  ```bash
  gh issue view -R "$REPO" "$ISS" --json labels --jq '.labels[].name' | grep -x gaia-triaged
  gh issue view -R "$REPO" "$ISS" --json comments --jq '.comments[-1].body' | grep -E 'verdict:|reason:'
  ```
- **Pass criterion**: both commands exit 0.

---

## UAT-002; `non-issue` verdict closes + comments + labels

- **Fixture**: `non-issue-config.md`. The reporter is missing `.env`; the classifier should call this `non-issue`.
- **Expected outcome**: Issue is CLOSED. Labels: `non-issue` AND `gaia-triaged`. The closing comment names `verdict: non-issue` with a one-line reason and a remediation pointer (e.g. "run `cp .env.example .env`").
- **Verify**:
  ```bash
  gh issue view -R "$REPO" "$ISS" --json state,labels --jq '{state: .state, labels: [.labels[].name]}'
  ```
- **Pass criterion**: `state == "CLOSED"` and `labels` contains both `non-issue` and `gaia-triaged`.

---

## UAT-004; `auto-fixable` verdict opens draft PR + labels

- **Fixture**: `valid-init-failure.md`. The bug is in `.claude/skills/gaia-init/SKILL.md` (allowlisted) and `.gaia/cli/templates/init/post-init.sh` (allowlisted via `.gaia/cli/`).
- **Expected outcome**: a branch named `forensics/<ISS>-init` exists on origin; a DRAFT PR is open against `main` linking back to the issue; the issue has labels `auto-fixable`, `gaia-bug-confirmed`, AND `gaia-triaged`. The PR body cites `## Capture` from the issue verbatim.
- **Verify**:
  ```bash
  git fetch origin "forensics/${ISS}-init" && git log --oneline -1 "origin/forensics/${ISS}-init"
  gh pr list -R "$REPO" --head "forensics/${ISS}-init" --json isDraft,title,body
  gh issue view -R "$REPO" "$ISS" --json labels --jq '[.labels[].name] | sort'
  ```
- **Pass criterion**: branch exists with at least one commit; PR is `isDraft: true` and body contains a "## Capture (verbatim from issue)" section quoting fixture content; issue labels include all three of `auto-fixable`, `gaia-bug-confirmed`, `gaia-triaged`.

---

## UAT-005; Quality Gate failure abandons the branch + demotes to `needs-human`

This UAT is the hardest to fixture cleanly because the gate has to FAIL on the model's diff. There are two ways to provoke it:

1. **Synthetic**: temporarily replace `.github/forensics/run-quality-gate.sh` on a throwaway branch with one that always exits 1, then open `valid-init-failure.md` against that branch.
2. **Live**: open the fixture against the live workflow and trust the maintainer to read the gate result; if the gate happens to pass naturally, this UAT is exercised by inverting the assertion (no demote occurred). Re-run with synthetic-fail to actually exercise the failure path.

- **Fixture**: `valid-init-failure.md` plus a synthetic `run-quality-gate.sh` returning non-zero.
- **Expected outcome**: NO branch on origin matching `forensics/<ISS>-*`. Issue labels: `needs-human` AND `gaia-triaged`. Issue is OPEN. NO `auto-fixable` label. Comment names which gate step failed and links the workflow run.
- **Verify**:
  ```bash
  git fetch origin "+refs/heads/forensics/${ISS}-*:refs/remotes/origin/forensics/${ISS}-*" 2>&1 | grep -v 'forensics/' || echo 'no remote forensics branch; pass'
  gh issue view -R "$REPO" "$ISS" --json state,labels --jq '{state: .state, labels: [.labels[].name] | sort}'
  gh issue view -R "$REPO" "$ISS" --json comments --jq '.comments[-1].body' | grep -E 'failed step|gate-failure'
  ```
- **Pass criterion**: no `forensics/<ISS>-*` ref on origin; issue is OPEN with `needs-human` + `gaia-triaged` and WITHOUT `auto-fixable`; latest comment mentions the failed step.

---

## UAT-006; re-firing on an already-`gaia-triaged` issue is a no-op

- **Fixture**: any previously-triaged issue (e.g. the issue from UAT-001 above).
- **Expected outcome**: the workflow run terminates early with the `::notice::issue #N already triaged; skipping` line; no new comment, no new label, no new PR, no new branch.
- **Reproduce**:
  ```bash
  # Trigger a re-fire by removing and re-adding any label.
  gh issue edit -R "$REPO" "$ISS" --remove-label needs-human || true
  gh issue edit -R "$REPO" "$ISS" --add-label needs-human || true
  ```
- **Verify**:
  ```bash
  gh run list -R "$REPO" --workflow forensics-triage.yml --limit 3
  gh run view -R "$REPO" <newest-run-id> --log | grep 'already triaged'
  # Comment count must be unchanged versus the pre-refire state.
  gh issue view -R "$REPO" "$ISS" --json comments --jq '.comments | length'
  ```
- **Pass criterion**: the newest run logs `already triaged; skipping`; comment count did NOT increase across the re-fire.

---

## UAT-008; every PR opened by triage is `draft: true` and never auto-merged

- **Fixture**: re-use the PR opened by UAT-004 (no separate fixture needed).
- **Expected outcome**: PR is `isDraft: true` at the moment of opening; the workflow log shows no `gh pr merge` or `gh pr ready` invocation; branch protection on `main` blocks merge without human approval.
- **Verify**:
  ```bash
  gh pr view -R "$REPO" --head "forensics/${ISS}-init" --json isDraft,mergeable,reviewDecision
  gh run view -R "$REPO" <run-id> --log | grep -E 'gh pr merge|gh pr ready' && echo 'FAIL: workflow tried to merge or ready the PR' || echo 'pass: no merge/ready calls'
  ```
- **Pass criterion**: `isDraft == true`; the grep returns no lines; branch protection rejects any direct push to `main`.

---

## UAT-010; secrets never appear in logs / comments / PR bodies / commits

- **Fixture**: any successfully-run UAT (re-use UAT-001 / UAT-002 / UAT-004).
- **Expected outcome**: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, and any literal secret string the workflow observed are absent from every artifact. `::add-mask::` is emitted for any secret-shaped values surfaced through the parsed body.
- **Verify**:

  ```bash
  # Workflow log scan; neither the literal env-var name's value nor the masking-substitution token should leak.
  gh run view -R "$REPO" <run-id> --log > /tmp/run.log
  grep -E 'sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' /tmp/run.log && echo 'FAIL: leaked secret-shaped string' || echo 'pass: no secret-shaped strings in log'

  # Comment + PR-body scan; same shapes.
  gh issue view -R "$REPO" "$ISS" --json comments --jq '.comments[].body' | grep -E 'sk-ant-|ghp_|github_pat_' && echo 'FAIL: secret in issue comments' || echo 'pass: no secrets in comments'
  gh pr view -R "$REPO" --head "forensics/${ISS}-*" --json body --jq '.body' | grep -E 'sk-ant-|ghp_|github_pat_' && echo 'FAIL: secret in PR body' || echo 'pass: no secrets in PR body'
  ```

- **Pass criterion**: every grep returns no lines (each "FAIL" branch is unreached).

---

## UAT-011; concurrent re-fires queue and second run early-exits

- **Fixture**: a fresh issue from `non-issue-config.md` (or any conformant body).
- **Expected outcome**: two `issues.labeled` events fired in close succession produce two scheduled runs; the second one queues until the first applies `gaia-triaged`; the second run hits the UAT-006 early-exit; no duplicate label / comment / branch / PR is created.
- **Reproduce**:
  ```bash
  gh issue create -R "$REPO" --title '[forensics-uat-011] dual-fire' --body-file "$FIXTURE_DIR/non-issue-config.md" --label gaia-forensics
  ISS=<num-from-output>
  # Two near-simultaneous label edits; re-add an unrelated label twice.
  gh issue edit -R "$REPO" "$ISS" --add-label gaia-forensics &
  gh issue edit -R "$REPO" "$ISS" --add-label gaia-forensics &
  wait
  ```
- **Verify**:
  ```bash
  gh run list -R "$REPO" --workflow forensics-triage.yml --limit 5 --json databaseId,status,conclusion,headBranch
  # Expect two runs in the list for this issue's window: one success (the triage run), one success (the early-exit).
  gh run view -R "$REPO" <second-run-id> --log | grep 'already triaged'
  # Comment count is exactly one (the original verdict comment), labels include `gaia-triaged` exactly once.
  gh issue view -R "$REPO" "$ISS" --json comments --jq '.comments | length'
  gh issue view -R "$REPO" "$ISS" --json labels --jq '[.labels[].name] | map(select(. == "gaia-triaged")) | length'
  ```
- **Pass criterion**: second run logs `already triaged`; comment count is 1; `gaia-triaged` appears exactly once in the labels list.

---

## UAT-012; 30-min job timeout is fail-forward (no rollback)

This is the hardest UAT to fixture without artificial latency. There are two practical paths:

1. **Synthetic**: temporarily lower `timeout-minutes` in `.github/workflows/forensics-triage.yml` from 30 to 1 on a throwaway branch and inject a `sleep 120` step before the handler steps. Run a fixture; the timeout fires.
2. **Observational**: trust the timeout invariant by reading the workflow file. The workflow declares `timeout-minutes: 30` at the job level; GitHub Actions enforces it. UAT-012's invariant is that ALREADY-applied labels remain after the timeout; this is satisfied by construction because the workflow never `gh issue edit --remove-label` rolls back.

- **Fixture**: `valid-init-failure.md` plus a synthetic 1-min-timeout branch.
- **Expected outcome**: the run aborts at the timeout; any label that landed before the timeout REMAINS (no rollback); no PR opens; no branch is pushed; no half-applied state.
- **Verify**:
  ```bash
  gh run view -R "$REPO" <run-id> --json conclusion --jq '.conclusion'   # expect: cancelled OR failure
  gh issue view -R "$REPO" "$ISS" --json labels --jq '[.labels[].name] | sort'
  git ls-remote --heads origin "forensics/${ISS}-*"   # expect empty
  gh pr list -R "$REPO" --head "forensics/${ISS}-*"   # expect empty
  ```
- **Pass criterion**: run conclusion is `cancelled` or `failure`; labels that were applied PRE-timeout still exist; no remote branch; no PR.

---

## Local skill end-to-end; read-only + write-allowlist filesystem diff

Distinct from the SPEC-002 CI checks above: this exercises the **local
`/gaia-forensics` skill**, which the numbered bats detectors
(`02`/`04`/`06`/`07`/`08`/`09`-`*.bats`) only reach through inline surrogates.
Those detectors prove the branch *logic*; this proves the **shipped skill body**
honors the same write-surface + read-only contract. It stays a manual check
because the skill's diagnosis runs through the Claude Code LLM and cannot execute
inside a bats unit (do not fabricate an LLM-driven bats test for it).

The two write sinks are the only paths the skill may create or modify:
`.gaia/local/forensics/` and `.gaia/local/telemetry/`. Everything else -
`app/`, `wiki/`, `.claude/`, and any git-tracked source - must be untouched.

- **Setup**: from a clean tree (`git status --porcelain` empty), drop a marker
  and snapshot tracked state.
  ```bash
  ROOT="$(git rev-parse --show-toplevel)"
  MARKER="$ROOT/.forensics-e2e-marker"
  touch "$MARKER"
  git -C "$ROOT" status --porcelain > /tmp/forensics-pre.txt
  ```
- **Run**: invoke the skill with a fixed description and let it save locally
  (decline the GH-issue offer so the run stays on-disk and offline).
  ```
  /gaia-forensics the wiki-sync push failed with a merge conflict
  ```
- **Diff (a); nothing written outside the two sinks.** Any file newer than the
  marker, excluding the sinks / `.git/` / the marker itself, is a violation.
  ```bash
  find "$ROOT" -type f -newer "$MARKER" \
    -not -path "$ROOT/.git/*" \
    -not -path "$ROOT/.gaia/local/forensics/*" \
    -not -path "$ROOT/.gaia/local/telemetry/*" \
    -not -path "$MARKER" \
    && echo 'FAIL: write outside allowlist' || echo 'pass: writes confined to sinks'
  ```
- **Diff (b); no tracked source changed.** No modification to `app/`, `wiki/`,
  or anything git tracks (`.gaia/local/` is gitignored, so a clean porcelain
  proves the report landed only in the ignored sink).
  ```bash
  git -C "$ROOT" status --porcelain > /tmp/forensics-post.txt
  diff /tmp/forensics-pre.txt /tmp/forensics-post.txt \
    && echo 'pass: no tracked-source writes' || echo 'FAIL: tracked source changed'
  ```
- **Diff (c); no secret-shaped strings in the saved report** (cross-ref
  UAT-010 above).
  ```bash
  grep -rEl 'sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' \
    "$ROOT/.gaia/local/forensics/" \
    && echo 'FAIL: secret in saved report' || echo 'pass: no secrets in report'
  rm -f "$MARKER"
  ```
- **Pass criterion**: the `find` in (a) returns no lines; `git status` in (b) is
  unchanged from the pre-snapshot; the `grep` in (c) returns no lines. Any FAIL
  branch reached means the shipped skill violated the write-surface or redaction
  contract that `04-write-surface.bats` and the redaction fixtures only assert on
  surrogates.

> These commands are the deterministic, non-LLM half of the check: the only step
> that needs the LLM is the `/gaia-forensics` invocation itself. A future
> deterministic harness could feed a fixed description straight through the
> `capture -> redact.sh -> classify.sh -> render` pipeline and run diffs (a)-(c)
> with no LLM in the loop; the bats detectors above stop short of that.

---

## Coverage map (full SPEC-002 UAT roster)

| UAT     | Layer | Where verified                                                                                                                                 |
| ------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| UAT-001 | C     | This file, "UAT-001" section above.                                                                                                            |
| UAT-002 | C     | This file, "UAT-002" section above.                                                                                                            |
| UAT-003 | A+B   | `.github/forensics/tests/handlers.bats` (handle-needs-human) + `.github/forensics/tests/parse-verdict.bats` (ambiguous verdict downgrade).     |
| UAT-004 | C     | This file, "UAT-004" section above.                                                                                                            |
| UAT-005 | C     | This file, "UAT-005" section above.                                                                                                            |
| UAT-006 | C     | This file, "UAT-006" section above.                                                                                                            |
| UAT-007 | A+B   | `.gaia/tests/forensics/unit.bats` ("UAT-007: mixed allow + deny ...").                                                                         |
| UAT-008 | C     | This file, "UAT-008" section above.                                                                                                            |
| UAT-009 | A+B   | `.github/forensics/tests/parse-issue-body.bats` (24 tests, deterministic regex).                                                               |
| UAT-010 | C     | This file, "UAT-010" section above.                                                                                                            |
| UAT-011 | C     | This file, "UAT-011" section above.                                                                                                            |
| UAT-012 | C     | This file, "UAT-012" section above.                                                                                                            |
| UAT-013 | A+B   | `.gaia/tests/forensics/unit.bats` (`malformed-*` fixtures) + `.github/forensics/tests/parse-issue-body.bats` (failure-mode tests).             |
| UAT-014 | A+B   | `.gaia/tests/forensics/unit.bats` ("UAT-014: unenumerated path ...").                                                                          |
| UAT-015 | A+B   | `.gaia/tests/forensics/unit.bats` ("redaction-passthrough preserves ...") + `.github/forensics/tests/parse-issue-body.bats` (redaction tests). |

## Re-running this checklist

1. Open each fixture as a fresh issue via `gh issue create -R "$REPO" --label gaia-forensics --body-file <fixture>`.
2. Walk the section that matches the fixture (UAT-001 / UAT-002 / UAT-004 / UAT-005 / UAT-006 / UAT-008 / UAT-010 / UAT-011 / UAT-012).
3. After every section passes, close the test issues:
   ```bash
   gh issue list -R "$REPO" --label gaia-forensics --search '[forensics-uat' --json number --jq '.[].number' \
     | xargs -I{} gh issue close -R "$REPO" {}
   ```
4. Record pass/fail per UAT in the SPEC-002 amendment PR description.
