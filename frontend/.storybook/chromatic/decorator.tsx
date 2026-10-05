import type {ReactNode} from 'react';
import {useLayoutEffect} from 'react';
import type {ReactRenderer} from '@storybook/react-vite';
import type {DecoratorFunction} from 'storybook/internal/types';

type ThemeClassProps = {children: ReactNode; isDark: boolean};

// Sets `dark` on <html>, where the app puts it, so the body and anything a
// story portals into it take the theme. It runs as a layout effect because a
// story that renders a whole Document commits its own <html> className, which
// would overwrite a class set before the commit; the effect runs after it and
// before paint.
const ThemeClass = ({children, isDark}: ThemeClassProps) => {
  useLayoutEffect(() => {
    document.documentElement.classList.toggle('dark', isDark);
  }, [isDark]);

  return <>{children}</>;
};

const ChromaticDecorator: DecoratorFunction<ReactRenderer> = (
  storyFn,
  {globals}
) => {
  // sessionStorage carries over between snapshots, so clearing it before each
  // one keeps a snapshot independent of the story captured before it.
  sessionStorage.clear();

  // The Chromatic mode sets the `theme` global.
  return <ThemeClass isDark={globals.theme === 'dark'}>{storyFn()}</ThemeClass>;
};

export default ChromaticDecorator;
