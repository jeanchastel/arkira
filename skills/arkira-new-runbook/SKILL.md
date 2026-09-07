---
name: arkira-new-runbook
description: "Bootstrap a brand-new project from a brief. Runs a short wizard, scaffolds with the canonical stack generator (Next.js or Vite via pnpm), applies the Arkira standards overlay, and provisions GitHub, Vercel, and (when needed) Supabase at preview scope. The greenfield counterpart to intake. Use for a new product from nothing, new project from scratch, scaffold a new app, or bootstrap a project."
origin: arkira
---

# Greenfield Project Bootstrap

Turn a project brief into a scaffolded, standardized, preview-deployed project.
The greenfield counterpart to `intake`: the same re-home-and-standardize runbook,
but the source is a brief plus an official generator, not an existing codebase.
Nothing is provisioned beyond preview scope.

## When to Use

- Starting a new product from nothing.
- "New project from scratch", "scaffold a new app", "bootstrap a project".

## When Not to Use

- Adopting an existing external codebase. Use `intake`.
- A repo that already exists locally and only needs standards. Use `/arkira-sync`.
- A native iOS/Android app. `native-scaffold` runs after a web app exists; there
  is no greenfield native path here yet.

## Hard Invariants (never violate)

1. **Preview only on first run.** No prod domain, no prod Supabase, no promotion.
2. **New private GitHub repo under the resolved org.** Never push to an unrelated remote.
3. **Always create fresh cloud resources.** Create the Vercel project with
   `vercel project add` then link by name; create Supabase with
   `supabase projects create`. Never adopt a live project; on a name collision,
   pick a new name.
4. **Secrets scanned before the first push;** rotate then rescan on any hit.
5. **Verify green before the commit and push,** not after.

## Workflow

### Step 0: Read the brief

Take the brief from the command argument (inline text or a file path). If absent,
ask for a one-paragraph brief. Parse it for product name, stack hint, features,
and any auth / database / storage signals. These become wizard defaults.

### Step 1: Wizard (one question at a time, defaults from the brief)

- Target location. Default the entity `workspace` from `entity-map.json`, else
  `~/Developer/products/<slug>`.
- Repo name / slug.
- Entity to GitHub org. Resolve the entity in
  `~/Documents/Claude/Projects/AgenticOS/config/entity-map.json`. If the brief
  names an entity not in the map, ask for the org and offer to append it.
- Stack. Default Next.js; alternative Vite SPA.
- Vercel scope / team (for a scoped, collision-safe fresh project).
- Supabase needed? (auth, database, or storage). If yes, also collect the
  Supabase organization, region, and a generated database password, so
  `supabase projects create` runs without prompts.
- Confirm pnpm per `tooling/package-manager-standard.md`.

### Step 2: Scaffold with the official generator (Arkira owns git and context)

Before invoking a generator, enforce `governance/file-management-standard.md`:

- Resolve the parent directory and reject symbolic-link components.
- The target must not exist, or must be an empty regular directory created for
  this run. Never scaffold into a non-empty directory or nested existing repo.
- Record whether this run created the target. If the generator or overlay fails,
  remove only paths created by this run; preserve every pre-existing path.
- Treat generator completion as provisional until the Arkira overlay and local
  verification succeed.

- Next.js: `pnpm create next-app@latest <dir> --ts --yes --no-agents-md --use-pnpm --disable-git`
- Vite SPA: `pnpm create vite@latest <dir> --template react-ts`, then
  `pnpm --dir <dir> install`.

`--no-agents-md` and `--disable-git` keep the generator from writing its own
`AGENTS.md`/`CLAUDE.md` or initializing git, so Arkira owns both.

### Step 3: Arkira overlay (reuse only, in order)

1. `git init` in the target.
2. Run `/arkira-sync`, review its plan, then `/arkira-sync --apply`. The sync
   registry installs the target-local standards, scripts, and canonical
   three-file root overlay:
   - `AGENTS.md` is the shared, tool-agnostic source of truth.
   - `CLAUDE.md` is a pointer-only Claude role overlay.
   - `CODEX.md` is a pointer-only Codex role overlay.
