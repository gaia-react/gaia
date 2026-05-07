/**
 * Parse the structured-trailer YAML block from a Task tool output and produce
 * a list of `gaia telemetry emit` invocations to dispatch.
 *
 * The trailer is the canonical way agent skills surface mentorship events
 * back to the parent — a fenced YAML block at the end of the agent's
 * Task-tool return string:
 *
 *     ... agent prose ...
 *
 *     ---
 *     agent_type: Senior
 *     uat_passes_json: [{"uat_id":"UAT-007","spec_id":"SPEC-014",...}]
 *     needs_context_json: null
 *     blocked_json: null
 *     ---
 *
 * Pure function: takes the raw stdin JSON the PostToolUse `Task` hook receives
 * and returns the emit invocations. No I/O, no env reads. The caller decides
 * how to dispatch (production: invoke `handleEmit`; tests: assert on result).
 *
 * Idempotency is handled downstream — `handleEmit` writes content-derived
 * ULIDs, so a double-fire of the same payload short-circuits at the
 * append-idempotent layer.
 */

export type EmitInvocation = {
  args: readonly string[];
  eventType: string;
};

export type ParseResult = {
  invocations: readonly EmitInvocation[];
  /**
   * Reason the result was empty, when applicable. Useful for tests and the
   * parse-stdin CLI's optional debug logging. `undefined` when invocations
   * is non-empty OR when the trailer was processed but produced no emits.
   */
  reason?:
    | 'invalid_input_json'
    | 'invalid_trailer_json'
    | 'no_subagent_type'
    | 'no_trailer'
    | 'no_tool_response'
    | 'wrong_tool';
};

const TRAILER_FENCE = /^---\s*$/;

const extractTrailer = (output: string): string | undefined => {
  const lines = output.split('\n');
  const collected: string[] = [];
  let inBlock = false;

  for (const line of lines) {
    if (TRAILER_FENCE.test(line)) {
      if (inBlock) return collected.join('\n');
      inBlock = true;
      continue;
    }

    if (inBlock) collected.push(line);
  }

  return undefined;
};

const escapeRegex = (input: string): string =>
  input.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&');

const stripQuotes = (raw: string): string => {
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw.slice(1, -1);
  }

  return raw;
};

const trailerScalar = (trailer: string, key: string): string | undefined => {
  const pattern = new RegExp(
    `^${escapeRegex(key)}\\s*:\\s*(.*?)\\s*$`,
    'm'
  );
  const match = trailer.match(pattern);

  if (match === null) return undefined;
  const raw = match[1] ?? '';

  return stripQuotes(raw.trim());
};

const tryJsonParse = (raw: string): unknown => {
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
};

const isStringArray = (value: unknown): value is readonly string[] =>
  Array.isArray(value) && value.every((entry) => typeof entry === 'string');

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const stringField = (
  source: Record<string, unknown>,
  key: string
): string | undefined => {
  const raw = source[key];

  return typeof raw === 'string' && raw.length > 0 ? raw : undefined;
};

const numericField = (
  source: Record<string, unknown>,
  key: string
): string | undefined => {
  const raw = source[key];

  if (typeof raw === 'number' && Number.isFinite(raw)) return String(raw);
  if (typeof raw === 'string' && raw.length > 0) return raw;

  return undefined;
};

const areaTagsString = (source: Record<string, unknown>): string => {
  const raw = source.area_tags;

  if (isStringArray(raw)) return raw.join(',');

  return '';
};

const buildAuditFindings = (
  trailer: string
): readonly EmitInvocation[] => {
  const findingsRaw = trailerScalar(trailer, 'findings_json');

  if (findingsRaw === undefined) return [];

  const parsed = tryJsonParse(findingsRaw);

  if (!Array.isArray(parsed)) return [];

  const prNumber =
    trailerScalar(trailer, 'pr_number')?.replace(/^"|"$/g, '') ?? '0';
  const invocations: EmitInvocation[] = [];

  for (const finding of parsed) {
    if (!isPlainObject(finding)) continue;

    const findingClass = stringField(finding, 'finding_class');
    const severity = stringField(finding, 'severity');

    if (findingClass === undefined || severity === undefined) continue;

    invocations.push({
      args: [
        '--pr-number',
        prNumber,
        '--finding-class',
        findingClass,
        '--severity',
        severity,
        '--area-tags',
        areaTagsString(finding),
        '--auditor-type',
        'code-review-audit',
        '--agent-type',
        'Reviewer',
      ],
      eventType: 'code_review_audit_finding',
    });
  }

  return invocations;
};

