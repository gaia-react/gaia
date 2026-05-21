import {createRoutesStub, Form} from 'react-router';
import userEvent from '@testing-library/user-event';
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import FormError from '..';

const ERROR = 'Something went wrong';

const Stub = createRoutesStub([
  {
    action: () => ({error: ERROR}),
    Component: () => (
      <Form method="post">
        <FormError />
        <button type="submit">Submit</button>
      </Form>
    ),
    path: '/',
  },
]);

describe('FormError', () => {
  test('re-shows an identical error message after dismissal', async () => {
    const {click} = userEvent.setup();
    render(<Stub />);

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(ERROR);

    await click(screen.getByRole('button', {name: ERROR}));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();

    await click(screen.getByRole('button', {name: 'Submit'}));
    expect(await screen.findByRole('alert')).toHaveTextContent(ERROR);
  });
});
