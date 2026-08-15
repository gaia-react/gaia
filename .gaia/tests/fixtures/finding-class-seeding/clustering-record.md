# Clustering record: the six seeded holistic classes

## Provenance, read this before any count below

- A published findings block carries a class, a severity, and area tags, and **no
  finding text at all**. No count in this record is derived from a published block.
- Two mechanisms erase earlier rounds: a sidecar key that rotates when a clean round
  stamps its trailer, and a same-key write that replaces rather than accumulates. The
  merge-time publisher resolves exactly one key. A finding found and fixed during
  review leaves no trace, and a member not re-dispatched in the final window
  contributes nothing.
- The corpus this record rests on is 27 surviving audit sidecars carrying 44 findings
  across 16 branches, plus the bodies of all 27 pull requests, of which 26 carried
  recoverable finding text. Roughly 130 findings were recovered by hand. Only 10 of
  the 27 pull requests still hold a sidecar on disk; the other 17 contribute body
  prose alone.
- **Therefore every count below is a floor, not an estimate**, and every one is
  narrative-derived: read by hand from surviving sidecars and pull-request body prose,
  not queried from a database.
- The surviving records are reaped on a timer, so these counts are a snapshot, and
  re-deriving them gets harder the longer this record goes unrefreshed.

## Per-class counts

| Class | Distinct PRs | Basis |
| --- | --- | --- |
| `holistic/uncoupled-restatement` | 19 | largest family in the corpus on the distinct-pull-request axis |
| `holistic/hollow-assertion` | 15 | |
| `holistic/unarmed-guard` | 9 | |
| `holistic/stale-figure` | 8 | no boundary collisions against anything |
| `holistic/fail-open-discovery` | 6 | |
| `holistic/partial-cause-reporting` | 1 in-window | exception, see below |

The recurrence bar is 3 distinct pull requests inside a rolling 90-day window. Five of
the six classes clear it with room to spare.

## The named exception: `holistic/partial-cause-reporting`

One recorded in-window instance, well under the bar. This class is seeded on
**assignability**, not frequency, which is the vocabulary's own stated bar: seed only
classes an agent can reliably and repeatably assign. Its recurrence was directly
observed three times by three separate members inside one pull request whose published
findings block carried zero findings, which is exactly the evidence a published block
cannot hold. Of the six seeded classes, this is the one whose count rests on evidence
the block cannot hold.

## The residual-cluster denominator

Seven surviving findings were filed classless against classes that already existed in
the schema at the time (six against the already-seeded swallowed-error meaning, one
against a workflow script-injection shape), and one agent invented a class name the
schema has never carried, which the tally discarded entirely rather than counting.
Those seven are a labelling failure, not evidence of a vocabulary gap. The counts above
are measured against the residual cluster with all seven set aside. This matters
because correcting the misfilings before measuring is what stops a seeded class
inheriting a count from findings that were only ever misfiled, rather than from a real
recurring shape.

## The three rejected shapes, and what would change the answer

- **Lockstep copy drift**, on 8 pull requests, rejected on assignability rather than
  frequency: its instances split into a correctness half already reported under the
  already-seeded assertion-width meaning and a duplication half this repository has
  explicitly declined to act on as its own defect. Earns a class of its own when the
  repository decides to act on cross-file duplication as a defect in its own right,
  independent of the already-seeded prose meaning that currently absorbs it.
- **A deictic or positional reference**, one instance inside this cluster and two more
  across every pull request read, against a form whose own description concedes a high
  false-positive rate. Earns reconsideration at 3 distinct pull requests inside one
  window.
- **A self-referential status claim**, three instances, rejected on **habitat**: its
  dominant home is issue and comment prose, which no audit member reviews, and the
  repository's present-tense prose rule already governs its in-tree half. Earns seeding
  the moment a surface exists that reads issue and comment prose.
- **A falsification framing** for any of the above three, rejected on measurement: 53
  percent of the false-statement instances in the corpus were never true at all, 33
  percent were falsified by the change under review, and 14 percent by some earlier
  change, so 67 percent fail a falsification test, and 10 of the 23 pull requests
  carrying the family hold no diff-falsified instance at all. Earns reconsideration only
  if a future corpus inverts that measurement.

## The habitat bound

An audit member reviews the repository tree. Nothing in the instruction, harness, or
workflow surfaces reads a pull-request or issue body at all, so a defect living only
there is invisible to the recording mechanism as well as to any path-scoped rule or
tree lint. No class seeded here implies coverage of a surface no member reviews.
