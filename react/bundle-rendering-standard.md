# React Bundle and Rendering Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`react_bundle_rendering` in `ai-engineering/bootstrap/switches.json`. Default on.

## Bundle Discipline

- Avoid broad barrel imports. Use Next.js `optimizePackageImports` for supported
  packages or typed direct subpath imports elsewhere (`bundle-barrel-imports`).
- Dynamically import heavy components that are not required for the initial
  render, and load large modules or data only when their feature is activated
  (`bundle-dynamic-imports`, `bundle-conditional`).
- Defer non-critical analytics, logging, and error-reporting clients until after
  hydration (`bundle-defer-third-party`).
- Keep dynamic imports and filesystem access statically analyzable with literal
  paths or explicit maps. Hidden paths widen bundles and server file traces
  (`bundle-analyzable-paths`).
- Preload a heavy deferred feature only on credible intent such as focus, hover,
  or an enabled feature flag (`bundle-preload`).

The weight budget in `skills/perf-budget/SKILL.md` applies only to
`profile: static-web`. This standard governs bundle discipline for app repos
without changing that profile gate.

## Re-render Optimization

- **Correctness:** define component types at module scope. A component defined
  inside another component is a new type on every render, so React remounts it
  and destroys its state and DOM (`rerender-no-inline-components`).
- **Correctness:** derive values from current props and state during render. Do
  not mirror derivable values into state with an effect; use a keyed reset when
  state truly must restart (`rerender-derived-state-no-effect`).
- Subscribe to the narrowest derived value needed, read dynamic state at the
  point of use when no render subscription is required, and narrow effect
  dependencies to the primitive that drives the effect (`rerender-derived-state`,
  `rerender-defer-reads`, `rerender-dependencies`).
- Use functional state updates whenever the next value depends on the previous
  value, and lazy initialization for expensive initial values
  (`rerender-functional-setstate`, `rerender-lazy-state-init`).
- Put interaction-triggered side effects in their event handlers, not in state
  plus an effect (`rerender-move-effect-to-event`).
- Extract expensive work behind a memoized component when it lets a parent exit
  before doing that work. Keep default object, array, and function props stable,
  and do not memoize cheap primitive expressions (`rerender-memo`,
  `rerender-memo-with-default-value`, `rerender-simple-expression-in-memo`).
  Let React Compiler replace manual memoization where enabled.
- Split unrelated hook computations and effects by dependency set
  (`rerender-split-combined-hooks`).
- Mark non-urgent updates as transitions and defer values that drive expensive
  derived rendering so urgent input stays responsive (`rerender-transitions`,
  `rerender-use-deferred-value`).
- Store rapidly changing, non-visual transient values in refs; state remains for
  values that affect rendered output (`rerender-use-ref-transient-values`).

## Client Rendering and Hydration

- Apply `content-visibility: auto` with a representative intrinsic size to long,
  off-screen lists where deferred layout and paint are safe
  (`rendering-content-visibility`).
- Use React DOM resource hints only for resources the current page or a likely
  next action will need. Match DNS, connection, preload, and preinit strength to
  actual urgency (`rendering-resource-hints`).
- For client-only values that must be correct on first paint, use a vetted
  synchronous pre-hydration update rather than reading browser storage during
  SSR or correcting the value in a post-hydration effect. Preserve CSP and
  safely encode any injected value (`rendering-hydration-no-flicker`).
- Raw scripts must use `defer` when order or the parsed DOM matters and `async`
  when independent. In Next.js, prefer the matching `next/script` strategy
  (`rendering-script-defer-async`).

## Do / Do not

Do:

- keep the initial module graph narrow and statically visible
- make component identity stable across renders
- derive state in render and reserve effects for synchronization
- prioritize input and first paint over non-critical work

Do not:

- load heavy optional features or third parties in the initial bundle
- define components inside render functions
- use effects to maintain values already derivable from props or state
- hide import or filesystem paths from build analysis

## Pre-Ship Checklist

- broad package imports are optimized or replaced with typed direct imports
- heavy optional components and third parties are deferred
- dynamic paths are statically analyzable
- component types are stable and derived state is effect-free
- urgent input remains responsive during expensive rendering
- hydration has no mismatch or corrective flicker
- scripts and resource hints do not block rendering unnecessarily
