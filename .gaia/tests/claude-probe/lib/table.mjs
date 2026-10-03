// Expectation-table model for the Claude probe: row schema validation, the
// SPEC-092 Phase 0 floor, and `expand` resolution against a launch snapshot.
// Pure: reads only the files it is handed, never calls Claude.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const SCHEMA_KEYS = [
  'id', 'launch', 'kind', 'subject', 'expand', 'trigger',
  'expect', 'signal', 'floor', 'source', 'cited_run',
];
export const LAUNCHES = ['root', 'frontend', 'worktree'];
export const TASKS = ['component-write', 'commit', 'permissions-read', 'permissions-edit'];
export const PROBE_HOOK_MARKER = 'claude-probe/probe-hooks/';

// Which expectations and which signal each kind may carry. A row outside its
// kind's set is a table error, not an observation to compare.
const KIND_RULES = {
  claude_md: { expect: ['loaded', 'not_loaded'], signal: ['instructions_loaded'] },
  rule: { expect: ['loaded', 'not_loaded'], signal: ['instructions_loaded'] },
  skill: { expect: ['available', 'not_available'], signal: ['stream_json_init'] },
  agent: { expect: ['available', 'not_available'], signal: ['stream_json_init'] },
  mcp: { expect: ['available', 'not_available'], signal: ['stream_json_init'] },
  hook: { expect: ['registered', 'not_registered'], signal: ['session_start_probe'] },
  settings_source: { expect: ['loaded', 'not_loaded'], signal: ['session_start_probe'] },
  env: { expect: ['value:'], signal: ['session_start_probe'] },
  permission: { expect: ['allow', 'deny'], signal: ['post_tool_use'] },
  task: { expect: ['allow', 'deny', 'value:'], signal: ['post_tool_use', 'git_log'] },
};
export const SIGNALS = [
  'instructions_loaded', 'session_start_probe', 'stream_json_init',
  'post_tool_use', 'pre_tool_use', 'git_log', 'manual',
];

export class TableError extends Error {}

export const readTable = (tablePath) => {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(tablePath, 'utf8'));
  } catch (error) {
    throw new TableError(`cannot parse ${tablePath}: ${error.message}`);
  }
  if (parsed?.schemaVersion !== 1 || !Array.isArray(parsed.rows)) {
    throw new TableError(`${tablePath}: expected {"schemaVersion": 1, "rows": [...]}`);
  }
  return parsed;
};

const expectAllowed = (kind, expect) => KIND_RULES[kind].expect.some((allowed) =>
  allowed.endsWith(':') ? expect.startsWith(allowed) && expect.length > allowed.length : expect === allowed);

const triggerProblem = (trigger) => {
  if (trigger === 'session_start') return null;
  if (trigger.startsWith('after_read:')) {
    const path = trigger.slice('after_read:'.length);
    return /^[A-Za-z0-9._/-]+$/.test(path) && !path.split('/').includes('..') ? null : `bad after_read path "${path}"`;
  }
  if (trigger.startsWith('after_task:')) {
    const task = trigger.slice('after_task:'.length);
    return TASKS.includes(task) ? null : `unknown task "${task}" (known: ${TASKS.join(', ')})`;
  }
  return `unknown trigger "${trigger}"`;
};

