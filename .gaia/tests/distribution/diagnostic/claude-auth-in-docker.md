# Claude Auth in Docker — Verification Runbook

**Status:** Not yet verified. Run the experiment below and update this file
with the outcome.

## Why this matters

Future Layer 2 distribution tests (Docker-based, see plan README §Q2) need
to invoke `claude` to validate end-to-end adopter flows like `/gaia-init`,
`/setup-gaia`, and `/gaia plan`. Three auth shapes are possible inside a
container:

1. **Host subscription propagates** — token in `~/.claude/` is bound to the
   host but readable from the container; the API recognizes it and
   subscription billing applies. **Cost: $0 marginal per test run.**
2. **API key fallback** — container has `ANTHROPIC_API_KEY` set; calls
   bill against pay-as-you-go pricing. **Cost: ~$0.05 per `/gaia-init`
   run by current pricing assumptions.**
3. **Auth fails** — neither propagates; tests can't invoke Claude in
   containers. Layer 2 Claude-invoking tests blocked.

The cost difference (1) vs (2) compounds over CI runs. If Layer 2 ships
without verifying which path activates, GAIA's CI bill becomes opaque.

## The experiment

Run on a Linux host with Docker installed and an active Claude Code
subscription on the host.

### Step 1 — Baseline: confirm subscription on host

```bash
# Should report your subscription state.
claude /status
```

Expected: subscription tier shown, no API-key-mode indicator.

If output looks like `API key mode`, your host is already on API key —
skip to Step 4 (you can't verify subscription propagation without an
active subscription on the host).

### Step 2 — Build a minimal Claude-in-container image

```bash
mkdir /tmp/claude-auth-probe && cd /tmp/claude-auth-probe
cat > Dockerfile <<'EOF'
FROM node:22-bullseye-slim
RUN apt-get update && apt-get install -y curl ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.claude/local:${PATH}"
WORKDIR /work
EOF
docker build -t gaia-claude-probe .
```

(Adjust `claude` install URL if it has changed; cross-reference with the
[official install docs](https://docs.claude.com/en/docs/claude-code/setup) at
experiment time. The point isn't the install command — it's the auth
behavior at runtime.)

### Step 3 — Subscription propagation test

Mount the host's `~/.claude/` directory read-only and probe:

```bash
docker run --rm \
  -v "$HOME/.claude:/root/.claude:ro" \
  -e CLAUDE_CONFIG_DIR=/root/.claude \
  gaia-claude-probe \
  claude /status
```

**Possible outcomes:**

- **Reports subscription tier.** Subscription propagates. Layer 2 tests
  are free. Update this file Status to `Verified: subscription propagates
  via $HOME/.claude bind-mount, cost $0/run`. Document any caveats
  observed.
- **Reports API-key-mode or auth error.** Subscription does NOT propagate.
  Goto Step 4.
- **Errors out before reaching Anthropic.** Container missing a
  dependency. Fix and rerun.

### Step 4 — API-key fallback cost check

Skip if Step 3 succeeded.

If subscription doesn't propagate, the alternative is `ANTHROPIC_API_KEY`
env-var auth. **Do not run this against your real API key without budget
caps in place.** Set a $1 monthly cap on the key first; one-prompt
experiments are well under the cap.

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  gaia-claude-probe \
  claude /status

docker run --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  gaia-claude-probe \
  claude --print "Reply with the single word: ok"
```

Inspect Anthropic Console → Usage. The print-prompt should show ~50-200
tokens billed at API pricing. **Cost: $0.001-$0.005 per run depending on
model selection.**

If this works, Layer 2 tests are feasible at API cost. Update this file's
Status accordingly with measured per-run cost.

### Step 5 — Document findings

Replace this file's `Status:` field with one of:

- `Verified <YYYY-MM-DD>: subscription propagates via bind-mount, cost $0/run.`
- `Verified <YYYY-MM-DD>: subscription does NOT propagate; API-key fallback works at ~$X.XX/run.`
- `Verified <YYYY-MM-DD>: neither path works; Layer 2 Claude tests blocked.`

Then add a `## Findings` section below the experiment with:

- The host environment (OS, Docker version, claude version).
- Exact docker invocation that worked / didn't work.
- Observed `claude /status` output.
- Cost-per-run measurement for the working path.
- Any caveats (e.g. token expiry windows, multi-tenant account quirks).

## When to revisit

Repeat the experiment when:

- Anthropic ships a major change to Claude Code auth.
- The `claude` CLI version on the host or in Docker shifts by a major
  version.
- A subscription quirk surfaces (e.g. token revocation, multi-account
  behavior).

The file is the institutional memory; commits to it are the changelog.
