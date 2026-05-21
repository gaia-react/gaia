import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Checkbox from '..';

describe('Checkbox', () => {
  test('is required from the required prop, independent of error state', () => {
    render(<Checkbox label="Accept terms" name="terms" required={true} />);

    expect(screen.getByRole('checkbox', {name: 'Accept terms'})).toBeRequired();
  });

  test('is not required when the required prop is absent', () => {
    render(<Checkbox label="Subscribe" name="subscribe" />);

    expect(
      screen.getByRole('checkbox', {name: 'Subscribe'})
    ).not.toBeRequired();
  });
});
