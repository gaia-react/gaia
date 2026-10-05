import {useSyncExternalStore} from 'react';

const BREAKPOINTS = {
  '2xl': 1536,
  lg: 1024,
  md: 768,
  sm: 390,
  xl: 1280,
};

type BreakpointType = keyof typeof BREAKPOINTS;

const getServerSnapshot = (): boolean => false;

export const useBreakpoint = (breakpoint: BreakpointType): boolean => {
  const query = `(min-width: ${BREAKPOINTS[breakpoint]}px)`;

  const subscribe = (callback: () => void) => {
    const mediaQueryList = window.matchMedia(query);
    mediaQueryList.addEventListener('change', callback);

    return () => mediaQueryList.removeEventListener('change', callback);
  };

  return useSyncExternalStore(
    subscribe,
    () => window.matchMedia(query).matches,
    getServerSnapshot
  );
};
