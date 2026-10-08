#!/usr/bin/env node
// compare.mjs: the Claude probe's pure comparator. Judges a probe-run evidence
// directory against the committed expectation table. Makes no Claude calls.
//
// Usage:
//   compare.mjs <expectations.json> <evidence_dir> [--only <row-id-glob>] [--first-run-commit <sha>]
//   compare.mjs --check-table <expectations.json> [--root-settings <settings.json>]
//   compare.mjs --floor-map <expectations.json>
//   compare.mjs --plan <expectations.json> [--only <row-id-glob>]
//
// Exit 0: every observation in every repetition matches and nothing in scope
// was observed that no row covers. Exit 1: a MISMATCH, UNLISTED, EMPTY
// (a row whose expansion found nothing), UNCITED, SCHEMA or MISSING_FLOOR
// line. Exit 2: usage error, or evidence or table that cannot be parsed;
// never 0 on unreadable input. A NOTE line is information and never changes
// the exit code.
//
// --plan prints the scenarios run-probe.sh must run, one per line:
// launch<TAB>trigger<TAB>scenario-slug<TAB>needs-listing-turn(0|1).
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { basename, dirname, join, relative } from 'node:path';
import {
  EvidenceError, ifGateSpawnCount, listedNames, loadScenario, loadedInstructionPaths, observe, scenarioSlug,
  sessionCommandNames, sessionProblem,
} from './lib/observe.mjs';
import {
  FLOOR_ITEMS, LAUNCHES, TableError, expandRow, floorMap, floorProblems, globToRegExp, parseIfSubject,
  readSnapshotJson, readSnapshotTree, readTable, schemaProblems, subjectKey,
} from './lib/table.mjs';

const USAGE = 'usage: compare.mjs <expectations.json> <evidence_dir> [--only <row-id-glob>] [--first-run-commit <sha>]\n'
  + '       compare.mjs --check-table <expectations.json> [--root-settings <settings.json>]\n'
  + '       compare.mjs --floor-map <expectations.json>\n'
  + '       compare.mjs --plan <expectations.json> [--only <row-id-glob>]';

class UsageError extends Error {}

const parseArguments = (argv) => {
  const options = { positional: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const takesValue = ['--only', '--first-run-commit', '--root-settings'];
    if (takesValue.includes(argument)) {
      if (index + 1 >= argv.length) throw new UsageError(`${argument} needs a value`);
      options[argument.slice(2)] = argv[index + 1];
      index += 1;
    } else if (['--check-table', '--floor-map', '--plan'].includes(argument)) {
      if (options.mode) throw new UsageError('pass at most one of --check-table, --floor-map, --plan');
      options.mode = argument.slice(2);
    } else if (argument.startsWith('--')) throw new UsageError(`unknown option ${argument}`);
    else options.positional.push(argument);
  }
  return options;
};

const selectRows = (table, onlyGlob) => {
  if (!onlyGlob) return table.rows;
  const matcher = globToRegExp(onlyGlob);
  return table.rows.filter((row) => matcher.test(row.id));
};

