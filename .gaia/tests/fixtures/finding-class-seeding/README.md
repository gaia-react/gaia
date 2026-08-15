# Finding-class seeding fixture set

## What this is for

Seeding a class cannot be verified backwards. The tally buckets every finding on the
literal class string its pull request already recorded, so no vocabulary change
relabels anything already written down, and no falling unclassified count can ever
prove that seeding worked. This set exists to run the only honest test: a **forward**
one. A member, given a finding of a seeded shape, assigns the seeded class rather than
the fallback.

## Structure

- `cases/<case-id>.md`: one unlabelled finding per file, in the exact shape an audit
  member has when it classifies (path, line, title, failure mode, verified-by evidence,
  suggested fix). No case names its own expected class.
- `labels.json`: the expected label per case id, kept in a separate file on purpose.
- `clustering-record.md`: per-class recurrence counts from the historical corpus, with
  the provenance bound and limits stated ahead of every count.

**Labels live apart from cases on purpose.** A classification run reads only `cases/`
and never opens `labels.json`. That separation is what makes a run a test rather than a
recitation: a classifier that could see the answer would not be measuring anything.

## How Phase 5 runs it

Each case is handed to a classifier alongside the updated `## Holistic class
assignment` section of the member whose remit covers that case's path (`labels.json`'s
`owning_members` field names which one). The classifier reads the case and the section
and returns one class.

Three independent passes run per case, scored best-of-three: a case counts as correctly
classified when at least two of the three runs return its labelled class. An audit
member is not a deterministic classifier, and no exact-reproduction bar is available
for prose-graded classification, so this non-determinism is a **stated limit** of the
method, not an assumption to design around.

## Where the result lands

`verification-record.md`, written beside this file by the classification run. It is not
part of this fixture set and is not committed by whatever authors the cases and labels.

## Re-running after a later vocabulary change

1. Re-read `clustering-record.md` and confirm its counts and rejected shapes still
   describe the current class set; a class added or retired since this record was
   written invalidates the counts that reference it.
2. Add or relabel cases for any newly seeded class, following the same authoring rules
   as the existing corpus cases (drawn from the corpus, never naming the class or a
   phrase lifted from a member's assignment line, spread across the surfaces the class
   can appear on).
3. Update `labels.json` to match, keeping the label separate from the case file.
4. Re-run the three-pass classification and write a fresh `verification-record.md`.
