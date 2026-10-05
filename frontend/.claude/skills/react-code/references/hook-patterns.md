# Hook Patterns, Extended Examples

## Contents

- [useEffect Anti-Patterns](#useeffect-anti-patterns)
- [When Effects ARE Correct](#when-effects-are-correct)
- [Strict Mode & Cleanup](#strict-mode--cleanup)
- [Memoization](#memoization)
- [useEffectEvent, Non-Reactive Effect Logic](#useeffectevent-non-reactive-effect-logic)
- [Ref Callback Cleanup](#ref-callback-cleanup)

---

## useEffect Anti-Patterns

### Don't transform data for rendering

```tsx
// BAD, unnecessary state + Effect + extra render cycle
const [filtered, setFiltered] = useState<Exercise[]>([]);
useEffect(() => {
  setFiltered(exercises.filter((e) => e.muscleGroup === selected));
}, [exercises, selected]);

// GOOD, derive inline
const filtered = exercises.filter((e) => e.muscleGroup === selected);
```

### Don't use Effects for expensive calculations

```tsx
// BAD, triggers a render to set state, then Effect runs and triggers a second render
useEffect(() => {
  setSorted(exercises.slice().sort((a, b) => a.name.localeCompare(b.name)));
}, [exercises]);

// GOOD, derive inline during render, no extra render; the compiler memoizes it
const sorted = exercises.slice().sort((a, b) => a.name.localeCompare(b.name));
```

### Don't derive redundant state

```tsx
// BAD, Effect sets state after render, causing an extra render cycle every time deps change
useEffect(() => {
  setFullName(`${firstName} ${lastName}`);
}, [firstName, lastName]);

// GOOD
const fullName = `${firstName} ${lastName}`;
```

### Don't put user-event logic in Effects

```tsx
// BAD, notification in Effect triggered by state change; effects fire after render,
// so the causal link between action and side effect is indirect; also runs on mount
// and every dep change, not just the user action
useEffect(() => {
  if (justAdded) showToast(`${product.name} added`);
}, [justAdded]);

// GOOD, in the event handler
function handleAddToPlan() {
  dispatch({type: 'add', product});
  showToast(`${product.name} added to your plan`);
}
```

### Don't chain Effects

```tsx
// BAD, multiple Effects cascading state updates; each setState triggers its own render,
// so n chained effects = n+1 render cycles
useEffect(() => {
  setCard(deck[index]);
}, [index]);
useEffect(() => {
  setGoldCount(card.isGold ? count + 1 : count);
}, [card]);

// GOOD, derive everything from the event
function pickCard(index: number) {
  const card = deck[index];
  const newGoldCount = card.isGold ? goldCardCount + 1 : goldCardCount;
  setIndex(index);
  setCard(card);
  setGoldCardCount(newGoldCount);
  setIsWon(newGoldCount >= 5);
}
```

### Don't notify parent via Effect

```tsx
// BAD, fires after every render where isOn changed, including the initial mount;
// easy source of infinite loops if parent updates props that feed back into this child
useEffect(() => {
  onChange(isOn);
}, [isOn]);

// GOOD
function handleToggle() {
  const next = !isOn;
  setIsOn(next);
  onChange(next);
}
```

### State reset, use key, not Effect

```tsx
// BAD, Effect fires after the stale state has already rendered, causing a visible flash before reset
useEffect(() => {
  setNotes('');
  setEditing(false);
}, [userId]);

// GOOD, key forces unmount/remount, all state resets before the first paint
<WorkoutNotes key={userId} userId={userId} />;
```

---

## When Effects ARE Correct

Effects are appropriate for synchronizing with external systems.

### Data fetching with ignore flag

```tsx
useEffect(() => {
  let ignore = false;

  async function fetchExercises() {
    const {data} = await supabase
      .from('exercises')
      .select('*')
      .eq('gym_id', gymId);
    if (!ignore) setExercises(data ?? []);
  }

  fetchExercises();
  return () => {
    ignore = true;
  };
}, [gymId]);
```

### External store subscription

Prefer `useSyncExternalStore` when possible. Use Effect for third-party widgets or browser APIs that don't expose a subscribe/getSnapshot pattern.

---

## Strict Mode & Cleanup

React 18 Strict Mode mounts → unmounts → remounts every component in development. Effects run twice. Cleanup must fully undo the setup, or the second invocation leaves duplicate state or stale listeners. This is intentional, it surfaces missing cleanups before they leak in production.

```tsx
// BAD, missing cleanup leaks the listener (and fires twice in dev with Strict Mode)
useEffect(() => {
  window.addEventListener('resize', handleResize);
}, [handleResize]);

// GOOD, cleanup mirrors setup exactly
useEffect(() => {
  window.addEventListener('resize', handleResize);
  return () => window.removeEventListener('resize', handleResize);
}, [handleResize]);
```

The same principle applies to any subscription, timer, or third-party widget: if the Effect sets something up, the cleanup must tear it down completely.

---

## Memoization

When to write a manual `useMemo`, `useCallback`, or `memo` is owned by `frontend/.claude/skills/react-code/SKILL.md` `## Memoization: compiler-first`. The default is none.

A hand-written memo's deps array is a stale-closure risk: a missing or stale dep makes the memoized value or function silently read an old snapshot, and an empty deps array breaks the moment the body needs current state or props. That is one more reason not to write one.

### Functions an Effect calls

```tsx
// BAD, a function defined outside the Effect becomes a dependency to manage
const fetchData = async () => {
  const result = await api.get(endpoint);
  setData(result);
};

useEffect(() => {
  fetchData();
}, [fetchData]);

// GOOD, define it inside the Effect; the only dependency is endpoint
useEffect(() => {
  let ignore = false;

  async function fetchData() {
    const result = await api.get(endpoint);
    if (!ignore) setData(result);
  }

  void fetchData();
  return () => {
    ignore = true;
  };
}, [endpoint]);
```

When the Effect must call a function that reads values it should not re-run for, use `useEffectEvent` (next section).

---

## useEffectEvent, Non-Reactive Effect Logic

`useEffectEvent` (stable in React 19.2) extracts a non-reactive read out of an Effect, so the Effect uses a current value without listing it as a dependency. It is the sanctioned replacement for "I had to omit X from the deps array" and for the latest-ref workaround (a callback ref updated during render behind an `eslint-disable react-hooks/refs`).

```tsx
// onVisit reads numItems, but the Effect should re-run only when url changes
const onVisit = useEffectEvent((visitedUrl: string) => {
  log(visitedUrl, numItems); // numItems is non-reactive here
});

useEffect(() => {
  onVisit(url);
}, [url]); // numItems intentionally absent, and lint won't demand it
```

Use sparingly, only for values that are genuinely non-reactive (the Effect should not re-run when they change). If the Effect should react to the value, keep it in the deps array.

---

## Ref Callback Cleanup

A ref callback may return a cleanup function, run when the element leaves the DOM. When it returns a cleanup, React no longer calls the callback again with `null`.

```tsx
<div
  ref={(node) => {
    const observer = new ResizeObserver(() => {/* … */});
    observer.observe(node);
    return () => observer.disconnect(); // runs on unmount
  }}
/>;
```

**Strict-TS pitfall:** because a returned value is now read as a cleanup function, an arrow ref-callback with an implicit return of a non-`undefined` value flags. Use a block body so the callback returns `undefined`.

```tsx
// BAD, implicit return of the assignment is read as a cleanup
<input ref={(node) => (ref.current = node)} />;
// GOOD, block body returns undefined
<input ref={(node) => { ref.current = node; }} />;
```
