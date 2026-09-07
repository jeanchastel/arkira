# DESIGN.md Schema

The canonical structure for a generated `DESIGN.md`. A `DESIGN.md` is the single
source of truth for a project's visual system: every styling decision traces
back to a section here, and brand or theme changes are made as token changes,
not component edits.

Mode 1 (Generate) emits all nine sections in order. Mode 2 (Audit) scores the
codebase against them. A section is never left as a placeholder. If a decision
has not been made, state the default chosen and why.

Each section below lists what it owns and a **Done when** check.

## 1. Brand & Personality

Owns: what the product is, three to five personality adjectives, voice, and an
explicit "what it is NOT" list. Anchors every later decision so the system has a
point of view instead of generic defaults.

Done when: a reader can predict whether a given visual choice fits the brand
without asking.

## 2. Color System

Owns: the base palette and the semantic token mapping built on top of it
(background, foreground, primary, secondary, muted, accent, destructive, border,
ring), for both light and dark. Raw hex lives here and nowhere else.

Done when: every color a component uses is a semantic token, and each token has a
light and dark value with its contrast pairing recorded.

## 3. Typography

Owns: font families with fallback stacks, and a type scale that assigns size,
line-height, weight, and letter-spacing to each role (display, h1, h2, h3, h4, body,
small, caption, code). Includes responsive scaling behavior.

Done when: every text style in the UI maps to one named role in the scale.

## 4. Spacing & Layout

Owns: the base spacing unit and scale (e.g. 4px base: 4/8/12/16/24/32/48/64),
container max-widths, the layout grid, and the breakpoint set.

Done when: no arbitrary spacing values appear in components; all spacing reads
from the scale.

## 5. Elevation & Surfaces

Owns: the border-radius scale, border treatment, and the shadow/elevation levels
that express surface layering (base, raised, overlay, popover). Defines how
stacked surfaces stay legible.

Done when: radius and elevation are chosen from named levels, not ad hoc per
component.

## 6. Motion & Interaction

Owns: the duration scale, easing curves, default transitions, and the visual
treatment of interaction states (hover, active, focus-visible, disabled,
loading). Includes the reduced-motion fallback.

Done when: motion is purposeful and consistent, every interactive element has a
defined state treatment, and `prefers-reduced-motion` is honored.

## 7. Components

Owns: the core component inventory (button, input, card, dialog, nav, etc.) with
each component's variants, states, and the tokens it consumes. This is the bridge
from the abstract system to concrete UI.

Done when: similar elements look similar because they consume the same tokens,
and each component's states are specified rather than improvised.

## 8. Accessibility

Owns: contrast targets (WCAG AA minimum, AAA where stated), the focus-visible
treatment, the touch-target floor (44px), semantic structure expectations, and
the motion-reduction commitment. Cross-references the `a11y-audit-aa` skill.

Done when: contrast pairings pass AA, focus is always visible, and touch targets
meet the floor on the smallest supported viewport.

## 9. Implementation & Tokens

Owns: how the decisions above become code: the `design-tokens.json` shape, the
CSS custom properties or Tailwind theme mapping, the token naming convention, and
the single-source-of-truth rule. The closing contract: a brand or dark-mode
change is a token change here, never a component change.

Done when: every section above resolves to a named token, and a reader can change
the theme by editing tokens alone.
