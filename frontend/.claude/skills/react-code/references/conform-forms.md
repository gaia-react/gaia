# Conform + Zod Form Wiring

Forms are composed directly from the ui `Field` parts, ui controls and Conform; GAIA has no form wrappers. Conform's Zod helpers import from the `@conform-to/zod/v4` subpath: the bare `@conform-to/zod` targets Zod 3 and throws at runtime (typecheck/lint/build don't catch it). The react-code SKILL.md carries this as the always-on rule; the examples below use `/v4` throughout.

## Form setup

### 1. Define the Zod schema (in the route file)

```tsx
const schema = z.object({
  colors: z.array(z.literal(['blue', 'green', 'red'])).min(1, 'required'),
  name: z.string().min(1, 'required'),
  size: z.literal(['lg', 'md', 'sm']),
});
```

Schema messages are keys, not display text; the page maps each key to a translated string (see `toErrors` below).

### 2. Action (in the route file)

```tsx
// import type {Route} from './+types/<route-file>';
export const action = async ({request}: Route.ActionArgs) => {
  const formData = await request.formData();
  const submission = parseWithZod(formData, {schema});

  if (submission.status !== 'success') {
    return data({result: submission.reply()});
  }

  // Use submission.value for typed data
  await fetch('/api/users', {
    body: JSON.stringify(submission.value),
    headers: {'Content-Type': 'application/json'},
    method: 'POST',
  });
  return redirect('/users');
};
```

### 3. Page component with `useForm`

```tsx
import {useTranslation} from 'react-i18next';
import {Form, useActionData, useNavigation} from 'react-router';
import type {SubmissionResult} from '@conform-to/react';
import {getFormProps, useForm} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {Button} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

const MyPage = () => {
  const {t} = useTranslation('pages');
  const actionData = useActionData<{result: SubmissionResult}>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === 'submitting';

  const [form, fields] = useForm({
    constraint: getZodConstraint(schema),
    lastResult: actionData?.result,
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
    shouldRevalidate: 'onInput',
    shouldValidate: 'onBlur',
  });

  // Conform returns string messages; ui FieldError wants {message} objects.
  const errorMessages: Record<string, string> = {required: t('required')};
  const toErrors = (messages?: string[]) =>
    messages?.map((message) => ({message: errorMessages[message]}));

  return (
    <Form method="post" {...getFormProps(form)}>
      {/* one composed Field per control, shown below */}
      <Button disabled={isSubmitting} type="submit">
        {isSubmitting && <Spinner aria-label={t('submitting')} />}
        {t('save')}
      </Button>
    </Form>
  );
};
```

## The composed Field

Every control sits in a `Field` with the same wiring:

- `FieldLabel htmlFor={field.id}` names the control (a group uses `FieldLegend` inside a `FieldSet`).
- The control spreads Conform's props (`getInputProps` and friends), which set `id`, `name`, `required`, `aria-invalid` and `aria-describedby` from `field`.
- `data-invalid` on `Field` styles the invalid state: `data-invalid={field.errors ? true : undefined}`.
- `FieldDescription id={field.descriptionId}` carries help text, and `getInputProps` lists it in `aria-describedby` when you pass `ariaDescribedBy: field.descriptionId`.
- `FieldError id={field.errorId} role="alert"` renders the messages, mapped from Conform's string errors. (ui `FieldError` already renders `role="alert"`; writing it keeps the contract visible. It renders nothing when there are no errors.)

A raw ui control carries none of this wiring on its own, which is why each example repeats it.

### Text input

`getInputProps` spread on `ui/input`:

```tsx
import {getInputProps} from '@conform-to/react';
import {
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
} from '~/components/ui/field';
import {Input} from '~/components/ui/input';

<Field data-invalid={fields.email.errors ? true : undefined}>
  <FieldLabel htmlFor={fields.email.id}>{t('email')}</FieldLabel>
  <Input
    {...getInputProps(fields.email, {
      ariaDescribedBy: fields.email.descriptionId,
      type: 'email',
    })}
  />
  <FieldDescription id={fields.email.descriptionId}>
    {t('emailDescription')}
  </FieldDescription>
  <FieldError
    errors={toErrors(fields.email.errors)}
    id={fields.email.errorId}
    role="alert"
  />
</Field>;
```

Textareas use `getTextareaProps` on `ui/textarea`; native selects use `getSelectProps` on `ui/native-select`. Both follow the same `Field` shape.

