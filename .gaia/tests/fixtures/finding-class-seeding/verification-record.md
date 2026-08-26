# Forward-assignment verification record

Three independent classification runs over the twenty-eight unlabelled cases in `cases/`, scored
best-of-three against each case's `expected` value in `labels.json`. Each run reads the owning
member's `## Holistic class assignment` section and the case file, and nothing else: no run sees
`labels.json`'s `expected`, `group`, or `reason` fields, no run sees another run's verdicts, and no
run scores itself. The prohibition is stated to each classifier and names the schema and the
sibling fixture files individually, because a classifier that reads either one is reciting rather
than classifying.

## Verdict: 26 of 28 against the labels as they now stand, unanimous on every one of the 26

**All ten wave-2 cases take their labelled class on all three runs**, in this round and in the
round before it, which is the question this corpus exists to answer for the five classes seeded in
wave 2. Three wave-1 cases did not take the value they were labelled with when these runs were
scored. The control run below covers two of them and establishes that neither is caused by the
wave-2 widening; the third, case 13, was never separately controlled, because both rounds returned
the same class against a criterion neither round touched.

One of the three, `13-duplicated-gate-command-text`, has since been decided the other way: the
label was wrong and now reads what all six runs returned, which is why the count above is 26 rather
than 25 and why that case's row shows agreement. **No run was repeated to produce that agreement.**
The runs' returned classes are exactly what they were; only the value they are scored against
changed. The two that remain are a single decision recorded in `labels.json` rather than an open
failure, and the field it is recorded in is described in `README.md`.

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
| `10-covered-classes-partial-merge` | corpus | `holistic/fail-open-discovery` | `unclassified` | = | `unclassified` | 1/3 |
| `11-noop-detect-stale-vs-missing-marker` | corpus | `holistic/partial-cause-reporting` | = | = | = | 3/3 |
| `12-ledger-status-margin-vs-window-failure` | corpus | `holistic/partial-cause-reporting` | = | = | = | 3/3 |
| `13-duplicated-gate-command-text` | corpus | `holistic/uncoupled-restatement` | = | = | = | 3/3 |
| `14-deictic-check-above-reference` | declined | `holistic/unclassified` | = | = | = | 3/3 |
| `15-self-referential-status-line` | declined | `holistic/unclassified` | = | = | = | 3/3 |
| `16-bundle-freshness-empty-list-skip` | ambiguous | `holistic/unclassified` | = | `fail-open-discovery` | `fail-open-discovery` | 1/3 |
| `17-timeout-hook-race-assertion` | ambiguous | `holistic/unclassified` | = | = | = | 3/3 |
| `18-config-flag-typo-tolerance` | ambiguous | `holistic/unclassified` | = | = | = | 3/3 |
| `19-skill-points-at-absent-wiki-page` | corpus | `holistic/dangling-reference` | = | = | = | 3/3 |
| `20-docblock-names-absent-runbook-step` | corpus | `holistic/dangling-reference` | = | = | = | 3/3 |
| `21-status-writer-pasted-across-jobs` | corpus | `holistic/drifting-duplicate` | = | = | = | 3/3 |
| `22-commit-grammar-written-three-times` | corpus | `holistic/drifting-duplicate` | = | = | = | 3/3 |
| `23-hook-root-from-process-cwd` | corpus | `holistic/ambient-context-resolution` | = | = | = | 3/3 |
| `24-status-step-takes-local-head` | corpus | `holistic/ambient-context-resolution` | = | = | = | 3/3 |
| `25-members-stage-to-one-filename` | corpus | `holistic/shared-state-collision` | = | = | = | 3/3 |
| `26-fixture-written-to-fixed-temp-path` | corpus | `holistic/shared-state-collision` | = | = | = | 3/3 |
| `27-runner-sets-no-output-ceiling` | corpus | `holistic/unbounded-invocation` | = | = | = | 3/3 |
| `28-guard-cost-grows-with-input` | corpus | `holistic/unbounded-invocation` | = | = | = | 3/3 |

`=` is the labelled class. A cell naming a class is that run's differing verdict.

## The earlier round, and the repair it bought

An earlier round of this same corpus scored 24 of 28 and put `04-required-check-name-drift` at 1 of
3, two runs assigning `holistic/dangling-reference` where the label is
`holistic/uncoupled-restatement`. The miss was diagnostic rather than incidental. The tie-break
sentence separating that pair turned on a referent that "resolves to nothing", which reads two ways:
this name matches nothing, and there is no such thing. Case 04's required check exists under a
different name after a rename, so both readings were available and the runs split on which they
took.

The repair was the criterion, not the fixture, whose text and expected value are unchanged. The
tie-break now turns on whether the thing pointed at is absent under **every** name, and each
member's `holistic/dangling-reference` line was rewritten to the same standard. Case 04 is 3 of 3
in this round, and one run cites the repaired sentence by its new wording.

