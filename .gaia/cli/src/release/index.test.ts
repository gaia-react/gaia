import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import {run} from './index.js';

let stderrSpy: ReturnType<typeof vi.spyOn>;
let stdoutSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
  stdoutSpy = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
});

afterEach(() => {
  stderrSpy.mockRestore();
  stdoutSpy.mockRestore();
});

const stderrPayload = (): Record<string, unknown> =>
  JSON.parse(String(stderrSpy.mock.calls[0]?.[0] ?? '{}')) as Record<
    string,
    unknown
  >;

const stdoutText = (): string => String(stdoutSpy.mock.calls[0]?.[0] ?? '');

describe('release subcommand router', () => {
  test.each(['--help', '-h', 'help'])(
    '%s prints help and exits 0',
    async (token) => {
      await expect(run([token])).resolves.toBe(EXIT_CODES.OK);
      expect(stdoutText()).toContain('Usage: gaia-maintainer release');
      expect(stderrSpy).not.toHaveBeenCalled();
    }
  );

  test('no subcommand prints help and exits 0', async () => {
    await expect(run([])).resolves.toBe(EXIT_CODES.OK);
    expect(stdoutText()).toContain('Usage: gaia-maintainer release');
  });

  test('an unknown subcommand exits non-zero', async () => {
    await expect(run(['bogus'])).resolves.not.toBe(EXIT_CODES.OK);
    expect(stderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });

  // A bare `Record` index resolves every `Object.prototype` member, so these
  // tokens would dispatch to an inherited method: the callable ones ran and
  // returned a non-number (silently exiting 0 without doing anything), and
  // `__proto__` resolved to a non-callable and crashed the router. Each must be
  // rejected as an unknown subcommand like any other typo.
  test.each([
    'toString',
    'constructor',
    'valueOf',
    'hasOwnProperty',
    '__proto__',
  ])('the Object.prototype member %s is not a subcommand', async (token) => {
    await expect(run([token])).resolves.not.toBe(EXIT_CODES.OK);
    expect(stderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });
});
