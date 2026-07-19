# Conform + Zod Form Wiring

Conform's Zod helpers import from the `@conform-to/zod/v4` subpath, the bare `@conform-to/zod` targets Zod 3 and throws at runtime (typecheck/lint/build don't catch it). The react-code SKILL.md carries this as the always-on rule; the examples below use `/v4` throughout.

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

For the native-element → Form-component table, see **Gate 2: Form Element Check** in `react-code/SKILL.md` (the authoritative superset, including the native-OK exceptions `hidden` / `file` / `range`).

## Compound Component Gotcha

Conform reads stale hidden input values from compound components (YearMonthDay, TimePicker). Fix: native `addEventListener('input', e => e.stopPropagation())` via ref callback on container div + sync hidden input DOM value via `useRef` in `onChange`. React `onInput` won't work (SSR hydration puts both handlers on same node).

## Zod Patterns

This project uses Zod 4, the typescript skill's `references/zod.md` is the full Zod 3 → Zod 4 migration map. Project convention: `z.literal([...])` not `z.enum()` for string unions (sort values alphanumerically).
