import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import Select from '..';
import type {SelectOption} from '../types';

const options: SelectOption[] = [
  {label: 'One', value: '1'},
  {label: 'Two', value: '2'},
];

describe('Select', () => {
  test('controlled value changes update placeholder styling', () => {
    const {rerender} = render(
      <Select
        name="num"
        onChange={() => {}}
        options={options}
        unselected="Choose…"
        value=""
      />
    );

    const select = screen.getByRole('combobox');
    expect(select).toHaveClass('text-placeholder');

    rerender(
      <Select
        name="num"
        onChange={() => {}}
        options={options}
        unselected="Choose…"
        value="1"
      />
    );

    expect(select).toHaveClass('text-body');
  });

  test('associates the description with the select via aria-describedby', () => {
    render(
      <Select
        description="Pick one"
        label="Number"
        name="num"
        options={options}
      />
    );

    expect(
      screen.getByRole('combobox', {name: 'Number'})
    ).toHaveAccessibleDescription('Pick one');
  });
});
