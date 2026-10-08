// Raw probe evidence -> observed states. Observations come only from the
// probe-hook log (probe.jsonl), the harness-emitted stream-json events (system
// init, result, and the structured tool_use / tool_result blocks), git's
// trace2 event log, and run-probe's post-scenario file check. Assistant text
// is never read: a model saying a rule loaded is not evidence that it did.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readSnapshotJson, settingsHookEntries } from './table.mjs';

export class EvidenceError extends Error {}

// Which settings file each probe tag stands for (inject-probe-fixtures.sh).
export const TAG_FILES = {
  'root-settings': '.claude/settings.json',
  'root-local': '.claude/settings.local.json',
  'frontend-settings': 'frontend/.claude/settings.json',
  'frontend-local': 'frontend/.claude/settings.local.json',
};

export const scenarioSlug = (trigger) => trigger.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

// A lenient read skips a malformed line instead of throwing: the session
// transcript is written by Claude Code, not by the probe, so a truncated or
// foreign line must not void the whole scenario.
const readJsonl = (path, { lenient = false } = {}) => {
  if (!existsSync(path)) return null;
  return readFileSync(path, 'utf8').split('\n').map((line, index) => {
    if (line.trim() === '') return null;
    try {
      const value = JSON.parse(line);
      if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('not a JSON object');
      return value;
    } catch (error) {
      if (lenient) return null;
      throw new EvidenceError(`malformed evidence line ${path}:${index + 1}: ${error.message}`);
    }
  }).filter(Boolean);
};

const readJson = (path) => {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    throw new EvidenceError(`malformed evidence file ${path}: ${error.message}`);
  }
};

