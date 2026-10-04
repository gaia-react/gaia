import {composeStory} from '@storybook/react-vite';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Meta, {Default} from './index.stories';

const InputEmail = composeStory(Default, Meta);

describe('InputEmail', () => {
  test('validation works', async () => {
    const {type} = userEvent.setup();
    render(<InputEmail />);

    const input = screen.getByRole('textbox', {
      name: /email/i,
    });
    await type(input, 'hello@');

    const submit = screen.getByRole('button');
    await userEvent.click(submit);
    expect(screen.getByRole('alert')).toBeInTheDocument();

    await type(input, 'example.com');
    await userEvent.click(submit);
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
