---
name: intake-runbook
description: Take a client's externally-hosted project (Lovable export, a repo on another GitHub/GitLab, a dev project) and re-home it onto your own GitHub + Vercel, then run full onboarding and apply Arkira standards, without ever touching the live deployment, source remote, or production data. Use when adopting a new client codebase, migrating a project off Lovable / another platform, or taking over an existing repo for ongoing work.
origin: Arkira Labs
---

# Client Intake

Adopt an externally-hosted client project into your own infrastructure: pull the
code local, re-home it to a fresh GitHub repo and a fresh Vercel project, run
the `onboarding` skill, and apply Arkira standards. The live deployment, the
source remote, and production data are never touched.

## When to Use

- Client hands you a project hosted on Lovable, another GitHub/GitLab org, or a
  zip export, and you need to own it going forward.
- Migrating a project off one platform onto your GitHub + Vercel.
- Taking over an existing dev repo for continued work under Arkira standards.

Not for: a repo already in your org that just needs standards. Use
`arkira-sync` directly. Not for: contributing a PR back to a repo that stays on
the client's infra. Use a normal branch + PR instead.

## Hard Invariants (never violate)

These define "don't touch live." Violating any one means the intake failed.

1. **Source remote is read-only.** Clone or export only. Never push back to the
   source remote. Rename it `upstream-archive` or remove it before the first
   push.
2. **New GitHub repo under the correct org.** Resolve the client in
   `entity-map.json` and use that `github_org`. The new repo becomes `origin`.
3. **New Vercel project, preview only.** Never link to the live project. No
   custom/prod domain on first deploy. The live deploy keeps running, untouched.
4. **Never reuse live data stores.** Stand up your own Supabase (or DB) project;
   migrate schema, swap env. The live database is never linked or written.
5. **Rotate any real secret** found committed or in `.env*` before the first
   push to your origin.
6. **Verify green** (lint / typecheck / test) before pushing.

## Workflow

### Step 0: Resolve the entity

Read `~/Documents/Claude/Projects/AgenticOS/config/entity-map.json`. Find the
client → `type` (client), `github_org`, `workspace`, `drive_root`,
`parent_entity`. The `github_org` is mandatory for Step 3; the `workspace`
decides the clone destination. Repo names in the map may not match on-disk dir
names. Match flexibly. If the client is not in the map, ask the operator for
the target org before proceeding.

Destination parent: the entity `workspace` if set, else
`~/Developer/products`. Resolve it physically before choosing a target.

### Step 1: Get the code local

Apply `governance/file-management-standard.md` before any clone, unzip, or copy:

1. Resolve the destination parent with physical, no-follow semantics. Reject a
   symbolic-link parent or a target outside that resolved parent.
2. Derive one strict repository slug. The target is exactly one child of the
   resolved parent. Reject absolute paths, separators, `.` and `..` segments,
   control characters, and nested existing repositories.
3. The target must not exist. Do not reuse an existing directory, even if it
   appears empty. Use the executable target binder below to create it and its
   private run-state file. The helper records the physical parent and target
   paths plus both device/inode identities. Target creation runs from the
   already-bound parent directory. State publication runs from an independently
   bound, identity-checked private state parent, and that binding remains live
   through creation commit or rollback. It refuses nested repositories,
   symlinked or replaced parents, existing targets, and non-private or replaced
   state.
4. A failed clone, unzip, copy, or validation is terminal. Do not `cd` into the
   target, initialize Git, or run cleanup commands after failure. Report the
   run-created path for explicit cleanup; never infer that a pre-existing path
   is safe to remove.

Create the target through the installed helper. Keep run state outside the
target so a failed acquisition cannot replace it:

```bash
intake_target="${CLAUDE_PLUGIN_ROOT}/skills/intake-runbook/scripts/intake-target.js"
intake_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/arkira-intake.XXXXXX")"
chmod 700 "$intake_run_dir"
intake_state="$intake_run_dir/target.json"
target_physical="$(node "$intake_target" create \
  --parent "$destination_parent_physical" --slug "$repo_slug" \
  --state "$intake_state")"
```

Run every Git, verification, secret-scan, GitHub, and deployment command through
`intake-target.js run`. The helper changes into the proven directory inode
before spawning the command, revalidates the named parent and target after it
exits, and sets `ARKIRA_INTAKE_TARGET=.`. A path exchange after validation
therefore cannot redirect the command. Failed creation removes state and the
target only after same-parent claims prove the exact run-created inodes; state
rollback uses the state-parent binding retained before publication, even if its
pathname is replaced. Never split the helper's check from the consequential
command and never rely on the agent's current working directory.

