/**
 * Confirmation abstraction for the mentorship CLI surface.
 *
 * The `--yes` flag is the documented non-interactive bypass for scripted /
 * CI use. When `yesFlag === true`, this returns `true` immediately without
 * touching stdin or invoking any prompt; structured stdout/stderr must
 * stay parseable in scripted contexts.
 *
 * Outside Claude Code, when the user runs `gaia mentorship enable` directly
 * from a shell, this falls back to a stdin Y/N prompt. The slash-command /
 * skill layer (gaia-init) wraps the CLI invocation with `AskUserQuestion`
 * outside the CLI and passes `--yes` once the user confirms; so the CLI
 * never needs to invoke `AskUserQuestion` itself (that tool is LLM-only).
 *
 * If stdin is not a TTY and `--yes` was not passed, the prompt fails closed
 * (returns `false`); never silently proceed in a scripted context.
 */
import {createInterface} from 'node:readline';

type AskConfirmArguments = {
  cancelLabel?: string;
  confirmLabel: string;
  question: string;
  yesFlag: boolean;
};

const promptStdin = async (text: string): Promise<string> =>
  new Promise((resolve) => {
    const rl = createInterface({input: process.stdin, output: process.stderr});
    rl.question(text, (answer) => {
      rl.close();
      resolve(answer);
    });
  });

export const askConfirm = async (
  arguments_: AskConfirmArguments
): Promise<boolean> => {
  const {cancelLabel = 'Cancel', confirmLabel, question, yesFlag} = arguments_;

  if (yesFlag) {
    return true;
  }

  if (!process.stdin.isTTY) {
    // Non-TTY without --yes: refuse to proceed silently. Caller surfaces
    // the structured stdout `cancelled` outcome.
    return false;
  }
  const answer = await promptStdin(
    `${question} [${confirmLabel}/${cancelLabel}] `
  );
  const normalized = answer.trim().toLowerCase();

  return normalized === 'y' || normalized === 'yes';
};
