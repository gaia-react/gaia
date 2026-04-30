import type {AnchorHTMLAttributes, FC} from 'react';
import {Link, NavLink} from 'react-router';
import {twJoin, twMerge} from 'tailwind-merge';
import type {IconUnion, Variant} from '~/components/Button';
import {ICON_POSITION, ICON_SIZES, SIZES, VARIANTS} from '~/components/Button';
import type {Size} from '~/types';

type LinkButtonProps = AnchorHTMLAttributes<HTMLAnchorElement> &
  IconUnion & {
    disabled?: boolean;
    href?: never;
    isNav?: boolean;
    prefetch?: 'intent' | 'none' | 'render';
    size?: Size;
    to: string;
    variant?: Variant;
  };

const LinkButton: FC<LinkButtonProps> = ({
  children,
  className,
  classNameIcon,
  disabled,
  icon,
  iconPosition = 'left',
  isNav,
  prefetch,
  size = 'base',
  to = '',
  variant = 'primary',
  ...props
}) => {
  const Icon = icon;
  const iconComponent =
    Icon ?
      <Icon className={twJoin(children && 'flex-none', classNameIcon)} />
    : null;

  const innerSpan = (
    <span
      className={twJoin(
        icon &&
          children &&
          `flex items-center justify-center gap-1.5 ${ICON_POSITION[iconPosition]}`
      )}
    >
      {iconComponent}
      {children}
    </span>
  );

  const css = twMerge(
    'plain-link text-center whitespace-nowrap select-none',
    disabled ?
      VARIANTS[variant].split('disabled:').join('')
    : VARIANTS[variant],
    SIZES[size],
    icon && ICON_SIZES[size],
    variant !== 'custom' && 'rounded-sm transition-colors duration-200',
    disabled && 'cursor-not-allowed opacity-50 dark:opacity-30',
    className
  );

  if (to.startsWith('http')) {
    return (
      <a
        className={css}
        data-disabled={disabled ? true : undefined}
        href={to}
        rel="noopener noreferrer"
        tabIndex={disabled ? -1 : undefined}
        target="_blank"
        {...props}
      >
        {innerSpan}
      </a>
    );
  }

  if (isNav) {
    return (
      <NavLink
        className={({isActive}) => twMerge(css, !isActive && VARIANTS.tertiary)}
        data-disabled={disabled ? true : undefined}
        prefetch={prefetch}
        tabIndex={disabled ? -1 : undefined}
        to={to}
        {...props}
      >
        {innerSpan}
      </NavLink>
    );
  }

  return (
    <Link
      className={css}
      data-disabled={disabled ? true : undefined}
      prefetch={prefetch}
      tabIndex={disabled ? -1 : undefined}
      to={to}
      {...props}
    >
      {innerSpan}
    </Link>
  );
};

export default LinkButton;
