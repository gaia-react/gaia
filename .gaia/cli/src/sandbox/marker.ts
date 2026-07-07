/**
 * Per-machine sandbox resolution marker at `.gaia/local/sandbox.json`
 * (UAT-012 mechanism).
 *
 * Records how THIS machine resolved the sandbox-enablement prompt: enabled
 * (applied), declined (offered, said no), or incapable (detection said
 * unsupported). Gitignored via `.gaia/local/`. Atomic write (temp+rename),
 * mode 644, mirroring `mentorship/config.ts`. `repoRoot` is resolved by the
 * caller via `resolveMainWorktreeRoot` (`setup/util/state-file.ts`) so a
 * linked worktree anchors to the same clone.
 */
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import type {Capability} from './capability.js';

export const MARKER_FILENAME = 'sandbox.json';

export type SandboxMarker = {
  capability: Capability;
  outcome: SandboxOutcome;
  resolved_at: string;
  version: 1;
};

export type SandboxOutcome = 'declined' | 'enabled' | 'incapable';

// Canonical enum vocabularies, used to reject a present-but-off-vocabulary
// hand-edited marker, matching the enum validation the sibling
// automation-config reader gets from Zod.
const CAPABILITIES: readonly Capability[] = [
  'needs-deps',
  'ready',
  'unsupported',
];
const OUTCOMES: readonly SandboxOutcome[] = [
  'declined',
  'enabled',
  'incapable',
];

export const resolveMarkerPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', MARKER_FILENAME);

export const readSandboxMarker = (repoRoot: string): null | SandboxMarker => {
  const filePath = resolveMarkerPath(repoRoot);

  if (!existsSync(filePath)) return null;

  const raw = readFileSync(filePath, 'utf8');
  const parsed = JSON.parse(raw) as Partial<SandboxMarker>;

  if (parsed.version !== 1) {
    throw new Error(
      `sandbox.json has unexpected version: ${String(parsed.version)}`
    );
  }

  if (
    typeof parsed.outcome !== 'string' ||
    typeof parsed.capability !== 'string' ||
    typeof parsed.resolved_at !== 'string'
  ) {
    // Malformed/wrong-version file: fail loud rather than silently
    // defaulting, mirroring the sibling state readers (setup-state.json).
    throw new TypeError('sandbox.json is missing required fields');
  }

  if (
    !(OUTCOMES as readonly string[]).includes(parsed.outcome) ||
    !(CAPABILITIES as readonly string[]).includes(parsed.capability)
  ) {
    // Present but off-vocabulary (e.g. a hand-edited marker): fail loud,
    // matching the enum validation the automation-config reader gets from Zod.
    throw new TypeError('sandbox.json has an unknown outcome or capability');
  }

  return {
    capability: parsed.capability,
    outcome: parsed.outcome,
    resolved_at: parsed.resolved_at,
    version: 1,
  };
};

export const writeSandboxMarker = (
  repoRoot: string,
  marker: SandboxMarker
): void => {
  const filePath = resolveMarkerPath(repoRoot);
  const parent = path.dirname(filePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  const contents = `${JSON.stringify(marker, null, 2)}\n`;

  atomicWriteFileSync(filePath, contents, {mode: 0o644});
};
