# Sync Standard

The `/arkira-sync` command runs a merge-aware sync of the Arkira
engineering-standards files in a target repo. This standard describes the
two-tier classifier, the sentinel and registry contract, and the drift-resolution
policy that downstream agents must follow.

## Immutable harness source

### Public distribution candidate

The unreleased reference-mode implementation targets the generated public repository
`jeanchastel/arkira`. It does not change the installed-channel default or migrate consumers
automatically. Rollout requires the approved central-distribution plan and a verified pilot.

`harness.channel: stable` with `repository: jeanchastel/arkira` opts into the
protected public stable tag. Resolution verifies the exact exported payload,
then uses the existing immutable harness store. New sessions adopt stable,
including major releases with a one-time notice. Existing release sessions and
active goals remain bound. Local offline work requires a verified cache.
Publication requires online verification.

Legacy sync check/apply detects public-reference selection and returns a read-only
central-reference notice. It never reinstalls copied controls for these consumers.

Public product CI calls `jeanchastel/arkira/.github/workflows/validate.yml@stable`.
This exact first-party reference is the sole floating exception in action-pin validation.
All third-party references remain SHA-pinned. The reusable workflow checks out its own
`job.workflow_sha` separately from the product and retains mandatory product validation.
Consumer configuration does not select a public commit. Stable is the only
public control channel.

`arkira migrate <repo>` previews owned changes without writing. `--apply` first requires
an online verified public release, then applies the complete plan through the shared
contained filesystem primitives. Dirty trees, ownership drift, unsafe paths, and retained
callers of retired controls abort migration. Recovery receipts remain private outside the
consumer; `arkira rollback-migration <repo> <receipt>` refuses intervening target edits.
`arkira migrate <repo>` and `arkira migrate <repo> --apply` select stable and
the stable reusable CI reference together.

Native SessionStart only prints the central context command. It does not fetch, install,
or write state. Native session IDs map to deterministic release session IDs; delegated
commands retain their inherited binding.

Public publication accepts only source commits contained in accepted source main. It
exports listed committed blobs, excludes explicitly marked private regions, verifies
publisher rulesets, publishes immutable version tags and release pages, then advances
stable with an exact lease. Stable rollback re-verifies accepted source provenance.
The authoring publisher is not part of the public payload. See
`ai-engineering/distribution/publishing.md` in the source repository.

P1. The implementation is not rollout authorization. Independent review, source release
acceptance, protected public publication, and a verified RiderVision pilot remain required.
Other consumers stay vendored until separately approved.

### Installed distribution

Ordinary runtime commands capture the installed harness into a private,
content-addressed snapshot and verify its manifest before use. Resolution uses
the active goal binding first, then an explicit verified rollback pin, then a
fresh installed-root capture. A legacy repository binding is only a fallback
when no installed source is available. A running goal keeps one exact harness
when the installed plugin changes. New runs adopt the installed release without
per-repository sync. Installation/update remains a native platform operation;
this does not promise background plugin upgrades.

`harness.channel: installed` is the default. For rollback, set
`harness.channel: pinned` with the exact `harness.pin` and
`harness.digest` of a previously verified installed snapshot.
The legacy pin without `channel: pinned` records provenance, not an indefinite
update freeze. Active goals retain their original snapshot until they end.

Pinned sync captures the current installed root once, verifies the private
snapshot, and reads every pinned canonical input from that immutable source. A
successful apply binds the target repository to the same digest in the sync transaction.
Standards checks remain read-only against the current installed root. When a
product goal is active, perform a requested mid-flight sync from a separate
clean worktree. The active goal continues on its bound snapshot until it ends.

## Tiers

Every file the bootstrap installs is classified at design time as one of two
tiers:

- **Tier A: managed-region shared context.** Users edit around the canonical content.
  Arkira sections are wrapped in `<!-- ARKIRA:MANAGED START id=… v=… sha=… -->`
  and `<!-- ARKIRA:MANAGED END id=… -->` sentinels.
  - File: `AGENTS.md`.
  - Sync rewrites **only** inside sentinels. Content outside is sacred and is
    never touched.
- **Provider overlays.** Sync iterates configured adapters' `context_file` values. Every context
  filename other than `AGENTS.md` receives a generated pointer to the universal authority, with
  display text derived from the adapter's `display_name`. During
  migration, it removes known pristine legacy harness blocks and moves every
  genuine outside, drifted, or unknown fragment into the user-owned area of
  `AGENTS.md` before canonicalizing the overlay.
- **Tier B: pristine files.** Arkira fully owns these. Local edits are
  unsupported but happen in practice, so sync uses a per-file baseline SHA
  registry to detect drift before overwriting.
  - Files: `workflows/*.md`, `scripts/*.sh`, `scripts/test-suites.tsv`,
    `ai-engineering/runtime/*`, `ai-engineering/adapters/*`,
    `.github/workflows/*.yml`,
    `.github/ISSUE_TEMPLATE/*.md`,
    `.arkira/standards/supabase-cli-first.md`,
    `.arkira/standards/vercel-cli-first.md`,
    `.arkira/standards/test-suite-standard.md`,
    `.arkira/standards/static-web-standard.md`.

