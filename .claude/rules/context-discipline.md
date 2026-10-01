# Context Discipline

- Keep the main thread lean: it decides and synthesizes, and does not read in bulk.
- Fan out work that reads much and returns little to sub-agents, and keep what they return small.
- Dispatch results follow `.claude/rules/subagent-dispatch.md`.
- Choose each model by fit to the task, from the model table in `wiki/concepts/Workflow Doctrine.md`.
- Keep durable research output under `.gaia/local/research/<topic>-<date>/`: one small current-state file, rewritten in place and never appended, plus artifacts beside it.
