import type {RefObject} from 'react';
import {useEffect, useRef, useState} from 'react';

// Use trigger if you want to force a measurement based on a variable changing
export const useComponentRect = (
  ref: RefObject<HTMLElement | null>,
  trigger?: unknown
): DOMRect => {
  const [rect, setRect] = useState({
    bottom: 0,
    height: 0,
    left: 0,
    right: 0,
    toJSON: () => {},
    top: 0,
    width: 0,
    x: 0,
    y: 0,
  });

  const timeoutRef = useRef<null | number>(null);

  useEffect(() => {
    if (ref.current) {
      const onUpdate = () => {
        if (ref.current) {
          setRect(ref.current.getBoundingClientRect());
        }
      };

      const scrollOptions: AddEventListenerOptions = {passive: true};

      window.addEventListener('resize', onUpdate);
      window.addEventListener('scroll', onUpdate, scrollOptions);

      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
      timeoutRef.current = window.setTimeout(onUpdate);

      return () => {
        if (timeoutRef.current) {
          clearTimeout(timeoutRef.current);
        }
        window.removeEventListener('resize', onUpdate);
        window.removeEventListener('scroll', onUpdate, scrollOptions);
      };
    }

    return undefined;
  }, [ref, trigger]);

  return rect;
};
