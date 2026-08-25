# Forward-assignment verification record

Three independent classification runs over the twenty-eight unlabelled cases in `cases/`, scored
best-of-three against each case's `expected` value in `labels.json`. Each run reads the owning
member's `## Holistic class assignment` section and the case file, and nothing else: no run sees
`labels.json`'s `expected`, `group`, or `reason` fields, no run sees another run's verdicts, and no
run scores itself. The prohibition is stated to each classifier and names the schema and the
sibling fixture files individually, because a classifier that reads either one is reciting rather
than classifying.

## Verdict: 25 of 28, unanimous on every one of the 25

**All ten wave-2 cases take their labelled class on all three runs**, in this round and in the
round before it, which is the question this corpus exists to answer for the five classes seeded in
wave 2. Three cases do not take their labelled value, all three from wave 1, and the control run
below establishes that none of the three is caused by the wave-2 widening.

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
| `13-duplicated-gate-command-text` | declined | `prose/redundant-instruction` | `uncoupled-restatement` | `uncoupled-restatement` | `uncoupled-restatement` | 0/3 |
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

## The control: the three misses predate the widening

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

## The three misses, each read on its own

**`10-covered-classes-partial-merge`** straddles `holistic/fail-open-discovery` and
`holistic/unarmed-guard`, and every run that took the fallback named that pair and the absence of a
tie-break between them as its grounds. That is the multi-match rule operating exactly as written.
The pair is deliberately un-tie-broken: resolving it would make a genuinely unresolvable case look
resolvable, and it would also pull case 16 off the fallback its label asks for, so the two cases
constrain each other and no sentence satisfies both. Two of the three runs are arguably right and
the label is arguably wrong; neither was changed here, because deciding that is a judgement about
the fixture set rather than about the vocabulary.

**`13-duplicated-gate-command-text`** takes `holistic/uncoupled-restatement` unanimously, in both
rounds, against a `prose/redundant-instruction` label. All six runs give the same grounds: the
`code-audit-maintainer-prose` member's own criterion carves `prose/redundant-instruction` out for
"a duplicated instruction whose copies agree with each other and with the code", and this case's
copies have drifted apart. The criterion as written says what the runs say. This is a disagreement
between a label and a criterion neither round touched, and the earlier record already noted that
this case demonstrates less than the others because its expected class reaches a classifier through
its dispatch rather than through the member definition.

**`16-bundle-freshness-empty-list-skip`** is covered by the control above.

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
