import {Fragment} from 'react';
import {useTranslation} from 'react-i18next';
import {Link, NavLink} from 'react-router';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {StarIcon} from 'lucide-react';
import stubs from 'test/stubs';
import {Button} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

const meta: Meta = {
  component: Button,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Button',
};

export default meta;

const VARIANTS = [
  'default',
  'outline',
  'secondary',
  'ghost',
  'destructive',
  'link',
] as const;

// Each text size pairs with the icon-only size of the same height.
const SIZES = [
  {icon: 'icon-xs', text: 'xs'},
  {icon: 'icon-sm', text: 'sm'},
  {icon: 'icon', text: 'default'},
  {icon: 'icon-lg', text: 'lg'},
] as const;

type GridProps = {
  content?: 'icon' | 'icon-text' | 'text';
  isDisabled?: boolean;
  isInvalid?: boolean;
  isLoading?: boolean;
};

// Every variant (columns) at every size (rows), in one state.
const ButtonGrid = ({
  content = 'text',
  isDisabled = false,
  isInvalid = false,
  isLoading = false,
}: GridProps) => {
  const {t} = useTranslation();
  const label = isLoading ? t('form.submitting') : t('form.submit');

  return (
    <div className="grid grid-cols-7 items-center justify-items-start gap-x-6 gap-y-4">
      <span />
      {VARIANTS.map((variant) => (
        <span key={variant} className="text-muted-foreground text-sm">
          {variant}
        </span>
      ))}
      {SIZES.map((size) => (
        <Fragment key={size.text}>
          <span className="text-muted-foreground text-sm">
            {content === 'icon' ? size.icon : size.text}
          </span>
          {VARIANTS.map((variant) => (
            <Button
              key={variant}
              aria-invalid={isInvalid}
              aria-label={content === 'icon' ? label : undefined}
              disabled={isDisabled || isLoading}
              size={content === 'icon' ? size.icon : size.text}
              variant={variant}
            >
              {isLoading && (
                <Spinner aria-label={t('loading')} data-icon="inline-start" />
              )}
              {!isLoading && content !== 'text' && (
                <StarIcon data-icon="inline-start" />
              )}
              {content !== 'icon' && label}
            </Button>
          ))}
        </Fragment>
      ))}
    </div>
  );
};

export const Default: StoryFn = () => <ButtonGrid />;

export const Disabled: StoryFn = () => <ButtonGrid isDisabled={true} />;

export const Loading: StoryFn = () => <ButtonGrid isLoading={true} />;
Loading.parameters = {
  chromatic: {disableSnapshot: true},
};

export const Invalid: StoryFn = () => <ButtonGrid isInvalid={true} />;

export const Icon: StoryFn = () => <ButtonGrid content="icon" />;

export const IconDisabled: StoryFn = () => (
  <ButtonGrid content="icon" isDisabled={true} />
);

export const IconText: StoryFn = () => <ButtonGrid content="icon-text" />;

export const AsLink: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Button nativeButton={false} render={<Link role="link" to="/" />}>
      {t('next')}
    </Button>
  );
};

export const AsNavLink: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Button nativeButton={false} render={<NavLink role="link" to="/" />}>
      {t('next')}
    </Button>
  );
};

export const AsExternalLink: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Button
      nativeButton={false}
      // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles
      render={<a href="https://example.com" role="link" />}
    >
      {t('next')}
    </Button>
  );
};