## Profile gating

Some Tier B targets only apply to certain repo profiles, so sync routes
per-profile. The profile is read from the target repo's
`.arkira/config.json` (`.profile`, default `app`).

| Target                                                | Profiles      |
|-------------------------------------------------------|---------------|
| `.arkira/standards/supabase-cli-first.md`             | `app`         |
| `.arkira/standards/vercel-cli-first.md`               | `app`         |
| `.arkira/standards/test-suite-standard.md`            | `app`         |
| `.arkira/standards/react-data-fetching.md`            | `app`         |
| `.arkira/standards/react-bundle-rendering.md`         | `app`         |
| `.arkira/standards/react-composition.md`              | `app`         |
| `.arkira/standards/react-motion.md`                   | `app`         |
| `.arkira/standards/static-web-standard.md`            | `static-web`  |
| Everything else under Tier B (workflows, scripts, CI) | all profiles  |
| Tier A `AGENTS.md` and generated provider overlays   | all profiles  |

Static-web brochure-site repos do not pick up Supabase or Vercel CLI
standards. App repos do not pick up the static-web standard. The gate
lives in the `checks=()` arrays in
`ai-engineering/bootstrap/check-ai-engineering-standards.sh` and
`update-ai-engineering-standards.sh`. Each entry's third pipe field is
`*` (any profile) or a comma-separated profile list.

## Product release inventory

The standards repo's `scripts/test-suites.tsv` is the harness's internal test
inventory and is never copied into product repos. Product sync instead maps
`ai-engineering/gates/product-test-suites.tsv` to the product repo's
`scripts/test-suites.tsv`. That inventory has one required entry which calls
`scripts/run-product-release-gate.sh`.

The product release gate does not install dependencies. The workflow resolves
one trusted base commit from the pull request base or the pre-push main commit
and passes it as `ARKIRA_TRUSTED_BASE_SHA` to both release helpers. Repository
class comes only from that base's profile and package tree. Candidate changes
cannot reclassify a package, static-web, or non-package repository.

The helpers follow this closed contract:

1. Every package repo has a committed regular `package.json`, exactly one
   committed supported lockfile, an exact matching `packageManager` name and
   version pin, and non-empty `lint`, `typecheck`, `test`, and `build` scripts.
2. The installer always performs the lockfile-specific immutable install. The
   release gate always runs all four package scripts in order.
3. A committed regular `scripts/project-release-gate.sh` adds product-specific
   checks after the four package checks. It never replaces dependency setup or
   the mandatory package checks.
4. Static-web and non-package repos must provide the explicit project gate.
   Static-web repos that also have a package manifest satisfy both contracts.

An absent or ambiguous required gate exits `77`. The canonical runner records
that as a development skip and as a blocker for a required release suite.
The synced `validate` CI job installs dependencies separately through
`scripts/install-product-dependencies.sh`. That installer accepts only a
committed regular `package.json` and exactly one committed regular npm, pnpm,
or Yarn lockfile. npm must match the installed version. pnpm and Yarn run
through Corepack and must resolve to the exact `packageManager` version. There
is no lockfile or package-manager fallback. The CI job then invokes the same
canonical product inventory with `scripts/run-all-tests.sh --mode release`.
The `validate` workflow runs on pull requests to `main` only. Release mode
captures the clean candidate before any suite and fails if HEAD or the worktree
changes during a suite.

Only one unfiltered canonical gate may own a repository at a time. Every suite
runs in a separate process group so a gate termination or suite timeout stops
the complete descendant tree. The per-suite timeout defaults to 900 seconds and
may be changed with a positive integer `ARKIRA_SUITE_TIMEOUT_SECONDS` value.
Filtered development runs do not take the repository-wide full-gate lock.

## Legacy hook retirement

Sync owns removal of the exact repo-local `ggshield` commands previously
installed by Arkira and the retired managed dash-guard block. Read-only sync
reports affected pre-commit and pre-push hooks. Apply removes only these complete lines:

```sh
ggshield secret scan pre-commit "$@"
ggshield secret scan pre-push "$@"
```

It also removes only a complete `pre-commit` block beginning with
`# >>> arkira dash-guard >>>` and ending with `# <<< arkira dash-guard <<<`.
An incomplete block remains untouched.

The migration resolves the repository's common Git directory, which holds the
default hooks Git executes for the main work tree and for every linked
worktree. It never follows `core.hooksPath` into a configured global or
external hook location. Its lock also lives in the common Git directory, so
concurrent syncs from different linked worktrees serialize against one
another. It preserves all other bytes and file modes, including user hooks.
Both hooks publish as one contained transaction.
Symlinks, non-regular files, concurrent changes, or partial publication fail
closed and retain the original hooks. Affected hooks are reported by their
path inside the Git directory, such as `hooks/pre-commit`.

## Sentinel format (Tier A)

```markdown
<!-- ARKIRA:MANAGED START id=role-and-purpose v=2 sha=abc123… -->
canonical content
<!-- ARKIRA:MANAGED END id=role-and-purpose -->
```

