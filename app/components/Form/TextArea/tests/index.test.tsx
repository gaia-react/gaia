import {describe, expect, test, vi} from 'vitest';
import {fireEvent, render, screen} from 'test/rtl';
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

  test('associates the description with the textarea via aria-describedby', () => {
    render(
      <TextArea description="Markdown supported" label="Bio" name="bio" />
    );

    expect(
      screen.getByRole('textbox', {name: 'Bio'})
    ).toHaveAccessibleDescription('Markdown supported');
  });

  test('does not give the field description a redundant note role', () => {
    render(
      <TextArea description="Markdown supported" label="Bio" name="bio" />
    );

    expect(screen.queryByRole('note')).not.toBeInTheDocument();
  });

  test('invokes onAutoSize when the textarea reports a resize', () => {
    const onAutoSize = vi.fn();
    render(<TextArea label="Bio" name="bio" onAutoSize={onAutoSize} />);
    const textArea = screen.getByRole('textbox', {name: 'Bio'});

    onAutoSize.mockClear();
    fireEvent(textArea, new Event('autosize:resized'));

    expect(onAutoSize).toHaveBeenCalledTimes(1);
  });

  test('does not resubscribe the resize listener when re-rendered', () => {
    const removeListener = vi.spyOn(
      HTMLTextAreaElement.prototype,
      'removeEventListener'
    );

    const {rerender} = render(
      <TextArea label="Bio" name="bio" onAutoSize={() => {}} />
    );
    rerender(<TextArea label="Bio" name="bio" onAutoSize={() => {}} />);

    expect(removeListener).not.toHaveBeenCalledWith(
      'autosize:resized',
      expect.any(Function)
    );

    removeListener.mockRestore();
  });
});