// Repo-relative form of an absolute path, tolerating macOS's /private alias
// for /var and /tmp. Paths outside the launch's repo root keep an @outside:
// prefix so they never collide with an in-repo subject.
export const relativeTo = (root, path) => {
  if (typeof path !== 'string' || path === '') return null;
  if (!path.startsWith('/')) return path.replace(/^\.\//, '');
  const roots = new Set([root, `/private${root}`, root.replace(/^\/private/, '')]);
  for (const candidate of roots) {
    if (path === candidate) return '.';
    if (path.startsWith(`${candidate}/`)) return path.slice(candidate.length + 1);
  }
  return `@outside:${path}`;
};

export const loadScenario = (directory) => {
  const scenario = readJson(join(directory, 'scenario.json'));
  if (!scenario) return null;
  const streams = [readJsonl(join(directory, 'stream-1.jsonl')) ?? [], readJsonl(join(directory, 'stream-2.jsonl'))];
  return {
    scenario,
    probe: readJsonl(join(directory, 'probe.jsonl')) ?? [],
    streams,
    transcript: readJsonl(join(directory, 'transcript-1.jsonl'), { lenient: true }),
    trace2: readJsonl(join(directory, 'trace2.jsonl')) ?? [],
    filesAfter: readJson(join(directory, 'files-after.json')) ?? {},
  };
};

const initEvent = (stream) => (stream ?? []).find((event) => event.type === 'system' && event.subtype === 'init') ?? null;
const names = (list) => (list ?? []).map((entry) => (typeof entry === 'string' ? entry : entry?.name)).filter(Boolean);
const nameMatches = (listed, key) => listed === key || listed.endsWith(`:${key}`);

// Session-level problems that void every row of the scenario.
export const sessionProblem = (data) => {
  if (!data) return 'no_session';
  if (data.probe.some((line) => line.event === 'ProbeError')) return 'probe_error';
  if (!data.probe.some((line) => line.event === 'SessionStart')) return 'no_session';
  if (!initEvent(data.streams[0])) return 'no_session';
  return null;
};

const readVerified = (data) => {
  const { trigger, launch_root: root } = data.scenario;
  if (!trigger.startsWith('after_read:')) return true;
  const target = trigger.slice('after_read:'.length);
  return data.probe.some((line) => line.event === 'PostToolUse' && line.tool_name === 'Read'
    && relativeTo(root, line.file_path) === target);
};

export const loadedInstructionPaths = (data) => new Set(data.probe
  .filter((line) => line.event === 'InstructionsLoaded')
  .map((line) => relativeTo(data.scenario.launch_root, line.file_path))
  .filter(Boolean));

// A Read of an instruction file, proven by its PostToolUse probe line. Claude
// Code emits no InstructionsLoaded for a CLAUDE.md whose content entered the
// context through a direct Read (the spike run showed a Read of
// frontend/CLAUDE.md log nothing for that file, while a Read of any other file
// under frontend/ logged it as nested_traversal), so for a claude_md row the
// verified Read is the other way the file reaches the session.
export const readInstructionPaths = (data) => new Set(data.probe
  .filter((line) => line.event === 'PostToolUse' && line.tool_name === 'Read')
  .map((line) => relativeTo(data.scenario.launch_root, line.file_path))
  .filter(Boolean));

// The listing an agent or MCP row is judged on: an after_read row uses the
// turn issued after the Read was verified; every other row the session's own
// init event. The init event is a session-start snapshot, so it cannot show
// anything discovered mid-session.
const listingInit = (data) => (data.scenario.trigger.startsWith('after_read:') ? initEvent(data.streams[1]) : initEvent(data.streams[0]));

// Skill and command names the first turn's session exposed: the init event's
// skills and slash_commands, plus every later system `commands_changed` event.
// Claude Code emits commands_changed with the full command list whenever the
// set changes, including when a Read discovers a nested .claude/skills
// directory mid-session, which the init snapshot cannot show (the spike run:
// 87 init skills on both turns, while the Read of frontend/CLAUDE.md drew a
// commands_changed adding exactly the 12 frontend skills).
export const sessionCommandNames = (stream) => {
  const listed = [...listedNames(initEvent(stream), 'skill')];
  for (const event of stream ?? []) {
    if (event.type === 'system' && event.subtype === 'commands_changed') listed.push(...names(event.commands));
  }
  return listed;
};

export const listedNames = (init, kind) => {
  if (!init) return [];
  if (kind === 'skill') return [...names(init.skills), ...names(init.slash_commands)];
  if (kind === 'agent') return names(init.agents);
  if (kind === 'mcp') return names(init.mcp_servers);
  return [];
};

// Names the first turn's transcript listed: the union over every skill_listing
// attachment. A later attachment may in principle remove a name; the union
// cannot model that, so a name once listed stays listed.
export const transcriptListedNames = (transcript) => {
  const listings = (transcript ?? []).map((line) => line.attachment).filter((attachment) => attachment?.type === 'skill_listing');
  return listings.length === 0 ? null : listings.flatMap((attachment) => attachment.names ?? []);
};

const loadedTags = (data) => new Set(data.probe.filter((line) => line.event === 'SessionStart').map((line) => line.tag));

const toolAttempts = (data) => {
  const attempts = new Map();
  const results = new Map();
  const denied = new Set();
  for (const stream of data.streams) {
    for (const event of stream ?? []) {
      if (event.type === 'assistant') {
        for (const block of event.message?.content ?? []) {
          if (block.type === 'tool_use') attempts.set(block.id, { id: block.id, name: block.name, input: block.input ?? {} });
        }
      } else if (event.type === 'user') {
        for (const block of event.message?.content ?? []) {
          if (block.type === 'tool_result') results.set(block.tool_use_id, block);
        }
      } else if (event.type === 'result') {
        for (const denial of event.permission_denials ?? []) {
          denied.add(denial.tool_use_id);
          if (!attempts.has(denial.tool_use_id)) attempts.set(denial.tool_use_id, { id: denial.tool_use_id, name: denial.tool_name, input: denial.tool_input ?? {} });
        }
      }
    }
  }
  return { attempts: [...attempts.values()], results, denied };
};

const resultText = (result) => (typeof result?.content === 'string' ? result.content
  : (result?.content ?? []).map((part) => part?.text ?? '').join('\n'));

// allow wins over deny: one executed attempt means the deny did not hold.
const fileToolOutcome = (data, toolNames, relativePath) => {
  const root = data.scenario.launch_root;
  const { attempts, results, denied } = toolAttempts(data);
  const posted = data.probe.filter((line) => line.event === 'PostToolUse');
  const matching = attempts.filter((attempt) => toolNames.includes(attempt.name)
    && relativeTo(root, attempt.input.file_path ?? attempt.input.notebook_path) === relativePath);
  const ranByProbe = posted.some((line) => toolNames.includes(line.tool_name) && relativeTo(root, line.file_path) === relativePath);
  if (ranByProbe) return 'allow';
  if (matching.length === 0) return 'not_attempted';
  const outcomes = matching.map((attempt) => {
    if (denied.has(attempt.id)) return 'deny';
    const result = results.get(attempt.id);
    const text = resultText(result);
    if (result?.is_error && /permission|denied|blocked|hook/i.test(text)) return 'deny';
    // Claude Code refuses an oversized Read at execution, after every
    // permission check and PreToolUse hook passed, so no PostToolUse line is
    // logged; the refusal still proves the permission layer allowed the call.
    if (result?.is_error && /exceeds maximum allowed size/i.test(text)) return 'allow';
    return 'error';
  });
  if (outcomes.includes('allow')) return 'allow';
  return outcomes.includes('deny') ? 'deny' : 'error';
};

// red-verify-commit-check.sh opens every deny reason with this prefix; it is
// how the RED gate's own decision is told apart from any other PreToolUse
// hook that denied the same call (the spike's commit-to-main guard).
export const RED_GATE_REASON_PREFIX = 'TDD RED-verification:';

const hookDenyReasons = (stream) => (stream ?? [])
  .filter((event) => event.type === 'system' && event.subtype === 'hook_response' && event.hook_event === 'PreToolUse')
  .map((event) => {
    try {
      const output = JSON.parse(event.stdout || event.output || 'null');
      const decision = output?.hookSpecificOutput;
      return decision?.permissionDecision === 'deny' ? String(decision.permissionDecisionReason ?? '') : null;
    } catch {
      return null;
    }
  })
  .filter((reason) => reason !== null);

// Whether the RED gate itself denied commit <marker>. Two structural sources,
// neither of them model text: the denied call's own tool_result (Claude Code
// quotes the hook's reason there), and a PreToolUse hook_response whose
// RED-gate reason names one of the marker's staged paths (run-probe.sh records
// them in scenario.json as commit_paths).
const redGateDenied = (data, marker, commitAttempts) => {
  const { results } = toolAttempts(data);
  const inResult = commitAttempts.some((attempt) => {
    const result = results.get(attempt.id);
    return Boolean(result?.is_error) && resultText(result).includes(RED_GATE_REASON_PREFIX);
  });
  if (inResult) return true;
  const paths = data.scenario.commit_paths?.[marker] ?? [];
  if (paths.length === 0) return false;
  return data.streams.flatMap(hookDenyReasons).some((reason) => reason.startsWith(RED_GATE_REASON_PREFIX)
    && paths.some((path) => reason.includes(path)));
};

const commitObservation = (data, marker) => {
  const commitProcesses = data.trace2.filter((event) => event.event === 'start' && Array.isArray(event.argv)
    && event.argv.includes('commit') && event.argv.join(' ').includes(`probe-commit-${marker}`));
  const sids = new Set(commitProcesses.map((event) => event.sid));
  const preCommit = data.trace2.some((event) => event.event === 'child_start' && sids.has(event.sid)
    && event.child_class === 'hook' && event.hook_name === 'pre-commit') ? 'ran' : 'not_run';
  const { attempts, results, denied } = toolAttempts(data);
  const commitAttempts = attempts.filter((attempt) => attempt.name === 'Bash'
    && String(attempt.input.command ?? '').includes(`probe-commit-${marker}`));
  const attempted = commitAttempts.length > 0
    || data.probe.some((line) => line.event === 'PreToolUse' && line.probe_commit_marker === marker);
  // The RED gate's own decision only: a call some other PreToolUse hook
  // denied never reached git, so it says nothing about the gate and is
  // reported as blocked_before_git, never as the gate's deny.
  let redGate = 'not_reached';
  if (redGateDenied(data, marker, commitAttempts)) redGate = 'deny';
  else if (commitProcesses.length > 0) redGate = 'allow';
  else if (commitAttempts.some((attempt) => denied.has(attempt.id) || results.get(attempt.id)?.is_error)) redGate = 'blocked_before_git';
  else if (attempted) redGate = 'undetermined';
  return { 'pre-commit': preCommit, 'red-gate': redGate };
};

export const commitTuple = (data) => ['a', 'b'].map((marker) => {
  const observation = commitObservation(data, marker);
  return `${marker}.pre-commit=${observation['pre-commit']},${marker}.red-gate=${observation['red-gate']}`;
}).join(';');

const envValue = (data, subject) => {
  const lines = data.probe.filter((line) => line.event === 'SessionStart');
  const field = { CLAUDE_PROJECT_DIR: 'claude_project_dir', pwd: 'pwd', git_toplevel: 'toplevel' }[subject];
  if (!field) return 'unknown_env_subject';
  const values = new Set(lines.map((line) => (line[field] === '' ? '(empty)' : relativeTo(data.scenario.launch_root, line[field]))));
  if (values.size !== 1) return `inconsistent:${[...values].join('|')}`;
  return `value:${[...values][0]}`;
};

// Observed state of one expanded row in one scenario. `context.rootCommit`
// supplies the root launch's commit scenario for the parity row.
export const observe = (row, expanded, data, snapshotDirectory, context = {}) => {
  const problem = sessionProblem(data);
  if (problem) return problem;
  if (!readVerified(data)) return 'read_not_verified';
  const { subject } = expanded;
  switch (row.kind) {
    case 'claude_md':
      return loadedInstructionPaths(data).has(subject) || readInstructionPaths(data).has(subject) ? 'loaded' : 'not_loaded';
    case 'rule':
      return loadedInstructionPaths(data).has(subject) ? 'loaded' : 'not_loaded';
    case 'skill':
      return sessionCommandNames(data.streams[0]).some((listed) => nameMatches(listed, context.key)) ? 'available' : 'not_available';
    case 'listing': {
      const { transcript } = data;
      if (!transcript) return 'no_transcript';
      const listed = transcriptListedNames(transcript);
      if (listed === null) return 'no_skill_listing';
      return listed.some((name) => nameMatches(name, context.key)) ? 'listed' : 'not_listed';
    }
    case 'agent': {
      const init = listingInit(data);
      if (!init) return 'no_listing';
      return listedNames(init, row.kind).some((listed) => nameMatches(listed, context.key)) ? 'available' : 'not_available';
    }
    case 'mcp': {
      const init = listingInit(data);
      if (!init) return 'no_listing';
      const server = (init.mcp_servers ?? []).find((entry) => entry?.name === subject);
      if (!server) return 'not_available';
      return server.status === 'connected' ? 'available' : `status:${server.status}`;
    }
    case 'settings_source':
      return [...loadedTags(data)].some((tag) => TAG_FILES[tag] === subject) ? 'loaded' : 'not_loaded';
    case 'hook': {
      const entry = expanded.entry ?? (() => {
        const [event, matcher, ...command] = subject.split('|');
        return { event, matcher, command: command.join('|') };
      })();
      const registered = [...loadedTags(data)].some((tag) => {
        const settings = TAG_FILES[tag] ? readSnapshotJson(snapshotDirectory, TAG_FILES[tag]) : null;
        return settingsHookEntries(settings).some((candidate) => candidate.event === entry.event
          && candidate.matcher === entry.matcher && candidate.command === entry.command);
      });
      return registered ? 'registered' : 'not_registered';
    }
    case 'env':
      return envValue(data, subject);
    case 'permission': {
      const [tool, ...pathParts] = subject.split(' ');
      return fileToolOutcome(data, [tool], pathParts.join(' '));
    }
    case 'task': {
      if (row.trigger === 'after_task:commit') {
        if (subject === 'commit-parity') {
          if (!context.rootCommit || sessionProblem(context.rootCommit)) return 'no_root_baseline';
          const mine = commitTuple(data);
          const root = commitTuple(context.rootCommit);
          return mine === root ? 'value:match-root' : `value:differs(${data.scenario.launch}=${mine} root=${root})`;
        }
        const match = /^commit-([a-z]):(pre-commit|red-gate)$/.exec(subject);
        if (!match) return 'unknown_commit_subject';
        return `value:${commitObservation(data, match[1])[match[2]]}`;
      }
      const outcome = fileToolOutcome(data, ['Write', 'Edit'], subject);
      if (outcome === 'allow' && data.filesAfter[subject] !== true) return 'allow_but_file_missing';
      return outcome;
    }
    default:
      return 'unknown_kind';
  }
};
