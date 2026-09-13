import {describe, expect, test} from 'vitest';
import type {CorpusProvider} from '../corpus.js';
import {resolveCitedLine, unresolvedResolver} from '../resolve.js';

const fakeProvider = (params: {
  currentText?: null | string;
  headText?: null | string;
}): CorpusProvider => ({
  blobAt: () => params.headText ?? null,
  blobAtHead: () => params.currentText ?? null,
  mergedPrs: () => ({ok: true, prs: [], truncated: false}),
  techDebtIssues: () => ({issues: [], ok: true}),
});

describe('resolveCitedLine', () => {
  test('still: the cited content is unchanged at current HEAD, same line', () => {
    const provider = fakeProvider({
      currentText: 'line one\nline two\nline three\n',
      headText: 'line one\nline two\nline three\n',
    });

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'still', resolved_line_text: 'line two'});
  });

  test('moved: the cited content survives but at a different line', () => {
    const provider = fakeProvider({
      currentText: 'preamble\nline one\nline two\nline three\n',
      headText: 'line one\nline two\nline three\n',
    });

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'moved', resolved_line_text: 'line two'});
  });

  test('gone: the cited content appears nowhere at current HEAD', () => {
    const provider = fakeProvider({
      currentText: 'entirely different content\n',
      headText: 'line one\nline two\n',
    });

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'gone', resolved_line_text: 'line two'});
  });

  test('gone: the file is absent at current HEAD', () => {
    const provider = fakeProvider({
      currentText: null,
      headText: 'line one\nline two\n',
    });

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'gone', resolved_line_text: 'line two'});
  });

  test('unresolvable: the cited line is blank at the head object', () => {
    const provider = fakeProvider({
      currentText: 'anything\n',
      headText: 'line one\n   \nline three\n',
    });

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'unresolvable', resolved_line_text: ''});
  });

  test('unresolvable: the head object could not be read at all', () => {
    const provider = fakeProvider({headText: null});

    expect(
      resolveCitedLine(provider, {
        headSha: 'abc',
        line: 2,
        path: 'x.ts',
        prNumber: 1,
      })
    ).toEqual({resolution: 'unresolvable', resolved_line_text: ''});
  });

  test('unresolvedResolver never touches the provider and always reports unresolved', () => {
    expect(unresolvedResolver()).toEqual({
      resolution: 'unresolved',
      resolved_line_text: '',
    });
  });
});
