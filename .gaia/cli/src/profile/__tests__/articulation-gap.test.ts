import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {detectArticulationGap} from '../patterns/articulation-gap.js';
import type {MentorshipEvent} from '../reader.js';

const FIXTURE_DIRECTORY = path.join(
  process.cwd(),
  '.gaia',
  'cli',
  'test-fixtures',
  'profile'
);

const loadFixture = (filename: string): MentorshipEvent[] => {
  const filePath = path.join(FIXTURE_DIRECTORY, filename);

  if (!existsSync(filePath)) return [];
  const raw = readFileSync(filePath, 'utf8');

  return raw
    .split('\n')
    .flatMap((line) => (line ? [JSON.parse(line) as MentorshipEvent] : []));
};

const buildArticulationEvent = (
  taskId: string,
  area: string
): MentorshipEvent => ({
  agent_type: 'Senior',
  event_id: `01HZZZ${taskId.padStart(20, '0')}`,
  event_type: 'needs_context_returned',
  payload: {
    agent_type: 'Senior',
    area_tags: [area],
    context_request_class: 'unclear_acceptance_criteria',
    spec_id: 'SPEC-001',
    task_id: taskId,
  },
  project_id: 'a'.repeat(32),
  schema_version: 1,
  session_hash: 'b'.repeat(32),
  timestamp: '2026-05-07T12:00:00.000Z',
});

const buildOtherEvent = (taskId: string, area: string): MentorshipEvent => ({
  agent_type: 'Senior',
  event_id: `01HZZZOTHER${taskId.padStart(15, '0')}`,
  event_type: 'uat_pass',
  payload: {
    area_tags: [area],
    attempts: 1,
    spec_id: 'SPEC-001',
    task_id: taskId,
    uat_id: 'UAT-001',
  },
  project_id: 'a'.repeat(32),
  schema_version: 1,
  session_hash: 'b'.repeat(32),
  timestamp: '2026-05-07T12:00:00.000Z',
});

describe('detectArticulationGap (unit)', () => {
  test('UAT-029 path: <10 matching events -> strength: null', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 4; index += 1) {
      events.push(buildArticulationEvent(`TASK-${index}`, 'visual'));
    }

    // pad the denominator with non-matching tasks in the same area
    for (let index = 0; index < 16; index += 1) {
      events.push(buildOtherEvent(`TASK-other-${index}`, 'visual'));
    }

    const results = detectArticulationGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual).toBeDefined();
    expect(visual?.sample_count).toBe(4);
    expect(visual?.strength).toBeNull();
    expect(visual?.pattern_id).toBe('articulation_gap');
  });

  test('UAT-030 path: 30 matching events at 60% rate -> strength saturates at 1', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 30; index += 1) {
      events.push(buildArticulationEvent(`TASK-${index}`, 'visual'));
    }

    // bring the denominator to 50 distinct tasks
    for (let index = 0; index < 20; index += 1) {
      events.push(buildOtherEvent(`TASK-other-${index}`, 'visual'));
    }

    const results = detectArticulationGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual).toBeDefined();
    expect(visual?.sample_count).toBe(30);
    expect(visual?.strength).toBeCloseTo(1, 5);
  });

  test('only fires for unclear_acceptance_criteria — knowledge-gap class is ignored', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 30; index += 1) {
      events.push({
        agent_type: 'Senior',
        event_id: `01HZZZK${index.toString().padStart(19, '0')}`,
        event_type: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'missing_codebase_knowledge',
          spec_id: 'SPEC-001',
          task_id: `TASK-${index}`,
        },
        project_id: 'a'.repeat(32),
        schema_version: 1,
        session_hash: 'b'.repeat(32),
        timestamp: '2026-05-07T12:00:00.000Z',
      });
    }

    const results = detectArticulationGap({events, windowDays: 30});
    // Visual area still appears (denominator counts task ids), but the
    // matching count is 0 → strength: null because <10.
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual?.sample_count).toBe(0);
    expect(visual?.strength).toBeNull();
  });

  test('returns empty array when no events provided', () => {
    expect(detectArticulationGap({events: [], windowDays: 30})).toEqual([]);
  });
});

describe('detectArticulationGap (fixture)', () => {
  test('articulation-fire fixture fires when present', () => {
    const events = loadFixture('articulation-fire.jsonl');

    if (events.length === 0) {
      // Fixtures are produced by task-fixtures (parallel sibling). Skip
      // gracefully if not present at the time of this run; the harness
      // executes the unit assertions above to cover detector logic.
      return;
    }
    const results = detectArticulationGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual).toBeDefined();
    expect(visual?.sample_count).toBeGreaterThanOrEqual(10);
    expect(visual?.strength).not.toBeNull();
    expect(visual?.strength).toBeGreaterThanOrEqual(0.5);
  });

  test('below-threshold fixture stays below threshold when present', () => {
    const events = loadFixture('below-threshold.jsonl');

    if (events.length === 0) return;
    const results = detectArticulationGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual?.sample_count).toBeLessThan(10);
    expect(visual?.strength).toBeNull();
  });
});
