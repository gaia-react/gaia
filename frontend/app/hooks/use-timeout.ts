import {useEffect, useState} from 'react';

export const useTimeout = (delay: number, trigger?: unknown): boolean => {
  const [complete, setComplete] = useState(false);
  const [previous, setPrevious] = useState({delay, trigger});

  if (previous.delay !== delay || previous.trigger !== trigger) {
    setPrevious({delay, trigger});
    setComplete(false);
  }

  useEffect(() => {
    const id = setTimeout(() => {
      setComplete(true);
    }, delay);

    return () => clearTimeout(id);
  }, [delay, trigger]);

  return complete;
};
