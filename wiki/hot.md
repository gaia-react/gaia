---
type: meta
title: Hot Cache
status: active
created: 2026-05-26
updated: 2026-06-02
tags: [meta, cache]
---

# Recent Context

## Last Updated

2026-06-02. Unreleased work sits on top of GAIA v1.3.4.

## Key Recent Facts

- The two expensive required checks (`code-review-audit`, `Vitest and Playwright`) gate on the delta *since that check last passed green*, not the full PR diff — a passing code commit followed by a prose-only commit re-runs neither. `Run Chromatic` stays always-on. See [[Incremental CI Skipping]].
- Content-Security-Policy ships enforcing (not Report-Only); every streamed script carries a per-request nonce. See [[Content Security Policy]].
- React Router v8 future flags are enabled for readiness; pnpm supply-chain hardening adds `minimumReleaseAge` + `trustPolicy`. See [[pnpm]].

## Recent Changes

- #254 since-last-green CI gating (`resolve-check-base.sh`).
- #253 CSP enforcement.
- #252 incremental `code-review-audit` scope.
- #251 RR v8 flags + pnpm hardening + react-doctor 100/100.
- #250 dependency bumps + dev-only CVE overrides.

## Active Threads

- Live-testing the incremental CI skip on PR #255 (code → prose-only sequence).
