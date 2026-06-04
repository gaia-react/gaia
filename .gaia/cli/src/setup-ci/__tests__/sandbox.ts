/**
 * Shared sandbox helpers for setup-ci tests.
 *
 * Two scopes overlap here:
 *
 * 1. Filesystem sandbox: `setupSandbox` creates a tmp dir with
 *    `git init` + an initial commit + `.gaia/` ready for config files.
 *    Mirror's slice 1's `automation/__tests__/sandbox.ts` shape.
 *
 * 2. `gh` shim: `installGhShim` writes a tiny Node script to
 *    `<sandbox>/bin/gh` that records argv + stdin to sandbox files
 *    and emits scripted stdout / exit code. Tests that assert the
 *    secret never appears on argv use this shim end-to-end (PATH
 *    override) rather than spying on `runGh` directly.
 */
import {execFileSync} from 'node:child_process';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {automationConfigPath} from '../../automation/paths.js';
import type {AutomationConfig} from '../../schemas/automation-config.js';

export type Sandbox = {
  binDir: string;
  cleanup: () => void;
  ghArgvPath: string;
  ghExitCodeQueuePath: string;
  ghStderrQueuePath: string;
  ghStdinPath: string;
  ghStdoutQueuePath: string;
  installGhShim: (options?: {
    exitCode?: number;
    exitCodeQueue?: number[];
    stderrQueue?: string[];
    stdoutQueue?: string[];
  }) => {pathOverride: string; restore: () => void};
  root: string;
  writeConfig: (config: AutomationConfig) => void;
};

export const VALID_BASE_CONFIG: AutomationConfig = {
  pnpm_audit: {mode: 'ci', schedule: 'weekly'},
  setup_complete: false,
  setup_opted_out: false,
  stale_branches: {mode: 'ci', schedule: 'monthly'},
  update_deps: {mode: 'ci', schedule: 'weekly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci', schedule: 'daily'},
};

const SHIM_NODE_SOURCE = `#!/usr/bin/env node
// Sandbox \`gh\` shim. Records argv + stdin and emits scripted output.
import {appendFileSync, readFileSync, writeFileSync, existsSync} from 'node:fs';

const argvFile = process.env.GH_SHIM_ARGV_FILE;
const stdinFile = process.env.GH_SHIM_STDIN_FILE;
const stdoutQueueFile = process.env.GH_SHIM_STDOUT_QUEUE_FILE;
const stderrQueueFile = process.env.GH_SHIM_STDERR_QUEUE_FILE;
const exitCodeQueueFile = process.env.GH_SHIM_EXIT_CODE_QUEUE_FILE;
const fallbackExitCode = Number.parseInt(process.env.GH_SHIM_EXIT_CODE ?? '0', 10);
const args = process.argv.slice(2);

if (argvFile) {
  let lines = [];
  if (existsSync(argvFile)) {
    try { lines = JSON.parse(readFileSync(argvFile, 'utf8')); } catch { lines = []; }
  }
  lines.push(args);
  writeFileSync(argvFile, JSON.stringify(lines), 'utf8');
}

const chunks = [];
process.stdin.on('data', (chunk) => chunks.push(chunk));
process.stdin.on('end', () => {
  const buf = Buffer.concat(chunks);
  if (stdinFile) {
    appendFileSync(stdinFile, buf);
  }
  if (stdoutQueueFile && existsSync(stdoutQueueFile)) {
    let queue = [];
    try { queue = JSON.parse(readFileSync(stdoutQueueFile, 'utf8')); } catch { queue = []; }
    const next = queue.shift();
    writeFileSync(stdoutQueueFile, JSON.stringify(queue), 'utf8');
    if (typeof next === 'string') {
      process.stdout.write(next);
    }
  }
  if (stderrQueueFile && existsSync(stderrQueueFile)) {
    let queue = [];
    try { queue = JSON.parse(readFileSync(stderrQueueFile, 'utf8')); } catch { queue = []; }
    const next = queue.shift();
    writeFileSync(stderrQueueFile, JSON.stringify(queue), 'utf8');
    if (typeof next === 'string') {
      process.stderr.write(next);
    }
  }
  let exitCode = fallbackExitCode;
  if (exitCodeQueueFile && existsSync(exitCodeQueueFile)) {
    let q = [];
    try { q = JSON.parse(readFileSync(exitCodeQueueFile, 'utf8')); } catch { q = []; }
    if (q.length > 0) {
      exitCode = q.shift();
      writeFileSync(exitCodeQueueFile, JSON.stringify(q), 'utf8');
    }
  }
  process.exit(exitCode);
});
`;

