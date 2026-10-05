import {Profiler, useState} from 'react';
import {render, screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';

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

    render(<Parent />);
    await userEvent.click(screen.getByRole('button'));

    expect(screen.getByRole('button')).toHaveTextContent('count 1');
    expect(onChildRender).toHaveBeenCalledTimes(REACT_COMPILER_ENABLED ? 1 : 2);
  });
});
