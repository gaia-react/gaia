---
type: decision
status: active
date: 2026-10-08
created: 2026-10-08
updated: 2026-10-08
tags: [decision, hooks, performance]
---

# Per-call Bash hook cost cut

Every tool call pays for every hook registered on its matcher, so hook process count is a per-call tax. A typical Bash call runs about 14 hook processes and 12 `jq` processes, about 500 ms of summed hook wall time (Claude Code 2.1.293). Read and Grep calls each run one guard and one `jq`.

## Decisions

- **`if` gating on advisory hooks only.** Advisory hooks (token tallies, artifact capture, the debt sentinel, the issue-claim release, the doctrine inject) carry an `if` rule in `.claude/settings.json`, so Claude Code spawns them only for matching commands. Deny guards never use `if`: they must run on every call. A Claude Code version that ignores `if` runs the gated hooks on every call, which costs time but loses nothing. A live probe pins which command shapes spawn each gated hook. Claude Code does not dedupe identical PostToolUse handlers, so a chain matching two of one hook's rules spawns it twice; the doctrine inject's per-session marker makes the second run inject nothing.
- **One payload read per hook.** `.claude/hooks/lib/hook-payload.sh` reads every payload field a hook needs with one `jq` call into shared globals. A hook calls the reader at line start so the jq-availability lint sees it. An empty or unreadable payload exits 0 in the guards.
- **One read-side guard.** `block-sensitive-read.sh` is the whole read-side guard for dotenv files and key, certificate and credential paths across Read, Grep, Bash and Monitor; an input matching both classes gets the dotenv reason. `block-secrets-write.sh` carries the dotenv write-path deny. `.claude/hooks/lib/git-segments.sh` is the shared git segment walker, with an early exit that skips `--git-common-dir` calls on read-only git commands.

## Related

- [[Claude Hooks]]