Pick the source track only after that preflight:

**Lovable**: Lovable syncs to a GitHub repo via its GitHub app, or exports a
zip.
- If GitHub-connected, clone into the already proven empty target with
  `node "$intake_target" run --state "$intake_state" --before empty --after git
  -- git clone --no-hardlinks <source-url> .`. Continue only when the
  command succeeds, the target is a valid worktree, and `origin` exactly matches
  the requested source URL.
- For an export, validate the archive inventory before extraction. Reject
  absolute paths, `..` traversal, device files, and absolute or escaping
  symlinks. Extract only into the proven target. If the export contains one
  wrapper directory, move its children through a contained, no-clobber step.

**Existing git (another org / GitLab / dev project)**: clone it:

```bash
node "$intake_target" run --state "$intake_state" --before empty --after git -- \
  git clone --no-hardlinks <source-url> .
node "$intake_target" run --state "$intake_state" --kind git -- \
  git rev-parse --is-inside-work-tree
node "$intake_target" run --state "$intake_state" --kind git -- \
  git remote get-url origin
```

Any non-zero result or remote mismatch stops intake. Never fall through into an
existing destination after a failed clone.

### Step 2: Sever the source remote, set history strategy

For a cloned source, sever its push path before any other Git operation:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- \
  git remote rename origin upstream-archive
node "$intake_target" run --state "$intake_state" --kind git -- \
  git remote set-url --push upstream-archive no_push://source-remote-disabled
node "$intake_target" run --state "$intake_state" --kind git -- git remote -v
```

Confirm `git remote -v` shows the unsupported `no_push` URL for
`upstream-archive`.
History strategy is then per-source:

- **Lovable → squash.** Lovable produces noisy auto-commits; drop them.
  ```bash
  node "$intake_target" run --state "$intake_state" --kind git -- \
    git checkout --orphan arkira-import
  node "$intake_target" run --state "$intake_state" --kind git -- \
    git rm --cached -r .
  ```
  Leave the orphan branch uncommitted. The first root commit is created only
  after onboarding, generated data artifacts, verification, and the working-tree
  secret scan. A raw import commit is never publishable. This preserves Git
  metadata without deleting or replacing `.git`.
  Never run `rm -rf .git` during intake.
- **Existing dev git → preserve history.** Keep the source for reference,
  with the disabled push URL above. Do not rewrite history unless a secret scan
  requires explicit credential removal.
- **Archive with no Git metadata.** Run `git init`, create `main`, then commit
  only after onboarding, generated artifacts, verification, and the working-tree
  scan below. Initialize only through the identity gate, then immediately switch
  the gate to its `git` mode:
  ```bash
  node "$intake_target" run --state "$intake_state" --before empty --after git -- \
    git init
  node "$intake_target" run --state "$intake_state" --kind git -- \
    git branch -M main
  ```

### Step 3: Onboard and apply Arkira before publication

Run, in order:

1. `onboarding` skill: recon, architecture map, and conventions. Hold its durable
   project context for the user-owned area of `AGENTS.md`; do not let it replace
   Arkira's root overlays with a single context file.
2. `/arkira-init`, or `/arkira-init-web` for a static brochure site.
3. `/arkira-sync`, review, then `/arkira-sync --apply`. This installs the
   canonical root trio: shared source of truth `AGENTS.md`, pointer-only Claude
   overlay `CLAUDE.md`, and pointer-only Codex overlay `CODEX.md`.
4. Put the onboarding context outside managed regions in `AGENTS.md`, then run
   the `intent-layer` skill for warranted child `AGENTS.md` nodes. Preserve both
   pointer overlays.

No remote publication occurs in this step.

### Step 4: Replace live dependencies and prepare preview

If the source uses Supabase or another managed store, create a fresh project now
with the relevant CLI skill. Build the schema as migrations, apply it only to
the fresh project, generate local types through an atomic temporary-file rename,
and replace live URLs/keys with preview-only values. Migration and generated
types must exist before verification and the first push.

Create a new Vercel project by exact new name, link it, and set preview env vars.
Do not run `vercel` yet. Never select or link the source's live project.

### Step 5: Verify and optionally scan before creating origin

Run the project's lint, typecheck, test, and build commands as applicable. Every
runner is target-pinned. For a pnpm project, the pattern is:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- pnpm --dir . lint
node "$intake_target" run --state "$intake_state" --kind git -- pnpm --dir . typecheck
node "$intake_target" run --state "$intake_state" --kind git -- pnpm --dir . test
node "$intake_target" run --state "$intake_state" --kind git -- pnpm --dir . build
```