- `id`: stable block name, chosen at design time, never renamed.
- `v`: canonical block version, bumped by the maintainer when canonical content
  changes.
- `sha`: SHA-256 of the body text between the markers (trimmed of leading and
  trailing blank lines). Drift detection: sync recomputes the body SHA in the
  target and compares to the `sha` attribute. Match = clean (safe to replace).
  Mismatch = drifted (prompt the user).

In `AGENTS.md`, a target block with an `id` unknown to the canonical source is
**left alone** for forward compatibility. A canonical block missing from the
target is **inserted at end of file** with a log entry. In a role overlay, an
unknown block is migrated to `AGENTS.md`; overlays never retain a second manual.

## Registry (Tier B)

The baseline registry lives at `.arkira/sync-state.json` in the target repo,
schema `1`. Only `--apply` writes the registry. A read-only check never
writes.

```json
{
  "schema": "1",
  "plugin_version": "0.25.0",
  "files": {
    "workflows/design-pass.md": {
      "tier": "pristine",
      "baseline_sha": "abc1…"
    },
    "CLAUDE.md": {
      "tier": "managed",
      "blocks": {
        "tool-role-pointer": { "v": "1", "sha": "def2…" }
      }
    }
  }
}
```

The registry is a managed output of `--apply`. When the run writes it, the run's transformer receipt
records it. The candidate gate reserves exactly `.arkira/sync-state.json` outside `SYNC_CHECKS`.
It reserves no other `.arkira/*` path.

Products may own an optional `.arkira/risk-paths.json` routing manifest. Sync never creates,
updates, deletes, or registers this file. A product may add Elevated globs under the central schema.
It cannot weaken central routing defaults. The synced evaluator reads both the trusted-base and
candidate manifests. Removing a rule cannot lower the candidate that removes it.

Key separator is ASCII Unit Separator (`\x1f`), not `.`. File paths can
contain dots and slashes, so a dot-path scheme would alias `files.AGENTS.md`
into `files["AGENTS"]["md"]`. Callers that build keys use the `SYNC_KSEP`
constant exported by `ai-engineering/bootstrap/lib/sync-lib.sh`.

## Drift classes

| target == baseline? | canonical == baseline? | Class | Default action |
|---|---|---|---|
| yes | yes | `clean` | none |
| yes | no | `update-clean` | auto-update, refresh baseline |
| no | yes | `local-drift` | skip; warn; require `--force-pristine` |
| no | no | `conflict` | skip; show diff; require `--force-pristine` |

A target file with no baseline entry is treated as `local-drift` if it differs
from canonical, or migrated to `clean` (and a baseline written) if it matches.

## Apply prompts

- Drifted `AGENTS.md` block: `keep | replace | abort`: `keep` preserves the local
  content and sentinel byte-for-byte. The block remains drifted, so every future
  apply prompts again. `replace` overwrites with canonical. `abort` exits with
  no further writes.
- Tier B drifted file (only with `--force-pristine`): `replace | abort`.
- `--yes` auto-answers `replace` to every prompt. Document this in CI/CD usage:
  it WILL overwrite local edits without review.

## Promises

- Outside-sentinel content in `AGENTS.md` is never changed by ordinary managed
  block updates. Pointer-overlay migration reads noncanonical fragments only to
  preserve them in that user-owned `AGENTS.md` area before replacing the legacy
  manual.
- Sync never commits, pushes, or merges. `/arkira-sync --apply` does enable and read back the
  repository's GitHub auto-merge setting through the canonical branch-protection helper. Missing
  GitHub access or a failed read-back is a clear blocked state. It never publishes a candidate.
- Sync never invokes a CLI installer. CLI version freshness is report-only and
  is not registered on SessionStart.
- Product repository sessions never install, update, remove, enable, disable,
  or re-register Claude plugins. User-global plugin state is owned by the
  canonical standards release workflow or by an operator outside a repository.
- Sync never introduces a runtime dependency on `jq`. JSON and sentinel
  parsing use `node` exclusively, matching the rest of the plugin family.
- When the sync target is the standards repo itself (`target_repo ==
  standards_repo`), the repo-root context and provider overlays are skipped. Those files are the
  standards repo's own local-only
  root context, not sync targets. The synced product-repo root context is
  `ai-engineering/root/*`. The skip lives in the sync routines.

## Lint

CI runs `ai-engineering/bootstrap/lint-canonical-sentinels.sh` to enforce on
the canonical sources (`ai-engineering/root/*.md`):

- every START has a matching END,
- every `id` is unique within a file,
- every `sha=` matches the SHA-256 of the body,
- `v=` is a positive integer.

A canonical-source block-ID collision is a maintainer bug, not a target-repo
bug.

## See also

- Spec: `docs/specs/2026-05-23-arkira-sync-merge.md`
- Plan: `docs/plans/2026-05-23-arkira-sync-merge.md`
- Library: `ai-engineering/bootstrap/lib/sync-lib.sh`
- Command: `commands/arkira-sync.md`
