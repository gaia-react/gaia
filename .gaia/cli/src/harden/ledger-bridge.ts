/**
 * Bridge from the tally pass to the machine-local decline ledger.
 *
 * The ledger is a sibling subcommand of this same binary
 * (`gaia harden-ledger`), so the bridge re-invokes the running binary rather
 * than importing the ledger module directly: it keeps the tally bound to the
 * frozen ledger CLI contract (the verbs + exit codes), not to ledger internals.
 *
 * Contract consumed:
 *   - `harden-ledger is-suppressed --finding-class <c> --current-pr-count <n>`
 *     exits 0 when suppressed, non-zero when the class should re-surface.
 *   - `harden-ledger prune --window-classes <c1,c2,...>` self-cleans the ledger.
 *
 * The runner is injectable so the tally tests drive suppression deterministically
 * without spawning a process.
 */
import {spawnSync} from 'node:child_process';
import type {ProcessResult} from '../ci/util/run-process.js';
import {EXIT_CODES} from '../exit.js';

export type LedgerRunner = (
  argv: readonly string[],
  cwd: string
) => ProcessResult;

/**
 * Default runner: re-invokes the running binary so the ledger subcommand runs
 * against the same install. `process.argv[1]` is the entry script (the bundled
 * `gaia` under node, or the `tsx` entry in dev), `process.execPath` is the node
 * runtime.
 */
export const defaultLedgerRunner: LedgerRunner = (argv, cwd) => {
  const entry = process.argv[1] ?? '';
  const result = spawnSync(process.execPath, [entry, ...argv], {
    cwd,
    encoding: 'utf8',
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  return {
    exitCode: result.status ?? 1,
    stderr: result.stderr ?? '',
    stdout: result.stdout ?? '',
  };
};

type BridgeOptions = {
  cwd: string;
  runLedger?: LedgerRunner;
};

export const makeLedgerSuppressionPredicate = ({
  cwd,
  runLedger = defaultLedgerRunner,
}: BridgeOptions): ((findingClass: string, currentPrCount: number) => boolean) =>
  (findingClass, currentPrCount) => {
    const result = runLedger(
      [
        'harden-ledger',
        'is-suppressed',
        '--finding-class',
        findingClass,
        '--current-pr-count',
        String(currentPrCount),
      ],
      cwd
    );

    // Exit-code discrimination. OK (0) → suppressed. The legitimate
    // not-suppressed code (1, returned for both no_decline_entry and
    // threshold_reached) → not suppressed; mapping 1 → not-suppressed is safe
    // only because the bridge always supplies well-formed --finding-class /
    // --current-pr-count args, so is-suppressed's arg-error path (which also
    // exits 1) is unreachable here. Any OTHER non-zero code (CONFIG_INVALID 30
    // for a corrupt/version-skewed ledger, STORAGE_INACCESSIBLE 20, ...) is a
    // read error: fail closed → stay suppressed, so a corrupt ledger never
    // silently re-surfaces a declined candidate.
    if (result.exitCode === EXIT_CODES.OK) return true;
    if (result.exitCode === EXIT_CODES.UNKNOWN_SUBCOMMAND) return false;

    return true;
  };

type PruneOptions = BridgeOptions & {
  windowClasses: readonly string[];
};

export const pruneLedger = ({
  cwd,
  runLedger = defaultLedgerRunner,
  windowClasses,
}: PruneOptions): void => {
  runLedger(
    ['harden-ledger', 'prune', '--window-classes', windowClasses.join(',')],
    cwd
  );
};
