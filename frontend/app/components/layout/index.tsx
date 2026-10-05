import type {ReactNode} from 'react';
import {cn} from 'cn';

type LayoutProps = {
  children: ReactNode;
  className?: string;
};

const Layout = ({children, className}: LayoutProps) => (
  <div className={cn('flex h-dvh flex-col', className)}>
    <main className="flex-1">{children}</main>
  </div>
);

export default Layout;
