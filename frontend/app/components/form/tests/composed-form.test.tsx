import {createRoutesStub} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {setTimeout as delay} from 'node:timers/promises';
import {render, screen, waitFor} from 'test/rtl';
import {ComposedForm} from './composed-form';

type PostedEntries = [string, string][];

const createStub = (
  onPost: (entries: PostedEntries) => void,
  action?: () => Promise<null>
) =>
  createRoutesStub([
    {
      action: async ({request}) => {
        const formData = await request.formData();

        onPost(
          [...formData.entries()].map(([key, value]) => [key, String(value)])
        );

        return action ? action() : null;
      },
      Component: () => <ComposedForm />,
      path: '/',
    },
  ]);

const submitEmpty = async () => {
  const user = userEvent.setup();
  const Stub = createStub(() => {});

  render(<Stub />);
  await user.click(screen.getByRole('button', {name: 'Submit'}));

  return user;
};

describe('ComposedForm empty submit', () => {
  test('marks each invalid control and points it at its alert', async () => {
    await submitEmpty();

    const invalidControls = [
      screen.getByRole('textbox', {name: 'Name'}),
      ...screen.getAllByRole('checkbox', {name: /Blue|Green|Red/}),
      screen.getByRole('radiogroup', {name: 'Size'}),
    ];

    for (const control of invalidControls) {
      await waitFor(() => {
        expect(control).toHaveAttribute('aria-invalid', 'true');
      });

      const describedBy = (
        control.getAttribute('aria-describedby') ?? ''
      ).split(' ');
      const alertIds = screen.getAllByRole('alert').map((alert) => alert.id);

      expect(describedBy.some((id) => alertIds.includes(id))).toBe(true);
      expect(
        screen
          .getAllByRole('group')
          .filter(
            (group) => group.dataset.slot === 'field' && group.contains(control)
          )
          .every((group) => group.dataset.invalid === 'true')
      ).toBe(true);
    }
  });

  test('marks required controls and leaves the checkbox group unrequired', async () => {
    await submitEmpty();

    expect(screen.getByRole('textbox', {name: 'Name'})).toBeRequired();
    expect(screen.getByRole('radiogroup', {name: 'Size'})).toBeRequired();

    for (const checkbox of screen.getAllByRole('checkbox', {
      name: /Blue|Green|Red/,
    })) {
      expect(checkbox).not.toBeRequired();
    }
  });

  test('names the checkbox group and the radio group by their legends', async () => {
    await submitEmpty();

    expect(
      screen.getByRole('group', {name: 'Favorite colors'})
    ).toBeInTheDocument();
    expect(screen.getByRole('radiogroup', {name: 'Size'})).toBeInTheDocument();
  });

  test('moves focus to the first invalid control', async () => {
    await submitEmpty();

    await waitFor(() => {
      expect(screen.getByRole('textbox', {name: 'Name'})).toHaveFocus();
    });
  });
});

describe('ComposedForm interaction', () => {
  test('toggles each checkbox and radio from its visible label', async () => {
    const user = userEvent.setup();
    const Stub = createStub(() => {});

    render(<Stub />);

    for (const name of ['Blue', 'Green', 'Red']) {
      const checkbox = screen.getByRole('checkbox', {name});

      expect(checkbox).not.toBeChecked();
      await user.click(screen.getByText(name));
      expect(checkbox).toBeChecked();
    }

    for (const name of ['Large', 'Medium', 'Small']) {
      await user.click(screen.getByText(name));
      expect(screen.getByRole('radio', {name})).toBeChecked();
    }
  });

  test('toggles a focused checkbox with Space as one Tab stop', async () => {
    const user = userEvent.setup();
    const Stub = createStub(() => {});

    render(<Stub />);

    const red = screen.getByRole('checkbox', {name: 'Red'});
    const green = screen.getByRole('checkbox', {name: 'Green'});

    red.focus();
    await user.keyboard(' ');
    expect(red).toBeChecked();

    await user.tab();
    expect(green).toHaveFocus();
    await user.keyboard(' ');
    expect(green).toBeChecked();
  });

  test('moves the radio group with arrow keys as one Tab stop', async () => {
    const user = userEvent.setup();
    const Stub = createStub(() => {});

    render(<Stub />);

    await user.click(screen.getByRole('radio', {name: 'Small'}));
    expect(screen.getByRole('radio', {name: 'Small'})).toHaveFocus();

    await user.keyboard('{ArrowDown}');
    expect(screen.getByRole('radio', {name: 'Medium'})).toBeChecked();
    expect(screen.getByRole('radio', {name: 'Medium'})).toHaveFocus();

    await user.tab();
    expect(screen.getByRole('radio', {name: 'Medium'})).not.toHaveFocus();
    expect(screen.getByRole('button', {name: 'Submit'})).toHaveFocus();
  });
});

describe('ComposedForm filled submit', () => {
  test('posts exactly the filled entries in DOM order', async () => {
    const user = userEvent.setup();
    let posted: PostedEntries = [];
    const Stub = createStub((entries) => {
      posted = entries;
    });

    render(<Stub />);

    await user.type(screen.getByRole('textbox', {name: 'Name'}), 'Ada');
    await user.type(
      screen.getByRole('textbox', {name: 'Email'}),
      'ada@example.com'
    );
    await user.type(screen.getByLabelText('Password'), 'Secret123!');
    await user.type(screen.getByRole('textbox', {name: 'Bio'}), 'Hello');
    await user.selectOptions(
      screen.getByRole('combobox', {name: 'Country'}),
      'jp'
    );
    await user.click(screen.getByText('I accept the terms'));
    await user.click(screen.getByText('Blue'));
    await user.click(screen.getByText('Red'));
    await user.click(screen.getByText('Medium'));
    await user.click(screen.getByRole('button', {name: 'Submit'}));

    await waitFor(() => {
      expect(posted).not.toHaveLength(0);
    });

    expect(posted).toEqual([
      ['name', 'Ada'],
      ['email', 'ada@example.com'],
      ['password', 'Secret123!'],
      ['bio', 'Hello'],
      ['country', 'jp'],
      ['terms', 'on'],
      ['colors', 'red'],
      ['colors', 'blue'],
      ['size', 'md'],
    ]);
  });

  test('disables the submit button and shows the spinner while the action runs', async () => {
    const user = userEvent.setup();

    const Stub = createStub(
      () => {},
      async () => {
        await delay(400);

        return null;
      }
    );

    render(<Stub />);

    await user.type(screen.getByRole('textbox', {name: 'Name'}), 'Ada');
    await user.click(screen.getByText('Blue'));
    await user.click(screen.getByText('Medium'));
    await user.click(screen.getByRole('button', {name: 'Submit'}));

    const button = await screen.findByRole('button', {name: /Please wait/});

    expect(button).toBeDisabled();
    expect(screen.getByRole('status')).toBeInTheDocument();
  });
});
