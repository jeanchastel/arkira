---
name: native-scaffold
description: Scaffold an Expo + React Native native app version of an existing Arkira web app, wired to the shared design tokens and EAS, per the native app standard. Use when the user wants to start an iOS/Android app for a product, "make a native app", "generate a mobile app version", or "scaffold an Expo app". Not for responsive-web work and not for auditing an existing native app.
origin: arkira
---

# Native App Scaffold

Scaffold a sanctioned native app version of an existing web product, following
`mobile/native-app-standard.md`. The default approach is Expo + React Native.

## When to Use

- The user wants to start an iOS/Android native app for an existing product.
- The user says "make a native app", "generate a mobile app version", or
  "scaffold an Expo app".

## When Not to Use

- Responsive-web mobile work; that is `mobile-compliance-standard.md`.
- Auditing an existing native app; use `native-audit`.
- A non-default approach (Capacitor, fully native, Flutter) without an approved
  justification per `AGENTS.md`. Confirm the justification first.

## Procedure

1. Confirm the source web app and target approach. Default to Expo + React
   Native. If the user wants Capacitor, confirm the 4.2 mitigation plan first.
2. Scaffold an Expo app: New Architecture, TypeScript, Expo Router, pnpm per
   `tooling/package-manager-standard.md`.
3. Add styling: NativeWind (v4 today) and react-native-reusables.
4. Wire tokens: point styling at the shared Style Dictionary React Native token
   output so brand and dark mode match web. Do not hand-maintain a native
   palette. See `theme/theme-standard.md`.
5. Stub the app-like surface required by Apple 4.2: native navigation, push
   registration, an offline shell, and deep linking / universal links.
6. Set the payments model: default to portal / reader, no in-app sale of the
   membership (bought and managed on the web). Add IAP / Play Billing only if a
   digital good is sold or unlocked for in-app consumption and required. Gate any
   web-checkout steering by storefront. See the Payments and IAP section of
   `mobile/native-app-standard.md`.
7. Configure EAS: `eas.json` with development, preview, and production profiles;
   GitHub Actions submit via `EXPO_TOKEN` per `github/ci-validation-standard.md`.
8. Emit the pre-ship checklist from `mobile/native-app-standard.md` for the team
   to complete before submit.

## Notes

- This skill scaffolds in the product repo, not in the standards repo.
- Token-pipeline details live in `theme/theme-standard.md`; store and release
  details live in `mobile/native-app-standard.md`. This skill references both
  rather than restating them.
- OTA updates carry JS/asset changes only.