Use the equivalent explicit working-directory option for another package
manager. Fix failures and rerun the complete relevant set. Verification includes
generated database artifacts and must be green before commit or push.

Only when the operator explicitly requests a secret scan, run the working-tree
scan through the local wrapper:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- \
  bash scripts/secret-scan.sh working-tree
```

Rotate every real credential on a working-tree hit, remove it from files, then
rerun verification and the path scan. A missing scanner, finding, or scan error
blocks publication only when this scan was requested. Do not invoke Gitleaks
otherwise.

After verification and any explicitly requested path scan pass, commit the
complete onboarded candidate. This is the first commit on the Lovable and
archive tracks. It is a new onboarding commit on the preserve-history track:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- git add -A
node "$intake_target" run --state "$intake_state" --kind git -- git diff --cached --check
node "$intake_target" run --state "$intake_state" --kind git -- \
  git commit -m "Onboard project under Arkira standards"
node "$intake_target" run --state "$intake_state" --kind git -- git branch -M main
node "$intake_target" run --state "$intake_state" --kind git -- git status --porcelain
node "$intake_target" run --state "$intake_state" --kind git -- \
  git show --stat --oneline HEAD
```

`HEAD` must contain the imported application, canonical three-file overlay,
warranted child context, fresh migrations, generated types, and preview config.
The worktree must be clean. Never create or push a raw import commit.

If the operator explicitly requested the Gitleaks history scan, scan the
exact committed history that would be published:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- \
  bash scripts/secret-scan.sh history
```

A history hit requires rotation and history cleanup or an amended candidate
commit. After any change, rerun verification, the candidate commit checks, and
the explicitly requested scans. Gitleaks is optional and is never implied by
`/intake`.

### Step 6: Create the fresh origin and perform the first push

Only after verification and any explicitly requested scans pass:

```bash
node "$intake_target" run --state "$intake_state" --kind git -- \
  gh repo create <github_org>/<repo> --private --source .
node "$intake_target" run --state "$intake_state" --kind git -- \
  git remote add origin git@github.com:<github_org>/<repo>.git
node "$intake_target" run --state "$intake_state" --kind git -- git remote get-url origin
node "$intake_target" run --state "$intake_state" --kind git -- git status --porcelain
node "$intake_target" run --state "$intake_state" --kind git -- git push -u origin main
```

For the preserve-history track, push additional reviewed branches and tags only
after the same repo-history scan covers them. Never use a source remote as
`origin`, and never use `gh repo create --push`.

### Step 7: Deploy preview, report, and stop

Run `node "$intake_target" run --state "$intake_state" --kind git -- vercel
--cwd .` for a preview deployment after the first push and after preview env
vars exist. Do not wire a production domain or live data. Report the source
track, local path, new repo URL, preview URL, and fresh data-project reference.
After the report, remove only the helper state with `node "$intake_target"
finish --state "$intake_state" --kind git`, then remove the now-empty
`$intake_run_dir`. Leave any failed run-created directory and its state untouched
and clearly label both for explicit cleanup.

## Quick Reference

| Source type      | History  | Get code            | Supabase / DB         |
|------------------|----------|---------------------|-----------------------|
| Lovable          | squash   | clone repo or unzip | new project, migrate  |
| Existing dev git | preserve | clone, rename remote| new project, migrate  |

## Common Mistakes

- **Pushing to the source remote.** Always rename/remove it first (Invariant 1).
- **Continuing after clone failure or reusing an existing destination.** A
  destination belongs to this intake only when this run created and validated it.
- **Deleting `.git` to squash history.** Use an orphan branch; never remove Git
  metadata from a directory whose provenance could be wrong.
- **Linking the live Vercel project** instead of creating a new one. `vercel
  link` must create, not adopt.
- **Reusing the live Supabase URL** because "it already works." That writes to
  production. Stand up your own (Invariant 4).
- **Skipping the entity lookup** and pushing to the wrong org.
- **Wiring a prod domain on first deploy.** Preview only until the operator
  explicitly promotes.
- **Creating or pushing origin before verification.** Publication is the last
  gate before preview deployment. Explicitly requested Gitleaks scans must also
  pass before publication.
