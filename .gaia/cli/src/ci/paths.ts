/**
 * Path constants for GAIA CI revert-ledger state.
 *
 * Mirrors `automation/paths.ts`: every helper takes an explicit
 * `repoRoot` argument; never calls `process.cwd()` directly.
 */
import path from 'node:path';

export const revertLedgerPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'automation.state-revert-attempts.json');