One repair in that round did nothing. A run had cited the fail-open-discovery tie-break as its
grounds on `16-bundle-freshness-empty-list-skip`, so that sentence was rewritten to read as a
discriminator between two classes rather than as a sufficient condition for one. Case 16's split is
byte-identical across the two rounds, so the citation was a rationalisation of a verdict reached on
other grounds, and the rewritten sentence is kept on its own merits rather than as a fix.

## The control: the two disputed cases predate the widening

`10-covered-classes-partial-merge` and `16-bundle-freshness-empty-list-skip` were re-run three times
each against an archived copy of their owning members' assignment sections taken from before the
wave-2 classes were seeded, held outside the repository so no run could reach the current revision.

| Case | Label | Against the wave-1 vocabulary | Against the current vocabulary |
| --- | --- | --- | --- |
| `10-covered-classes-partial-merge` | `holistic/fail-open-discovery` | `holistic/unclassified`, 3 of 3 | `holistic/unclassified`, 2 of 3 |
| `16-bundle-freshness-empty-list-skip` | `holistic/unclassified` | `holistic/fail-open-discovery`, 3 of 3 | `holistic/fail-open-discovery`, 2 of 3 |

Both fail their labels **more** decisively against the vocabulary they were authored for than against
the widened one. The widening is not what moved them, and case 16 is nearer its label now than it
was. What the control measures is the fixture set, not the seeding: for these two cases, the record
of 18 of 18 unanimous does not reproduce.

## The three, each read on its own, and what was decided

**`10-covered-classes-partial-merge`** straddles `holistic/fail-open-discovery` and
`holistic/unarmed-guard`, and every run that took the fallback named that pair and the absence of a
tie-break between them as its grounds. That is the multi-match rule operating exactly as written.
The pair is deliberately un-tie-broken: resolving it would make a genuinely unresolvable case look
resolvable, and it would also pull case 16 off the fallback its label asks for, so the two cases
constrain each other and no sentence satisfies both. Two of the three runs are arguably right and
the label is arguably wrong.

**Decided: keep both labels and record the pair as unstable.** Relabelling either one asserts that
the boundary is settled when it is not, and adding the tie-break that would settle it breaks the
other case by construction. So `labels.json` now carries `reproduces: "unstable"` on this case and
on case 16, each naming the other, and a re-run that splits here reads as expected rather than as a
regression. Each label stays as the reading its case should take once a tie-break exists, which is
what makes the pair worth keeping rather than deleting.

**`13-duplicated-gate-command-text`** takes `holistic/uncoupled-restatement` unanimously, in both
rounds, against a `prose/redundant-instruction` label. All six runs give the same grounds: the
`code-audit-maintainer-prose` member's own criterion carves `prose/redundant-instruction` out for
"a duplicated instruction whose copies agree with each other and with the code", and this case's
copies have drifted apart. The criterion as written says what the runs say. This was a disagreement
between a label and a criterion neither round touched, and the earlier record already noted that
this case demonstrates less than the others because its expected class reaches a classifier through
its dispatch rather than through the member definition.

**Decided: the label was wrong, and it now reads `holistic/uncoupled-restatement`.** The carve-out
is explicit that the duplicated-instruction class covers copies that still agree with each other
and with the code, and a drifted copy is not merely redundant, it is false: a reader who follows it
runs the wrong gate. Widening the carve-out to swallow drifted copies would have been the reverse
move, tuning a criterion until a wrong label went green, and it would have made the class say
something untrue about what a drifted duplicate costs a reader. The case moves out of the
`declined` group with the label, since it no longer demonstrates a decline.

**`16-bundle-freshness-empty-list-skip`** is covered by the control above, and by case 10's
decision, which is one decision over both.

## What this record does not establish

**The workflow bucket is still not forward-verified.** No case expects a `workflow/*` class, so no
run can demonstrate one being assigned. That bucket's reachability rests on the section-scoped greps
in `.gaia/tests/lib/doc-finding-class-seeding.bats`, which prove the four lines exist in the shape a
member reads, not that a member routes a workflow-security finding onto one of them.

**Nothing here is a claim about the unclassified share falling.** The tally buckets every finding on
the literal class string its pull request already recorded, so no vocabulary change relabels
anything already written down. That measurement is a lagging one and can only move on findings
recorded after the seeding merges.

**Classification is not deterministic and this method does not assume it is.** Best-of-three is the
scoring rule for that reason, and the round-to-round movement on cases 10 and 16 is a direct
observation of it rather than a defect either round introduced.

**Delivery is file-backed, and that is load-bearing.** Each verdict is returned through a validated
structured channel rather than through free text, and every dispatch is accounted for: 84 of 84 in
each round, 6 of 6 in the control, with no empty results. A lost verdict is indistinguishable from
a classifier that declined, which is the one reading this record must not admit.
