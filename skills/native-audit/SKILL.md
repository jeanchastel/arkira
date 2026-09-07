---
name: native-audit
description: "Local-evidence audit of an Arkira native iOS/Android app against the native app standard. Use when the user asks whether a native app is ready to ship, \"audit this Expo app\", \"is the mobile app store-ready\", or wants a pre-submit risk pass. Maintainer-safe: no external upload. Not for responsive-web audits and not for scaffolding."
origin: arkira
---

# Native App Audit

Score an existing native app against `mobile/native-app-standard.md` from local
and user-authorized evidence. Maintainer-safe: do not upload repo contents to
external services or run unpinned remote code.

## When to Use

- The user asks "is the native app ready to ship", "audit this Expo app", or
  "is the mobile app store-ready".
- A native app is approaching TestFlight, Play, or a store submission.

## When Not to Use

- Responsive-web readiness; use the `production-audit` skill with the
  `mobile-compliance-standard.md` checklist.
- Scaffolding a new native app; use `native-scaffold`.
- Formal legal or regulatory certification.

## Checklist

Grade each finding P0/P1/P2/P3 per the repo severity classes.

- **Approach.** Sanctioned tier (Expo + RN default). Capacitor only with 4.2
  mitigations. Non-default only with an approved justification.
- **Tokens.** Brand and dark mode render from shared tokens; no hand-maintained
  native palette; `--target-min` respected.
- **Accessibility.** 44pt/dp targets; Dynamic Type; VoiceOver and TalkBack
  labels; visible focus; accessible equivalents for gestures.
- **Platform.** Safe areas, deep linking, push (if used), offline handling,
  correct keyboard types.
- **Store and privacy.** Icon and splash, metadata and screenshots, privacy
  labels / Data Safety, permission usage strings.
- **Payments.** Portal / reader model with no in-app sale of the web membership;
  IAP / Play Billing present where a digital good is consumed in-app and required;
  meaningful free functionality (no thin login-wall client); web-checkout steering
  gated by storefront.
- **CI, build, OTA.** EAS profiles present, CI via `EXPO_TOKEN`, pnpm, a green
  production build, OTA limited to JS/asset changes.

## Output

A severity-graded findings list (P0/P1/P2/P3), each with the evidence and the
exact requirement from `native-app-standard.md` it fails, and a go / no-go
recommendation for submission.
