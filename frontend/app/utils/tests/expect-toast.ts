// eslint-disable-next-line import-x/no-extraneous-dependencies -- story-only helper: storybook is a devDependency and this file never ships
import {expect, waitFor, within} from 'storybook/test';

// Waits until a toast with the given text is on screen. The toast renders in a
// portal on the document body, outside the canvas element, so the query runs
// against the body.
export const expectToast = async (
  canvasElement: HTMLElement,
  text: string
): Promise<void> => {
  await waitFor(async () => {
    await expect(
      within(canvasElement.ownerDocument.body).getByText(text)
    ).toBeVisible();
  });
};
