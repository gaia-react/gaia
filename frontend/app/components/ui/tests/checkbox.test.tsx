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

  test('takes its accessible name from an associated Label', () => {
    render(
      <>
        <Checkbox id="acceptPlain" />
        <Label htmlFor="acceptPlain">Accept</Label>
      </>
    );
    expect(screen.getByRole('checkbox')).toHaveAccessibleName('Accept');
  });

  test('takes its accessible name from a FieldLabel in a horizontal Field', () => {
    render(
      <Field orientation="horizontal">
        <Checkbox id="accept" />
        <FieldLabel htmlFor="accept">Accept</FieldLabel>
      </Field>
    );
    expect(screen.getByRole('checkbox')).toHaveAccessibleName('Accept');
  });
});
