/**
 * Vitest mock for the `runGh` / `runGit` helpers.
 *
 * The fixture intercepts at the CLI's helper layer
 * (`src/ci/util/run-process.ts`) so the slice 2 handlers shell out
 * "for real" and the mock returns scripted JSON / exit codes per a
 * scenario object. This mirrors slice 1's pattern of testing CLI
 * surfaces without spawning external processes.
 */
import {vi} from 'vitest';
import * as runProcess from '../../src/ci/util/run-process.js';
import type {ProcessResult} from '../../src/ci/util/run-process.js';

export type GhCall = {
  argv: readonly string[];
  cwd?: string;
};

export type GhMockResponse = ProcessResult;

export type ScenarioResponse = {
  match: string | RegExp;
  response: GhMockResponse;
};

export type GhMockScenario = {
  gh?: ScenarioResponse[];
  git?: ScenarioResponse[];
};

export type GhMock = {
  ghCalls: GhCall[];
  gitCalls: GhCall[];
  reset: () => void;
  restore: () => void;
};

const matches = (matcher: string | RegExp, joined: string): boolean => {
  if (matcher instanceof RegExp) return matcher.test(joined);

  return joined.includes(matcher);
};

const respond = (
  responses: readonly ScenarioResponse[] | undefined,
  argv: readonly string[]
): GhMockResponse => {
  const joined = argv.join(' ');
  const match = (responses ?? []).find((entry) => matches(entry.match, joined));

  if (match === undefined) {
    return {
      exitCode: 0,
      stderr: '',
      stdout: '',
    };
  }

  return match.response;
};

export const installGhMock = (scenario: GhMockScenario): GhMock => {
  const ghCalls: GhCall[] = [];
  const gitCalls: GhCall[] = [];

  const ghSpy = vi
    .spyOn(runProcess, 'runGh')
    .mockImplementation((argv: readonly string[], options) => {
      ghCalls.push({argv, cwd: options?.cwd});

      return respond(scenario.gh, argv);
    });

  const gitSpy = vi
    .spyOn(runProcess, 'runGit')
    .mockImplementation((argv: readonly string[], options) => {
      gitCalls.push({argv, cwd: options?.cwd});

      return respond(scenario.git, argv);
    });

  return {
    ghCalls,
    gitCalls,
    reset: () => {
      ghCalls.length = 0;
      gitCalls.length = 0;
    },
    restore: () => {
      ghSpy.mockRestore();
      gitSpy.mockRestore();
    },
  };
};
