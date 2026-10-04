import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import {INVALID_OVERRIDE_EXIT, run} from './check-security-override.js';

let outputs: string[];

beforeEach(() => {
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const check = (key: string, value: string): number =>
  run([
    '--key',
    key,
    '--value',
    value,
    '--package',
    'cookie',
    '--first-patched',
    '0.7.0',
  ]);

describe('check-security-override', () => {
  test.each(['cookie', 'react-router>cookie'])(
    'accepts %s mapped to the first patched floor',
    (key) => {
      expect(check(key, '>=0.7.0')).toBe(EXIT_CODES.OK);
      expect(JSON.parse(outputs.join(''))).toStrictEqual({valid: true});
    }
  );

  test.each([
    ['cookie', 'npm:cookie@0.7.0'],
    ['cookie', '>=0.7.0 || <0.1.0'],
    ['cookie', '>=0.6.9'],
    ['cookie', 'workspace:*'],
    ['cookie', 'https://evil.example/cookie.tgz'],
    ['a>b>cookie', '>=0.7.0'],
    ['react-router>other', '>=0.7.0'],
    ['cookie', '>= 0.7.0'],
    ['>cookie', '>=0.7.0'],
    ['Bad Parent>cookie', '>=0.7.0'],
  ])('refuses key %s with value %s', (key, value) => {
    expect(check(key, value)).toBe(INVALID_OVERRIDE_EXIT);

    const result = JSON.parse(outputs.join('')) as {valid: boolean};

    expect(result.valid).toBe(false);
  });

  test('refuses a first patched version that is not semver', () => {
    const exit = run([
      '--key',
      'cookie',
      '--value',
      '>=latest',
      '--package',
      'cookie',
      '--first-patched',
      'latest',
    ]);

    expect(exit).toBe(INVALID_OVERRIDE_EXIT);
  });

  test('a missing argument or unknown flag is a usage error', () => {
    expect(run(['--key', 'cookie'])).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(run(['--bogus', 'x'])).toBe(EXIT_CODES.INVALID_ARGUMENTS);
  });

  test('--help prints usage naming the verb and exits 0', () => {
    expect(run(['--help'])).toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain(
      'Usage: gaia update-deps check-security-override'
    );
  });
});
