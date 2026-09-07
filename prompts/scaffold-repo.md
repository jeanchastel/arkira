# Scaffold Repo Prompt

A legacy, paste-in prompt for **manually bootstrapping a fresh application repository**
to the Arkira baseline from an empty folder. Prefer `/arkira-new` for a framework-backed
greenfield project; use this only when a structure-only scaffold is intentional. Use it in any Claude Code
surface: the desktop app's **cowork** or **code** mode, the terminal CLI, or an IDE
extension.

It lays down the skeleton that `/arkira-init` assumes already exists, then hands off to
the wizard. It is **stack-agnostic**: it does not pick a framework, install
dependencies, or write application code. You add those after, when you know what you are
building.

## When to use

- Starting a brand-new project and you want Arkira's conventions from commit one.
- You have an empty folder (or just a `git init`) and want the standard structure.

Do **not** use it on an existing repo with code, run `/arkira-init` directly there
instead.

## How to use

1. Open Claude Code in the folder you want the repo to live in (create it first:
   `mkdir my-project && cd my-project`).
2. Paste the prompt block below.
3. Review the proposed file tree, confirm, then follow the `/arkira-init` wizard it
   triggers at the end.

---

## The prompt

> Copy everything in this block.

```text
Bootstrap this directory into a new application repository following the Arkira Labs
baseline. Work step by step and show me the planned file tree before creating anything.

1. Safety check. If this directory is not empty or already has a .git, stop and ask me
   how to proceed. Do not overwrite existing files.

2. Initialize git (`git init`) if there is no repo yet. Do not make any commits until
   step 7.

3. Create this skeleton (empty placeholder dirs get a `.gitkeep`):
     README.md: project name, one-line purpose, "## Stack" and "## Getting
                            Started" headings left as TODOs for me to fill in.
     .gitignore: sensible defaults for a generic project (OS files, env
                            files, node_modules/ and common build output, editor dirs).
     .claude/settings.json: copy `templates/claude-settings.baseline.json`
                            exactly. Its supported `permissions.deny` rules deny
                            built-in Read access to runtime state, proposals,
                            diagnostics, dependencies, and build output; Claude
                            Code applies them to Grep and Glob on a best-effort
                            basis. It also makes Glob respect `.gitignore`.
     .claudeignore: copy the Arkira compatibility baseline. Claude Code does not
                            read this file; it is not the context-control boundary.
     docs/specs/: design-pass specs live here as YYYY-MM-DD-<topic>.md
     docs/plans/: design-pass plans live here as YYYY-MM-DD-<topic>.md
     reports/: audit and remediation reports (the source of record)

   Do NOT hand-write AGENTS.md, CLAUDE.md, or .arkira/. `/arkira-sync --apply`
   installs managed governance files and `/arkira-init` writes configuration.

4. In README.md, add a short "## Conventions" section noting: specs in docs/specs/,
   plans in docs/plans/, audit context in reports/, and that this repo follows Arkira
   Labs standards via the arkira plugin.

5. Do NOT choose a framework, run any package manager, or write application code. Leave
   the stack to me.

6. Show me the final file tree and the contents of README.md, .gitignore,
   .claude/settings.json, and .claudeignore for review.

7. After I approve, make the first commit: "chore: scaffold Arkira baseline repo".

8. Then run `/arkira-sync --apply` to install managed governance files, followed by
   `/arkira-init` so the wizard writes `.arkira/config.json` switches and Claude Code
   settings patches. Walk me through its questions.

9. (Optional) If the project will have complex subsystems, suggest running the
   intent-layer skill afterward to add child AGENTS.md context nodes, but only when a
   subsystem actually earns one.
```

---

## What you end up with

```text
my-project/
├── README.md            # purpose, stack TODO, conventions
├── .gitignore
├── .claudeignore        # compatibility only; Claude Code does not read it
├── .claude/
│   └── settings.json    # supported permissions.deny noise controls
├── docs/
│   ├── specs/           # docs/specs/YYYY-MM-DD-<topic>.md  (design pass)
│   └── plans/           # docs/plans/YYYY-MM-DD-<topic>.md  (design pass)
├── reports/             # audit + remediation source of record
└── .arkira/             # written by /arkira-init (config.json)
    └── config.json
# plus managed root governance installed by /arkira-sync --apply
```

From here, the design-pass / feature-pass / remediation-pass workflows have a home, and
the arkira hooks and skills are wired up.

## Notes

- This prompt creates structure only. `/arkira-init` owns the governance files and
  config: keep that split so plugin upgrades can update the managed regions cleanly.
- For a **static brochure site** (plain HTML/CSS, no build step), do not use this. Run
  `/arkira-init-web`, which scaffolds the static-web layout directly.
- The `docs/specs`, `docs/plans`, and `reports/` conventions come from the Arkira
  workflows (`ai-engineering/workflows/`). See the repo root `AGENTS.md` after
  `/arkira-init` runs for the normative rules.
