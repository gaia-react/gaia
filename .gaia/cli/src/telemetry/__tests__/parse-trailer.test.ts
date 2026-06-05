import {describe, expect, test} from 'vitest';
import {parseTrailer} from '../parse-trailer.js';

const buildHookInput = (subagentType: string, output: string): string =>
  JSON.stringify({
    tool_input: {subagent_type: subagentType},
    tool_name: 'Task',
    tool_response: {output},
  });

const trailer = (...lines: readonly string[]): string =>
  ['Some agent prose here.', '', '---', ...lines, '---', ''].join('\n');

describe('parseTrailer: guard rails', () => {
  test('returns wrong_tool when tool_name is not Task', () => {
    const input = JSON.stringify({tool_name: 'Bash'});
    const result = parseTrailer(input);
    expect(result).toEqual({invocations: [], reason: 'wrong_tool'});
  });

  test('returns invalid_input_json on malformed JSON', () => {
    const result = parseTrailer('{not-json');
    expect(result).toEqual({invocations: [], reason: 'invalid_input_json'});
  });

  test('returns no_subagent_type when subagent_type is missing', () => {
    const input = JSON.stringify({
      tool_input: {},
      tool_name: 'Task',
      tool_response: {output: 'hi'},
    });
    expect(parseTrailer(input)).toEqual({
      invocations: [],
      reason: 'no_subagent_type',
    });
  });

  test('returns no_tool_response when tool_response.output is missing', () => {
    const input = JSON.stringify({
      tool_input: {subagent_type: 'general-purpose'},
      tool_name: 'Task',
    });
    expect(parseTrailer(input)).toEqual({
      invocations: [],
      reason: 'no_tool_response',
    });
  });

  test('returns no_trailer when output has no fenced YAML block', () => {
    const input = buildHookInput(
      'general-purpose',
      'agent prose without trailer\n'
    );
    const result = parseTrailer(input);
    expect(result.invocations).toEqual([]);
    expect(result.reason).toBe('no_trailer');
  });

  test('returns no_trailer for an unclosed --- fence', () => {
    const input = buildHookInput(
      'general-purpose',
      'agent prose\n\n---\nfoo: bar\nno-closing-fence-ever\n'
    );
    const result = parseTrailer(input);
    expect(result.invocations).toEqual([]);
    expect(result.reason).toBe('no_trailer');
  });
});

