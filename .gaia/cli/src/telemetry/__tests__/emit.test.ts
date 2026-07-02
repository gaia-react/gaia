/* eslint-disable no-bitwise -- POSIX file mode masking */
/* eslint-disable no-underscore-dangle -- `_local` is the SPEC-mandated
   mentorship-namespace key. */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {writeMentorshipConfig} from '../../mentorship/config.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../../storage/paths.js';
import type {StorageRoots} from '../../storage/paths.js';
import {handleEmit} from '../emit.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-emit-repo-'));
  const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-emit-home-'));
  const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
      rmSync(homeDirectory, {force: true, recursive: true});
    },
    homeDirectory,
    repoRoot,
    roots,
  };
};

const enableMentorship = async (roots: StorageRoots): Promise<void> => {
  await ensureMentorshipDirectories(roots);
  writeMentorshipConfig({
    analyticsEnabled: true,
    decidedVia: 'gaia-init',
    enabled: true,
    roots,
  });
};

const todayJsonl = (directory: string): string => {
  const now = new Date();
  const yyyy = now.getUTCFullYear().toString().padStart(4, '0');
  const mm = (now.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = now.getUTCDate().toString().padStart(2, '0');

  return path.join(directory, `events-${yyyy}-${mm}-${dd}.jsonl`);
};

const readLines = (filePath: string): string[] => {
  if (!existsSync(filePath)) return [];

  return readFileSync(filePath, 'utf8').split('\n').filter(Boolean);
};

const goodUatPassArgv = [
  'uat_pass',
  '--uat-id',
  'UAT-007',
  '--spec-id',
  'SPEC-014',
  '--task-id',
  'TASK-093',
  '--attempts',
  '1',
  '--area-tags',
  'visual,react,form',
  '--agent-type',
  'Senior',
  '--session-hash',
  'a'.repeat(32),
];

const timeToResolvedArgv = (abandoned: string): string[] => [
  'time_to_resolved_spec',
  '--spec-id',
  'SPEC-014',
  '--question-count',
  '10',
  '--duration-seconds',
  '1800',
  '--area-tags',
  'visual',
  '--abandoned',
  abandoned,
];

describe('handleEmit', () => {
  let sandbox: Sandbox;
  let stderrSpy: ReturnType<typeof vi.spyOn>;
  let stdoutSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stderrSpy = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);
    stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation(() => true);
  });

  afterEach(() => {
    sandbox.cleanup();
    stderrSpy.mockRestore();
    stdoutSpy.mockRestore();
  });

  test('UAT-008: writes one line to mentorship + cloud when enabled', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    // No stdout writes on the happy path.
    expect(stdoutSpy).not.toHaveBeenCalled();

    const cloudFile = todayJsonl(sandbox.roots.cloudDir);
    const mentorshipFile = todayJsonl(sandbox.roots.mentorshipDir);

    expect(readLines(cloudFile)).toHaveLength(1);
    expect(readLines(mentorshipFile)).toHaveLength(1);

    // Cloud file has mode 644.
    expect(statSync(cloudFile).mode & 0o777).toBe(0o644);
    // Mentorship file has mode 600.
    expect(statSync(mentorshipFile).mode & 0o777).toBe(0o600);

    const mentorshipLine = JSON.parse(
      readLines(mentorshipFile)[0] ?? '{}'
    ) as Record<string, unknown>;
    const cloudLine = JSON.parse(readLines(cloudFile)[0] ?? '{}') as Record<
      string,
      unknown
    >;

    expect(mentorshipLine.event_type).toBe('uat_pass');
    expect(cloudLine.event_type).toBe('uat_pass');
    expect(cloudLine._local).toBeUndefined();
    expect(mentorshipLine.schema_version).toBe(1);
  });

  test('--abandoned false emits abandoned: false (success path)', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(timeToResolvedArgv('false'), {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    const cloudLine = JSON.parse(
      readLines(todayJsonl(sandbox.roots.cloudDir))[0] ?? '{}'
    ) as {payload?: Record<string, unknown>};
    expect(cloudLine.payload?.abandoned).toBe(false);
  });

  test('--abandoned true emits abandoned: true (abandoned-exit path)', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(timeToResolvedArgv('true'), {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    const cloudLine = JSON.parse(
      readLines(todayJsonl(sandbox.roots.cloudDir))[0] ?? '{}'
    ) as {payload?: Record<string, unknown>};
    expect(cloudLine.payload?.abandoned).toBe(true);
  });

  test('--auto true lands in both mentorship + cloud payloads (no drift)', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(
      [...timeToResolvedArgv('false'), '--auto', 'true'],
      {roots: sandbox.roots}
    );

    expect(exit).toBe(EXIT_CODES.OK);

    const cloudLine = JSON.parse(
      readLines(todayJsonl(sandbox.roots.cloudDir))[0] ?? '{}'
    ) as {payload?: Record<string, unknown>};
    const mentorshipLine = JSON.parse(
      readLines(todayJsonl(sandbox.roots.mentorshipDir))[0] ?? '{}'
    ) as {payload?: Record<string, unknown>};

    expect(cloudLine.payload?.auto).toBe(true);
    expect(mentorshipLine.payload?.auto).toBe(true);
  });

  test('omitting --auto leaves the field absent (human-mode default)', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(timeToResolvedArgv('false'), {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    const cloudLine = JSON.parse(
      readLines(todayJsonl(sandbox.roots.cloudDir))[0] ?? '{}'
    ) as {payload?: Record<string, unknown>};
    expect(cloudLine.payload).not.toHaveProperty('auto');
  });

  test('--abandoned rejects a non-boolean value, no writes', async () => {
    await enableMentorship(sandbox.roots);

    const exit = await handleEmit(timeToResolvedArgv('nope'), {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
    expect(existsSync(todayJsonl(sandbox.roots.cloudDir))).toBe(false);
  });

  test('UAT-009: writes only cloud when mentorship is disabled', async () => {
    // No `enableMentorship` call -> readMentorshipConfig returns the pre-decision default.
    const exit = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);

    const cloudFile = todayJsonl(sandbox.roots.cloudDir);
    const mentorshipFile = todayJsonl(sandbox.roots.mentorshipDir);

    expect(readLines(cloudFile)).toHaveLength(1);
    expect(existsSync(mentorshipFile)).toBe(false);
    // Mentorship dir tree should not have been created either.
    expect(existsSync(sandbox.roots.mentorshipDir)).toBe(false);
  });

  test('UAT-010: unknown event_type exits non-zero with structured stderr, no writes', async () => {
    const exit = await handleEmit(
      ['no_such_event_type', '--spec-id', 'SPEC-014'],
      {
        roots: sandbox.roots,
      }
    );

    expect(exit).toBe(EXIT_CODES.UNKNOWN_EVENT_TYPE);
    expect(stderrSpy).toHaveBeenCalled();

    const stderrCall = stderrSpy.mock.calls[0]?.[0] as string;
    const payload = JSON.parse(stderrCall) as Record<string, unknown>;
    expect(payload.code).toBe('unknown_event_type');
    expect(payload.event_type).toBe('no_such_event_type');

    expect(existsSync(todayJsonl(sandbox.roots.cloudDir))).toBe(false);
  });

  test('UAT-011: malformed payload exits non-zero, names missing fields, no writes', async () => {
    await enableMentorship(sandbox.roots);

    // Missing spec-id, task-id, attempts, area-tags.
    const exit = await handleEmit(['uat_pass', '--uat-id', 'UAT-007'], {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
    expect(stderrSpy).toHaveBeenCalled();

    const stderrCall = stderrSpy.mock.calls[0]?.[0] as string;
    const payload = JSON.parse(stderrCall) as Record<string, unknown>;
    expect(payload.code).toBe('payload_validation_failed');
    // Issue list should mention the missing fields.
    const issues = JSON.stringify(payload.issues);
    expect(issues).toMatch(/spec_id|area_tags|attempts|task_id/u);

    expect(existsSync(todayJsonl(sandbox.roots.cloudDir))).toBe(false);
    expect(existsSync(todayJsonl(sandbox.roots.mentorshipDir))).toBe(false);
  });

  test('UAT-012/025: idempotent, same content twice yields one line per stream', async () => {
    await enableMentorship(sandbox.roots);

    const first = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});
    const second = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    expect(first).toBe(EXIT_CODES.OK);
    expect(second).toBe(EXIT_CODES.OK);

    const cloudFile = todayJsonl(sandbox.roots.cloudDir);
    const mentorshipFile = todayJsonl(sandbox.roots.mentorshipDir);

    expect(readLines(cloudFile)).toHaveLength(1);
    expect(readLines(mentorshipFile)).toHaveLength(1);
  });

  test('UAT-013: cloud line never carries _local or forbidden fields', async () => {
    await enableMentorship(sandbox.roots);

    // Pass a `--local` blob carrying identity-bearing fields. Mentorship
    // line should retain it; cloud line must not.
    const argv = [
      ...goodUatPassArgv,
      '--local',
      JSON.stringify({git_author_email: 'leak@example.com'}),
    ];
    const exit = await handleEmit(argv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);

    const cloudLine = readLines(todayJsonl(sandbox.roots.cloudDir))[0] ?? '';
    expect(cloudLine).not.toContain('_local');
    expect(cloudLine).not.toContain('git_author_email');
    expect(cloudLine).not.toContain('leak@example.com');

    // Mentorship line preserves _local for in-session adaptation.
    const mentorshipLine =
      readLines(todayJsonl(sandbox.roots.mentorshipDir))[0] ?? '';
    expect(mentorshipLine).toContain('_local');
    expect(mentorshipLine).toContain('leak@example.com');
  });

  test('writes the project-id file as a side effect of cloud emit (UAT-002)', async () => {
    expect(existsSync(sandbox.roots.projectIdPath)).toBe(false);

    const exit = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(existsSync(sandbox.roots.projectIdPath)).toBe(true);
    expect(statSync(sandbox.roots.projectIdPath).mode & 0o777).toBe(0o644);
  });

  test('rejects an invalid --agent-type flag value', async () => {
    const argv = [...goodUatPassArgv];
    const index = argv.indexOf('--agent-type');
    argv[index + 1] = 'engineer'; // not in AgentTypeSchema enum

    const exit = await handleEmit(argv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
    expect(existsSync(todayJsonl(sandbox.roots.cloudDir))).toBe(false);
  });

  test('emits a cloud-only event type with envelope-validation only', async () => {
    const exit = await handleEmit(
      ['pr_merged', '--session-hash', 'b'.repeat(32), '--agent-type', 'human'],
      {roots: sandbox.roots}
    );

    expect(exit).toBe(EXIT_CODES.OK);
    expect(readLines(todayJsonl(sandbox.roots.cloudDir))).toHaveLength(1);
    // Mentorship not enabled by default, so nothing lands in mentorship stream.
    expect(existsSync(todayJsonl(sandbox.roots.mentorshipDir))).toBe(false);
  });

  test('treats a pre-existing mentorship.json with enabled:false as disabled', async () => {
    // Write mentorship.json with explicit disabled state.
    writeMentorshipConfig({
      analyticsEnabled: false,
      decidedVia: 'mentorship-disable',
      enabled: false,
      roots: sandbox.roots,
    });

    const exit = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(readLines(todayJsonl(sandbox.roots.cloudDir))).toHaveLength(1);
    expect(existsSync(sandbox.roots.mentorshipDir)).toBe(false);
  });

  test('rejects unknown CLI flag with structured error', async () => {
    const exit = await handleEmit(['uat_pass', '--no-such-flag', 'x'], {
      roots: sandbox.roots,
    });

    expect(exit).toBe(EXIT_CODES.PAYLOAD_VALIDATION_FAILED);
    expect(stderrSpy).toHaveBeenCalled();
  });

  test('fails loud on a corrupted mentorship.json (no silent fallback)', async () => {
    // Manually write a malformed mentorship.json (not via writeMentorshipConfig).
    const localDirectory = path.dirname(sandbox.roots.projectIdPath);
    const fs = await import('node:fs');
    fs.mkdirSync(localDirectory, {mode: 0o755, recursive: true});
    writeFileSync(
      path.join(localDirectory, 'mentorship.json'),
      '{not valid json'
    );

    const exit = await handleEmit(goodUatPassArgv, {roots: sandbox.roots});

    // The corrupted-config read throws synchronously; we surface it as an
    // internal CLI error. The UNKNOWN_SUBCOMMAND code is the catch-all from
    // the top-level wrapper; here we check it is non-zero (the actual code
    // will depend on the throw site; the contract is "fail loud").
    expect(exit).not.toBe(EXIT_CODES.OK);
    expect(existsSync(todayJsonl(sandbox.roots.cloudDir))).toBe(false);
  });
});