### Checkbox group

`FieldSet` and `FieldLegend` around one `ui/checkbox` per option, each from `getCollectionProps`. Conform's `type` is an input attribute the Base UI checkbox root does not take, so drop it:

```tsx
import {getCollectionProps} from '@conform-to/react';
import {Checkbox} from '~/components/ui/checkbox';
import {
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';

<FieldSet aria-describedby={fields.colors.descriptionId}>
  <FieldLegend variant="label">{t('colors')}</FieldLegend>
  <FieldDescription id={fields.colors.descriptionId}>
    {t('colorsDescription')}
  </FieldDescription>
  {getCollectionProps(fields.colors, {
    options: COLORS,
    type: 'checkbox',
  }).map(({key, type: _type, ...checkboxProps}) => (
    <Field
      key={key}
      data-invalid={fields.colors.errors ? true : undefined}
      orientation="horizontal"
    >
      <Checkbox {...checkboxProps} />
      <FieldLabel htmlFor={checkboxProps.id}>{colorLabels[checkboxProps.value]}</FieldLabel>
    </Field>
  ))}
  <FieldError
    errors={toErrors(fields.colors.errors)}
    id={fields.colors.errorId}
    role="alert"
  />
</FieldSet>;
```

A single checkbox is one `Field orientation="horizontal"` with `getInputProps(field, {type: 'checkbox'})` (type dropped the same way) and its `FieldLabel` after it.

### Radio group

`ui/radio-group` in a `FieldSet` and `FieldLegend`, given `name` and `defaultValue` from Conform and labelled by the legend (Conform has no radio-group props helper, so the invalid and described-by attributes are set by hand):

```tsx
import {
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '~/components/ui/field';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';

<Field data-invalid={fields.size.errors ? true : undefined}>
  <FieldSet>
    <FieldLegend id={`${fields.size.id}-legend`} variant="label">
      {t('size')}
    </FieldLegend>
    <FieldDescription id={fields.size.descriptionId}>
      {t('sizeDescription')}
    </FieldDescription>
    <RadioGroup
      aria-describedby={
        fields.size.errors
          ? `${fields.size.descriptionId} ${fields.size.errorId}`
          : fields.size.descriptionId
      }
      aria-invalid={fields.size.errors ? true : undefined}
      aria-labelledby={`${fields.size.id}-legend`}
      defaultValue={fields.size.initialValue}
      id={fields.size.id}
      name={fields.size.name}
      required={true}
    >
      {SIZES.map((size) => (
        <Field
          key={size}
          data-invalid={fields.size.errors ? true : undefined}
          orientation="horizontal"
        >
          <RadioGroupItem id={`${fields.size.id}-${size}`} value={size} />
          <FieldLabel htmlFor={`${fields.size.id}-${size}`}>
            {sizeLabels[size]}
          </FieldLabel>
        </Field>
      ))}
    </RadioGroup>
    <FieldError
      errors={toErrors(fields.size.errors)}
      id={fields.size.errorId}
      role="alert"
    />
  </FieldSet>
</Field>;
```

## Dates

`YearMonthDay` (`~/components/form/year-month-day`) is controlled. Drive it with `useInputControl(fields.dob)` (`value={control.value ?? ''}`, `onChange={control.change}`, `onBlur={control.blur}`), place it in a `FieldSet` with a `FieldLegend` (omit its own `label` prop so no second legend renders) and render its `FieldError` yourself, since it has no `error` prop. Passing `name` posts `dob`, `dobYear`, `dobMonth` and `dobDate`.

## Actions and disabled states

A disabled action renders a disabled `ui/button`, never a disabled link: `<Button disabled>` keeps the button role and the disabled semantics, while an `<a>` cannot be disabled and a styled link stays focusable and clickable. Pass `disabled` to the controls and the `FieldSet` together when a whole form is disabled. A button that navigates is `<Button nativeButton={false} render={<Link to="/path" role="link" />}>`; Base UI sets `role="button"` on a non-native render target, so the explicit `role="link"` restores the link role.

## Typing

Components are typed inline (`type FormProps = {...}; const Form = ({...}: FormProps) => ...`); do not import `FC` or `FunctionComponent`.

## Zod Patterns

This project uses Zod 4, the typescript skill's `references/zod.md` is the full Zod 3 → Zod 4 migration map. Project convention: `z.literal([...])` not `z.enum()` for string unions (sort values alphanumerically).
