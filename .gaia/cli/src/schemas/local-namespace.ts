import {z} from 'zod';

// `_local` namespace travels only on the mentorship stream. It carries
// identity-bearing context (git author email, machine paths, hostname, etc.).
// Open shape: engineers may attach freeform fields, so we use `passthrough()`
// rather than `strict()`.
export const LocalNamespaceSchema = z.looseObject({
  git_author_email: z.email().optional(),
  hostname: z.string().optional(),
  machine_paths: z.array(z.string()).optional(),
});

export type LocalNamespace = z.infer<typeof LocalNamespaceSchema>;
