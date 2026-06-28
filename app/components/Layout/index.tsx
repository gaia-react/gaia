import type {FC, ReactNode} from 'react';
import {twMerge} from 'tailwind-merge';

type LayoutProps = {
  children: ReactNode;
  className?: string;
};

const Layout: FC<LayoutProps> = ({children, className}) => (
  <div className={twMerge('flex h-dvh flex-col', className)}>
    <main className="flex-1">{children}</main>
  </div>
);

export default Layout;
