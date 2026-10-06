import SsrQueryPage from '~/pages/ssr-query/page';
import {ssrQueryOptions} from '~/pages/ssr-query/query';
import {getQueryClient} from '~/query-client';

// No server loader: React Router runs the clientLoader at hydration and
// server-renders HydrateFallback in place of the page.
export const clientLoader = async () => {
  await getQueryClient().query(ssrQueryOptions());
};

export const HydrateFallback = () => (
  <>
    <title>Query probe loading</title>
    <p>hydrate-fallback-rendered</p>
  </>
);

const SsrQueryRoute = () => <SsrQueryPage />;

export default SsrQueryRoute;
