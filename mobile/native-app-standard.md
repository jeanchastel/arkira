# Native App Standard

Status: canonical. Propagates to product repos via the `native_app_standard`
switch policy reference and review behavior.

## Purpose

Define one sanctioned way to ship iOS and Android native app versions of Arkira
products, so native apps stay consistent with the web theme system and the
existing engineering standards instead of each app choosing its own stack.

## Scope

Applies to any Arkira product shipping a native iOS or Android app. Responsive
web is governed separately by `mobile/mobile-compliance-standard.md`.

## Switch

`native_app_standard` in `ai-engineering/bootstrap/switches.json`. Default off
at v0.26.0 (opt-in). Escalate to default-on in a later minor once the first
product opts in and validates the standard.

## Standards References

- Apple Human Interface Guidelines and App Store Review Guideline 4.2
  (Minimum Functionality)
- Material Design (48dp targets)
- WCAG 2.2 target size and resize intent, applied to native
- Theme tokens: `theme/theme-standard.md` (`--target-min`, semantic tokens)
- Package and CI standards: `tooling/package-manager-standard.md`,
  `github/ci-validation-standard.md`
- App Store payments: App Review Guidelines 3.1.1 (in-app purchase),
  3.1.3(a) reader apps, 3.1.3(b) multiplatform services; Google Play Billing
  and its reader / portal carve-outs

## Approach Tiers

### Default: Expo + React Native

Build native apps with Expo and React Native on the New Architecture (Fabric,
TurboModules, JSI), TypeScript, Expo Router, NativeWind for styling, and
react-native-reusables for components. This is the default for the whole
portfolio. It reuses the React/TypeScript stack, shares design tokens with the
web theme system, and ships true-native UI.

### Fast-path: Capacitor

Wrapping an existing web app with Capacitor is allowed only when speed-to-store
from a finished web app outweighs native fidelity, and only with app-like native
features sufficient to clear Apple Guideline 4.2: native navigation, push
notifications, real offline behavior, and at least one device capability
(camera, biometrics, or similar). A bare webview mirror of a website is not
shippable.

### Non-default: fully native or Flutter

SwiftUI + Jetpack Compose, or Flutter, are allowed only with a written
justification approved per `AGENTS.md`. They forfeit web code and token reuse and
must still meet token parity through the shared token output.

## Requirements

### Tokens and theming

- Native consumes the shared Style Dictionary token output (a React Native /
  NativeWind token target compiled from the same W3C JSON source as web CSS
  variables). No separate hand-maintained native palette.
- Brand and dark mode are token changes, not component changes, identical to
  `theme/theme-standard.md`.
- `--target-min` (44pt iOS / dp Android) is the touch-target floor for primary
  interactive controls.
- Styling pins to NativeWind v4 today; adopt NativeWind v5 when it is
  production-ready. The token source absorbs the web/native Tailwind-version gap.

### Accessibility parity

- Primary interactive targets meet the 44pt/dp floor.
- Support Dynamic Type / font scaling; no fixed tiny body text.
- VoiceOver and TalkBack labels on interactive elements; visible focus.
- No gesture-only critical action without an accessible equivalent.

### Platform readiness

- Safe-area insets respected on notched devices.
- Dark mode supported and driven by tokens.
- Deep linking / universal links configured.
- Push notifications registered and useful where the product uses them.
- Offline and poor-network states handled, not blank screens.
- Correct keyboard types for inputs.

### Store and release readiness

- App icon, splash, store metadata, and screenshots present.
- Privacy nutrition labels (Apple) and Data Safety (Google) completed.
- Every requested permission has a usage description string.
- A passing EAS production build exists before submit.

### CI, build, and OTA

- Build, submit, and update run on EAS with `eas.json` profiles development,
  preview, and production.
- CI runs through GitHub Actions with `EXPO_TOKEN`, consistent with
  `github/ci-validation-standard.md`. Package management is pnpm per
  `tooling/package-manager-standard.md`.