const buildUatPasses = (
  trailer: string,
  agentType: string
): readonly EmitInvocation[] => {
  const raw = trailerScalar(trailer, 'uat_passes_json');

  if (raw === undefined) return [];

  const parsed = tryJsonParse(raw);

  if (!Array.isArray(parsed)) return [];

  const invocations: EmitInvocation[] = [];

  for (const entry of parsed) {
    if (!isPlainObject(entry)) continue;

    const uatId = stringField(entry, 'uat_id');
    const specId = stringField(entry, 'spec_id');
    const taskId = stringField(entry, 'task_id');

    if (uatId === undefined || specId === undefined || taskId === undefined) {
      continue;
    }

    const attempts = numericField(entry, 'attempts') ?? '1';

    invocations.push({
      args: [
        '--uat-id',
        uatId,
        '--spec-id',
        specId,
        '--task-id',
        taskId,
        '--attempts',
        attempts,
        '--area-tags',
        areaTagsString(entry),
        '--agent-type',
        agentType,
      ],
      eventType: 'uat_pass',
    });
  }

  return invocations;
};

const buildNeedsContext = (
  trailer: string,
  agentType: string
): EmitInvocation | undefined => {
  const raw = trailerScalar(trailer, 'needs_context_json');

  if (raw === undefined || raw === 'null') return undefined;

  const parsed = tryJsonParse(raw);

  if (!isPlainObject(parsed)) return undefined;

  const requestClass = stringField(parsed, 'context_request_class');

  if (requestClass === undefined) return undefined;

  return {
    args: [
      '--context-request-class',
      requestClass,
      '--spec-id',
      stringField(parsed, 'spec_id') ?? '',
      '--task-id',
      stringField(parsed, 'task_id') ?? '',
      '--area-tags',
      areaTagsString(parsed),
      '--agent-type',
      agentType,
    ],
    eventType: 'needs_context_returned',
  };
};

const buildBlocked = (
  trailer: string,
  agentType: string
): EmitInvocation | undefined => {
  const raw = trailerScalar(trailer, 'blocked_json');

  if (raw === undefined || raw === 'null') return undefined;

  const parsed = tryJsonParse(raw);

  if (!isPlainObject(parsed)) return undefined;

  const classification = stringField(parsed, 'classification');

  if (classification === undefined) return undefined;

  return {
    args: [
      '--classification',
      classification,
      '--spec-id',
      stringField(parsed, 'spec_id') ?? '',
      '--task-id',
      stringField(parsed, 'task_id') ?? '',
      '--area-tags',
      areaTagsString(parsed),
      '--agent-type',
      agentType,
    ],
    eventType: 'blocked_returned',
  };
};

type HookInput = {
  subagentType: string;
  toolOutput: string;
};

const extractHookInput = (
  rawJson: string
): {input: HookInput; ok: true} | {ok: false; reason: ParseResult['reason']} => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(rawJson);
  } catch {
    return {ok: false, reason: 'invalid_input_json'};
  }

  if (!isPlainObject(parsed)) {
    return {ok: false, reason: 'invalid_input_json'};
  }

  if (parsed.tool_name !== 'Task') {
    return {ok: false, reason: 'wrong_tool'};
  }

  const toolInput = parsed.tool_input;
  const subagentType =
    isPlainObject(toolInput) ? stringField(toolInput, 'subagent_type') : (
      undefined
    );

  if (subagentType === undefined) {
    return {ok: false, reason: 'no_subagent_type'};
  }

  const toolResponse = parsed.tool_response;
  const toolOutput =
    isPlainObject(toolResponse) ? stringField(toolResponse, 'output') : (
      undefined
    );

  if (toolOutput === undefined) {
    return {ok: false, reason: 'no_tool_response'};
  }

  return {input: {subagentType, toolOutput}, ok: true};
};

export const parseTrailer = (rawHookInputJson: string): ParseResult => {
  const extracted = extractHookInput(rawHookInputJson);

  if (!extracted.ok) {
    return {invocations: [], reason: extracted.reason};
  }
  const {subagentType, toolOutput} = extracted.input;
  const trailer = extractTrailer(toolOutput);

  if (trailer === undefined || trailer.trim().length === 0) {
    return {invocations: [], reason: 'no_trailer'};
  }

  if (subagentType === 'code-review-audit') {
    const invocations = buildAuditFindings(trailer);

    return invocations.length > 0 ?
        {invocations}
      : {invocations: [], reason: 'invalid_trailer_json'};
  }

  // Engineer-return path: agent_type defaults to Senior when absent.
  const agentType = trailerScalar(trailer, 'agent_type') ?? 'Senior';
  const collected: EmitInvocation[] = [];
  collected.push(...buildUatPasses(trailer, agentType));
  const needsContext = buildNeedsContext(trailer, agentType);

  if (needsContext !== undefined) collected.push(needsContext);
  const blocked = buildBlocked(trailer, agentType);

  if (blocked !== undefined) collected.push(blocked);

  return {invocations: collected};
};
