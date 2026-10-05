// @vitest-environment jsdom
import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import {Checkbox} from '~/components/ui/checkbox';
import {Field, FieldLabel} from '~/components/ui/field';
import {Label} from '~/components/ui/label';

describe('Checkbox', () => {
  test('applies a passed className to the root without a label', () => {
    render(<Checkbox aria-label="Accept" className="mt-2" />);
    expect(screen.getByRole('checkbox', {name: 'Accept'})).toHaveClass('mt-2');
  });

  test('applies a passed className to the root next to a label', () => {
    render(
      <>
        <Checkbox className="mt-2" id="acceptPlain" />
        <Label htmlFor="acceptPlain">Accept</Label>
      </>
    );
    expect(screen.getByRole('checkbox', {name: 'Accept'})).toHaveClass('mt-2');
  });

  test('applies a passed className to the root beside an associated field label', () => {
    render(
      <Field orientation="horizontal">
        <Checkbox className="mt-2" id="accept" />
        <FieldLabel htmlFor="accept">Accept</FieldLabel>
      </Field>
    );
    expect(screen.getByRole('checkbox', {name: 'Accept'})).toHaveClass('mt-2');
  });
});