// Every schema problem in the table, one string each, "SCHEMA <row-id>: ...".
export const schemaProblems = (table) => {
  const problems = [];
  const seen = new Set();
  table.rows.forEach((row, index) => {
    const label = typeof row?.id === 'string' ? row.id : `#${index}`;
    const missing = SCHEMA_KEYS.filter((key) => !(key in (row ?? {})));
    if (missing.length > 0) {
      problems.push(`SCHEMA ${label}: missing key(s) ${missing.join(', ')}`);
      return;
    }
    if (!/^[a-z0-9][a-z0-9-]*$/.test(row.id)) problems.push(`SCHEMA ${label}: id must match ^[a-z0-9][a-z0-9-]*$`);
    if (seen.has(row.id)) problems.push(`SCHEMA ${label}: duplicate id`);
    seen.add(row.id);
    if (!LAUNCHES.includes(row.launch)) problems.push(`SCHEMA ${label}: launch must be one of ${LAUNCHES.join(', ')}`);
    if (!(row.kind in KIND_RULES)) {
      problems.push(`SCHEMA ${label}: unknown kind "${row.kind}"`);
      return;
    }
    if (typeof row.subject !== 'string' || row.subject === '') problems.push(`SCHEMA ${label}: subject must be a non-empty string`);
    if (row.expand !== null && (typeof row.expand !== 'string' || row.expand === '')) problems.push(`SCHEMA ${label}: expand must be null or a non-empty string`);
    if (typeof row.trigger !== 'string') problems.push(`SCHEMA ${label}: trigger must be a string`);
    else {
      const problem = triggerProblem(row.trigger);
      if (problem) problems.push(`SCHEMA ${label}: ${problem}`);
    }
    if (typeof row.expect !== 'string' || !expectAllowed(row.kind, row.expect)) problems.push(`SCHEMA ${label}: expect "${row.expect}" is not valid for kind ${row.kind}`);
    if (!SIGNALS.includes(row.signal)) problems.push(`SCHEMA ${label}: unknown signal "${row.signal}"`);
    else if (row.signal !== 'manual' && !KIND_RULES[row.kind].signal.includes(row.signal)) problems.push(`SCHEMA ${label}: signal ${row.signal} cannot observe kind ${row.kind}`);
    if (typeof row.floor !== 'boolean') problems.push(`SCHEMA ${label}: floor must be a boolean`);
    if (typeof row.source !== 'string' || row.source.trim() === '') problems.push(`SCHEMA ${label}: source must be a non-empty string`);
    if (row.cited_run !== null && (typeof row.cited_run !== 'string' || row.cited_run === '')) problems.push(`SCHEMA ${label}: cited_run must be null or a cited-runs/ summary path`);
    if (row.floor === true && row.signal === 'manual') problems.push(`SCHEMA ${label}: a floor row needs an observable signal, not manual`);
  });
  return problems;
};

// The SPEC-092 Phase 0 floor (SPEC "How it behaves" step 3, plus the UAT-017
// and UAT-023 rows the plan's probe task files under it). Each item is met by
// at least one floor row with exactly these fields.
const item = (id, description, fields) => ({ id, description, fields });
const PERMISSION_FLOOR_TARGETS = [
  'Edit .env', 'Edit frontend/.env', 'Edit frontend/.claude/settings.json', 'Edit pnpm-lock.yaml',
  'Edit .gaia/local/audit/x.ok', 'Edit .gaia/local/audit/x.carried', 'Edit .gaia/local/audit/x.refused',
  'Edit .husky/_/h', 'Edit .husky/_/pre-commit', 'Read .env', 'Read frontend/.env',
];
const UAT017_TARGETS = ['Edit .gaia/local/audit/x.ok', 'Edit .husky/_/pre-commit', 'Edit pnpm-lock.yaml'];
const permissionTrigger = (subject) => (subject.startsWith('Read ') ? 'after_task:permissions-read' : 'after_task:permissions-edit');

