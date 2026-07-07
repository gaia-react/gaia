/* eslint-disable no-bitwise -- POSIX file mode bit masking. */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
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
import {PROFILE_DO_NOT_EDIT_HEADER} from '../header.js';
import {computeProfile} from '../index.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-profile-repo-'));
  const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-profile-home-'));
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

const enableMentorship = async (
  roots: StorageRoots,
  analyticsEnabled: boolean
): Promise<void> => {
  await ensureMentorshipDirectories(roots);
  writeMentorshipConfig({
    analyticsEnabled,
    decidedVia: 'gaia-init',
    enabled: true,
    roots,
  });
};

const FIXED_NOW = new Date('2026-05-07T12:00:00.000Z');

const writeJsonlLine = (filePath: string, payload: object): void => {
  appendFileSync(filePath, `${JSON.stringify(payload)}\n`, {mode: 0o600});
};

const todayJsonl = (mentorshipDirectory: string, now: Date): string => {
  const yyyy = now.getUTCFullYear().toString().padStart(4, '0');
  const mm = (now.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = now.getUTCDate().toString().padStart(2, '0');

  return path.join(mentorshipDirectory, `events-${yyyy}-${mm}-${dd}.jsonl`);
};

describe('computeProfile', () => {
  let sandbox: Sandbox;
  let stdoutSpy: ReturnType<typeof vi.spyOn>;
  let stderrSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation(() => true);
    stderrSpy = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);
  });

  afterEach(() => {
    sandbox.cleanup();
    stdoutSpy.mockRestore();
    stderrSpy.mockRestore();
  });

  test('UAT-040: short-circuits silently when mentorship is disabled', async () => {
    // No mentorship.json written → readMentorshipConfig returns
    // pre-decision default (enabled: null) → short-circuit.
    const exit = await computeProfile({now: FIXED_NOW, roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdoutSpy).not.toHaveBeenCalled();
    expect(existsSync(sandbox.roots.profilePath)).toBe(false);
  });

  test('short-circuits when mentorship is explicitly disabled', async () => {
    writeMentorshipConfig({
      analyticsEnabled: false,
      decidedVia: 'gaia-init',
      enabled: false,
      roots: sandbox.roots,
    });

    const exit = await computeProfile({now: FIXED_NOW, roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(existsSync(sandbox.roots.profilePath)).toBe(false);
  });

  test('UAT-029 path: writes profile.md with "below sample threshold" branch when enabled with no events', async () => {
    await enableMentorship(sandbox.roots, false);

    const exit = await computeProfile({now: FIXED_NOW, roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(existsSync(sandbox.roots.profilePath)).toBe(true);

    const contents = readFileSync(sandbox.roots.profilePath, 'utf8');
    // UAT-036: top-line DO-NOT-EDIT header verbatim.
    expect(contents.split('\n', 1)[0]).toBe(PROFILE_DO_NOT_EDIT_HEADER);
    // UAT-029 default content shape: pattern detail says "below sample threshold across all areas".
    expect(contents).toContain('(below sample threshold across all areas)');
    expect(contents).toContain('## Active patterns');
    expect(contents).toContain(
      '(none - all patterns below sample threshold or strength below threshold)'
    );
    // UAT-035: file mode 600.
    expect(statSync(sandbox.roots.profilePath).mode & 0o777).toBe(0o600);
  });

  test('UAT-036: full regeneration overwrites pre-existing user-edited profile.md', async () => {
    await enableMentorship(sandbox.roots, false);
    // Pre-existing profile.md with user edits.
    mkdirSync(path.dirname(sandbox.roots.profilePath), {
      mode: 0o700,
      recursive: true,
    });
    const userEdited =
      '# my custom header\nNot the do-not-edit text\n## stuff\nuser-added content\n';
    appendFileSync(sandbox.roots.profilePath, userEdited, {mode: 0o600});

    const exit = await computeProfile({now: FIXED_NOW, roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);

    const regenerated = readFileSync(sandbox.roots.profilePath, 'utf8');
    expect(regenerated.split('\n', 1)[0]).toBe(PROFILE_DO_NOT_EDIT_HEADER);
    expect(regenerated).not.toContain('user-added content');
    expect(regenerated).not.toContain('my custom header');
  });

  test('UAT-030: synthetic 30-event articulation fixture fires the pattern', async () => {
    await enableMentorship(sandbox.roots, false);
    const eventsFile = todayJsonl(sandbox.roots.mentorshipDir, FIXED_NOW);

    // ULIDs use Crockford-base32 (no I, L, O, U). Use a 26-char digit/A-H seed.
    for (let index = 0; index < 30; index += 1) {
      writeJsonlLine(eventsFile, {
        agent_type: 'Senior',
        event_id: `01HZZZA${index.toString().padStart(19, '0')}`,
        event_type: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-001',
          task_id: `TASK-${index}`,
        },
        project_id: 'a'.repeat(32),
        schema_version: 1,
        session_hash: 'b'.repeat(32),
        timestamp: FIXED_NOW.toISOString(),
      });
    }

    // Pad denominator with 20 distinct uat_pass tasks in the same area.
    for (let index = 0; index < 20; index += 1) {
      writeJsonlLine(eventsFile, {
        agent_type: 'Senior',
        event_id: `01HZZZB${index.toString().padStart(19, '0')}`,
        event_type: 'uat_pass',
        payload: {
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-001',
          task_id: `TASK-other-${index}`,
          uat_id: 'UAT-007',
        },
        project_id: 'a'.repeat(32),
        schema_version: 1,
        session_hash: 'b'.repeat(32),
        timestamp: FIXED_NOW.toISOString(),
      });
    }

    const exit = await computeProfile({now: FIXED_NOW, roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const contents = readFileSync(sandbox.roots.profilePath, 'utf8');
    expect(contents).toMatch(
      /## Active patterns\n\n- articulation_gap \(visual\)/u
    );
    expect(contents).toContain('po_socratic_depth_increased');
  });

  test('UAT-035: concurrent compute-profile invocations leave the file well-formed', async () => {
    await enableMentorship(sandbox.roots, false);

    const both = await Promise.all([
      computeProfile({now: FIXED_NOW, roots: sandbox.roots}),
      computeProfile({now: FIXED_NOW, roots: sandbox.roots}),
    ]);
    expect(both[0]).toBe(EXIT_CODES.OK);
    expect(both[1]).toBe(EXIT_CODES.OK);

    const contents = readFileSync(sandbox.roots.profilePath, 'utf8');
    // No half-written prefix; full DO-NOT-EDIT header present.
    expect(contents.split('\n', 1)[0]).toBe(PROFILE_DO_NOT_EDIT_HEADER);
    expect(contents).toContain('## Pattern detail');
  });
});
