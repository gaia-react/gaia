import {z} from 'zod';

const schema = z.object({
  API_URL: z.string(),
  COMMIT_SHA: z
    .string()
    .optional()
    .transform((value) => value?.slice(0, 6)),
  MSW_ENABLED: z.stringbool().optional(),
  NODE_ENV: z.string(),
  npm_package_version: z.string(),
  SESSION_SECRET: z.string(),
  SITE_URL: z.string(),
});

const clientSchema = schema.omit({
  SESSION_SECRET: true,
  SITE_URL: true,
});

export const env = schema.parse(process.env);

export const envClient = clientSchema.parse(process.env);

type Environment = z.infer<typeof clientSchema>;

// `app/root.tsx` populates `window.process` on every render, so these fields
// are present in the running app. Storybook is deliberately exempt:
// `.storybook/preview-head.html` seeds `window.process = {env: {}}` and the
// preview inlines nothing, so under a story every field reads `undefined`
// despite the type. Give a story the values it needs as args.
declare global {
  // eslint-disable-next-line @typescript-eslint/consistent-type-definitions
  interface Window {
    process: {
      env: Environment;
    };
  }
}
