import type {FC} from 'react';
import {useEffect, useState} from 'react';

// For Playwright
// Adds meta tag to document when JavaScript is hydrated
const MetaHydrated: FC = () => {
  const [isHydrated, setIsHydrated] = useState(false);

  useEffect(() => {
    queueMicrotask(() => setIsHydrated(true));
  }, []);

  if (isHydrated) {
    return <meta content="true" name="hydrated" />;
  }

  return null;
};

export default MetaHydrated;
