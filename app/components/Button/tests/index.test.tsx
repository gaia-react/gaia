// @vitest-environment jsdom
import userEvent from '@testing-library/user-event';
import {describe, expect, test, vi} from 'vitest';
import {expectNoA11yViolations} from 'test/a11y';
import {render, screen} from 'test/rtl';
import Button from '..';

describe('Button', () => {
  test('Active', async () => {
    const handleClickButton = vi.fn();
    render(<Button onClick={handleClickButton}>Test</Button>);
    const button = screen.getByRole('button');
    expect(button).toHaveTextContent('Test');
    await userEvent.click(button);
    expect(handleClickButton).toHaveBeenCalledWith(
      expect.objectContaining({type: 'click'})
    );
  });

  test('Disabled', async () => {
    const handleClickButton = vi.fn();
    render(
      <Button disabled={true} onClick={handleClickButton}>
        Test
      </Button>
    );
    const button = screen.getByRole('button');
    await userEvent.click(button);
    expect(handleClickButton).not.toHaveBeenCalled();
  });

  test('Loading', () => {
    const handleClickButton = vi.fn();
    render(
      <Button isLoading={true} onClick={handleClickButton}>
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