export const setupSandbox = (prefix = 'gaia-setup-ci-'): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), prefix));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});

  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  const binDir = path.join(root, 'bin');
  mkdirSync(binDir, {recursive: true});

  const ghArgvPath = path.join(root, 'gh-argv.json');
  const ghStdinPath = path.join(root, 'gh-stdin.bin');
  const ghStdoutQueuePath = path.join(root, 'gh-stdout-queue.json');
  const ghStderrQueuePath = path.join(root, 'gh-stderr-queue.json');
  const ghExitCodeQueuePath = path.join(root, 'gh-exit-code-queue.json');

  const writeConfig = (config: AutomationConfig): void => {
    writeFileSync(automationConfigPath(root), JSON.stringify(config), 'utf8');
  };

  const installGhShim = (
    options: {
      exitCode?: number;
      exitCodeQueue?: number[];
      stderrQueue?: string[];
      stdoutQueue?: string[];
    } = {}
  ): {pathOverride: string; restore: () => void} => {
    const shimPath = path.join(binDir, 'gh');
    writeFileSync(shimPath, SHIM_NODE_SOURCE, 'utf8');
    chmodSync(shimPath, 0o755);
    writeFileSync(
      ghStdoutQueuePath,
      JSON.stringify(options.stdoutQueue ?? []),
      'utf8'
    );
    writeFileSync(
      ghStderrQueuePath,
      JSON.stringify(options.stderrQueue ?? []),
      'utf8'
    );
    writeFileSync(
      ghExitCodeQueuePath,
      JSON.stringify(options.exitCodeQueue ?? []),
      'utf8'
    );

    const previousPath = process.env.PATH;
    const previousArgv = process.env.GH_SHIM_ARGV_FILE;
    const previousStdin = process.env.GH_SHIM_STDIN_FILE;
    const previousQueue = process.env.GH_SHIM_STDOUT_QUEUE_FILE;
    const previousStderrQueue = process.env.GH_SHIM_STDERR_QUEUE_FILE;
    const previousExitQueue = process.env.GH_SHIM_EXIT_CODE_QUEUE_FILE;
    const previousExitCode = process.env.GH_SHIM_EXIT_CODE;

    process.env.PATH = `${binDir}${path.delimiter}${previousPath ?? ''}`;
    process.env.GH_SHIM_ARGV_FILE = ghArgvPath;
    process.env.GH_SHIM_STDIN_FILE = ghStdinPath;
    process.env.GH_SHIM_STDOUT_QUEUE_FILE = ghStdoutQueuePath;
    process.env.GH_SHIM_STDERR_QUEUE_FILE = ghStderrQueuePath;
    process.env.GH_SHIM_EXIT_CODE_QUEUE_FILE = ghExitCodeQueuePath;
    process.env.GH_SHIM_EXIT_CODE = String(options.exitCode ?? 0);

    return {
      pathOverride: process.env.PATH,
      restore: () => {
        if (previousPath === undefined) {
          delete process.env.PATH;
        } else {
          process.env.PATH = previousPath;
        }
        if (previousArgv === undefined) {
          delete process.env.GH_SHIM_ARGV_FILE;
        } else {
          process.env.GH_SHIM_ARGV_FILE = previousArgv;
        }
        if (previousStdin === undefined) {
          delete process.env.GH_SHIM_STDIN_FILE;
        } else {
          process.env.GH_SHIM_STDIN_FILE = previousStdin;
        }
        if (previousQueue === undefined) {
          delete process.env.GH_SHIM_STDOUT_QUEUE_FILE;
        } else {
          process.env.GH_SHIM_STDOUT_QUEUE_FILE = previousQueue;
        }
        if (previousStderrQueue === undefined) {
          delete process.env.GH_SHIM_STDERR_QUEUE_FILE;
        } else {
          process.env.GH_SHIM_STDERR_QUEUE_FILE = previousStderrQueue;
        }
        if (previousExitQueue === undefined) {
          delete process.env.GH_SHIM_EXIT_CODE_QUEUE_FILE;
        } else {
          process.env.GH_SHIM_EXIT_CODE_QUEUE_FILE = previousExitQueue;
        }
        if (previousExitCode === undefined) {
          delete process.env.GH_SHIM_EXIT_CODE;
        } else {
          process.env.GH_SHIM_EXIT_CODE = previousExitCode;
        }
      },
    };
  };

  return {
    binDir,
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ghArgvPath,
    ghExitCodeQueuePath,
    ghStderrQueuePath,
    ghStdinPath,
    ghStdoutQueuePath,
    installGhShim,
    root,
    writeConfig,
  };
};
