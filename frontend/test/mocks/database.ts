// Barrel for `@msw/data` collections.
//
// Each `/new-service` adds two things to this file:
//   1. A re-export of the domain's `Collection` (so handlers and stories can
//      `import database from 'test/mocks/database'` and reach `database.things`).
//   2. A call to the domain's `reset*` in `resetTestData` so test setup wipes
//      and re-seeds every collection between cases.
//
// Empty until the first `/new-service` is run.

export const resetTestData = async (): Promise<void> => {};

export default {} as Record<string, never>;