export const FLOOR_ITEMS = [
  item('frontend-root-claude-md', 'frontend launch: root CLAUDE.md loads', { launch: 'frontend', kind: 'claude_md', subject: 'CLAUDE.md', trigger: 'session_start', expect: 'loaded' }),
  item('frontend-root-always-rules', 'frontend launch: root always-loaded rules load at session start', { launch: 'frontend', kind: 'rule', expand: '.claude/rules/**/*.md#unscoped', trigger: 'session_start', expect: 'loaded' }),
  item('frontend-root-hooks', 'frontend launch: every root hook is registered', { launch: 'frontend', kind: 'hook', expand: 'hooks:.claude/settings.json', trigger: 'session_start', expect: 'registered' }),
  item('frontend-root-skills', 'frontend launch: root skills are available', { launch: 'frontend', kind: 'skill', expand: '.claude/skills/*/SKILL.md', trigger: 'session_start', expect: 'available' }),
  item('frontend-root-agents', 'frontend launch: root agents are available', { launch: 'frontend', kind: 'agent', expand: '.claude/agents/*.md', trigger: 'session_start', expect: 'available' }),
  item('frontend-frontend-skills', 'frontend launch: frontend-only skills are invocable', { launch: 'frontend', kind: 'skill', expand: 'frontend/.claude/skills/*/SKILL.md', trigger: 'session_start', expect: 'available' }),
  ...PERMISSION_FLOOR_TARGETS.map((subject) => item(
    `frontend-deny-${subject.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-+$/, '')}`,
    `frontend launch: root deny holds for ${subject}`,
    { launch: 'frontend', kind: 'permission', subject, trigger: permissionTrigger(subject), expect: 'deny' })),
  item('root-frontend-claude-md-before-read', 'root launch: frontend/CLAUDE.md not loaded before any Read inside frontend/', { launch: 'root', kind: 'claude_md', subject: 'frontend/CLAUDE.md', trigger: 'session_start', expect: 'not_loaded' }),
  item('root-frontend-rules-before-read', 'root launch: frontend/.claude/rules not loaded before any Read inside frontend/', { launch: 'root', kind: 'rule', expand: 'frontend/.claude/rules/**/*.md', trigger: 'session_start', expect: 'not_loaded' }),
  item('root-frontend-claude-md-after-read', 'root launch: frontend/CLAUDE.md loads after a Read of frontend/CLAUDE.md', { launch: 'root', kind: 'claude_md', subject: 'frontend/CLAUDE.md', trigger: 'after_read:frontend/CLAUDE.md', expect: 'loaded' }),
  item('root-frontend-rules-after-read', 'root launch: frontend rules load after a Read of frontend/CLAUDE.md', { launch: 'root', kind: 'rule', expand: 'frontend/.claude/rules/**/*.md#unscoped', trigger: 'after_read:frontend/CLAUDE.md', expect: 'loaded' }),
  item('root-frontend-skills-after-read', 'root launch: frontend skills load after a Read of frontend/CLAUDE.md', { launch: 'root', kind: 'skill', expand: 'frontend/.claude/skills/*/SKILL.md', trigger: 'after_read:frontend/CLAUDE.md', expect: 'available' }),
  item('root-code-audit-frontend', 'root launch: code-audit-frontend is spawnable', { launch: 'root', kind: 'agent', subject: '.claude/agents/code-audit-frontend.md', trigger: 'session_start', expect: 'available' }),
  item('worktree-code-audit-frontend', 'worktree launch: code-audit-frontend is spawnable', { launch: 'worktree', kind: 'agent', subject: '.claude/agents/code-audit-frontend.md', trigger: 'session_start', expect: 'available' }),
  item('root-task-component-write', 'root launch: scripted component Write task', { launch: 'root', kind: 'task', subject: 'frontend/app/components/ProbeX/index.tsx', trigger: 'after_task:component-write', expect: 'allow' }),
  item('frontend-task-component-write', 'frontend launch: scripted component Write task', { launch: 'frontend', kind: 'task', subject: 'frontend/app/components/ProbeX/index.tsx', trigger: 'after_task:component-write', expect: 'allow' }),
  ...UAT017_TARGETS.map((subject) => item(
    `uat017-root-${subject.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-+$/, '')}`,
    `UAT-017 root launch: ${subject} denied`,
    { launch: 'root', kind: 'permission', subject, trigger: 'after_task:permissions-edit', expect: 'deny' })),
  item('uat023-commit-parity', 'UAT-023: a frontend launch commit runs pre-commit and the RED gate exactly as a root launch', { launch: 'frontend', kind: 'task', subject: 'commit-parity', trigger: 'after_task:commit', expect: 'value:match-root' }),
  item('uat023-frontend-pre-commit-ran', 'UAT-023: pre-commit runs on a frontend launch commit', { launch: 'frontend', kind: 'task', subject: 'commit-a:pre-commit', trigger: 'after_task:commit', expect: 'value:ran' }),
  item('uat023-root-pre-commit-ran', 'UAT-023: pre-commit runs on a root launch commit', { launch: 'root', kind: 'task', subject: 'commit-a:pre-commit', trigger: 'after_task:commit', expect: 'value:ran' }),
];

const rowMeetsItem = (row, floorItem) => row.floor === true
  && Object.entries(floorItem.fields).every(([key, value]) => row[key] === value)
  && ('expand' in floorItem.fields || row.expand === null);

// item id -> ids of the floor rows that meet it.
export const floorMap = (table) => new Map(FLOOR_ITEMS.map((floorItem) =>
  [floorItem.id, table.rows.filter((row) => rowMeetsItem(row, floorItem)).map((row) => row.id)]));

export const floorProblems = (table) => [...floorMap(table)]
  .filter(([, rowIds]) => rowIds.length === 0)
  .map(([itemId]) => `MISSING_FLOOR ${itemId}: ${FLOOR_ITEMS.find((floorItem) => floorItem.id === itemId).description}`);

