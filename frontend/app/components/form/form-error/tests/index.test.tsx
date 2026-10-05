import type {ReactNode} from 'react';
import {createRoutesStub, Form} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {fireEvent, render, screen} from 'test/rtl';
import {Input} from '~/components/ui/input';
import FormError from '..';

const actionErrorMessage = 'Something went wrong';

const createStub = (formErrorContent: ReactNode) =>
  createRoutesStub([
    {
      action: () => ({error: actionErrorMessage}),
      Component: () => (
        <Form method="post">
          {formErrorContent}
          <button type="submit">Submit</button>
        </Form>
      ),
      path: '/',
    },
  ]);

const Stub = createStub(<FormError />);

const PairStub = createStub(
  <>
    <FormError />
    <FormError isHidden={true} />
  </>
);

const FieldStub = createStub(
  <>
    <FormError />
    <Input aria-label="Email" name="email" type="email" />
  </>
);

const UnfocusableFirstFieldStub = createStub(
  <>
    <FormError />
    <Input
      ref={(element) => {
        // jsdom focuses a hidden input; browsers silently ignore focus() on it.
        if (element) {
          element.focus = () => undefined;
        }
      }}
      aria-label="Hidden"
      hidden={true}
      name="hidden"
      type="text"
    />
    <Input aria-label="Email" name="email" type="email" />
  </>
);

describe('FormError', () => {
  test('moves focus to the first form field when dismissed from the keyboard', async () => {
    const {click, keyboard, tab} = userEvent.setup();
    render(<FieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    screen.getByRole('button', {name: 'Dismiss'}).focus();
    await keyboard('{Enter}');

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).toHaveFocus();

    await tab();
    expect(screen.getByRole('button', {name: 'Submit'})).toHaveFocus();
  });

  test('leaves focus alone when dismissed by a touch tap', async () => {
    const {click} = userEvent.setup();
    render(<FieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    fireEvent(
      screen.getByRole('button', {name: 'Dismiss'}),
      new PointerEvent('click', {
        bubbles: true,
        cancelable: true,
        pointerType: 'touch',
      })
    );

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
  });

  test('leaves focus alone when dismissed by a pen tap', async () => {
    const {click} = userEvent.setup();
    render(<FieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    fireEvent(
      screen.getByRole('button', {name: 'Dismiss'}),
      new PointerEvent('click', {
        bubbles: true,
        cancelable: true,
        pointerType: 'pen',
      })
    );

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
  });

  test('leaves focus alone when a click carries no pointerType and a click count', async () => {
    const {click} = userEvent.setup();
    render(<FieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    fireEvent(
      screen.getByRole('button', {name: 'Dismiss'}),
      new MouseEvent('click', {bubbles: true, cancelable: true, detail: 1})
    );

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).not.toHaveFocus();
  });

  test('moves focus to the first control when a click carries no pointerType and no click count', async () => {
    const {click} = userEvent.setup();
    render(<FieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    const dismissButton = screen.getByRole('button', {name: 'Dismiss'});
    dismissButton.focus();
    fireEvent(
      dismissButton,
      new MouseEvent('click', {bubbles: true, cancelable: true, detail: 0})
    );

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).toHaveFocus();
  });

  test('skips a first field that cannot take focus', async () => {
    const {click, keyboard} = userEvent.setup();
    render(<UnfocusableFirstFieldStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    screen.getByRole('button', {name: 'Dismiss'}).focus();
    await keyboard('{Enter}');

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', {name: 'Email'})).toHaveFocus();
  });

  test('moves focus to the submit button when the form has no other field', async () => {
    const {click, keyboard} = userEvent.setup();
    render(<Stub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');

    screen.getByRole('button', {name: 'Dismiss'}).focus();
    await keyboard('{Enter}');

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('button', {name: 'Submit'})).toHaveFocus();
  });

  test('re-shows an identical error message after dismissal', async () => {
    const {click} = userEvent.setup();
    render(<Stub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      actionErrorMessage
    );

    await click(screen.getByRole('button', {name: 'Dismiss'}));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      actionErrorMessage
    );
  });

  test('renders nothing when isHidden is set', async () => {
    const {click} = userEvent.setup();
    render(<PairStub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    await screen.findByRole('alert');
    expect(screen.getAllByRole('alert')).toHaveLength(1);
  });

  test('renders exactly one alert region with a named dismiss button and a lucide icon', async () => {
    const {click} = userEvent.setup();
    render(<Stub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    const alert = await screen.findByRole('alert');

    expect(screen.getAllByRole('alert')).toHaveLength(1);
    expect(screen.getByRole('button', {name: 'Dismiss'})).toBeInTheDocument();
    // Icons are aria-hidden, so the lucide class is the only handle on them.
    // eslint-disable-next-line testing-library/no-node-access
    expect(alert.querySelector('svg.lucide')).toBeInTheDocument();
  });
});
