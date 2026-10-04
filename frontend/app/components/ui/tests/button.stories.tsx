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

type IconSize = 'icon' | 'icon-lg' | 'icon-sm' | 'icon-xs';
type Size = 'default' | 'lg' | 'sm' | 'xs';
type Variant =
  'default' | 'destructive' | 'ghost' | 'link' | 'outline' | 'secondary';

const VariantStory = ({variant}: {variant: Variant}) => {
  const {t} = useTranslation();

  return <Button variant={variant}>{t('form.submit')}</Button>;
};

const SizeStory = ({size}: {size: Size}) => {
  const {t} = useTranslation();

  return <Button size={size}>{t('form.submit')}</Button>;
};

const IconSizeStory = ({size}: {size: IconSize}) => {
  const {t} = useTranslation();

  return (
    <Button aria-label={t('form.submit')} size={size}>
      <StarIcon />
    </Button>
  );
};

export const Default: StoryFn = () => <VariantStory variant="default" />;

export const Outline: StoryFn = () => <VariantStory variant="outline" />;

export const Secondary: StoryFn = () => <VariantStory variant="secondary" />;

export const Ghost: StoryFn = () => <VariantStory variant="ghost" />;

export const Destructive: StoryFn = () => (
  <VariantStory variant="destructive" />
);

export const LinkVariant: StoryFn = () => <VariantStory variant="link" />;

export const SizeDefault: StoryFn = () => <SizeStory size="default" />;

export const SizeXs: StoryFn = () => <SizeStory size="xs" />;

export const SizeSm: StoryFn = () => <SizeStory size="sm" />;

export const SizeLg: StoryFn = () => <SizeStory size="lg" />;

export const SizeIcon: StoryFn = () => <IconSizeStory size="icon" />;

export const SizeIconXs: StoryFn = () => <IconSizeStory size="icon-xs" />;

export const SizeIconSm: StoryFn = () => <IconSizeStory size="icon-sm" />;

export const SizeIconLg: StoryFn = () => <IconSizeStory size="icon-lg" />;

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Button aria-invalid={true} variant="outline">
      {t('form.submit')}
    </Button>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return <Button disabled={true}>{t('form.submit')}</Button>;
};

export const Loading: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Button disabled={true}>
      <Spinner aria-label={t('loading')} />
      {t('form.submitting')}
    </Button>
  );
};

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
