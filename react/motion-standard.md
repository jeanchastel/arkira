# React Motion Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Switch

`react_motion` in `ai-engineering/bootstrap/switches.json`. Default on.

This standard requires the React 19+ baseline in
`react/composition-standard.md`.

## When to Animate

- Every transition must communicate spatial relationship, identity, arrival, or
  continuity. If that meaning cannot be stated, do not add the animation
  (`skills/react-view-transitions/SKILL.md`, "When to Animate").
- Implement every applicable pattern in this priority order: shared element,
  Suspense reveal, list identity, state change, then route change. The order
  prevents broad route motion from hiding more meaningful local continuity
  (`skills/react-view-transitions/SKILL.md`, "When to Animate").

## Native React Mechanism

- Declare transitions with React's `<ViewTransition>`. Never call
  `document.startViewTransition` directly. Trigger updates with
  `startTransition`, `useDeferredValue`, or Suspense
  (`skills/react-view-transitions/SKILL.md`, "Core Concepts").
- Place the boundary before the DOM nodes whose insertion or removal it owns.
  Use `default="none"` and opt into named triggers so unrelated navigation,
  revalidation, and Suspense work does not cross-fade
  (`skills/react-view-transitions/SKILL.md`, "Critical Placement Rule" and
  "How Multiple VTs Interact").
- Shared-element names are globally unique. Compose a keyed outer boundary for
  list identity with a separately named inner boundary for the shared element
  (`skills/react-view-transitions/SKILL.md`, "Shared Element Transitions" and
  "Common Patterns").
- Suspense reveals use string enter and exit classes because navigation types do
  not carry into the later reveal transition
  (`skills/react-view-transitions/references/implementation.md`, Step 5).

## Navigation and State Patterns

- Audit every navigation path, Suspense boundary, persistent element, and shared
  visual before implementation. Record which shared pairs form and which paths
  need a fallback (`skills/react-view-transitions/references/implementation.md`,
  Step 1).
- Reserve directional slides for hierarchical navigation and ordered sequences.
  Lateral or unordered navigation uses a cross-fade or no animation
  (`skills/react-view-transitions/SKILL.md`, "Choosing Animation Style").
- Put directional route boundaries in page components, not persistent layouts,
  and pair enter with exit. Type maps include an explicit `default: "none"`
  (`skills/react-view-transitions/references/implementation.md`, Step 4).
- Use a stable key for list identity, and change a key only when a remount and
  state reset are intended. Isolate persistent and floating UI from a parent
  snapshot with a unique `viewTransitionName`
  (`skills/react-view-transitions/references/patterns.md`).

## Animation Styles

- Adapt the vetted pseudo-element and keyframe structures in
  `skills/react-view-transitions/references/css-recipes.md`; do not invent a new
  motion vocabulary for each feature.
- All animation CSS consumes `--motion-page`, `--motion-shared`, or
  `--motion-reveal` semantic motion token pairs from
  `theme/theme-standard.md`. Raw duration and easing values do not live in the
  global stylesheet or component CSS.
- Keep the reduced-motion implementation in the theme token override governed by
  `theme/theme-standard.md`; do not duplicate its requirement here.

## Do / Do not

Do:

- choose the most local pattern that communicates the change
- verify every forward, back, same-route, and Suspense path
- keep shared names unique and persistent UI isolated
- consume semantic motion tokens in all transition CSS

Do not:

- add motion without a communicative purpose
- call `startViewTransition` directly
- use directional slides for tabs or other lateral navigation
- embed raw milliseconds or easing curves in a global stylesheet

## Pre-Ship Checklist

- all five applicable patterns were considered in priority order
- every animation has a stated spatial or continuity meaning
- `<ViewTransition>` placement and triggers verified on each navigation path
- shared names are globally unique and fallback behavior is intentional
- persistent UI remains visually stationary
- animation CSS consumes semantic motion tokens
- reduced-motion token override verified
