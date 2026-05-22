# Hook Patterns — Extended Examples

## Contents

- [useEffect Anti-Patterns](#useeffect-anti-patterns)
- [When Effects ARE Correct](#when-effects-are-correct)
- [Strict Mode & Cleanup](#strict-mode--cleanup)
- [useCallback — When to Use](#usecallback--when-to-use)
- [useMemo — When to Use](#usememo--when-to-use)

---

## useEffect Anti-Patterns

### Don't transform data for rendering

```tsx
// BAD — unnecessary state + Effect + extra render cycle
const [filtered, setFiltered] = useState<Exercise[]>([]);
useEffect(() => {
  setFiltered(exercises.filter((e) => e.muscleGroup === selected));
}, [exercises, selected]);

// GOOD — derive inline
const filtered = exercises.filter((e) => e.muscleGroup === selected);
```

### Don't use Effects for expensive calculations

```tsx
// BAD — triggers a render to set state, then Effect runs and triggers a second render
useEffect(() => {
  setSorted(exercises.slice().sort((a, b) => a.name.localeCompare(b.name)));
}, [exercises]);

// GOOD — useMemo runs synchronously, no extra render
const sorted = useMemo(
  () => exercises.slice().sort((a, b) => a.name.localeCompare(b.name)),
  [exercises]
);
```

### Don't derive redundant state

```tsx
// BAD — Effect sets state after render, causing an extra render cycle every time deps change
useEffect(() => {
  setFullName(`${firstName} ${lastName}`);
}, [firstName, lastName]);

// GOOD
const fullName = `${firstName} ${lastName}`;
```

### Don't put user-event logic in Effects

```tsx
// BAD — notification in Effect triggered by state change; effects fire after render,
// so the causal link between action and side effect is indirect; also runs on mount
// and every dep change, not just the user action
useEffect(() => {
  if (justAdded) showToast(`${product.name} added`);
}, [justAdded]);

// GOOD — in the event handler
function handleAddToPlan() {
  dispatch({type: 'add', product});
  showToast(`${product.name} added to your plan`);
}
```

### Don't chain Effects

```tsx
// BAD — multiple Effects cascading state updates; each setState triggers its own render,
// so n chained effects = n+1 render cycles
useEffect(() => {
  setCard(deck[index]);
}, [index]);
useEffect(() => {
  setGoldCount(card.isGold ? count + 1 : count);
}, [card]);

// GOOD — derive everything from the event
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
// BAD — fires after every render where isOn changed, including the initial mount;
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

### State reset — use key, not Effect

```tsx
// BAD — Effect fires after the stale state has already rendered, causing a visible flash before reset
useEffect(() => {
  setNotes('');
  setEditing(false);
}, [userId]);

// GOOD — key forces unmount/remount, all state resets before the first paint
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

React 18 Strict Mode mounts → unmounts → remounts every component in development. Effects run twice. Cleanup must fully undo the setup, or the second invocation leaves duplicate state or stale listeners. This is intentional — it surfaces missing cleanups before they leak in production.

```tsx
// BAD — missing cleanup leaks the listener (and fires twice in dev with Strict Mode)
useEffect(() => {
  window.addEventListener('resize', handleResize);
}, [handleResize]);

// GOOD — cleanup mirrors setup exactly
useEffect(() => {
  window.addEventListener('resize', handleResize);
  return () => window.removeEventListener('resize', handleResize);
}, [handleResize]);
```

The same principle applies to any subscription, timer, or third-party widget: if the Effect sets something up, the cleanup must tear it down completely.

---

## useCallback — When to Use

```tsx
// ✅ Passed to memo-wrapped child — prevents unnecessary child re-renders
const handleSubmitForm = useCallback((data: FormData) => {
  post('/api/submit', data);
}, []);
return <MemoizedForm onSubmit={handleSubmitForm} />;

// ✅ Used in useEffect dependency array — keeps a stable reference
const fetchData = useCallback(async () => {
  const result = await api.get(endpoint);
  setData(result);
}, [endpoint]);

useEffect(() => {
  fetchData();
}, [fetchData]);

// ❌ Not passed to a memo child, not in any hook deps — skip useCallback
const handleClickIncrement = () => {
  setCount(count + 1);
};
```

### Anti-pattern: wrapping every handler "just in case"

```tsx
// BAD — premature optimization; every render still allocates the deps array,
// so if deps change often useCallback saves nothing. An empty deps array is
// a stale closure waiting to happen if the handler ever needs to read state or props.
const handleChangeName = useCallback((e: ChangeEvent<HTMLInputElement>) => {
  setName(e.target.value);
}, []); // looks safe now — breaks the moment handleChangeName needs to read other state

// GOOD — plain function is the right default
const handleChangeName = (e: ChangeEvent<HTMLInputElement>) => {
  setName(e.target.value);
};
```

The default should be a plain function. Reach for `useCallback` only when you have a concrete reason: a `memo`-wrapped child that's visibly re-rendering, or a stable reference needed by an Effect.

---

## useMemo — When to Use

Use `useMemo` for computations that are:

- Genuinely expensive (sorting/filtering large arrays, building derived structures)
- Passed as props to `memo`-wrapped children where reference stability matters
- Used in `useEffect` dependency arrays to maintain a stable reference

### Anti-pattern: memoizing cheap calculations

```tsx
// BAD — trivial calculation; memo bookkeeping costs more than it saves
const label = useMemo(() => `Hello, ${name}`, [name]);

// GOOD — just compute inline
const label = `Hello, ${name}`;
```

Missing or stale deps in `useMemo` introduce the same stale closure bugs as `useCallback` — the memoized value silently reads an old snapshot of whatever was omitted from the deps array.
