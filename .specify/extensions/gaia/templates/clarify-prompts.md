# GAIA `/speckit.clarify` prompt templates

Structured Q&A copy applied by the GAIA preset when `/speckit.clarify`
runs under `/gaia-spec`. These templates are visible and editable here
by design, never hardcode a question bank outside this directory
(per the SPEC's `scope_boundaries.never`).

The PO agent driving the Socratic loop reads these templates and adapts
the placeholder slots (`<topic>`, `<question>`, `<option-N>`, `<next>`)
at runtime. Phrasing of the fixed-text portions is normative, do not
paraphrase the per-topic exhaustion checkpoint, the "Other" option, or
the "Discuss this" option.

---

## Rule 1: One question at a time

The PO asks **exactly one question per turn**. No multi-question forms.
No "and also" clauses that smuggle a second question into the prompt.
If the PO has two adjacent questions, it asks the more load-bearing one
first and queues the other for the next turn.

Canonical phrasing when the PO needs to acknowledge a queued follow-up
without asking it:

> Noted, I'll come back to `<queued-question>` after we settle this one.

---

## Rule 2: Closed-set questions use `AskUserQuestion`

A "closed-set" question is one with discrete possible answers the PO
can enumerate. These ALWAYS use the `AskUserQuestion` tool with the
following option ordering:

1. **Recommended option first.** The PO names the option it would
   choose given the discovery so far, with a short reason.
2. **Ranked alternatives.** Other plausible options, ordered by how
   close they are to the recommendation.
3. **`Other`**, free-text escape. The user types an answer the PO
   did not enumerate.
4. **`Discuss this`**, drops to plain Q&A on this question until the
   user signals settlement, then resumes the structured loop on the
   next topic.

### Closed-set template

```
Question:
  <One sentence. The decision the PO needs the human to make.>

Why this matters:
  <One sentence. The downstream consequence of the choice.>

Options:
  1. <recommended-option>, recommended. <Short reason. Name the
     trade-off the PO weighed.>
  2. <alternative-option-A>, <Short reason this is plausible.>
  3. <alternative-option-B>, <Short reason this is plausible.>
  …
  N-1. Other, type your own answer.
  N.   Discuss this, talk it through; we'll resume the structured
       loop after you signal settlement.
```

When code-context is available (a known component, an existing pattern,
a prior SPEC's decision), annotate the option with that context inline,
borrowing GSD's pattern:

> 1. Cards (reuses existing `Card` component), recommended. Lowest
>    delta vs. shipped UI.
> 2. List (simpler, would be a new pattern), cleaner read on small
>    screens but introduces a third list pattern in the app.
> 3. Timeline (needs new `Timeline` component), visually richest but
>    largest scope.

---

## Rule 3: "Discuss this" escape and resume

When the user picks `Discuss this`, the PO leaves the structured
`AskUserQuestion` loop and conducts plain Q&A on the current topic
until the user signals settlement (any of: "got it", "settled", "let's
move on", "back to the loop", or an explicit "resume").

On settlement:

1. The PO writes a one-paragraph summary of the discussion outcome.
2. The PO appends an entry to `clarifications.answered[]` of the
   in-progress draft with shape `{ q: <original-question>, a: <summary> }`.
3. The PO announces:

   > Settled. Recording in `clarifications.answered`. Resuming the
   > structured loop.

4. The PO advances to the next planned topic (it does NOT re-ask the
   question that triggered the discussion).

Silent resume is forbidden, the announce step is required so the user
knows the loop has re-engaged.

---

## Rule 4: Open-ended questions use plain prompts

A "genuinely open-ended" question is one where enumerating options
would be reductive: free-form intent, success-criteria phrasing,
research-shaped curiosity. These use a plain prompt, no
`AskUserQuestion`, no enumerated options.

### Open-ended template

```
<One sentence framing the question.>

<Optional: one sentence on why the PO is asking it now.>
```

Example:

> What's the smallest version of this feature that would still feel
> like a win to you?
>
> I'm asking now so we can scope the UATs around the floor, not the
> ceiling.

---

## Rule 5: Per-topic exhaustion checkpoint

When the PO has run out of natural follow-up questions on the current
topic, it announces explicitly via `AskUserQuestion`. **Silent topic
advance is forbidden.**

### Exhaustion checkpoint phrasing: NORMATIVE

```
Out of questions on <topic>. Move to <next>, or push deeper?

Options:
  1. Move to <next>, recommended. <Short reason if useful.>
  2. Push deeper on <topic>, I'll mine for follow-ups; you can
     provide a seed if there's something specific I'm missing.
  3. Other, name a different topic to jump to.
```

Slot semantics:

- `<topic>`: the topic the PO just exhausted, named the same way it
  was named when the topic opened (consistency aids the user's
  mental model).
- `<next>`: the next topic in the PO's planned topic order. If the
  topic order is fluid, the PO names the topic with the highest
  remaining question count.

The exhaustion checkpoint never collapses into a default-advance, the
user's choice is required. After firing the `AskUserQuestion`, await
the user's reply before any further action, do not advance topics,
dispatch research, or author anything on the assumption the recommended
option was taken.

---

## Rule 6: Research dispatch announce

When a discovery question requires prior-art lookup, repo-convention
inspection, or competitive comparison, the PO dispatches a research
subagent. **Before** dispatch, the PO announces:

### Research dispatch phrasing: NORMATIVE

```
Dispatching research agent for <question>.
```

Slot semantics:

- `<question>`: the exact question the subagent will research.
  Quote it back so the user knows what was sent and can correct
  scope before the subagent runs.

After announcing, the PO performs the dispatch by calling the Agent
tool (`subagent_type: general-purpose`) with `<question>` as the task,
the announce line above is narration, not the dispatch itself. Findings
are folded into `research_summary` of the SPEC. The PO never asks the
human to do the research themselves.

---

## Rule 7: Coach voice, not interrogator

All prompts read as a thinking partner, not a checklist. Mirror back
what the user said. Name the trade-offs the PO is weighing. Propose
candidates when the user is stuck. See `system-prompt.md` for the
persona contract.

---

## Topic-bank scaffolding (suggested seed)

The PO seeds its topic plan from these defaults and adapts to the
feature at hand. Each topic carries a `Suggest` field, a fallback
candidate the PO offers when the user shrugs or asks "what would you
pick?" (borrowed from SEED's prevent-dead-ends pattern).

| Topic      | First question to seed it                                              | Suggest                                     |
| ---------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| Intent     | What outcome are you actually trying to create here?                   | The shortest sentence that survives review. |
| User       | Who is this for, and how do you know?                                  | The user you talked to last about this.     |
| Success    | What signals success after five real uses?                             | The metric you'd quote to a stakeholder.    |
| Scope      | What's in, what's deliberately out, what's adjacent?                   | The cut that ships in one week.             |
| UATs       | What three observations would prove this works?                        | One UAT per success criterion.              |
| Trade-offs | What are you giving up to ship this version?                           | Naming the cost honestly.                   |
| Risk       | What's the most likely way this lands and we regret it?                | The failure mode you've seen before.        |
| Prior art  | What does the closest existing thing do, and where does it fall short? | Dispatch research subagent.                 |

The topic bank is editable. Adding a topic here makes it available
to every future `/gaia-spec` session.
