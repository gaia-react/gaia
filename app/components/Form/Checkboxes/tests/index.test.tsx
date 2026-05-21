import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Checkboxes from '..';

describe('Checkboxes', () => {
  test('empty options do not render a required badge', () => {
    render(<Checkboxes label="Pick some" options={[]} />);

    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  test('renders a required badge when every option is required', () => {
    render(
      <Checkboxes
        label="Pick some"
        options={[
          {label: 'One', name: 'one', required: true},
          {label: 'Two', name: 'two', required: true},
        ]}
      />
    );

    expect(screen.getByRole('status')).toBeInTheDocument();
    expect(screen.getByRole('checkbox', {name: 'One'})).toBeInTheDocument();
  });
});
