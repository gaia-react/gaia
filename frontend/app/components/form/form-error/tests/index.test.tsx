import type {ReactNode} from 'react';
import {createRoutesStub, Form} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import FormError from '..';

const ERROR = 'Something went wrong';

const createStub = (formErrorContent: ReactNode) =>
  createRoutesStub([
    {
      action: () => ({error: ERROR}),
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

describe('FormError', () => {
  test('re-shows an identical error message after dismissal', async () => {
    const {click} = userEvent.setup();
    render(<Stub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(ERROR);

    await click(screen.getByRole('button', {name: 'Dismiss'}));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(ERROR);
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