// Every Edit(...) deny in the root settings must be exercised, from both
// launch dirs, by a floor permission row whose target the deny glob matches.
const denyCoverageProblems = (table, rootSettingsPath) => {
  const settings = JSON.parse(readFileSync(rootSettingsPath, 'utf8'));
  const denies = (settings.permissions?.deny ?? []).map((rule) => /^Edit\((.*)\)$/.exec(rule)?.[1]).filter(Boolean);
  if (denies.length === 0) return [`MISSING_FLOOR deny-set: ${rootSettingsPath} has no Edit(...) deny rule to exercise`];
  const problems = [];
  for (const deny of denies) {
    const matcher = globToRegExp(deny.replace(/^\.\//, '').replace(/^\//, ''));
    for (const launch of ['frontend', 'root']) {
      const covered = table.rows.some((row) => row.floor === true && row.launch === launch && row.kind === 'permission'
        && row.expect === 'deny' && row.subject.startsWith('Edit ') && matcher.test(row.subject.slice('Edit '.length)));
      if (!covered) problems.push(`MISSING_FLOOR deny-${launch}: no ${launch} floor row exercises root deny Edit(${deny})`);
    }
  }
  return problems;
};

const tableProblems = (table, rootSettingsPath) => [
  ...schemaProblems(table),
  ...floorProblems(table),
  ...(rootSettingsPath ? denyCoverageProblems(table, rootSettingsPath) : []),
];

const canonicalRow = (row) => {
  const { cited_run: citedRun, ...rest } = row;
  return JSON.stringify(rest, Object.keys(rest).sort());
};

// A row changed since the first probe run must cite the run that justified
// the change; a row deleted since then cannot cite anything and always fails.
const uncitedProblems = (table, tablePath, firstRunCommit) => {
  const directory = dirname(tablePath);
  let repoRoot;
  let previous;
  try {
    repoRoot = execFileSync('git', ['-C', directory, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
    // realpath on both sides: macOS reports /var temp paths as /private/var.
    const relativePath = relative(realpathSync(repoRoot), realpathSync(tablePath));
    previous = JSON.parse(execFileSync('git', ['-C', repoRoot, 'show', `${firstRunCommit}:${relativePath}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
  } catch (error) {
    throw new UsageError(`cannot read the table at --first-run-commit ${firstRunCommit}: ${error.message.split('\n')[0]}`);
  }
  const previousRows = new Map((previous.rows ?? []).map((row) => [row.id, row]));
  const problems = [];
  for (const row of table.rows) {
    const before = previousRows.get(row.id);
    if ((!before || canonicalRow(before) !== canonicalRow(row)) && row.cited_run === null) problems.push(`UNCITED ${row.id}`);
  }
  const currentIds = new Set(table.rows.map((row) => row.id));
  for (const id of previousRows.keys()) if (!currentIds.has(id)) problems.push(`UNCITED ${id} (deleted since the first run)`);
  return problems;
};

const planLines = (table, onlyGlob) => {
  const rows = selectRows(table, onlyGlob);
  const scenarios = new Map();
  const add = (launch, trigger, needsListing) => {
    const key = `${launch}\t${trigger}`;
    scenarios.set(key, (scenarios.get(key) ?? 0) | (needsListing ? 1 : 0));
  };
  for (const row of rows) {
    if (row.signal === 'manual') continue;
    // Skill rows read the first turn's commands_changed events, so only agent
    // and MCP rows still need the second (listing) turn.
    add(row.launch, row.trigger, row.trigger.startsWith('after_read:') && ['agent', 'mcp'].includes(row.kind));
    if (row.trigger === 'after_task:commit' && row.subject === 'commit-parity') add('root', 'after_task:commit', false);
  }
  const triggerOrder = (trigger) => (trigger === 'session_start' ? '0' : `1${trigger}`);
  return [...scenarios].map(([key, needsListing]) => {
    const [launch, trigger] = key.split('\t');
    return { launch, trigger, needsListing };
  }).sort((left, right) => LAUNCHES.indexOf(left.launch) - LAUNCHES.indexOf(right.launch)
    || triggerOrder(left.trigger).localeCompare(triggerOrder(right.trigger)))
    .map(({ launch, trigger, needsListing }) => `${launch}\t${trigger}\t${scenarioSlug(trigger)}\t${needsListing}`);
};

const inventory = (snapshotDirectory) => {
  const tree = readSnapshotTree(snapshotDirectory);
  const skills = new Set();
  const agents = new Set();
  for (const path of tree) {
    const skill = /(?:^|\/)\.claude\/skills\/([^/]+)\/SKILL\.md$/.exec(path);
    if (skill) skills.add(skill[1]);
    const command = /(?:^|\/)\.claude\/commands\/(.+)\.md$/.exec(path);
    if (command) skills.add(command[1].replace(/\//g, ':'));
    const agent = /(?:^|\/)\.claude\/agents\/(?:.*\/)?([^/]+)\.md$/.exec(path);
    if (agent) agents.add(agent[1]);
  }
  const mcp = new Set(Object.keys(readSnapshotJson(snapshotDirectory, '.mcp.json')?.mcpServers ?? {}));
  return { skill: skills, agent: agents, mcp };
};

const baseName = (listed) => listed.split(':').pop();

const runCompare = (tablePath, evidenceDirectory, options) => {
  const table = readTable(tablePath);
  // The deny-set check runs against the root settings the run snapshotted, so
  // a deny added to the target after the table was written fails here.
  const snapshotSettings = join(evidenceDirectory, 'snapshot', 'root', 'files', '.claude', 'settings.json');
  const problems = tableProblems(table, existsSync(snapshotSettings) ? snapshotSettings : null);
  if (options['first-run-commit']) problems.push(...uncitedProblems(table, tablePath, options['first-run-commit']));
  const metaPath = join(evidenceDirectory, 'meta.json');
  if (!existsSync(metaPath)) throw new EvidenceError(`missing ${metaPath}`);
  let meta;
  try {
    meta = JSON.parse(readFileSync(metaPath, 'utf8'));
  } catch (error) {
    throw new EvidenceError(`malformed ${metaPath}: ${error.message}`);
  }
  if (!Number.isInteger(meta.reps) || meta.reps < 1) throw new EvidenceError(`${metaPath}: reps must be a positive integer`);
  const tableSha = createHash('sha256').update(readFileSync(tablePath)).digest('hex');
  if (meta.table_sha256 && meta.table_sha256 !== tableSha) {
    console.log(`NOTE the table differs from the one this run recorded (table_sha256 ${meta.table_sha256}); judging against the current table`);
  }

  const snapshotFor = (launch) => join(evidenceDirectory, 'snapshot', launch);
  const rows = selectRows(table, options.only).filter((row) => row.signal !== 'manual');
  const expansions = new Map();
  for (const row of table.rows) {
    if (row.signal === 'manual' || !existsSync(snapshotFor(row.launch))) continue;
    expansions.set(row.id, expandRow(row, snapshotFor(row.launch)));
  }

  let floorMismatches = 0;
  let otherMismatches = 0;
  // Informational, never a failure: the dedup row's spawn count decides how a
  // hook registered under two rules is gated, so it is printed even on a match.
  const notes = [];
  for (const row of rows) {
    if (!existsSync(snapshotFor(row.launch))) {
      problems.push(`MISMATCH ${row.id} rep=* expected=${row.expect} observed=launch_not_run`);
      if (row.floor) floorMismatches += 1; else otherMismatches += 1;
      continue;
    }
    const expanded = expansions.get(row.id);
    if (expanded.length === 0) {
      problems.push(`EMPTY ${row.id} launch=${row.launch}: "${row.expand}" matched nothing in the target tree`);
      if (row.floor) floorMismatches += 1; else otherMismatches += 1;
      continue;
    }
    for (let rep = 1; rep <= meta.reps; rep += 1) {
      const scenarioDirectory = join(evidenceDirectory, `rep-${rep}`, row.launch, scenarioSlug(row.trigger));
      const data = loadScenario(scenarioDirectory);
      const rootCommit = loadScenario(join(evidenceDirectory, `rep-${rep}`, 'root', scenarioSlug('after_task:commit')));
      for (const item of expanded) {
        const observed = observe(row, item, data, snapshotFor(row.launch), { key: subjectKey(row.kind, item.subject), rootCommit });
        if (observed !== row.expect) {
          const label = row.expand === null ? row.id : `${row.id}@${item.display.replace(/\s+/g, '_')}`;
          problems.push(`MISMATCH ${label} rep=${rep} expected=${row.expect} observed=${observed}`);
          if (row.floor) floorMismatches += 1; else otherMismatches += 1;
        }
        if (row.kind === 'hook_if' && parseIfSubject(row.subject)?.rule === 'dedup') {
          notes.push(`NOTE ${row.id} rep=${rep} spawn_count=${ifGateSpawnCount(row, data)}`);
        }
      }
    }
  }

  // UNLISTED: anything in the target's scope a session showed that no row
  // for that launch covers. Ambient items (user-level CLAUDE.md, auto memory,
  // personal skills, built-in agents, user MCP servers) are out of scope.
  const coverage = new Map();
  for (const row of table.rows) {
    for (const item of expansions.get(row.id) ?? []) {
      coverage.set(`${row.launch}\t${row.kind}\t${subjectKey(row.kind, item.subject)}`, true);
    }
  }
  const unlisted = new Set();
  for (let rep = 1; rep <= meta.reps; rep += 1) {
    for (const launch of LAUNCHES) {
      if (!existsSync(snapshotFor(launch))) continue;
      const scope = inventory(snapshotFor(launch));
      const launchDirectory = join(evidenceDirectory, `rep-${rep}`, launch);
      if (!existsSync(launchDirectory)) continue;
      for (const slug of scenarioDirectories(launchDirectory)) {
        const data = loadScenario(join(launchDirectory, slug));
        if (sessionProblem(data)) continue;
        for (const path of loadedInstructionPaths(data)) {
          if (path.startsWith('@outside:')) continue;
          const kind = basename(path) === 'CLAUDE.md' || basename(path) === 'CLAUDE.local.md' ? 'claude_md' : 'rule';
          if (!coverage.has(`${launch}\t${kind}\t${path}`)) unlisted.add(`UNLISTED ${kind} ${path} launch=${launch}`);
        }
        for (const stream of data.streams) {
          const init = (stream ?? []).find((event) => event.type === 'system' && event.subtype === 'init');
          for (const kind of ['skill', 'agent', 'mcp']) {
            const listedForKind = kind === 'skill' ? sessionCommandNames(stream) : listedNames(init, kind);
            for (const listed of listedForKind) {
              const key = kind === 'mcp' ? listed : baseName(listed);
              if (!scope[kind].has(key)) continue;
              if (!coverage.has(`${launch}\t${kind}\t${key}`)) unlisted.add(`UNLISTED ${kind} ${key} launch=${launch}`);
            }
          }
        }
      }
    }
  }
  problems.push(...unlisted);
  for (const line of problems) console.log(line);
  for (const line of notes) console.log(line);
  console.log(`SUMMARY floor_mismatches=${floorMismatches} other_mismatches=${otherMismatches} unlisted=${unlisted.size} reps=${meta.reps}`);
  return problems.length === 0 ? 0 : 1;
};

const scenarioDirectories = (directory) => readdirSync(directory, { withFileTypes: true })
  .filter((entry) => entry.isDirectory()).map((entry) => entry.name);

const main = () => {
  const options = parseArguments(process.argv.slice(2));
  if (options.mode === 'check-table' || options.mode === 'floor-map' || options.mode === 'plan') {
    if (options.positional.length !== 1) throw new UsageError(`--${options.mode} takes exactly one table path`);
    const table = readTable(options.positional[0]);
    if (options.mode === 'floor-map') {
      for (const [itemId, rowIds] of floorMap(table)) console.log(`${itemId}\t${rowIds.join(',')}`);
      return 0;
    }
    if (options.mode === 'plan') {
      const schema = schemaProblems(table);
      if (schema.length > 0) {
        schema.forEach((line) => console.log(line));
        return 1;
      }
      planLines(table, options.only).forEach((line) => console.log(line));
      return 0;
    }
    const problems = tableProblems(table, options['root-settings']);
    problems.forEach((line) => console.log(line));
    if (problems.length === 0) console.log(`OK ${table.rows.length} rows, ${FLOOR_ITEMS.length} floor items met`);
    return problems.length === 0 ? 0 : 1;
  }
  if (options.positional.length !== 2) throw new UsageError('expected <expectations.json> <evidence_dir>');
  return runCompare(options.positional[0], options.positional[1], options);
};

try {
  process.exitCode = main();
} catch (error) {
  if (error instanceof UsageError) console.error(`compare.mjs: ${error.message}\n${USAGE}`);
  else if (error instanceof EvidenceError || error instanceof TableError) console.error(`compare.mjs: ${error.message}`);
  else console.error(`compare.mjs: unexpected error: ${error.stack}`);
  process.exitCode = 2;
}

