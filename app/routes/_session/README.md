# `_session`: Auth-Guarded Route Group Hook Point

Hook point for authenticated pages. Empty by design; the template is not prescriptive about auth.

## When you add auth

1. Pick your auth provider (Supabase, Clerk, Auth0, Firebase, custom, etc.)
2. Create `app/routes/_session.tsx` as the guarded pathless layout, with a loader that enforces authentication:

   ```tsx
   import {Outlet, redirect} from 'react-router';
   import type {Route} from './+types/_session';

   export const loader = async ({request}: Route.LoaderArgs) => {
     const user = await yourAuthProvider.getUser(request);
     if (!user) throw redirect('/login');
     return {user};
   };

   const SessionLayout = () => <Outlet />;
   export default SessionLayout;
   ```

3. Add child routes as `app/routes/_session.<name>.tsx` (e.g. `_session.profile.tsx`, `_session.settings.tsx`); they inherit the guard. `gaia scaffold route <name> --group _session` writes those children for you.

## Why this file is not a route

This folder holds no `route.*` or `index.*` module, so `@react-router/fs-routes` skips it entirely. Do not add route modules inside this folder; routes are flat files that live beside it, directly under `app/routes/`.
