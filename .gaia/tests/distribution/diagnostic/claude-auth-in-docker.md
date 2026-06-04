# Claude Auth in Docker; Verification Runbook

**Status:** Verified 2026-05-08: `CLAUDE_CODE_OAUTH_TOKEN` attributes to
subscription, cost $0/run on a Claude Max host. See `## Findings` below.

## What's settled vs. what isn't

The official Claude Code dev-container docs at
<https://code.claude.com/docs/en/devcontainer> settle the auth _mechanism_:

- **OAuth token via `claude setup-token`**; generates a long-lived
  `CLAUDE_CODE_OAUTH_TOKEN` you inject as a container env var. Designed
  for headless / non-interactive use.
- **API key via `ANTHROPIC_API_KEY`**; pay-as-you-go fallback.
- **Browser sign-in inside the container, persisted in a named volume**
 ; supported but only useful for interactive editor flows.

The docs also explicitly discourage bind-mounting the host's `~/.claude/`
directory ("Avoid mounting host secrets … prefer repository-scoped or
short-lived tokens"). Earlier drafts of this runbook tested that path
removed.

What the docs do NOT settle, and what this runbook still has to verify:

- ~~Does `CLAUDE_CODE_OAUTH_TOKEN` attribute to subscription billing, or
  silently bill as API?~~ **Resolved 2026-05-08** (see `## Findings`):
  attributes to subscription on a Claude Max host. No API/pay-as-you-go
  billing observed for in-container calls.
- ~~Token lifetime and refresh behavior.~~ **Resolved 2026-05-08**:
  `claude setup-token` issues a 1-year OAuth token. Rotation cadence,
  failure mode on expiry, and refresh procedure documented in `## Findings`.

## Why this matters

Future Layer 2 distribution tests (Docker-based, see plan README §Q2) need
to invoke `claude` to validate end-to-end adopter flows like `/gaia-init`,
`/setup-cloned-gaia-project`, and `/gaia-plan`. Per-run cost depends on which auth path
activates:

1. **OAuth token attributes to subscription**; **$0 marginal per run.**
2. **OAuth token silently bills as API**; **~$0.05 per `/gaia-init`** at
   current pricing assumptions.
3. **API key only**; same ~$0.05/run as (2) but at least it's expected.

If Layer 2 ships without confirming (1) vs (2), GAIA's CI bill becomes
opaque.

## The experiment

Run on a Linux host with Docker installed and an active Claude Code
subscription on the host.

### Step 1; Baseline: confirm subscription on host

```bash
claude /status
```

Expected: subscription tier shown, no API-key-mode indicator.

If output looks like `API key mode`, your host is already on API key
skip to Step 4 (you can't verify subscription attribution without an
active subscription on the host).

### Step 2; Generate a long-lived OAuth token

```bash
claude setup-token
```

Copy the printed token into a local env file you don't commit:

```bash
echo 'CLAUDE_CODE_OAUTH_TOKEN=<paste>' > /tmp/claude-probe.env
chmod 600 /tmp/claude-probe.env
```

### Step 3; Build a minimal Claude-in-container image

```bash
mkdir /tmp/claude-auth-probe && cd /tmp/claude-auth-probe
cat > Dockerfile <<'EOF'
FROM node:22-bullseye-slim
RUN apt-get update && apt-get install -y curl ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
WORKDIR /work
EOF
docker build -t gaia-claude-probe .
```

(Adjust install URL against the [official install docs][install] at
experiment time. The point isn't the install command; it's the auth
behavior at runtime.)

[install]: https://docs.claude.com/en/docs/claude-code/setup

### Step 4; Subscription-via-OAuth-token attribution test

```bash
docker run --rm \
  --env-file /tmp/claude-probe.env \
  gaia-claude-probe \
  claude --version

docker run --rm \
  --env-file /tmp/claude-probe.env \
  gaia-claude-probe \
  claude --print "Reply with the single word: ok"
```

(Slash commands like `claude /status` need an interactive REPL and don't
work under `docker run` without a TTY; use `claude --version` as the
sanity-check sentinel that the binary is on PATH and runnable.)

Then check **Anthropic Console → Usage** at
<https://console.anthropic.com/settings/usage>. Note: `console.anthropic.com`
is the **API** console; subscription/Max usage is NOT itemized there.
Interpret as follows:

- **Nothing recorded on console.anthropic.com → Usage** + container call
  succeeded (returned a real response, no auth error) → OAuth token
  attributed to subscription. **Layer 2 tests are $0/run.** This is the
  desired outcome. The absence is the positive signal; per-call
  itemization on Max plans isn't exposed.
- Calls appearing under **API / pay-as-you-go** usage → OAuth token
  silently bills as API. **Layer 2 tests are ~$X/run.** Still feasible
  at API cost; weigh against budget before wiring Layer 2.
- Container call returned an auth error or the request failed → check
  container logs; likely a network issue or token expiry.

### Step 5; API-key fallback cost reference

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

### Step 6; Document findings

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

## Findings

**Verified 2026-05-08** by Steven Sacks.

### Host environment

- **OS:** macOS 26.4.1 (build 25E253)
- **Docker:** 29.4.2 (build 055a478)
- **Claude Code on host:** 2.1.132
- **Claude Code in container:** 2.1.132 (installed via `claude.ai/install.sh`
  inside `node:22-bullseye-slim`; resolved to `/root/.local/bin/claude` →
  `/root/.local/share/claude/versions/2.1.132`)
- **Subscription tier:** Claude Max (20x), org `stevensacks@gmail.com's Organization`

### Working docker invocation

```bash
docker run --rm \
  --env-file /tmp/claude-probe.env \
  gaia-claude-probe \
  claude --print "Reply with the single word: ok"
```

Returned `ok`; auth via `CLAUDE_CODE_OAUTH_TOKEN` succeeded, model
produced a real response.

### Anthropic Console attribution

Checked <https://console.anthropic.com/settings/usage> repeatedly across
hour / day / month scopes for 2026-05-08. **No entry recorded** for the
container call (and no API usage anywhere in May 2026 on this account).

The Claude Max (20x) plan's usage view at claude.ai does not itemize
per-call usage at the 20x tier; a single small prompt does not visibly
move the consumption indicator; so positive subscription-side
itemization could not be observed.

The combination; successful in-container response + no auth error +
zero API/pay-as-you-go billing; confirms by elimination that
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` attributes to the
Max subscription, not API pay-as-you-go.

### Cost-per-run measurement

**$0 marginal** on a Claude Max host. Layer 2 distribution tests that
shell out to `claude --print` from inside Docker run at zero per-run cost
on contributors with active Max subscriptions.

(API-key baseline not measured; Step 5 was skipped per the runbook's
"skip if Step 4 attributed to subscription" instruction.)

### Token expiry / refresh

**Lifetime: 1 year from issuance.** Tokens issued by `claude setup-token`
expire ~365 days after generation.

The CI org secret was first populated 2026-05-08, so rotation is due by
**2027-05-08**. Failure mode after expiry: in-container `claude --print`
calls return an auth error and Layer 2 scenarios fail with a non-zero
exit; the pre-publish gate inside `release.yml` halts the release until
the secret is rotated.

Rotation procedure:

1. On a host with an active Claude subscription, run `claude setup-token`
   to issue a fresh token.
2. Update GAIA's GitHub organization secret `CLAUDE_CODE_OAUTH_TOKEN`
   (Settings → Secrets and variables → Actions → Organization secrets).
3. Optionally run `gh workflow run distribution.yml --ref main` to
   confirm the new token authenticates from a runner before the next
   release.

Refresh-without-replay (renewing an existing token in place) is not
supported; `setup-token` always issues a new token; rotation means
generating + replacing.

### Bugs found and corrected during this run

- **Step 3 Dockerfile PATH was wrong.** `claude.ai/install.sh` installs
  to `/root/.local/bin/claude` (symlinked to
  `/root/.local/share/claude/versions/<version>`), not `/root/.claude/local/`.
  Step 3 corrected.
- **Step 4 `claude /status` doesn't work in headless `docker run`.** Slash
  commands need an interactive REPL; the non-TTY container exits with
  `Cannot find module '/work/claude'` because node's docker-entrypoint
  falls back to treating `claude` as a JS path. Step 4 now uses
  `claude --version` as the sanity-check sentinel instead.
- **Step 4 attribution interpretation was misleading.** The original
  text implied subscription usage would appear in console.anthropic.com.
  It does not; `console.anthropic.com` is the API console; Max usage is
  not itemized there. Reworded so absence-from-API + successful container
  call is the correct positive signal.

## When to revisit

Repeat the experiment when:

- Anthropic changes how `setup-token` issues or attributes tokens.
- `CLAUDE_CODE_OAUTH_TOKEN` semantics shift across a major Claude Code
  release.
- The host or container `claude` version moves by a major version.
- Subscription billing model changes (e.g. seat-based → call-based).

The file is the institutional memory; commits to it are the changelog.
