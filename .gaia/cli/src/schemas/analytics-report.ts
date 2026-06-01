import {z} from 'zod';

export const AnalyticsReportSchema = z.strictObject({
  adaptations: z.array(
    z.object({
      adaptation_id: z.string(),
      fire_count: z.number().int(),
      linked_pattern: z.string(),
      outcome: z
        .object({
          after_sample_size: z.number().int(),
          after_window_value: z.number(),
          before_sample_size: z.number().int(),
          before_window_value: z.number(),
          target_metric: z.string(),
        })
        .nullable(),
      weeks_since_first_fire: z.number().int(),
    })
  ),
  anonymous_install_id: z.string(),
  audit: z.object({
    fields_present: z.array(z.string()),
    no_event_data: z.literal(true),
    no_project_identifiers: z.literal(true),
    no_user_paths: z.literal(true),
    no_user_text: z.literal(true),
  }),
  engagement: z.object({
    days_active_in_window: z.number().int(),
    profile_md_read_count: z.number().int(),
    sessions_in_window: z.number().int(),
    specs_closed_in_window: z.number().int(),
    tasks_completed_in_window: z.number().int(),
    weeks_since_install: z.number().int(),
  }),
  gaia_version: z.string(),
  patterns: z.array(
    z.object({
      avg_strength_at_fire: z.number().min(0).max(1),
      fire_count: z.number().int(),
      min_sample_size_met: z.boolean(),
      pattern_id: z.string(),
      strength_p10: z.number().min(0).max(1),
      strength_p90: z.number().min(0).max(1),
    })
  ),
  report_generated_at: z.iso.datetime(),
  report_id: z.string(),
  report_window_days: z.literal(30),
  schema_version: z.literal(1),
});

export type AnalyticsReport = z.infer<typeof AnalyticsReportSchema>;
