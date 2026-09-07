# Secret Scanning Standard

Gitleaks is the optional local secret scanner. The harness exposes it through
one explicit wrapper and never calls it from initialization, the canonical
gate, CI, new-project work, intake, hooks, or background automation.

The advisory secret review remains active independently of this tool.

## Decision

Use pinned Gitleaks `8.30.1` for operator-requested scans. Do not use a hosted
scanner, API token, persistent hook, or automatic scan.

Run the central route from anywhere inside the target repository:

```bash
bin/arkira secret-scan working-tree
bin/arkira secret-scan history
```

The launcher resolves the installed harness snapshot or the `ARKIRA_HOME_DEV`
development checkout, then runs the harness-owned scanner against the current
Git repository. It takes no target repository path and requires no copied file.
A missing or unknown mode prints one usage line and runs no scanner.

Synchronization still installs `scripts/secret-scan.sh` as a working legacy
path. That path is transitional. The reference-only pilot migration removes
reliance on the copied wrapper.

`working-tree` scans the current files. `history` scans Git history. Neither
mode is implied by another Arkira workflow.

The wrapper:

- resolves and scans the Git repository root;
- redacts every detected secret from terminal output;
- disables color and decorative output for concise logs;
- applies a 300-second scanner timeout by default;
- uses a regular, non-symlink `.gitleaks.toml` when the repository provides one;
- rejects an unsafe configuration before invoking Gitleaks; and
- returns the scanner's nonzero status without printing a success message.

`ARKIRA_GITLEAKS_BIN` may point tests or controlled installations at a specific
binary. `ARKIRA_GITLEAKS_TIMEOUT_SECONDS` may set another positive timeout.

## Severity

P0 Critical:

- A production credential is committed.
- A service-role key is committed.
- A private key or signing secret enters Git history.

P1 High:

- An explicitly requested scan reports a real secret and publication continues.
- A scan prints an unredacted credential.
- An automatic workflow invokes the scanner without an operator request.

P2 Medium:

- A requested scan cannot run because Gitleaks is missing.
- A repository uses an unsafe or malformed scanner configuration.
- A broad allowlist hides more than one reviewed false positive.

P3 Low:

- Installation guidance names a stale reviewed version.
- An intentionally fake fixture lacks a precise path allowlist.

## Review Switches

There is no `secret_guard` switch. It was retired because a persistent switch
conflicts with the explicit-call contract.

`secret_exposure_review` remains the judgment layer. It requires explicit
checks for committed secrets, browser-exposed server secrets, logged
credentials, service-role exposure, and unsafe production secret handling.

`environment_separation_review` remains the environment layer. It requires
local, preview, staging, and production variables to stay scoped correctly.

Both advisory switches are owned by
[security/environment-variable-standard.md](./environment-variable-standard.md).

## Installation

Install Gitleaks locally, then confirm the installed version:

```bash
brew install gitleaks
gitleaks version
```

The reviewed version is `8.30.1`. Installation and upgrades are operator
actions. The harness does not download or update the binary.

## Configuration and Allowlisting

Gitleaks uses its built-in rules unless the repository provides
`.gitleaks.toml`. A repository configuration should extend the defaults:

```toml
[extend]
useDefault = true
```

Allow only a reviewed finding or precise fixture path. Never exclude an entire
source, configuration, migration, or environment-file directory. Keep
`.gitleaks.toml` in review scope because changing it changes scanner behavior.

## Automatic Execution

The following surfaces must not invoke or install Gitleaks:

- canonical local gates;
- standards or product CI;
- initialization and synchronization;
- pre-commit, pre-push, or assistant hooks;
- new-project and intake workflows without an explicit operator request; and
- background jobs or session-start hooks.

Tests may use a fake scanner binary to verify the wrapper. They must not invoke
the real scanner or require network access.

`/arkira-sync` may remove the two exact `ggshield` commands that an older
Arkira release installed in the pre-commit and pre-push hooks of the
repository's common Git directory. A configured `core.hooksPath` is never
followed. This is a retirement migration, not secret scanning. It does not
execute Gitleaks or GitGuardian, and it preserves every other hook line and
file mode.

## Incident Handling

On a real finding:

1. Stop publication.
2. Revoke or rotate the credential before treating deletion as remediation.
3. Remove it from the working tree and, when applicable, Git history.
4. Review any new allowlist entry as a security-sensitive change.
5. Rerun every explicitly requested scan.

Do not print or paste the secret into chat, issues, reports, or commit messages.
