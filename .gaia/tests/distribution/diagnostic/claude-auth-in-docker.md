# Claude Auth in Docker — Verification Runbook

**Status:** Auth mechanism documented; billing attribution unverified. Run
the experiment below and update this file with the outcome.

## What's settled vs. what isn't

The official Claude Code dev-container docs at
<https://code.claude.com/docs/en/devcontainer> settle the auth *mechanism*:

- **OAuth token via `claude setup-token`** — generates a long-lived
  `CLAUDE_CODE_OAUTH_TOKEN` you inject as a container env var. Designed
  for headless / non-interactive use.
- **API key via `ANTHROPIC_API_KEY`** — pay-as-you-go fallback.
- **Browser sign-in inside the container, persisted in a named volume**
  — supported but only useful for interactive editor flows.

The docs also explicitly discourage bind-mounting the host's `~/.claude/`
directory ("Avoid mounting host secrets … prefer repository-scoped or
short-lived tokens"). Earlier drafts of this runbook tested that path —
removed.

What the docs do NOT settle, and what this runbook still has to verify:

- **Does `CLAUDE_CODE_OAUTH_TOKEN` attribute to subscription billing**, or
  does it silently bill against API pay-as-you-go? The doc lists it
  alongside `ANTHROPIC_API_KEY` as alternative auth, strongly implying
  different billing paths, but never says so explicitly. The cost
  difference compounds across CI runs; we need to confirm before wiring
  Layer 2 tests.
- **Token lifetime and refresh behavior.** `setup-token` says
  "long-lived" but doesn't pin a duration.

## Why this matters

Future Layer 2 distribution tests (Docker-based, see plan README §Q2) need
to invoke `claude` to validate end-to-end adopter flows like `/gaia-init`,
`/setup-gaia`, and `/gaia plan`. Per-run cost depends on which auth path
activates:

1. **OAuth token attributes to subscription** — **$0 marginal per run.**
2. **OAuth token silently bills as API** — **~$0.05 per `/gaia-init`** at
   current pricing assumptions.
3. **API key only** — same ~$0.05/run as (2) but at least it's expected.

If Layer 2 ships without confirming (1) vs (2), GAIA's CI bill becomes
opaque.

## The experiment

Run on a Linux host with Docker installed and an active Claude Code
subscription on the host.

### Step 1 — Baseline: confirm subscription on host

```bash
claude /status
```

Expected: subscription tier shown, no API-key-mode indicator.

If output looks like `API key mode`, your host is already on API key —
skip to Step 4 (you can't verify subscription attribution without an
active subscription on the host).

### Step 2 — Generate a long-lived OAuth token

```bash
claude setup-token
```

Copy the printed token into a local env file you don't commit:

```bash
echo 'CLAUDE_CODE_OAUTH_TOKEN=<paste>' > /tmp/claude-probe.env
chmod 600 /tmp/claude-probe.env
```

### Step 3 — Build a minimal Claude-in-container image

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

(Adjust install URL against the [official install docs][install] at
experiment time. The point isn't the install command — it's the auth
behavior at runtime.)

[install]: https://docs.claude.com/en/docs/claude-code/setup

### Step 4 — Subscription-via-OAuth-token attribution test

```bash
docker run --rm \
  --env-file /tmp/claude-probe.env \
  gaia-claude-probe \
  claude /status

docker run --rm \
  --env-file /tmp/claude-probe.env \
  gaia-claude-probe \
  claude --print "Reply with the single word: ok"
```

Then check **Anthropic Console → Usage**:

- Calls appearing under **subscription** usage → OAuth token attributes
  to subscription. **Layer 2 tests are $0/run.** This is the desired
  outcome.
- Calls appearing under **API** usage → OAuth token silently bills as
  API. **Layer 2 tests are ~$X/run.** Still feasible at API cost; weigh
  against budget before wiring Layer 2.
- No call recorded → check container logs; likely a network or token
  expiry issue.

### Step 5 — API-key fallback cost reference

Skip if Step 4 attributed to subscription; you don't need this path.

If you want a baseline measurement of API-key cost for comparison:

**Do not run this against your real API key without budget caps in place.**
Set a $1 monthly cap on the key first; one-prompt experiments are well
under the cap.

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  gaia-claude-probe \
  claude --print "Reply with the single word: ok"
```

Inspect Anthropic Console → Usage. The print-prompt should show ~50-200
tokens billed at API pricing. **Cost: $0.001-$0.005 per run depending on
model selection.**

### Step 6 — Document findings

Replace this file's `Status:` field with one of:

- `Verified <YYYY-MM-DD>: CLAUDE_CODE_OAUTH_TOKEN attributes to subscription, cost $0/run.`
- `Verified <YYYY-MM-DD>: CLAUDE_CODE_OAUTH_TOKEN bills as API, cost ~$X.XX/run.`
- `Verified <YYYY-MM-DD>: neither path works; Layer 2 Claude tests blocked.`

Then add a `## Findings` section below with:

- Host environment (OS, Docker version, claude version).
- Exact docker invocation that worked.
- Observed `claude /status` output inside the container.
- Anthropic Console attribution screenshot or quote (subscription vs API).
- Cost-per-run measurement.
- Token expiry / refresh observations.

## When to revisit

Repeat the experiment when:

- Anthropic changes how `setup-token` issues or attributes tokens.
- `CLAUDE_CODE_OAUTH_TOKEN` semantics shift across a major Claude Code
  release.
- The host or container `claude` version moves by a major version.
- Subscription billing model changes (e.g. seat-based → call-based).

The file is the institutional memory; commits to it are the changelog.
