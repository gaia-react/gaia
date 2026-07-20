import {describe, expect, test, vi} from 'vitest';
import {COMMIT_TYPES} from '../../util/conventional-commit.js';
import {checkSubject, run} from '../check-subject.js';

describe('checkSubject', () => {
  test.each([...COMMIT_TYPES])('%s: is accepted', (type) => {
    const checked = checkSubject(`${type}(scope): do the thing`);
    expect(checked.ok).toBe(true);
  });

  test('an unscoped subject is accepted', () => {
    expect(checkSubject('fix: do the thing').ok).toBe(true);
  });

  test('a breaking marker is accepted', () => {
    expect(checkSubject('feat(api)!: drop the endpoint').ok).toBe(true);
  });

  // The two real non-conforming subjects observed on main were both PR
  // titles, which is the artifact this check exists for: squash merges make
  // the title the subject on main and discard the branch commits.
  test.each([
    'Harden the Code Audit Team merge gate (#793)',
    'Remove the adaptive mentorship layer (SPEC-038) (#763)',
  ])('%s is rejected as non-conventional', (subject) => {
    const checked = checkSubject(subject);
    expect(checked.ok).toBe(false);
    expect(checked.ok ? '' : checked.message).toContain(
      'not a conventional-commit subject'
    );
  });

  test('a well-formed but undeclared type is rejected by name', () => {
    const checked = checkSubject('spike(cli): try a thing');
    expect(checked.ok).toBe(false);
    expect(checked.ok ? '' : checked.message).toContain(
      '"spike" is not a declared commit type'
    );
  });

  test('a type with no description is rejected', () => {
    const checked = checkSubject('fix(cli):');
    expect(checked.ok).toBe(false);
    expect(checked.ok ? '' : checked.message).toContain('no description');
  });

  test('the rejection message names the declared vocabulary', () => {
    const checked = checkSubject('nope');
    expect(checked.ok ? '' : checked.message).toContain('debt');
  });
});

const capture = (): {errors: string[]; restore: () => void} => {
  const errors: string[] = [];
  const spy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(String(chunk));

      return true;
    });
  const outSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation(() => true);

  return {
    errors,
    restore: () => {
      spy.mockRestore();
      outSpy.mockRestore();
    },
  };
};

describe('run', () => {
  test('exits 0 on a valid subject', () => {
    const stdio = capture();
    expect(run(['--subject', 'fix(cli): repair the parser'])).toBe(0);
    stdio.restore();
  });

  test('exits 1 and reports on an invalid subject', () => {
    const stdio = capture();
    expect(run(['--subject', 'Harden the merge gate (#793)'])).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid_subject');
    stdio.restore();
  });

  test('exits 1 when --subject is missing', () => {
    const stdio = capture();
    expect(run(['--json'])).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
    stdio.restore();
  });
});
