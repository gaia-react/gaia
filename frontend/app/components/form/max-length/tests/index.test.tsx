import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import MaxLength from '..';

describe('MaxLength', () => {
  test('shows the length against the maximum', () => {
    render(<MaxLength length={12} maxLength={100} />);

    expect(screen.getByText('12 / 100')).toBeInTheDocument();
  });

  test('uses the muted color below the maximum and destructive at it', () => {
    const {rerender} = render(<MaxLength length={99} maxLength={100} />);

    expect(screen.getByText('99 / 100')).toHaveClass('text-muted-foreground');

    rerender(<MaxLength length={100} maxLength={100} />);

    expect(screen.getByText('100 / 100')).toHaveClass('text-destructive');
  });

  test('reserves a wider minimum width for more digits', () => {
    const {rerender} = render(<MaxLength length={1} maxLength={50} />);

    expect(screen.getByText('1 / 50')).toHaveClass('min-w-12');

    rerender(<MaxLength length={1} maxLength={5000} />);

    expect(screen.getByText('1 / 5000')).toHaveClass('min-w-20');
  });

  test('keeps a caller className', () => {
    render(<MaxLength className="ml-2" length={1} maxLength={10} />);

    expect(screen.getByText('1 / 10')).toHaveClass('ml-2');
  });
});
