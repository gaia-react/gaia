import {Profiler, useState} from 'react';
import {describe, expect, test, vi} from 'vitest';
import {render} from 'vitest-browser-react';
import {page, userEvent} from 'vitest/browser';

describe('React Compiler canary', () => {
  test('a child with constant props re-renders only when the compiler is off', async () => {
    const onChildRender = vi.fn();

    const Child = () => <p>child</p>;

    const Parent = () => {
      const [count, setCount] = useState(0);

      return (
        <div>
          <button
            onClick={() => {
              setCount(count + 1);
            }}
            type="button"
          >
            {`count ${count}`}
          </button>
          <Profiler id="child" onRender={onChildRender}>
            <Child />
          </Profiler>
        </div>
      );
    };

    await render(<Parent />);
    // `page` is Vitest browser mode's own locator API, not a Testing Library render result.
    // eslint-disable-next-line testing-library/prefer-screen-queries
    const counterButton = page.getByRole('button');
    await userEvent.click(counterButton);

    await expect.element(counterButton).toHaveTextContent('count 1');
    expect(onChildRender).toHaveBeenCalledTimes(REACT_COMPILER_ENABLED ? 1 : 2);
  });
});
