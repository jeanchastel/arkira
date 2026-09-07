# Vendored Components

This plugin vendors a curated subset of tools from the `ecc`
(everything-claude-code) plugin. Items were selected by reviewing every
stack-relevant candidate; see `docs/specs/2026-05-18-arkira-standards-plugin.md`
for the selection rationale.

## Source

- Plugin: `ecc` version `2.0.0-rc.1`
- Repository: `affaan-m/everything-claude-code`
- Commit: `0071fa5c3c389d2b4b235a39402c891e146cdef3` (reviewed 2026-07-20; previously `aae735d458dd`)
- License: MIT

**These are maintained forks, not verbatim copies.** Each item below was seeded from
ecc and then hardened for the Arkira surface (artifact-flow `reads:`/`writes:`
frontmatter, agent Prompt Defense Baselines, removal of unpinned external execution
and third-party data sharing). Refreshing is a three-way merge, never an overwrite.
Upstream review 2026-07-20 against `0071fa5c`: no substantive changes to the live
items (frontmatter-format and reflow only); `click-audit`, `adr`, and `onboarding`
were removed upstream and remain here as last-known-good forks.

## External Tool Pins

| Tool | Version | Source | License | Notes |
| ---- | ------- | ------ | ------- | ----- |
| `gitleaks` | `8.30.1` | `gitleaks/gitleaks` release `v8.30.1` | MIT | Local binary used only through the explicit `secret-scan.sh` wrapper. No hosted API, token, persistent hook, CI job, or automatic invocation. |

## Skills

| Skill | Reason vendored |
| ----- | --------------- |
| `production-audit` | Local-evidence production readiness audit; matches the repo audit workflow. |
| `click-audit` | Traces UI handlers through state stores to find state-cancellation bugs. |
| `adr` | Captures ADRs in a standard Nygard format. |
| `design-system` | Audits visual consistency and detects AI-generated design patterns. |
| `onboarding` | Generates a structured onboarding guide and starter CLAUDE.md. |
| `seo` | Canonical SEO workflow; dependency of the `seo-specialist` agent. |

## Vercel Skills

Source: `vercel-labs/agent-skills`, commit `f8a72b9603728bb92a217a879b7e62e43ad76c81`.
Vercel is a first-party publisher under the Trusted Sources criterion in
`tooling/third-party-skills-standard.md`. All three are MIT per their SKILL.md
frontmatter. Markdown + JSON only; no hooks or executable scripts. Content
reviewed on 2026-07-20.

| Skill | Upstream path | License | Reviewed |
| ----- | ------------- | ------- | -------- |
| `react-best-practices` | `skills/react-best-practices` | MIT | 2026-07-20 |
| `composition-patterns` | `skills/composition-patterns` | MIT | 2026-07-20 |
| `react-view-transitions` | `skills/react-view-transitions` | MIT | 2026-07-20 |

## Agents

| Agent | Reason vendored |
| ----- | --------------- |
| `silent-failure-hunter` | Read-only review for swallowed errors and bad fallbacks. |
| `type-design-analyzer` | Read-only review of type design and invariant enforcement. |
| `seo-specialist` | Technical SEO audits; uses the `seo` skill. |

## Third-party Plugins

Decision: P2. Record third-party plugin pins separately from external tool pins
so the adopted skill surface has its own review trail.

| Field | Value |
| ----- | ----- |
| name | ponytail |
| author | Dietrich Gebert |
| repository | github.com/DietrichGebert/ponytail |
| version | 4.8.4 |
| tag | v4.8.4 |
| commit | 16f29800fd2681bdf24f3eb4ccffe38be3baec6b |
| license | MIT |
| note | hooks/claude-codex-hooks.json reviewed line by line on 2026-06-25 (adoption). Refreshed to 16f2980 on 2026-07-20: full diff since 025da371 reviewed. Hook JSON change benign (dropped `; exit 0` so hook exit codes propagate; added Windows PowerShell variants). Hook scripts +226/-23 are defensive-only (stdin-EOF guard, BOM strip, config merge, subagent agent-type scoping); scan found no child_process/exec/spawn/network/eval/Function/secret-env access; fs writes local config/state only. No new attack surface. |

## Updating

The ecc items are maintained forks, not verbatim copies (see Source). To refresh:
review the upstream diff for the specific vendored paths, three-way merge any
substantive upstream change into the fork while preserving the Arkira hardening,
then bump the commit and `reviewed` date. If upstream has no substantive change,
bump only the pin and `reviewed` date to record the review. Never overwrite a fork
wholesale. The `vendored-freshness` pipeline flags drift but never auto-merges.
