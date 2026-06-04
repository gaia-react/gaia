# `_session+/`: Auth-Guarded Route Group

Hook point for authenticated pages. Empty by design; the template is not prescriptive about auth.

## When you add auth

1. Pick your auth provider (Supabase, Clerk, Auth0, Firebase, custom, etc.)
2. Create `_layout.tsx` here with a loader that enforces authentication:

   ```tsx
   import {Outlet, redirect} from 'react-router';
   import type {Route} from './+types/_layout';

   export const loader = async ({request}: Route.LoaderArgs) => {
     const user = await yourAuthProvider.getUser(request);
     if (!user) throw redirect('/login');
     return {user};
   };

   const SessionLayout = () => <Outlet />;
   export default SessionLayout;
   ```

3. Add routes (e.g. `profile.tsx`, `settings.tsx`) as siblings; they inherit the guard.

Using remix-flat-routes: the `_` prefix makes this a pathless layout group; everything under `_session+/` renders inside it.

This README is not picked up as a route (flat-routes only matches `.ts`/`.tsx`).
