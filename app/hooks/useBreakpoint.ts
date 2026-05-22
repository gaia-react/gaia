import {useEffect, useState} from 'react';

const BREAKPOINTS = {
  '2xl': 1536,
  lg: 1024,
  md: 768,
  sm: 390,
  xl: 1280,
};

type BreakpointType = keyof typeof BREAKPOINTS;

export const useBreakpoint = (breakpoint: BreakpointType): boolean => {
  const [isBreakpoint, setIsBreakpoint] = useState(false);

  useEffect(() => {
    const onUpdate = () => {
      const {innerWidth} = window;
      setIsBreakpoint(innerWidth >= BREAKPOINTS[breakpoint]);
    };
    onUpdate();
    window.addEventListener('resize', onUpdate);

    return () => {
      window.removeEventListener('resize', onUpdate);
    };
  }, [breakpoint]);

  return isBreakpoint;
};
