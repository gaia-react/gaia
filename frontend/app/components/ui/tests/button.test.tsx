// @vitest-environment jsdom
import type {MouseEvent, ReactNode} from 'react';
import {
  createMemoryRouter,
  Link,
  NavLink,
  RouterProvider,
  useLocation,
} from 'react-router';
import userEvent from '@testing-library/user-event';
import {cn} from 'cn';
import {describe, expect, test, vi} from 'vitest';
import {render, screen} from 'test/rtl';
import {Button, buttonVariants} from '~/components/ui/button';

const CurrentPathname = () => (
  <p data-testid="location">{useLocation().pathname}</p>
);

const renderInRouter = (element: ReactNode) => {
  const router = createMemoryRouter([
    {
      element: (
        <>
          {element}
          <CurrentPathname />
        </>
      ),
      path: '/',
    },
    {element: <CurrentPathname />, path: '/target'},
  ]);
  render(<RouterProvider router={router} />);
};

const getVariantClasses = (variant: 'outline') =>
  cn(buttonVariants({variant})).split(' ');

describe('Button rendered as a link', () => {
  test('Link: exposes link semantics, slot and variant classes', () => {
    renderInRouter(
      <Button
        nativeButton={false}
        render={<Link role="link" to="/target" />}
        variant="outline"
      >
        Go
      </Button>
    );
    const link = screen.getByRole('link', {name: 'Go'});
    expect(link).toHaveAttribute('href', '/target');
    expect(link).toHaveAttribute('data-slot', 'button');
    expect(link).not.toHaveAttribute('type');
    expect(link).toHaveClass(...getVariantClasses('outline'));
  });

  test('Link: navigates on click', async () => {
    const user = userEvent.setup();
    renderInRouter(
      <Button nativeButton={false} render={<Link role="link" to="/target" />}>
        Go
      </Button>
    );
    await user.click(screen.getByRole('link', {name: 'Go'}));
    expect(screen.getByTestId('location')).toHaveTextContent('/target');
  });

  test('Link: navigates on Enter', async () => {
    const user = userEvent.setup();
    renderInRouter(
      <Button nativeButton={false} render={<Link role="link" to="/target" />}>
        Go
      </Button>
    );
    await user.tab();
    expect(screen.getByRole('link', {name: 'Go'})).toHaveFocus();
    await user.keyboard('{Enter}');
    expect(screen.getByTestId('location')).toHaveTextContent('/target');
  });

  test('NavLink: exposes link semantics, slot and variant classes', () => {
    renderInRouter(
      <Button
        nativeButton={false}
        render={<NavLink role="link" to="/target" />}
        variant="outline"
      >
        Go
      </Button>
    );
    const link = screen.getByRole('link', {name: 'Go'});
    expect(link).toHaveAttribute('href', '/target');
    expect(link).toHaveAttribute('data-slot', 'button');
    expect(link).not.toHaveAttribute('type');
    expect(link).toHaveClass(...getVariantClasses('outline'));
  });

  test('NavLink: navigates on click', async () => {
    const user = userEvent.setup();
    renderInRouter(
      <Button
        nativeButton={false}
        render={<NavLink role="link" to="/target" />}
      >
        Go
      </Button>
    );
    await user.click(screen.getByRole('link', {name: 'Go'}));
    expect(screen.getByTestId('location')).toHaveTextContent('/target');
  });

  test('NavLink: navigates on Enter', async () => {
    const user = userEvent.setup();
    renderInRouter(
      <Button
        nativeButton={false}
        render={<NavLink role="link" to="/target" />}
      >
        Go
      </Button>
    );
    await user.tab();
    await user.keyboard('{Enter}');
    expect(screen.getByTestId('location')).toHaveTextContent('/target');
  });

  test('external anchor: exposes link semantics, slot and variant classes', () => {
    render(
      <Button
        nativeButton={false}
        // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles
        render={<a href="https://example.com/docs" role="link" />}
        variant="outline"
      >
        Docs
      </Button>
    );
    const link = screen.getByRole('link', {name: 'Docs'});
    expect(link).toHaveAttribute('href', 'https://example.com/docs');
    expect(link).toHaveAttribute('data-slot', 'button');
    expect(link).not.toHaveAttribute('type');
    expect(link).toHaveClass(...getVariantClasses('outline'));
  });

  test('external anchor: stays focusable and activates on Enter', async () => {
    const user = userEvent.setup();
    // jsdom cannot navigate, so the handler stops the navigation and records
    // that Enter activated the link.
    const handleClickLink = vi.fn((event: MouseEvent<HTMLAnchorElement>) => {
      event.preventDefault();
    });
    render(
      <Button
        nativeButton={false}
        render={
          // eslint-disable-next-line jsx-a11y/anchor-has-content, jsx-a11y/no-redundant-roles
          <a
            href="https://example.com/docs"
            onClick={handleClickLink}
            role="link"
          />
        }
      >
        Docs
      </Button>
    );
    await user.tab();
    const link = screen.getByRole('link', {name: 'Docs'});
    expect(link).toHaveFocus();
    await user.keyboard('{Enter}');
    expect(link).toHaveAttribute('href', 'https://example.com/docs');
    expect(handleClickLink).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({type: 'click'})
    );
  });
});

describe('Button disabled action', () => {
  test('is disabled and does not fire', async () => {
    const user = userEvent.setup();
    const handleClickSaveButton = vi.fn();
    render(
      <Button disabled={true} onClick={handleClickSaveButton}>
        Save
      </Button>
    );
    const button = screen.getByRole('button', {name: 'Save'});
    expect(button).toBeDisabled();
    await user.click(button);
    expect(handleClickSaveButton).not.toHaveBeenCalled();
  });
});
