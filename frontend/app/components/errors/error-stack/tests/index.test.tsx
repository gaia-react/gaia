import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';
import {render, screen} from 'test/rtl';
import ErrorStack from '..';

describe('ErrorStack', () => {
  test('copies the stack to the clipboard', async () => {
    const user = userEvent.setup();
    const writeText = vi.spyOn(navigator.clipboard, 'writeText');

    render(<ErrorStack stack="boom stack" />);

    await user.click(screen.getByRole('button', {name: /copy/i}));

    expect(writeText).toHaveBeenCalledWith('boom stack');
    writeText.mockRestore();
  });

  test('a clipboard rejection does not surface as an unhandled error', async () => {
    const user = userEvent.setup();
    const writeText = vi
      .spyOn(navigator.clipboard, 'writeText')
      .mockRejectedValue(new Error('clipboard denied'));

    render(<ErrorStack stack="boom stack" />);

    await user.click(screen.getByRole('button', {name: /copy/i}));

    expect(writeText).toHaveBeenCalledWith('boom stack');
    writeText.mockRestore();
  });

  test('renders a lucide icon in the copy control', () => {
    render(<ErrorStack stack="boom stack" />);

    const button = screen.getByRole('button');
    // Icons are aria-hidden, so the lucide class is the only handle on them.
    // eslint-disable-next-line testing-library/no-node-access
    const icon = button.querySelector('svg.lucide');

    expect(icon).toBeInTheDocument();
  });
});
