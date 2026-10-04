import type {ComponentProps} from 'react';
import {useState} from 'react';
import {composeStory} from '@storybook/react-vite';
import userEvent from '@testing-library/user-event';
import {within} from 'storybook/test';
import {describe, expect, test, vi} from 'vitest';
import {render, screen} from 'test/rtl';
import YearMonthDayComponent from '..';
import Meta, {Default} from './index.stories';

const YearMonthDay = composeStory(Default, Meta);

const SubmitForm = ({
  fieldProps,
  onSubmit,
}: {
  fieldProps?: Partial<ComponentProps<typeof YearMonthDayComponent>>;
  onSubmit: (data: FormData) => void;
}) => {
  const [value, setValue] = useState('2000-01-01');

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit(new FormData(event.currentTarget));
      }}
    >
      <YearMonthDayComponent
        onChange={setValue}
        value={value}
        {...fieldProps}
      />
      <button type="submit">Send</button>
    </form>
  );
};

describe('YearMonthDay', () => {
  test('names the selects Year, Month and Day', () => {
    render(<YearMonthDay />);

    expect(screen.getByRole('combobox', {name: 'Year'})).toBeInTheDocument();
    expect(screen.getByRole('combobox', {name: 'Month'})).toBeInTheDocument();
    expect(screen.getByRole('combobox', {name: 'Day'})).toBeInTheDocument();
  });

  test('February date constraint works', async () => {
    render(<YearMonthDay />);

    const {selectOptions} = userEvent.setup();
    const [year, month, date] = screen.getAllByRole('combobox');
    await selectOptions(
      month,
      within(month).getByRole('option', {name: 'Mar'})
    );
    await selectOptions(date, within(date).getByRole('option', {name: '31'}));

    await selectOptions(
      month,
      within(month).getByRole('option', {name: 'Feb'})
    );
    expect(date).toHaveValue('29');

    await selectOptions(year, within(year).getByRole('option', {name: '2001'}));
    expect(date).toHaveValue('28');
  });

  test('30 day month constraint works', async () => {
    render(<YearMonthDay />);

    const {selectOptions} = userEvent.setup();
    const [, month, date] = screen.getAllByRole('combobox');
    await selectOptions(date, within(date).getByRole('option', {name: '31'}));
    await selectOptions(
      month,
      within(month).getByRole('option', {name: 'Apr'})
    );
    expect(date).toHaveValue('30');
  });

  test('removes the container input listener on unmount', () => {
    const addSpy = vi.spyOn(HTMLDivElement.prototype, 'addEventListener');
    const removeSpy = vi.spyOn(HTMLDivElement.prototype, 'removeEventListener');

    const {unmount} = render(<YearMonthDay />);

    expect(addSpy.mock.calls.some(([type]) => type === 'input')).toBe(true);

    unmount();

    expect(removeSpy.mock.calls.some(([type]) => type === 'input')).toBe(true);

    addSpy.mockRestore();
    removeSpy.mockRestore();
  });

  test('posts dob, dobYear, dobMonth and dobDate in DOM order', async () => {
    const {click} = userEvent.setup();
    const onSubmit = vi.fn();
    render(<SubmitForm onSubmit={onSubmit} />);

    await click(screen.getByRole('button', {name: 'Send'}));

    const data = onSubmit.mock.calls[0][0] as FormData;
    expect([...data.keys()]).toEqual(['dob', 'dobYear', 'dobMonth', 'dobDate']);
    expect(data.get('dob')).toBe('2000-01-01');
    expect(data.get('dobYear')).toBe('2000');
    expect(data.get('dobMonth')).toBe('01');
    expect(data.get('dobDate')).toBe('01');
  });

  test('puts id on the year select and the aria attributes on all three selects', () => {
    render(
      <SubmitForm
        fieldProps={{
          'aria-describedby': 'dob-error',
          'aria-invalid': true,
          id: 'dob-field',
          required: true,
        }}
        onSubmit={vi.fn()}
      />
    );

    const selects = screen.getAllByRole('combobox');
    expect(selects).toHaveLength(3);
    expect(selects[0]).toHaveAttribute('id', 'dob-field');
    expect(selects[1]).not.toHaveAttribute('id');
    expect(selects[2]).not.toHaveAttribute('id');

    for (const select of selects) {
      expect(select).toHaveAttribute('aria-invalid', 'true');
      expect(select).toHaveAttribute('aria-describedby', 'dob-error');
      expect(select).toBeRequired();
    }

    const hidden = screen.getByDisplayValue('2000-01-01');
    expect(hidden).toHaveAttribute('type', 'hidden');
    expect(hidden).toHaveAttribute('name', 'dob');
    expect(hidden).not.toHaveAttribute('id');
    expect(hidden).not.toHaveAttribute('aria-invalid');
    expect(hidden).not.toHaveAttribute('aria-describedby');
    expect(hidden).not.toBeRequired();
  });

  test('renders a legend only when a label is passed', () => {
    const {rerender} = render(<SubmitForm onSubmit={vi.fn()} />);

    expect(screen.getByRole('group')).not.toHaveAccessibleName();

    rerender(
      <SubmitForm fieldProps={{label: 'Birthday'}} onSubmit={vi.fn()} />
    );

    expect(screen.getAllByRole('group')).toHaveLength(1);
    expect(screen.getByRole('group', {name: 'Birthday'})).toBeInTheDocument();
  });
});
