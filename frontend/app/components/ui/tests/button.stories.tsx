import type {ComponentProps, MouseEvent} from 'react';
import {Fragment} from 'react';
import {useTranslation} from 'react-i18next';
import {Link, NavLink} from 'react-router';
import type {Meta, StoryFn, StoryObj} from '@storybook/react-vite';
import {StarIcon} from 'lucide-react';
import {expect, fn, userEvent, within} from 'storybook/test';
import stubs from 'test/stubs';
import {Button} from '~/components/ui/button';
import {Spinner} from '~/components/ui/spinner';

const meta: Meta = {
  component: Button,
  decorators: [stubs.reactRouter({destinations: ['/target']})],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Button',
};

export default meta;

// Compile-time guard: fails when a variant or size is missing from the lists
// below, so a registry overwrite that adds one cannot leave the grid behind.
type AssertNever<T extends never> = T;
type ButtonSizeName = NonNullable<ComponentProps<typeof Button>['size']>;
type ButtonVariantName = NonNullable<ComponentProps<typeof Button>['variant']>;
// eslint-disable-next-line unused-imports/no-unused-vars -- the alias exists only to fail compilation
type UncoveredSizes = AssertNever<
  Exclude<
    ButtonSizeName,
    'default' | (typeof SIZES)[number][keyof (typeof SIZES)[number]]
  >
>;
// eslint-disable-next-line unused-imports/no-unused-vars -- the alias exists only to fail compilation
type UncoveredVariants = AssertNever<
  Exclude<ButtonVariantName, (typeof VARIANTS)[number]>
>;

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

type ButtonGridProps = {
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
}: ButtonGridProps) => {
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

type LinkButtonProps = {label?: string; to?: string};

const LinkButton = ({label, to = '/'}: LinkButtonProps) => {
  const {t} = useTranslation();

  return (
    <Button nativeButton={false} render={<Link role="link" to={to} />}>
      {label ?? t('next')}
    </Button>
  );
};

const NavLinkButton = ({label, to = '/'}: LinkButtonProps) => {
  const {t} = useTranslation();

  return (
    <Button nativeButton={false} render={<NavLink role="link" to={to} />}>
      {label ?? t('next')}
    </Button>
  );
};

const ExternalLinkButton = () => {
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

const expectLinkSemantics = async (canvasElement: HTMLElement) => {
  const link = within(canvasElement).getByRole('link');

  await expect(link).toHaveAttribute('data-slot', 'button');
  await expect(link).not.toHaveAttribute('type');
};

export const AsLink: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expectLinkSemantics(canvasElement);
    await expect(within(canvasElement).getByRole('link')).toHaveAttribute(
      'href',
      '/'
    );
  },
  render: () => <LinkButton />,
};

export const AsNavLink: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expectLinkSemantics(canvasElement);
    await expect(within(canvasElement).getByRole('link')).toHaveAttribute(
      'href',
      '/'
    );
  },
  render: () => <NavLinkButton />,
};

export const AsExternalLink: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    await expectLinkSemantics(canvasElement);
    await expect(within(canvasElement).getByRole('link')).toHaveAttribute(
      'href',
      'https://example.com'
    );
  },
  render: () => <ExternalLinkButton />,
};

// The navigating stories end on the destination page, so the render-only link
// stories above stay axe-scanned in their resting state.
const navigatesOnClick: StoryObj<typeof meta>['play'] = async ({
  canvasElement,
}) => {
  await userEvent.click(within(canvasElement).getByRole('link', {name: 'Go'}));
  await expect(
    await within(canvasElement).findByText('Navigated to /target')
  ).toBeVisible();
};

const navigatesOnEnter: StoryObj<typeof meta>['play'] = async ({
  canvasElement,
}) => {
  await userEvent.tab();
  await expect(
    within(canvasElement).getByRole('link', {name: 'Go'})
  ).toHaveFocus();
  await userEvent.keyboard('{Enter}');
  await expect(
    await within(canvasElement).findByText('Navigated to /target')
  ).toBeVisible();
};

export const LinkNavigatesOnClick: StoryObj<typeof meta> = {
  play: navigatesOnClick,
  render: () => <LinkButton label="Go" to="/target" />,
};

export const LinkNavigatesOnEnter: StoryObj<typeof meta> = {
  play: navigatesOnEnter,
  render: () => <LinkButton label="Go" to="/target" />,
};

export const NavLinkNavigatesOnClick: StoryObj<typeof meta> = {
  play: navigatesOnClick,
  render: () => <NavLinkButton label="Go" to="/target" />,
};

export const NavLinkNavigatesOnEnter: StoryObj<typeof meta> = {
  play: navigatesOnEnter,
  render: () => <NavLinkButton label="Go" to="/target" />,
};

// The handler stops the navigation so the test never leaves the page, and
// records that Enter activated the link.
export const ExternalLinkActivatesOnEnter: StoryObj<typeof meta> = {
  args: {
    onClick: fn((event: MouseEvent<HTMLAnchorElement>) => {
      event.preventDefault();
    }),
  },
  play: async ({args, canvasElement}) => {
    await userEvent.tab();

    const link = within(canvasElement).getByRole('link', {name: 'Docs'});

    await expect(link).toHaveFocus();
    await userEvent.keyboard('{Enter}');
    await expect(link).toHaveAttribute('href', 'https://example.com/docs');
    await expect(args.onClick).toHaveBeenCalledTimes(1);
    await expect(args.onClick).toHaveBeenCalledWith(
      expect.objectContaining({type: 'click'})
    );
  },
  render: (args) => (
    <Button
      nativeButton={false}
      render={
        // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles
        <a href="https://example.com/docs" onClick={args.onClick} role="link" />
      }
    >
      Docs
    </Button>
  ),
};
