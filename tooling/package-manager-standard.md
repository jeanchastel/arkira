# Package Manager: pnpm Standard

Status: canonical. Synced to product repos via `/arkira-sync`.

## Rule

pnpm is the only supported JavaScript package manager for new Arkira-guided work.
A repository that already declares npm or Yarn keeps its declared manager and version;
the harness uses that declaration rather than mixing managers. Migration is a separate
approved change. Bun is not supported. When a repository migrates to pnpm, follow the
Migration section below.

## Rationale

- **Disk efficiency.** pnpm stores every package version once in a global
  content-addressable store and hard-links it into each project. Across a
  multi-repo portfolio this cuts disk use and install time sharply.
- **Strict resolution.** pnpm's symlinked, non-flat `node_modules` exposes only
  declared dependencies. This blocks the phantom-dependency bugs that npm's
  flat layout hides until a transitive package is removed.
- **Workspace support.** pnpm workspaces handle multi-package repos natively,
  with no extra tooling, which fits the Arkira monorepo-friendly layout.

## Command Equivalents

| Operation | pnpm | npm (fallback) |
|---|---|---|
| Install all deps | `pnpm install` | `npm install` |
| Clean CI install | `pnpm install --frozen-lockfile` | `npm ci` |
| Add a dependency | `pnpm add <pkg>` | `npm install <pkg>` |
| Add a dev dependency | `pnpm add -D <pkg>` | `npm install -D <pkg>` |
| Add a global tool | `pnpm add -g <pkg>` | `npm i -g <pkg>` |
| Run a script | `pnpm <script>` or `pnpm run <script>` | `npm run <script>` |
| Run a one-off binary | `pnpm dlx <pkg>` | `npx <pkg>` |
| Remove a dependency | `pnpm remove <pkg>` | `npm uninstall <pkg>` |

The lockfile is `pnpm-lock.yaml`. A repo on pnpm must not also commit
`package-lock.json` or `yarn.lock`.

## Migration

From npm:

1. Run `pnpm import` first. It reads the existing `package-lock.json` and
   generates `pnpm-lock.yaml`, preserving the resolved tree. Do this before
   deleting anything.
2. Delete `package-lock.json` and `node_modules`.
3. Run `pnpm install` to rebuild `node_modules` from `pnpm-lock.yaml`.
4. Replace `npm run` and `npx` invocations in scripts, docs, and CI with their
   pnpm equivalents.
5. Fix any phantom-dependency errors pnpm's strict layout surfaces by adding
   the missing packages to `package.json`. These are real bugs npm was hiding.
6. Commit `pnpm-lock.yaml` and the `package-lock.json` deletion in one commit.

From yarn:

1. Run `pnpm import` first. It reads the existing `yarn.lock` and generates
   `pnpm-lock.yaml`. Do this before deleting anything.
2. Delete `yarn.lock` and `node_modules`.
3. Run `pnpm install` to rebuild `node_modules` from `pnpm-lock.yaml`.
4. Replace `yarn <script>` with `pnpm <script>` and `yarn add` with `pnpm add`.
5. Migrate any Yarn-specific config (`.yarnrc`, resolutions) to the pnpm
   equivalents (`.npmrc`, `pnpm.overrides` in `package.json`).
6. Commit `pnpm-lock.yaml` and the `yarn.lock` deletion in one commit.

A lockfile swap is a package-file change. Under the feature-pass workflow it
requires explicit approval before it lands.

## Agent Behavior

Agents operating inside an Arkira product repo must:

1. Emit pnpm commands for new JavaScript work in generated code, scripts, and instructions.
2. Read the repository's declared manager and version before recommending commands. If the
   repository already declares npm or Yarn, follow that declaration and propose migration per
   the Migration section rather than mixing managers.
3. Never create a second lockfile in a repo that already has one.
4. Nothing installs or upgrades pnpm globally. Treat the absence of `pnpm` on `PATH` as a setup
   error in a pnpm repo, not a reason to fall back to npm. Resolve the pinned manager through the
   shared resolver:
   an exact-matching standalone manager on `PATH`, then Corepack where available, then
   fail closed with actionable guidance. The resolver selects and validates only. It
   does not install anything.
5. Repositories without `package.json` and non-JavaScript repositories are exempt from
   JavaScript package-manager commands.

## Toolchain resolution

`packageManager` must name an exact version with no range operator. Corepack is
deprecated and absent from Node 25 and newer, so it is a fallback for Node 24 and
earlier only. CI pins the active Node LTS major, currently Krypton.

Any migration past Node 24 must add its package-manager bootstrap mechanism in the
same change that moves the Node major. A bootstrap branch added in advance cannot be
exercised, and an unexercised branch on the release path is worse than no branch.

The shared resolver is sourced by both the installer and release gate. It selects and
validates only, with no installation. `hooks/cli-freshness-check.sh` tracks `node` and
`pnpm` report-only behind the `cli_version_freshness` switch. It does not track
Playwright. Dependabot, introduced by this pass, monitors `github-actions` at `/` and
`npm` at `/examples/auth-reference`; no automation edits a pin in place.

## Related

- `vercel/cli-first-standard.md`
- `supabase/cli-first-standard.md`
- `github/ci-validation-standard.md`
- The `cli_version_freshness` switch already tracks `pnpm` as a first-party CLI.
