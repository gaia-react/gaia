import {composeStory} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Meta, {Default} from './index.stories';

const Spinner = composeStory(Default, Meta);

describe('Spinner', () => {
  test('renders with proper role', () => {
    render(<Spinner />);
    expect(screen.getByRole('progressbar')).toBeInTheDocument();
  });
});
