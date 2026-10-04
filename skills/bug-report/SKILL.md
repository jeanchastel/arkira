---
name: bug-report
description: Use when behavior looks like an Arkira harness defect, in any repo. Covers `bin/arkira`, goal, gate, and session state, harness hooks, and the Arkira CI workflows. Checks for an existing report, then files or updates one redacted report in the shared local inbox and tells the user the path.
origin: arkira
---

# Bug Report

File each harness defect once, in one shared place, so the harness session can triage it.

The inbox is `~/.arkira/runtime/bug-reports/`. Every repo session on this machine writes there. Harness upgrades do not touch it.

## 1. Decide if it is a harness bug

It is a harness bug when the failure comes from one of these:

- `bin/arkira` or any script under `ai-engineering/`
- goal, gate, attestation, release, or session state under `~/.arkira/`
- a hook that the Arkira plugin registers
- an Arkira workflow (`arkira-*.yml`, the delivery authorization workflow, or a reusable `jeanchastel/arkira` workflow)

It is a product bug when the failure is in product code, product tests, product scripts, or a product-owned workflow. It is also a product bug when the harness correctly reports a real product defect. Do not file product bugs here.

If you cannot tell, reproduce once with no product change. A failure that stays is a harness bug.

## 2. Check for an existing report

```bash
bin/arkira bug-report list --status all
```

Find a report with the same command and error. If one is `open` or `confirmed`, update it. Do not file a second report.

```bash
bin/arkira bug-report update <report-path> --body-file <new-evidence.md>
```

## 3. File a new report

Write a body file with these five sections. `create` refuses a body without them.

```markdown
## Command
The command or workflow and job that failed.

## Error
The exact error text.

## Evidence
Log excerpts, run URLs, commit SHAs, PR numbers.

## Expected
What should have happened.

## Workaround
What unblocked you, or "none".
```

Then run:

```bash
bin/arkira bug-report create <repo> --manual --title "<one-line summary>" --body-file <body.md>
```

The command adds the repo, session, harness version, SHA, channel, date, and `status: open`. It redacts tokens, keys, emails, home paths, and environment values before it writes. Do not paste customer data into the body. Redaction does not detect it.

## 4. Tell the user

Give the user the printed `Bug report:` path. Continue your task with the workaround if one exists.

## Triage (harness sessions)

- `bin/arkira bug-report list` shows `open` and `confirmed` reports.
- `bin/arkira bug-report update <path> --status confirmed|fixed|wontfix` records the verdict.
- `bin/arkira bug-report submit` only forwards a report to a configured destination. Filing does not need it.
