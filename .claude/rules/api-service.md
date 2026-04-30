---
paths:
  - 'app/services/**/*'
  - 'test/mocks/**/*'
---

# API Service Pattern

For the full pattern with detailed rationale, see `wiki/concepts/API Service Pattern.md`.

## Structure

Each service domain lives under `app/services/gaia/{domain}/`:

- `requests.server.ts` — API request functions (`.server.ts` suffix = server-only)
- `parsers.ts` — Zod schemas for response validation
- `types.ts` — TypeScript types (inferred from Zod)
- `state.tsx` — Optional. Client-side Context/hook for deeply nested consumers of loader data.

## URL Constants

Define endpoints in `app/services/gaia/urls.ts`:

```ts
export const GAIA_URLS = {
  resources: 'resources',
  resourcesId: 'resources/:id',
};
```

## Request Functions

Use the `api()` wrapper with Zod parsing at the boundary:

```ts
import {api} from '../api';
import {GAIA_URLS} from '../urls';
import {resourceSchema} from './parsers';

export const getResourceById = async (id: string): Promise<Resource> => {
  const result = await api(GAIA_URLS.resourcesId, {pathParams: {id}});
  return resourceSchema.parse(result.data);
};
```

Use `schema.parse()` — never `.safeParse()`. A malformed response is a bug; let it throw.

## Barrel Export

Register in `app/services/gaia/index.server.ts`:

```ts
import * as resources from './resources/requests.server';

export default {resources};
```

## MSW Mocks

Mirror the service structure in `test/mocks/{domain}/` (handlers by HTTP method, `index.ts` barrel, `data.ts` for the Zod schema + `Collection`). Register handlers in `test/mocks/index.ts` and re-export the collection + `reset*` from `test/mocks/database.ts`. Handler URLs **must** resolve via the shared `url()` helper so `API_URL` is applied consistently.

For the full `@msw/data` collection conventions (sync reads vs async mutations, predicate-builder query syntax, `resetTestData()` async semantics) and a worked handler example, see `wiki/modules/MSW Handlers.md`.

## Checklist for New Service

1. Add URL constants to `urls.ts`
2. Create `{domain}/parsers.ts` with Zod schemas
3. Create `{domain}/types.ts`
4. Create `{domain}/requests.server.ts`
5. Export from `index.server.ts`
6. (Optional) Create `{domain}/state.tsx` for Context-based client access to loader data
7. Add MSW mock handlers in `test/mocks/{domain}/`
8. Register handlers in `test/mocks/index.ts`
9. Re-export the domain's `Collection` and reset from `test/mocks/database.ts`
