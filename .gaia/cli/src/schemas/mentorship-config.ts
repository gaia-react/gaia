import {z} from 'zod';

export const MentorshipConfigSchema = z.object({
  analytics: z.object({enabled: z.boolean()}),
  decided_at: z.iso.datetime().nullable(),
  decided_via: z
    .enum([
      'gaia-init',
      'mentorship-enable',
      'mentorship-disable',
      'mentorship-analytics-enable',
      'mentorship-analytics-disable',
    ])
    .nullable(),
  // null = pre-decision (gaia-init not yet run).
  enabled: z.boolean().nullable(),
});

export type MentorshipConfig = z.infer<typeof MentorshipConfigSchema>;
