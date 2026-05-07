import {describe, expect, test} from 'vitest';
import {detectKnowledgeGap} from '../patterns/knowledge-gap.js';
import type {MentorshipEvent} from '../reader.js';

const buildKnowledgeEvent = (
  taskId: string,
  area: string
): MentorshipEvent => ({
  agent_type: 'Senior',
  event_id: `01HZZZK${taskId.padStart(19, '0')}`,
  event_type: 'needs_context_returned',
  payload: {
    agent_type: 'Senior',
    area_tags: [area],
    context_request_class: 'missing_codebase_knowledge',
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

describe('detectKnowledgeGap (unit)', () => {
  test('returns strength=null when sample_count < 10', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 5; index += 1) {
      events.push(buildKnowledgeEvent(`TASK-${index}`, 'react'));
    }

    for (let index = 0; index < 10; index += 1) {
      events.push(buildOtherEvent(`TASK-other-${index}`, 'react'));
    }
    const results = detectKnowledgeGap({events, windowDays: 30});
    const react = results.find((entry) => entry.area_tag === 'react');

    expect(react?.sample_count).toBe(5);
    expect(react?.strength).toBeNull();
  });

  test('fires above threshold with strength saturating at 1', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 30; index += 1) {
      events.push(buildKnowledgeEvent(`TASK-${index}`, 'react'));
    }

    for (let index = 0; index < 20; index += 1) {
      events.push(buildOtherEvent(`TASK-other-${index}`, 'react'));
    }
    const results = detectKnowledgeGap({events, windowDays: 30});
    const react = results.find((entry) => entry.area_tag === 'react');

    expect(react?.sample_count).toBe(30);
    expect(react?.strength).toBeCloseTo(1, 5);
    expect(react?.pattern_id).toBe('knowledge_gap');
  });

  test('does not fire on unclear_acceptance_criteria events (articulation gap class)', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 30; index += 1) {
      events.push({
        agent_type: 'Senior',
        event_id: `01HZZZA${index.toString().padStart(19, '0')}`,
        event_type: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['react'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-001',
          task_id: `TASK-${index}`,
        },
        project_id: 'a'.repeat(32),
        schema_version: 1,
        session_hash: 'b'.repeat(32),
        timestamp: '2026-05-07T12:00:00.000Z',
      });
    }
    const results = detectKnowledgeGap({events, windowDays: 30});
    const react = results.find((entry) => entry.area_tag === 'react');

    expect(react?.sample_count).toBe(0);
    expect(react?.strength).toBeNull();
  });
});