3. Apply the complete init flow non-interactively through the installed plugin,
   never through a target-relative path:

   ```bash
   printf '%s' '<complete decisions JSON>' | \
     bash "${CLAUDE_PLUGIN_ROOT}/ai-engineering/bootstrap/arkira-apply-init.sh" \
       --repo-root "<dir>" --apply
   ```

   The helper derives its own plugin root, calls the config writer, provisions
   the optional knowledge graph and enabled repo-local secret guard. A side-effect failure stops
   the run before publication.
4. Add project-specific root context outside Arkira's managed regions in the
   installed `AGENTS.md`, per `governance/intent-layer-standard.md`. Preserve the
   installed `CLAUDE.md` and `CODEX.md` pointer overlays. Do not replace the
   canonical trio with a single-file convention.
5. Tokens: run the `design-system` skill for the token set, then wire Style
   Dictionary into the app build using
   `examples/theme-reference/style-dictionary.config.mjs` as the reference config
   and adding the `style-dictionary` dev dependency.
6. Run the `intent-layer` skill to add warranted child `AGENTS.md` nodes and
   refine the user-owned root context outside the managed region. This is the
   greenfield substitute for `onboarding`, which needs existing code.

### Step 4: Provision, verify, then publish at preview scope

1. If Supabase was requested, use the `supabase-cli` skill before verification
   or publication. Create a fresh project, link it, author and push the initial
   migration, then generate `types/supabase.ts` through a temporary file and an
   atomic rename. Migration and generated types are part of the candidate that
   must pass local verification and the first commit.
2. Create a fresh Vercel project and link by exact name, but do not deploy:
   `vercel project add <fresh-name> --scope <scope>`, then
   `vercel link --yes --project <fresh-name> --scope <scope>`. Set preview-only
   env vars in Vercel and `.env.local`. Never adopt a live project.
3. Verify the complete candidate locally: `pnpm lint`, typecheck, build. Fix
   failures and rerun all three. This verification includes Supabase migration
   and generated type consumers when Supabase is enabled.
4. Only when the operator explicitly requests a secret scan, scan the working
   tree with `bash scripts/secret-scan.sh working-tree`. On any hit, rotate the
   credential, remove it from files, and rescan. Do not invoke Gitleaks
   otherwise.
5. Stage and commit the complete generated app, overlay, migration, and types;
   ensure the branch is `main`. If the operator explicitly requested the
   Gitleaks history scan, run `bash scripts/secret-scan.sh history` and stop on a
   hit. The scan is optional and is never implied by `/arkira-new`.
6. Create the private GitHub repo without pushing:
   `gh repo create <org>/<repo> --private --source=. --remote=origin`. Confirm
   `origin` is the new repo, then perform the first push:
   `git push -u origin main`.
7. Deploy once, now that code, migrations, types, and preview env exist: bare
   `vercel` for a preview URL. Env vars do not retrofit an existing deployment,
   so the single deploy is last.

### Step 5: Report and stop

Stop at preview scope. Report the local path, repo URL, preview URL, and Supabase
project ref.

## Reuse map

Every path below is delegated to, not reimplemented. `test-refs.sh` asserts each exists.

<!-- refs:start -->
- skills/design-system/SKILL.md
- skills/intent-layer/SKILL.md
- skills/supabase-cli/SKILL.md
- skills/vercel-cli/SKILL.md
- skills/native-scaffold/SKILL.md
- commands/arkira-init.md
- commands/arkira-sync.md
- ai-engineering/bootstrap/arkira-apply-init.sh
- examples/theme-reference/style-dictionary.config.mjs
<!-- refs:end -->

## Common Mistakes

- Verifying or pushing before Supabase migration and generated types exist.
- Deploying before the Supabase env exists. Env vars do not retrofit a deployment.
- Adopting a live Vercel or Supabase project instead of creating fresh.
- Running `/arkira-init` before `/arkira-sync` in a fresh repo.
- Pushing before verify and the secrets scan.
- Trying to scaffold native here. Native follows the web app via `native-scaffold`.
- Skipping the entity lookup and pushing to the wrong org.
