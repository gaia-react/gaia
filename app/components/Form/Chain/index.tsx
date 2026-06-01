import type {FC, ReactNode} from 'react';
import {twMerge} from 'tailwind-merge';
import styles from './styles.module.css';

export type ChainProps = {
  children: ReactNode;
  className?: string;
  isFullWidth?: boolean;
};

const Chain: FC<ChainProps> = ({children, className, isFullWidth}) => (
  // role="group" not <fieldset>: a reusable grouping primitive that may sit
  // inside a consumer's own <fieldset>; keeps the group role without <fieldset>
  // legend/styling baggage or nested-group semantics it can't control.
  <div
    className={twMerge(
      styles.chain,
      isFullWidth && styles.fullWidth,
      className
    )}
    role="group"
  >
    {children}
  </div>
);

export default Chain;
