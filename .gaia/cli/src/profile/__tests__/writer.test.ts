/* eslint-disable no-bitwise -- POSIX file mode bit masking. */
/* eslint-disable testing-library/render-result-naming-convention --
   `renderProfile` produces a markdown string for a CLI tool, not a React
   render result; the testing-library rule triggers on any `render*`
   identifier without scoping to React. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
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
import {PROFILE_DO_NOT_EDIT_HEADER} from '../header.js';
import type {PatternResult} from '../patterns/types.js';
import {atomicWriteProfile, renderProfile} from '../writer.js';
import type {AdaptationRecord} from '../writer.js';

const fixedNow = new Date('2026-05-07T12:34:56.789Z');

describe('renderProfile', () => {
  test('UAT-036: top line is exactly the DO-NOT-EDIT header', () => {
    const output = renderProfile({
      adaptations: [],
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns: [],
      windowDays: 30,
    });

    const firstLine = output.split('\n')[0];
    expect(firstLine).toBe(PROFILE_DO_NOT_EDIT_HEADER);
  });

  test('renders the empty/inert state with (none) sections', () => {
    const output = renderProfile({
      adaptations: [],
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns: [],
      windowDays: 30,
    });

    expect(output).toContain('## Active patterns');
    expect(output).toContain(
      '(none - all patterns below sample threshold or strength below threshold)'
    );
    expect(output).toContain('## Active adaptations');
    expect(output).toContain('## Faded adaptations');
    expect(output).toMatch(/## Active adaptations\n\n\(none\)/u);
    expect(output).toMatch(/## Faded adaptations\n\n\(none\)/u);
  });

  test('renders generation metadata in the header block', () => {
    const output = renderProfile({
      adaptations: [],
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns: [],
      windowDays: 30,
    });

    expect(output).toContain(`Generated: ${fixedNow.toISOString()}`);
    expect(output).toContain('Window: last 30 days');
    expect(output).toContain('Mentorship enabled: true');
  });

  test('UAT-029: pattern with strength=null surfaces "below sample threshold"', () => {
    const patterns: PatternResult[] = [
      {
        area_tag: 'visual',
        components: [
          {metric: 'matching_events', value: 4},
          {metric: 'total_tasks_in_area', value: 20},
          {metric: 'rate', value: 0.2},
        ],
        pattern_id: 'articulation_gap',
        sample_count: 4,
        strength: null,
      },
    ];

    const output = renderProfile({
      adaptations: [],
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns,
      windowDays: 30,
    });

    expect(output).toContain(
      'visual: below sample threshold (N=4, min 10) - no fire'
    );
  });

  test('UAT-030: fired pattern lists active pattern + active adaptation', () => {
    const patterns: PatternResult[] = [
      {
        area_tag: 'visual',
        components: [
          {metric: 'matching_events', value: 30},
          {metric: 'total_tasks_in_area', value: 50},
          {metric: 'rate', value: 0.6},
        ],
        pattern_id: 'articulation_gap',
        sample_count: 30,
        strength: 1,
      },
    ];
    const adaptations: AdaptationRecord[] = [
      {
        adaptation_id: 'po_socratic_depth_increased',
        area_tag: 'visual',
        effective_strength: 1,
        fade_factor: 1,
        pattern_id: 'articulation_gap',
        raw_strength: 1,
        sample_count: 30,
        status: 'active',
      },
    ];

    const output = renderProfile({
      adaptations,
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns,
      windowDays: 30,
    });

    expect(output).toMatch(
      /## Active patterns\n\n- articulation_gap \(visual\)/u
    );
    expect(output).toMatch(
      /## Active adaptations\n\n- po_socratic_depth_increased \(visual,/u
    );
    expect(output).toMatch(/## Faded adaptations\n\n\(none\)/u);
  });

  test('UAT-031: adaptations move to faded section when status is faded', () => {
    const adaptations: AdaptationRecord[] = [
      {
        adaptation_id: 'po_socratic_depth_increased',
        area_tag: 'visual',
        effective_strength: 0.1,
        fade_factor: 0.1,
        pattern_id: 'articulation_gap',
        raw_strength: 1,
        sample_count: 30,
        status: 'faded',
      },
    ];
    const output = renderProfile({
      adaptations,
      generatedAt: fixedNow,
      mentorshipEnabled: true,
      patterns: [],
      windowDays: 30,
    });

    expect(output).toMatch(/## Active adaptations\n\n\(none\)/u);
    expect(output).toMatch(
      /## Faded adaptations\n\n- po_socratic_depth_increased \(visual,/u
    );
  });
});

describe('atomicWriteProfile (UAT-035)', () => {
  let directory: string;
  let profilePath: string;

  beforeEach(() => {
    directory = mkdtempSync(path.join(tmpdir(), 'gaia-profile-write-'));
    profilePath = path.join(directory, 'profile.md');
  });

  afterEach(() => {
    rmSync(directory, {force: true, recursive: true});
  });

  test('writes the file with mode 0o600', async () => {
    await atomicWriteProfile(profilePath, 'hello\n');

    expect(existsSync(profilePath)).toBe(true);
    expect(statSync(profilePath).mode & 0o777).toBe(0o600);
    expect(readFileSync(profilePath, 'utf8')).toBe('hello\n');
  });

  test('overwrites a prior file atomically (no half-written state)', async () => {
    writeFileSync(profilePath, 'old contents\n', {mode: 0o600});

    await atomicWriteProfile(profilePath, 'new contents\n');

    expect(readFileSync(profilePath, 'utf8')).toBe('new contents\n');
  });

  test('does not leave a temp sibling behind', async () => {
    await atomicWriteProfile(profilePath, 'hello\n');

    const fs = await import('node:fs');
    const entries = fs.readdirSync(directory);
    expect(entries.some((entry) => entry.includes('.tmp'))).toBe(false);
  });
});
