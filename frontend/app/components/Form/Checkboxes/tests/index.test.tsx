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

  test('associates the group description with every checkbox via aria-describedby', () => {
    render(
      <Checkboxes
        description="Choose at least one"
        label="Pick some"
        options={[
          {label: 'One', name: 'one'},
          {label: 'Two', name: 'two'},
        ]}
      />
    );

    expect(
      screen.getByRole('checkbox', {name: 'One'})
    ).toHaveAccessibleDescription('Choose at least one');
    expect(
      screen.getByRole('checkbox', {name: 'Two'})
    ).toHaveAccessibleDescription('Choose at least one');
  });

  test('omits aria-describedby when there is no description', () => {
    render(
      <Checkboxes label="Pick some" options={[{label: 'One', name: 'one'}]} />
    );

    expect(screen.getByRole('checkbox', {name: 'One'})).not.toHaveAttribute(
      'aria-describedby'
    );
  });

  test('does not wrap the group label in a label element', () => {
    render(
      <Checkboxes
        description="Choose at least one"
        label="Pick some"
        options={[{label: 'One', name: 'one'}]}
      />
    );

    const groupLabel = screen.getByText('Pick some');
    expect(groupLabel.closest('label')).toBeNull();
  });
});
