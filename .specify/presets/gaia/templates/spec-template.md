---
spec_id: SPEC-NNN
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan
intent: |
  <Plain-English statement of the feature. One paragraph. Captures the
  user-facing change, the user it is for, and the value delivered.
  No implementation detail.>
success_criteria:
  - <Observable outcome that, if true, proves the feature works.>
  - <One bullet per criterion. No internal mechanism, only outcomes
    a human or test can verify from outside the system.>
uats:
  - uat_id: UAT-NNN
    given: <Initial state, preconditions a verifier can establish.>
    when: <Action, a single trigger, user-driven or system-driven.>
    then: <Observable outcome, concrete and falsifiable. No "should",
      no hedging. The verifier can read this and write a Playwright
      assertion against it.>
scope_boundaries:
  always:
    - <Behavior that MUST hold for every invocation. Imperative voice.>
  ask_first:
    - <Behavior that requires explicit human confirmation before firing.
      Default direction noted in parentheses if material.>
  never:
    - <Behavior that is forbidden. Imperative voice. No exceptions
      without an explicit reopen ceremony.>
clarifications:
  answered:
    - q: <Question surfaced during the Socratic loop.>
      a: <The settled answer. Captures the decision and the reason
        when the reason is non-obvious.>
  pending: []
research_summary: |
  <Findings from research subagent dispatches during discovery.
  Reference prior art, repo conventions, competitive comparisons.
  Group by dispatch pass when there were multiple. Plain prose.>
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

# <Feature title, short, human-readable, mirrors `intent`>

## One-line summary

<One sentence the human can drop into a PR description without editing.
Names the feature, the surface it lives on, and the user-visible win.>

## Why this exists

<Two or three short paragraphs. The problem the feature solves; the
cost of not building it; the strategic frame that makes this the right
moment to ship it. Plain English, no jargon, no acronyms without
expansion. Treat the reader as an engaged stakeholder, not an implementer.>

## How it behaves (lifecycle / shape)

<Walk the reader through the feature from invocation to outcome.
Diagrams, lifecycle blocks, or numbered phases are welcome. This
section is the cognitive scaffold for the autonomous downstream
pipeline that consumes this SPEC, the clearer this is, the cleaner
the resulting plan and tasks.>

## Constitution / preconditions

<Anything that must be true about the project, environment, or other
specs before this feature can be invoked. List explicitly. Each
precondition should map to a `before_*` hook check or an obvious
bootstrap step.>

## Out of scope (for this SPEC)

- <Adjacent capability that belongs in a separate SPEC. Name it; link
  to the SPEC ID once it exists.>
- <Slot reservations: hook signatures or extension points reserved
  here so the contract is stable, but whose logic ships in a later
  SPEC. Mark these clearly.>

## Required reading

- <Source document, design lock, or prior SPEC the implementation
  engineer should read before starting.>
- <External reference, upstream tool docs, philosophy doc, video.
  One bullet per source.>

## Cross-references

- <Wikilink or repo-relative path to related decisions, sibling SPECs,
  or downstream targets.>
