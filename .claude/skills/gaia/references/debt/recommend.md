# /gaia-debt: recommend and present

The no-argument offer of `/gaia-debt`. `debt.md` routes here on a `top` parse after its backlog read, and `debt/named.md` routes here when the operator picks option 3 of the direct-number cluster offer.

## Recommend and present

Runs on a `top` parse, after the backlog read in `debt.md`, or when the operator picks option 3 of the direct-number cluster offer in `debt/named.md`; a named set never reaches it. The top candidate is the first in the sorted list. Before building the prompt, apply the offer-time security and spec reads (`debt.md`, `### Offer-time reads`), which decide which candidates are public-batch-eligible, then resolve which cluster, if any, anchors the recommendation.

The **recommended batch**, when one exists, is the top cluster all of whose members are public-batch-eligible: normally the cluster containing the top-ranked candidate, but a security-class top candidate is never public-batch-eligible on a non-PRIVATE repo, and a spec-class top candidate is never batch-eligible on any repo, so either anchors no batch and is offered only as its own single candidate. An eligible batch may span severities, a `severity:suggestion` in the same file as a `severity:important` is a cheap add-on.

How you present the choice depends on backlog size and cluster shape, counted over the **remaining candidates** (the backlog pass's `candidates`), not the raw open-issue count:

- **Zero remaining candidates** (`candidates` is empty and `excluded.investigate` is empty too: every open `tech-debt` issue already carries `in-progress` or one of the two park labels) → do not prompt. State that every open `tech-debt` issue is already in progress or parked on a SPEC, and stop. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
- **Exactly one remaining candidate** → do not prompt. State the issue (number, title, severity band, age derived from `createdAt`) and fix it directly. This is also the peer-session case: two open issues, one already claimed, fixes the single remaining candidate with no prompt.
- **Top candidate heads a public-batch-eligible cluster of 2 or more** → a batch is recommended. Offer it with a single `AskUserQuestion` prompt (header `Debt item`, single-select), phrased around the batch, for example: `"Top item #<A> is related to <N> other issue(s) (<shared signal>). Fix them together, or one at a time?"`. Options, top option carrying `(Recommended)`:
  1. `Batch #<A> #<B> #<C> (Recommended)`, description: the shared signal (e.g. "all in app/foo/index.ts"), the member count, the severity span, and "one branch, one PR, all close on merge."
  2. `#<A> only`, description: fix just the top issue (its severity band and its age), one at a time.
  3. (optional) the next distinct candidate slot: a batch option when that candidate itself heads a >= 2 cluster, else a single option.
  - The tool's built-in **Other** entry lets the human type any open `tech-debt` issue number to fix that one alone.
- **Top candidate is a singleton (no cluster), or a security-class top candidate on a non-PRIVATE repo** → present exactly today's shape: the top three candidates as options (or both when only two exist), top candidate first and its label suffixed `(Recommended)`. Any shown candidate that itself heads a public-batch-eligible cluster of 2 or more is presented as a **batch** option rather than a single, which keeps one-at-a-time the default natural path.

Cap the option set at **4** (plus the built-in Other), the `AskUserQuestion` maximum. When the backlog is deeper than the shown options, first print the full ordered backlog (per issue: number, title, severity band, age), now annotated with cluster membership (e.g. `[batch with #B #C]`), so numbers beyond the shown options are visible before choosing.

**Opt-out guarantee.** One-at-a-time stays an explicit, always-available choice: the `#<A> only` option, the built-in Other (type any open issue number to fix it alone), and the unchanged singleton path together guarantee it. A batch is always a recommendation the human approves, never a default that skips the choice.

**Security-class members never appear inside a public batch option.** On a non-PRIVATE repo the offer-time security read already withholds them, they surface only as single candidates. On a confirmed-PRIVATE repo they may appear as batch members.

**Spec-class members never appear inside a batch option, on any repo.** The offer-time spec read withholds them unconditionally; unlike the security peel, this hold never relaxes on a confirmed-PRIVATE repo.

Handle the pick, and anything typed into **Other**, as `### Offer-time reads` in `debt.md` states, then continue at `## Claim the fix unit` in `debt.md`.
