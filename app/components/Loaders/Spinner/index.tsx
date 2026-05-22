import type {FC} from 'react';
import {useId} from 'react';
import {useTranslation} from 'react-i18next';
import {twMerge} from 'tailwind-merge';
import type {Size} from '~/types';

export type SpinnerProps = {
  className?: string;
  label?: string;
  size?: Size;
};

const SIZES: Record<Size, string> = {
  base: 'h-5',
  lg: 'h-6',
  sm: 'h-4',
  xl: 'h-7',
  xs: 'h-3',
};

const Spinner: FC<SpinnerProps> = ({className = '', label, size = 'base'}) => {
  const {t} = useTranslation('common');
  const id = useId();

  return (
    <svg
      aria-busy="true"
      aria-label={label ?? t('loading')}
      aria-live="polite"
      className={twMerge(SIZES[size], className)}
      role="progressbar"
      viewBox="0 0 38 38"
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient id={id} x1="8.042%" x2="65.682%" y1="0%" y2="23.865%">
          <stop offset="0%" stopColor="currentColor" stopOpacity="0" />
          <stop offset="63.146%" stopColor="currentColor" stopOpacity=".631" />
          <stop offset="100%" stopColor="currentColor" />
        </linearGradient>
      </defs>
      <g fill="none" fillRule="evenodd">
        <g transform="translate(1 1)">
          <path
            d="M36 18c0-9.94-8.06-18-18-18"
            stroke={`url(#${id})`}
            strokeWidth="2"
          >
            <animateTransform
              attributeName="transform"
              dur="0.9s"
              from="0 18 18"
              repeatCount="indefinite"
              to="360 18 18"
              type="rotate"
            />
          </path>
          <circle cx="36" cy="18" fill="currentColor" r="1">
            <animateTransform
              attributeName="transform"
              dur="0.9s"
              from="0 18 18"
              repeatCount="indefinite"
              to="360 18 18"
              type="rotate"
            />
          </circle>
        </g>
      </g>
    </svg>
  );
};

export default Spinner;
