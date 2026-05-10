// @vitest-environment jsdom
import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';
import {expectNoA11yViolations} from 'test/a11y';
import {render, screen} from 'test/rtl';
import Button from '../index';

describe('Button', () => {
  test('Active', async () => {
    const handleClick = vi.fn();
    render(<Button onClick={handleClick}>Test</Button>);
    const button = screen.getByRole('button');
    expect(button.textContent).toBe('Test');
    await userEvent.click(button);
    expect(handleClick).toHaveBeenCalled();
  });

  test('Disabled', async () => {
    const handleClick = vi.fn();
    render(
      <Button disabled={true} onClick={handleClick}>
        Test
      </Button>
    );
    const button = screen.getByRole('button');
    await userEvent.click(button);
    expect(handleClick).not.toHaveBeenCalled();
  });

  test('Loading', () => {
    const handleClick = vi.fn();
    render(
      <Button isLoading={true} onClick={handleClick}>
        Test
      </Button>
    );
    const loader = screen.getByRole('progressbar');
    expect(loader).toBeInTheDocument();
  });

  test('a11y', async () => {
    const {container} = render(<Button>Test</Button>);
    await expectNoA11yViolations(container);
  });
});
