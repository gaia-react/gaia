// @vitest-environment jsdom
import {describe, expect, test, vi} from 'vitest';
import {runAxe} from 'test/a11y';
import {render} from 'test/rtl';

describe('runAxe', () => {
  // jsdom reports unimplemented APIs through its own default virtual console,
  // which writes to the process's stderr rather than the test's `console`, so
  // neither a `console.error` spy nor `onConsoleLog` sees it.
  test('writes nothing to stderr', async () => {
    const stderrWrite = vi.spyOn(process.stderr, 'write');
    const {container} = render(<button type="button">Test</button>);

    await runAxe(container);
    const {calls} = stderrWrite.mock;
    stderrWrite.mockRestore();

    expect(calls).toEqual([]);
  });

  test('restores getContext after the run', async () => {
    const original = HTMLCanvasElement.prototype.getContext;
    const {container} = render(<button type="button">Test</button>);

    await runAxe(container);

    expect(HTMLCanvasElement.prototype.getContext).toBe(original);
  });
});
