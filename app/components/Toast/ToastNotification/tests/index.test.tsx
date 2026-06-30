import {describe, expect, test} from 'vitest';
import {render, screen} from 'test/rtl';
import ToastNotification from '..';

describe('ToastNotification', () => {
  test('close button has an accessible name', () => {
    render(<ToastNotification id="0" payload="Test toast" type="info" />);

    expect(screen.getByRole('button', {name: /close/i})).toBeInTheDocument();
  });

  test('renders the message as text, never as HTML', () => {
    const messageXss = '<img src=x onerror="alert(1)">';

    render(<ToastNotification id="1" payload={messageXss} type="info" />);

    expect(screen.getByText(messageXss)).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  test('renders the description as text, never as HTML', () => {
    const messageXss = '<img src=a onerror="alert(1)">';
    const descriptionXss = '<img src=b onerror="alert(2)">';

    render(
      <ToastNotification
        id="2"
        payload={{description: descriptionXss, message: messageXss}}
        type="info"
      />
    );

    expect(screen.getByText(messageXss)).toBeInTheDocument();
    expect(screen.getByText(descriptionXss)).toBeInTheDocument();
    expect(screen.queryAllByRole('img')).toHaveLength(0);
  });

  test('renders accessible type label when only description is present', () => {
    render(
      <ToastNotification
        id="3"
        payload={{description: 'Something happened'}}
        type="error"
      />
    );

    expect(screen.getByText('Error')).toHaveClass('sr-only');
  });

  test('type label is sr-only so screen readers announce the toast type', () => {
    render(<ToastNotification id="4" payload="Test message" type="success" />);

    expect(screen.getByText('Success')).toHaveClass('sr-only');
  });
});