// The glob dialect of plan contract C3: `**/` spans zero or more whole
// directories, `*` and `?` never cross a `/`, `{a,b}` alternates.
export const globToRegExp = (glob) => {
  let pattern = '';
  for (let index = 0; index < glob.length; index += 1) {
    const character = glob[index];
    if (glob.startsWith('**/', index)) { pattern += '(?:[^/]+/)*'; index += 2; }
    else if (glob.startsWith('**', index)) { pattern += '.*'; index += 1; }
    else if (character === '*') pattern += '[^/]*';
    else if (character === '?') pattern += '[^/]';
    else if (character === '{') {
      const close = glob.indexOf('}', index);
      const options = glob.slice(index + 1, close).split(',').map((option) => option.replace(/[.+^$()|[\]\\]/g, '\\$&'));
      pattern += `(?:${options.join('|')})`;
      index = close;
    } else pattern += character.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${pattern}$`);
};

// Frontmatter `paths:` of a rule file: null when the rule has none (always
// loaded), else the list of globs.
export const rulePaths = (content) => {
  const match = /^---\n([\s\S]*?)\n---/.exec(content);
  if (!match || !/^paths:/m.test(match[1])) return null;
  const block = match[1].split('\n');
  const start = block.findIndex((line) => /^paths:/.test(line));
  const inline = block[start].replace(/^paths:\s*/, '');
  if (inline) return inline.replace(/^\[|\]$/g, '').split(',').map((entry) => entry.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  const globs = [];
  for (const line of block.slice(start + 1)) {
    const entry = /^\s+-\s+(.+)$/.exec(line);
    if (!entry) break;
    globs.push(entry[1].trim().replace(/^['"]|['"]$/g, ''));
  }
  return globs;
};

export const readSnapshotTree = (snapshotDirectory) => {
  const treePath = join(snapshotDirectory, 'tree.txt');
  if (!existsSync(treePath)) throw new TableError(`missing ${treePath}`);
  return readFileSync(treePath, 'utf8').split('\n').filter(Boolean);
};

const hookDisplay = (entry) => {
  const script = /\.(?:claude\/hooks|gaia\/[a-z-]+)\/[A-Za-z0-9._/-]+/.exec(entry.command);
  return `${entry.event}|${entry.matcher}|${script ? script[0] : entry.command}`;
};

// Hook entries of a settings file, probe entries excluded, deduplicated.
export const settingsHookEntries = (settings) => {
  const entries = new Map();
  for (const [event, groups] of Object.entries(settings?.hooks ?? {})) {
    for (const group of groups ?? []) {
      for (const hook of group.hooks ?? []) {
        if (typeof hook.command !== 'string' || hook.command.includes(PROBE_HOOK_MARKER)) continue;
        const entry = { event, matcher: group.matcher ?? '', command: hook.command };
        entries.set(`${event}\u0000${entry.matcher}\u0000${hook.command}`, entry);
      }
    }
  }
  return [...entries.values()];
};

export const readSnapshotJson = (snapshotDirectory, relativePath) => {
  const path = join(snapshotDirectory, 'files', relativePath);
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    throw new TableError(`cannot parse snapshot ${path}: ${error.message}`);
  }
};

// The concrete subjects one row stands for. Each is {subject, display, entry?}.
export const expandRow = (row, snapshotDirectory) => {
  if (row.expand === null) return [{ subject: row.subject, display: row.subject }];
  if (row.expand.startsWith('hooks:')) {
    const settings = readSnapshotJson(snapshotDirectory, row.expand.slice('hooks:'.length));
    return settingsHookEntries(settings).map((entry) => ({
      subject: `${entry.event}|${entry.matcher}|${entry.command}`, display: hookDisplay(entry), entry,
    }));
  }
  const [glob, qualifier = ''] = row.expand.split('#');
  if (!['', 'unscoped', 'scoped'].includes(qualifier)) throw new TableError(`row ${row.id}: unknown expand qualifier #${qualifier}`);
  const matcher = globToRegExp(glob);
  return readSnapshotTree(snapshotDirectory)
    .filter((path) => matcher.test(path))
    .filter((path) => {
      if (qualifier === '') return true;
      const filePath = join(snapshotDirectory, 'files', path);
      if (!existsSync(filePath)) throw new TableError(`row ${row.id}: ${path} is in tree.txt but not under the snapshot's files/`);
      const scoped = rulePaths(readFileSync(filePath, 'utf8')) !== null;
      return qualifier === 'scoped' ? scoped : !scoped;
    })
    .map((path) => ({ subject: path, display: path }));
};

// The key an observation of this kind is matched on: rules and CLAUDE.md by
// repo-relative path, skills and agents by name, everything else verbatim.
export const subjectKey = (kind, subject) => {
  if (kind === 'skill') {
    const skill = /(?:^|\/)\.claude\/skills\/([^/]+)\/SKILL\.md$/.exec(subject);
    if (skill) return skill[1];
    const command = /(?:^|\/)\.claude\/commands\/(.+)\.md$/.exec(subject);
    if (command) return command[1].replace(/\//g, ':');
  }
  if (kind === 'agent') {
    const agent = /(?:^|\/)\.claude\/agents\/(?:.*\/)?([^/]+)\.md$/.exec(subject);
    if (agent) return agent[1];
  }
  return subject;
};
