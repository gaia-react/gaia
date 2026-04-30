import {Fragment} from 'react';
import {IoStar} from 'react-icons/io5';
import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import type {Variant} from '~/components/Button';
import type {Size} from '~/types';
import LinkButton from '../index';

const meta: Meta = {
  component: LinkButton,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/LinkButton',
};

export default meta;

const sizes: Size[] = ['xs', 'sm', 'base', 'lg', 'xl'];

const variants: Variant[] = [
  'primary',
  'secondary',
  'tertiary',
  'destructive',
  'borderless',
];

const legends = ['text-xs', 'text-sm', 'text-base', 'text-lg', 'text-xl'];

const render = (icon?: boolean, iconText?: boolean, disabled?: boolean) => (
  <div className="grid max-w-5xl grid-cols-11 items-center justify-items-start gap-x-8 gap-y-4">
    <div />
    {variants.map((variant) => (
      <legend key={variant} className="col-span-2 text-sm capitalize">
        {variant}
      </legend>
    ))}
    {sizes.map((size) => (
      <Fragment key={size}>
        <legend className={legends.find((value) => value.includes(size))}>
          {size}
        </legend>
        {variants.map((variant) => (
          <LinkButton
            key={variant}
            aria-label={`${variant}-${size}`}
            className="col-span-2 capitalize"
            disabled={disabled}
            icon={icon ? IoStar : undefined}
            size={size}
            to="/"
            variant={variant}
          >
            {!icon || iconText ? 'Label' : undefined}
          </LinkButton>
        ))}
      </Fragment>
    ))}
  </div>
);

export const Default: StoryFn = () => render();

export const Disabled: StoryFn = () => render(false, false, true);

export const Icon: StoryFn = () => render(true, false);

export const IconDisabled: StoryFn = () => render(true, false, true);

export const IconText: StoryFn = () => render(true, true);

export const IconTextDisabled: StoryFn = () => render(true, true, true);
