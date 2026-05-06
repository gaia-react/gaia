// Barrel re-exports for `gaia-cli/src/analytics/**`.
// Phase 5 (`task-compute-profile`) imports the two callable surfaces from here:
//   import {generateAnalyticsReport, writeAnalyticsReport} from '../analytics/index.js';

export {AuditDriftError} from './audit-attest.js';

export {computeAuditBlock} from './audit-attest.js';

export {generateAnalyticsReport} from './generator.js';

export type {PatternResult} from './generator.js';

export {writeAnalyticsReport} from './writer.js';
