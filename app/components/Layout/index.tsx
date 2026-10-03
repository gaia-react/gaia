import type {FC, ReactNode} from 'react';
import {cn} from 'cn';

type LayoutProps = {
  children: ReactNode;
  className?: string;
};

const Layout: FC<LayoutProps> = ({children, className}) => (
  <div className={cn('flex h-dvh flex-col', className)}>
    <main className="flex-1">{children}</main>
  </div>
);

export default Layout;
