import {useEffect, useState} from 'react';

export const useTimeout = (delay: number, trigger?: unknown): boolean => {
  const [complete, setComplete] = useState(false);
  const [prev, setPrevious] = useState({delay, trigger});

  if (prev.delay !== delay || prev.trigger !== trigger) {
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