describe('parseTrailer: code-review-audit', () => {
  test('emits one invocation per finding', () => {
    const findings = JSON.stringify([
      {
        area_tags: ['security', 'auth'],
        finding_class: 'holistic/missing-auth-check',
        severity: 'error',
      },
      {finding_class: 'react-doctor/no-generic-handler-names', severity: 'warning'},
    ]);
    const input = buildHookInput(
      'code-review-audit',
      trailer(`findings_json: ${findings}`, 'pr_number: 97')
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(2);

    expect(invocations[0]).toEqual({
      args: [
        '--pr-number',
        '97',
        '--finding-class',
        'holistic/missing-auth-check',
        '--severity',
        'error',
        '--area-tags',
        'security,auth',
        '--auditor-type',
        'code-review-audit',
        '--agent-type',
        'Reviewer',
      ],
      eventType: 'code_review_audit_finding',
    });

    expect(invocations[1]?.args).toContain(
      'react-doctor/no-generic-handler-names'
    );
    expect(invocations[1]?.args.at(-3)).toBe('code-review-audit');
  });

  test('defaults pr_number to "0" when absent', () => {
    const findings = JSON.stringify([
      {finding_class: 'axe/color-contrast', severity: 'warning'},
    ]);
    const input = buildHookInput(
      'code-review-audit',
      trailer(`findings_json: ${findings}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations[0]?.args.slice(0, 2)).toEqual(['--pr-number', '0']);
  });

  test('skips findings missing finding_class or severity', () => {
    const findings = JSON.stringify([
      {finding_class: 'cve/1098765', severity: 'error'},
      {severity: 'warning'},
      {finding_class: 'knip/exports'},
      {},
    ]);
    const input = buildHookInput(
      'code-review-audit',
      trailer(`findings_json: ${findings}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(1);
    expect(invocations[0]?.args).toContain('cve/1098765');
  });

  test('drops findings whose finding_class fails the controlled-set check', () => {
    const findings = JSON.stringify([
      {finding_class: 'axe/color-contrast', severity: 'error'},
      {finding_class: 'type_hole', severity: 'error'},
      {finding_class: 'holistic/something-made-up', severity: 'warning'},
      {finding_class: 'just free text', severity: 'error'},
    ]);
    const input = buildHookInput(
      'code-review-audit',
      trailer(`findings_json: ${findings}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(1);
    expect(invocations[0]?.args).toContain('axe/color-contrast');
  });

  test('returns invalid_trailer_json when every finding has an invalid class', () => {
    const findings = JSON.stringify([
      {finding_class: 'type_hole', severity: 'error'},
    ]);
    const input = buildHookInput(
      'code-review-audit',
      trailer(`findings_json: ${findings}`)
    );

    const result = parseTrailer(input);
    expect(result.invocations).toEqual([]);
    expect(result.reason).toBe('invalid_trailer_json');
  });

  test('returns invalid_trailer_json when findings_json is not parseable', () => {
    const input = buildHookInput(
      'code-review-audit',
      trailer('findings_json: not-json-at-all')
    );

    const result = parseTrailer(input);
    expect(result.invocations).toEqual([]);
    expect(result.reason).toBe('invalid_trailer_json');
  });

  test('returns invalid_trailer_json when findings_json is not an array', () => {
    const input = buildHookInput(
      'code-review-audit',
      trailer('findings_json: {"finding_class":"x","severity":"high"}')
    );

    const result = parseTrailer(input);
    expect(result.invocations).toEqual([]);
    expect(result.reason).toBe('invalid_trailer_json');
  });
});

describe('parseTrailer: engineer-return path', () => {
  test('emits uat_pass per entry in uat_passes_json', () => {
    const uats = JSON.stringify([
      {
        area_tags: ['ui'],
        attempts: 2,
        spec_id: 'SPEC-014',
        task_id: 'TASK-093',
        uat_id: 'UAT-007',
      },
      {
        spec_id: 'SPEC-015',
        task_id: 'TASK-094',
        uat_id: 'UAT-008',
      },
    ]);
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: Senior', `uat_passes_json: ${uats}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(2);

    expect(invocations[0]).toEqual({
      args: [
        '--uat-id',
        'UAT-007',
        '--spec-id',
        'SPEC-014',
        '--task-id',
        'TASK-093',
        '--attempts',
        '2',
        '--area-tags',
        'ui',
        '--agent-type',
        'Senior',
      ],
      eventType: 'uat_pass',
    });

    // Defaults attempts to "1" when absent.
    expect(invocations[1]?.args.slice(6, 8)).toEqual(['--attempts', '1']);
  });

  test('defaults agent_type to Senior when absent in trailer', () => {
    const uats = JSON.stringify([{spec_id: 'S', task_id: 'T', uat_id: 'U'}]);
    const input = buildHookInput(
      'general-purpose',
      trailer(`uat_passes_json: ${uats}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations[0]?.args.at(-1)).toBe('Senior');
  });

  test('respects custom agent_type from trailer', () => {
    const uats = JSON.stringify([{spec_id: 'S', task_id: 'T', uat_id: 'U'}]);
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: Lead', `uat_passes_json: ${uats}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations[0]?.args.at(-1)).toBe('Lead');
  });

  test('emits needs_context_returned when needs_context_json is a populated object', () => {
    const ctx = JSON.stringify({
      area_tags: ['router'],
      context_request_class: 'missing_route',
      spec_id: 'SPEC-001',
      task_id: 'TASK-001',
    });
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: Junior', `needs_context_json: ${ctx}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(1);
    expect(invocations[0]?.eventType).toBe('needs_context_returned');
    expect(invocations[0]?.args).toEqual([
      '--context-request-class',
      'missing_route',
      '--spec-id',
      'SPEC-001',
      '--task-id',
      'TASK-001',
      '--area-tags',
      'router',
      '--agent-type',
      'Junior',
    ]);
  });

  test('skips needs_context when value is null literal', () => {
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: Senior', 'needs_context_json: null')
    );

    expect(parseTrailer(input).invocations).toEqual([]);
  });

  test('skips needs_context when context_request_class is absent', () => {
    const ctx = JSON.stringify({spec_id: 'S', task_id: 'T'});
    const input = buildHookInput(
      'general-purpose',
      trailer(`needs_context_json: ${ctx}`)
    );

    expect(parseTrailer(input).invocations).toEqual([]);
  });

  test('emits blocked_returned when blocked_json is a populated object', () => {
    const blocked = JSON.stringify({
      area_tags: ['db'],
      classification: 'external_dependency',
      spec_id: 'SPEC-002',
      task_id: 'TASK-002',
    });
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: Senior', `blocked_json: ${blocked}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations).toHaveLength(1);
    expect(invocations[0]?.eventType).toBe('blocked_returned');
    expect(invocations[0]?.args).toContain('external_dependency');
  });

  test('emits all three event types from one trailer', () => {
    const uats = JSON.stringify([{spec_id: 'S', task_id: 'T', uat_id: 'U'}]);
    const ctx = JSON.stringify({
      context_request_class: 'cls',
      spec_id: 'S',
      task_id: 'T',
    });
    const blocked = JSON.stringify({
      classification: 'cls2',
      spec_id: 'S',
      task_id: 'T',
    });
    const input = buildHookInput(
      'general-purpose',
      trailer(
        `uat_passes_json: ${uats}`,
        `needs_context_json: ${ctx}`,
        `blocked_json: ${blocked}`
      )
    );

    const types = parseTrailer(input).invocations.map((i) => i.eventType);
    expect(types).toEqual([
      'uat_pass',
      'needs_context_returned',
      'blocked_returned',
    ]);
  });

  test('handles quoted scalar values', () => {
    const uats = JSON.stringify([{spec_id: 'S', task_id: 'T', uat_id: 'U'}]);
    const input = buildHookInput(
      'general-purpose',
      trailer('agent_type: "Lead"', `uat_passes_json: ${uats}`)
    );

    const {invocations} = parseTrailer(input);
    expect(invocations[0]?.args.at(-1)).toBe('Lead');
  });
});
