// Must fail with the `@gaia-react/lint` `no-restricted-syntax` selector that
// bans rendering `null` from a ternary.
export const ProbeTernary = ({visible}: {visible: boolean}) =>
  visible ? <p>visible</p> : null;
