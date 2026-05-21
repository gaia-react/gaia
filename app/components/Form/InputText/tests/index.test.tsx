import {composeStory} from '@storybook/react-vite';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import InputText from '..';
import Meta, {Default} from './index.stories';

const InputTextStory = composeStory(Default, Meta);

describe('InputText', () => {
  test('typing works', async () => {
    const {type} = userEvent.setup();
    render(<InputTextStory />);

    const input = screen.getByRole('textbox', {
      name: /^text input$/i,
    });
    await type(input, 'helloworld');
    expect(input).toHaveValue('helloworld');
  });

  test('maxLength works', async () => {
    const {clear, type} = userEvent.setup();
    render(<InputTextStory />);

    const input = screen.getByRole('textbox', {
      name: /^text input max length$/i,
    });
    await type(
      input,
      [
        'This is a long string!',
        'This is a long string!',
        'This is a long string!',
      ].join('')
    );
    expect(input).toHaveValue('This is a long strin');

    await clear(input);
    await type(input, 'hello world');
    expect(input).toHaveValue('hello world');
  });

  test('a visible label names the input without a redundant aria-label', () => {
    render(<InputText label="Full name" name="fullName" />);

    const input = screen.getByRole('textbox', {name: 'Full name'});
    expect(input).not.toHaveAttribute('aria-label');
  });

  test('a JSX label still names the input', () => {
    render(<InputText label={<span>Email address</span>} name="email" />);

    expect(
      screen.getByRole('textbox', {name: 'Email address'})
    ).toBeInTheDocument();
  });

  test('falls back to the name when there is no visible label', () => {
    render(<InputText name="search" />);

    expect(screen.getByRole('textbox', {name: 'search'})).toBeInTheDocument();
  });

  test('seeds the length counter from an initial value', () => {
    render(
      <InputText
        defaultValue="hello"
        label="Greeting"
        maxLength={20}
        name="g"
      />
    );

    expect(screen.getByText('5 / 20')).toBeInTheDocument();
  });
});