- OTA updates (EAS Update) carry JS and asset changes only. Native-module or
  permission changes require a store release, never an OTA push.

## Payments and IAP

Default to the portal / reader model. The app does not sell the membership
through in-app purchase. Membership is purchased and managed on the web, so no
Apple or Google commission applies to it; platform commission attaches only to
transactions that run through IAP or Play Billing.

- Keep meaningful free functionality. A login-wall-only client with no free
  utility is rejected under Apple 4.2.
- Any digital good or service sold or unlocked for in-app consumption requires
  IAP (Apple) or Play Billing (Google), unless it qualifies for an exception:
  reader apps (3.1.3(a)) or multiplatform services (3.1.3(b)). Physical goods and
  services never require IAP.
- Do not add an in-app buy button that bypasses IAP for in-app-consumed digital
  goods where IAP is required.
- Steering to web checkout is region-aware. US storefront: in-app links to web
  purchase are allowed with no entitlement and no commission (2025 Epic v. Apple
  injunction, pending appeal). EU: requires the External Purchase Link
  entitlement and may incur Apple's alternative fees under the DMA. Other
  regions: no in-app steering to web purchase. Gate steering by storefront; do
  not hardcode US link-outs into a non-US or global build.
- Google Play mirrors this: Play Billing for in-app digital goods, a parallel
  portal / reader carve-out, and a US steering allowance from the Epic v. Google
  ruling.

This area is in active litigation and varies by region. Verify against the
current App Review Guidelines and Play policies, and confirm with counsel for the
specific content type.

## Do Not

- ship a bare webview wrapper that fails Apple 4.2
- maintain a separate native color palette instead of shared tokens
- use sub-floor touch targets
- ship gesture-only critical actions with no accessible equivalent
- push native-module or permission changes over OTA
- submit without privacy disclosures or permission usage strings
- sell or unlock in-app-consumed digital goods outside IAP / Play Billing where
  required
- ship a thin login-wall client with no meaningful free functionality
- hardcode US web-checkout links into a non-US or global build

## Testing Matrix

Verify on an iOS device or simulator and an Android device or emulator:

- approach tier matches the standard, with justification on file if non-default
- tokens: brand and dark mode render from shared tokens, no hardcoded palette
- target size: primary targets meet the 44pt/dp floor
- accessibility: VoiceOver and TalkBack read interactive elements; Dynamic Type
  scales
- platform: safe areas, deep link, push (if used), and an offline state all work
- store: privacy labels and permission strings present; EAS production build
  passes
- payments: no in-app sale of the web membership; IAP present where required; any
  web-checkout steering is gated by storefront

## Pre-Ship Checklist

- approach tier sanctioned (or justified and approved)
- design tokens shared with web; brand and dark mode from tokens
- primary targets meet the 44pt/dp floor
- Dynamic Type, VoiceOver, and TalkBack supported
- safe areas, deep linking, push, and offline handled
- privacy labels and permission usage strings complete
- EAS production build green; `eas.json` profiles present
- OTA scope limited to JS/asset changes
- payments model correct: no in-app membership sale, IAP where required,
  region-aware steering

## Failure Conditions

Classify as `P0 Critical`:

- a core user flow cannot be completed in the native app
- a bare webview wrapper that fails Apple Guideline 4.2
- a thin login-wall client with no meaningful free functionality (Apple 4.2)
- a requested permission with no usage description string

Classify as `P1 High`:

- primary touch targets below the 44pt/dp floor
- no dark mode, or a hand-maintained palette instead of shared tokens
- no offline handling
- OTA used to ship a native-module or permission change
- missing store privacy disclosures
- in-app-consumed digital goods sold outside IAP / Play Billing where required
- web-checkout steering not gated by storefront (US link-outs in a global build)

## Final Standard

A native app is not a wrapped website. It shares the web token system, meets the
platform accessibility and readiness bars, and ships through EAS with disciplined
OTA. An app that does not meet these is not done.
