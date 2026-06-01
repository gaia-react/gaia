# Conform + Zod Form Wiring

## CRITICAL: Import from /v4

This project uses Zod v4. Always import from the `/v4` subpath:

```tsx
// GOOD
import {parseWithZod} from '@conform-to/zod/v4';
import {getZodConstraint} from '@conform-to/zod/v4';

// BAD — runtime error: 'zod' does not provide an export named 'ZodBranded'
import {parseWithZod} from '@conform-to/zod';
```

## Basic Form Setup

### 1. Define Zod schema (in route file)

```tsx
const schema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
  role: z.literal(['admin', 'member']),
});
```

### 2. Action (in route file)

```tsx
export const action = async ({request}: ActionFunctionArgs) => {
  const formData = await request.formData();
  const submission = parseWithZod(formData, {schema});

  if (submission.status !== 'success') {
    return data({result: submission.reply()});
  }

  // Use submission.value for typed data
  await fetch('/api/users', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(submission.value),
  });
  return redirect('/users');
};
```

### 3. Page component with useForm

```tsx
import {useForm, getFormProps, getInputProps} from '@conform-to/react';
import {getZodConstraint, parseWithZod} from '@conform-to/zod/v4';
import {useTranslation} from 'react-i18next';

const MyPage: FC = () => {
  const {t} = useTranslation('pages');
  const actionData = useActionData<{result: SubmissionResult}>();

  const [form, fields] = useForm({
    lastResult: actionData?.result,
    constraint: getZodConstraint(schema),
    onValidate: ({formData}) => parseWithZod(formData, {schema}),
    shouldValidate: 'onBlur',
    shouldRevalidate: 'onInput',
  });

  return (
    <Form method="post" {...getFormProps(form)}>
      <InputText
        {...getInputProps(fields.name, {type: 'text'})}
        label={t('nameLabel')}
        errors={fields.name.errors}
      />
      <InputText
        {...getInputProps(fields.email, {type: 'email'})}
        label={t('emailLabel')}
        errors={fields.email.errors}
      />
      <Select
        {...getInputProps(fields.role, {type: 'text'})}
        label={t('roleLabel')}
        options={roleOptions}
        errors={fields.role.errors}
      />
      <button type="submit">Save</button>
    </Form>
  );
};
```

## Form Component Mapping

| Native element                         | Form component                                      | Notes                                    |
| -------------------------------------- | --------------------------------------------------- | ---------------------------------------- |
| `<input type="text">`                  | `InputText` (`~/components/Form/InputText`)         |                                          |
| `<input type="email">`                 | `InputEmail` (`~/components/Form/InputEmail`)       |                                          |
| `<input type="password">`              | `InputPassword` (`~/components/Form/InputPassword`) |                                          |
| `<input type="checkbox">` (single)     | `Checkbox` (`~/components/Form/Checkbox`)           |                                          |
| `<input type="checkbox">` (group)      | `Checkboxes` (`~/components/Form/Checkboxes`)       | Needs `options: Option[]`                |
| `<input type="radio">` / radio group   | `RadioButtons` (`~/components/Form/RadioButtons`)   | Needs `options: Option[]`                |
| `<select>`                             | `Select` (`~/components/Form/Select`)               | Needs `name` + `options: SelectOption[]` |
| `<textarea>`                           | `TextArea` (`~/components/Form/TextArea`)           | Needs `name`; auto-resizes               |
| Date (year/month/day)                  | `YearMonthDay` (`~/components/Form/YearMonthDay`)   |                                          |
| Field with label + error + description | `Field` (`~/components/Form/Field`)                 |                                          |
| `<input type="hidden">`                | Native `<input>`                                    | Always use native                        |
| `<input type="file">`                  | Native `<input>`                                    | Custom upload flows                      |

## Compound Component Gotcha

Conform reads stale hidden input values from compound components (YearMonthDay, TimePicker). Fix: native `addEventListener('input', e => e.stopPropagation())` via ref callback on container div + sync hidden input DOM value via `useRef` in `onChange`. React `onInput` won't work (SSR hydration puts both handlers on same node).

## Zod Patterns

This project uses Zod 4 — the typescript skill's `references/zod.md` is the full Zod 3 → Zod 4 migration map. Project convention: `z.literal([...])` not `z.enum()` for string unions (sort values alphanumerically).
