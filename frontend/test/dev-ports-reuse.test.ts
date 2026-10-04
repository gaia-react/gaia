/* eslint-disable unicorn/prevent-abbreviations -- the module under test is named dev-ports-reuse */
import {describe, expect, test, vi} from 'vitest';
import {ASK_FIRST_SENTENCE} from '../dev-ports';
import type {ListenerOwner} from '../dev-ports';
import {decideServerReuse} from '../dev-ports-reuse';

const decide = (
  owner: ListenerOwner,
  isContinuousIntegration = false
): {decision: boolean | Error; probe: ReturnType<typeof vi.fn>} => {
  const probe = vi.fn(() => owner);

  try {
    return {
      decision: decideServerReuse({
        isContinuousIntegration,
        port: 5180,
        probe,
        treeRoot: '/trees/mine',
      }),
      probe,
    };
  } catch (error) {
    return {decision: error as Error, probe};
  }
};

describe('decideServerReuse', () => {
  test('reuses a server this tree owns', () => {
    expect(decide({kind: 'own', pid: 10}).decision).toBe(true);
  });

  test('does not reuse a free port', () => {
    expect(decide({kind: 'free'}).decision).toBe(false);
  });

  test('does not reuse when ownership is unknown', () => {
    expect(decide({kind: 'unknown'}).decision).toBe(false);
  });

  test('in continuous integration never reuses and never probes', () => {
    const {decision, probe} = decide({kind: 'own', pid: 10}, true);

    expect(decision).toBe(false);
    expect(probe).not.toHaveBeenCalled();
  });

  test('a foreign server with an owner path throws naming port, path, and the ask-first sentence', () => {
    const {decision} = decide({
      kind: 'foreign',
      ownerPath: '/trees/other',
      pid: 11,
    });

    expect(decision).toBeInstanceOf(Error);
    const {message} = decision as Error;
    expect(message).toContain('5180');
    expect(message).toContain('/trees/other');
    expect(message).toContain(ASK_FIRST_SENTENCE);
  });

  test('a foreign server with no owner path throws naming owner unknown', () => {
    const {decision} = decide({
      kind: 'foreign',
      ownerPath: undefined,
      pid: 0,
    });

    expect(decision).toBeInstanceOf(Error);
    expect((decision as Error).message).toContain('owner unknown');
  });

  test('defaults the probe to the real listener lookup, which answers unknown without a tree root', () => {
    expect(
      decideServerReuse({
        isContinuousIntegration: false,
        port: 5180,
        treeRoot: undefined,
      })
    ).toBe(false);
  });
});
