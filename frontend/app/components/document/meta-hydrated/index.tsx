import {useHydrated} from 'remix-utils/use-hydrated';

// For Playwright
// Adds meta tag to document when JavaScript is hydrated
const MetaHydrated = () => {
  const isHydrated = useHydrated();

  if (isHydrated) {
    return <meta content="true" name="hydrated" />;
  }

  return undefined;
};

export default MetaHydrated;
