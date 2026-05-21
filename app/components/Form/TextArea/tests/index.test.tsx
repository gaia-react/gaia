import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import TextArea from '..';

describe('TextArea', () => {
  test('a visible label names the textarea without a redundant aria-label', () => {
    render(<TextArea label="Biography" name="bio" />);

    const textArea = screen.getByRole('textbox', {name: 'Biography'});
    expect(textArea).not.toHaveAttribute('aria-label');
  });

  test('a JSX label still names the textarea', () => {
    render(<TextArea label={<span>Comments</span>} name="comments" />);

    expect(screen.getByRole('textbox', {name: 'Comments'})).toBeInTheDocument();
  });

  test('falls back to the name when there is no visible label', () => {
    render(<TextArea name="notes" />);

    expect(screen.getByRole('textbox', {name: 'notes'})).toBeInTheDocument();
  });

  test('seeds the length counter from an initial value', () => {
    render(
      <TextArea defaultValue="hello" label="Greeting" maxLength={20} name="g" />
    );

    expect(screen.getByText('5 / 20')).toBeInTheDocument();
  });
});
