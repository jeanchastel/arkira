# React Composition Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

Arkira app repos target React 19+. Next.js App Router provides the React canary
line it requires; React 19 is the hard floor for non-Next React app repos.

## Switch

`react_composition` in `ai-engineering/bootstrap/switches.json`. Default on.

## Primitive layer

Base UI is the standard primitive layer for new React and Next.js interface work. Use its primitives for that work.

Preserve an existing product-owned design system by default. Never rewrite a component library to adopt Base UI on your own initiative: not to reduce inconsistency, not to comply with this standard, and not as a side effect of unrelated work.

An operator may explicitly request migration of an existing component library. That request authorizes the rewrite and overrides the preceding paragraph. Treat it as a scoped project with a spec recorded before implementation. Migrate the components that carry real behavior, focus management, keyboard contracts, dismissal semantics, and leave pure-markup components alone.

New interface work must provide correct behavior, accessibility, keyboard interaction, and the
loading, empty, error, and responsive states that materially apply. Add no speculative wrapper or
generated component churn.

## Component Architecture

- Do not grow a component API through behavioral boolean props. Each boolean
  multiplies states and permits invalid combinations; compose explicit variants
  from shared parts instead (`architecture-avoid-boolean-props`).
- Structure complex component families as compound components with a shared,
  typed context. Consumers select the parts they need without prop drilling or
  hidden branches (`architecture-compound-components`).

## State Management

- Lift shared state into a provider whose boundary encloses every consumer,
  including controls that sit outside the visual component frame
  (`state-lift-state`).
- Define the context contract in `state`, `actions`, and `meta` terms so providers
  can dependency-inject different implementations into the same UI
  (`state-context-interface`).
- Keep storage, synchronization, and state-library knowledge inside providers.
  UI components consume the context contract, not a particular state mechanism
  (`state-decouple-implementation`).

## Implementation Patterns

- Prefer `children` for static structural composition. Use a render prop only
  when the parent must supply data or state to the rendered child
  (`patterns-children-over-render-props`).
- Give materially different modes named variant components. Each variant states
  its provider, available actions, and composed UI explicitly
  (`patterns-explicit-variants`).

## React 19 Idioms

- Accept `ref` as a regular prop. Do not introduce `forwardRef` wrappers
  (`react19-no-forwardref`).
- Read context with `use()`, including conditional reads where appropriate,
  instead of adding new `useContext()` calls (`react19-no-forwardref`).

These rules are unconditional because React 19+ is the Arkira app baseline.

## Do / Do not

Do:

- expose small compound parts and explicit variants
- lift shared state to the provider boundary that owns it
- make state implementations replaceable behind a typed context contract
- use React 19 ref and context idioms

Do not:

- accumulate boolean mode props on a monolithic component
- synchronize trapped child state upward with effects or imperative refs
- couple reusable UI to one state library or server-sync hook
- add `forwardRef` or new `useContext()` usage

## Pre-Ship Checklist

- app targets React 19 or the compatible Next.js App Router React line
- component variants cannot express invalid boolean combinations
- compound components expose only the pieces consumers need
- provider boundary contains every shared-state consumer
- context separates `state`, `actions`, and `meta`
- refs are regular props and context reads use `use()`
