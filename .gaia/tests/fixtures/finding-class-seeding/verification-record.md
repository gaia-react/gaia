# Forward-assignment verification record

Three independent classification runs over the eighteen unlabelled cases in `cases/`, scored
best-of-three against each case's `expected` value in `labels.json`. Each run reads the owning
member's `## Holistic class assignment` section and the case file, and nothing else: no run sees
`labels.json`'s `expected`, `group`, or `reason` fields, no run sees another run's verdicts, and no
run scores itself.

## Verdict: PASS, 18 of 18, unanimous

Every corpus case takes its labelled class on all three runs, no corpus case takes the fallback on
any run, and every declined and ambiguous case takes its labelled value on all three runs.

| Case | Group | Expected | Run 1 | Run 2 | Run 3 | Majority |
| --- | --- | --- | --- | --- | --- | --- |
| `01-comment-satisfies-doc-needle` | corpus | `holistic/hollow-assertion` | = | = | = | 3/3 |
| `02-icon-only-button-role-query` | corpus | `holistic/hollow-assertion` | = | = | = | 3/3 |
| `03-pickup-field-restatement` | corpus | `holistic/uncoupled-restatement` | = | = | = | 3/3 |
| `04-required-check-name-drift` | corpus | `holistic/uncoupled-restatement` | = | = | = | 3/3 |
| `05-debounce-mode-count` | corpus | `holistic/stale-figure` | = | = | = | 3/3 |
| `06-decline-field-count-docblock` | corpus | `holistic/stale-figure` | = | = | = | 3/3 |
| `07-shell-lint-path-filter-gap` | corpus | `holistic/unarmed-guard` | = | = | = | 3/3 |
| `08-marker-digest-empty-skip` | corpus | `holistic/unarmed-guard` | = | = | = | 3/3 |
| `09-registry-completeness-glob-gap` | corpus | `holistic/fail-open-discovery` | = | = | = | 3/3 |
| `10-covered-classes-partial-merge` | corpus | `holistic/fail-open-discovery` | = | = | = | 3/3 |
| `11-noop-detect-stale-vs-missing-marker` | corpus | `holistic/partial-cause-reporting` | = | = | = | 3/3 |
| `12-ledger-status-margin-vs-window-failure` | corpus | `holistic/partial-cause-reporting` | = | = | = | 3/3 |
| `13-duplicated-gate-command-text` | declined | `prose/redundant-instruction` | = | = | = | 3/3 |
| `14-deictic-check-above-reference` | declined | `holistic/unclassified` | = | = | = | 3/3 |
| `15-self-referential-status-line` | declined | `holistic/unclassified` | = | = | = | 3/3 |
| `16-bundle-freshness-empty-list-skip` | ambiguous | `holistic/unclassified` | = | = | = | 3/3 |
| `17-timeout-hook-race-assertion` | ambiguous | `holistic/unclassified` | = | = | = | 3/3 |
| `18-config-flag-typo-tolerance` | ambiguous | `holistic/unclassified` | = | = | = | 3/3 |

## What an earlier round found, and what changed because of it

An earlier round of three runs scored 17 of 18. `16-bundle-freshness-empty-list-skip` took
`holistic/fail-open-discovery` on two of three runs where the fallback is correct. The case is a
single `find` serving two roles at once: its `-name "*.js"` pattern drops `.mjs` output from the set
the probe walks, and an empty listing from that same pattern arms a skip that stops the freshness
comparison running at all. `holistic/fail-open-discovery` and `holistic/unarmed-guard` both apply,
and no tie-break separates that pair.

The diagnosis was narrower than a missing tie-break. Every member's framing stated the recording
rule for a finding matching **no** class and said nothing about one matching **two**, so a run that
noticed the discovery half first had no rule sending it to the fallback. Each member's framing now
carries the multi-match rule alongside the no-match rule.

The repair is a sharpened criterion, not a relabelled fixture. Case 16's text, its `expected` value,
and its `reason` are unchanged, and no fourth tie-break was added: a tie-break that resolved the
pair would make a case that is genuinely unresolvable look resolvable, which inverts the test the
same way relabelling would. All three runs now reach the fallback and all three cite the absence of
a separating tie-break as their reason, so the rule rather than the wording is carrying the case.

## Limits

**Best-of-three replaces exact reproduction.** An audit member is not a deterministic classifier.
Repeating a run can produce a different verdict on a case whose criterion is close to a boundary, so
the bar is agreement across independent runs rather than a single reproducible answer. A unanimous
result is stronger evidence than the bar requires, and it is still evidence about agreement, not
proof of determinism.

**These runs are a proxy for the members.** Each run carries the owning member's
`## Holistic class assignment` section verbatim, which is exactly the text a member reads, but not
the surrounding definition, its remit resolution, its review dimensions, or its proof gate. The
definitions are the thing under test; the pipeline around them is absent. A member's own routing
could differ.

**The proxy is better informed than the member on one case.** `13-duplicated-gate-command-text`
routes to `prose/redundant-instruction`, and the instruction that settles it against
`holistic/uncoupled-restatement` reaches the classifier through its dispatch rather than through
`code-audit-maintainer-prose.md`. A member reading only its own definition does not have that
routing. The unanimous verdict on case 13 therefore demonstrates less than the other seventeen do.

**The restored workflow bucket is not forward-verified.** The `code-audit-github-workflows` member's
classifier receives its restored `## Workflow class assignment` section, but every case's expected
value is one of the six seeded classes, `prose/redundant-instruction`, or the fallback, so no case
expects a `workflow/*` class and no run can demonstrate one being assigned. That bucket's
reachability rests on the section-scoped greps in
`.gaia/tests/lib/doc-finding-class-seeding.bats`, which prove the four lines exist in the shape a
member reads, not that a member routes a workflow-security finding onto one of them.

**Delivery is file-backed, and that is load-bearing.** Each run writes its verdicts to a path
outside the repository and returns only a digest; the scorer reads and validates the files. An
earlier round lost five of six runs' verdicts to agents that completed without their reply reaching
the caller, which is indistinguishable from a clean result at the scoring step. Validating an
expected verdict count, rather than only that a file exists and parses, is what separates a complete
run from a truncated one.
