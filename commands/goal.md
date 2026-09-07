---
description: Turn one accepted outcome into an exact verified pull request with minimal interruption.
---

# /goal

Turn `$ARGUMENTS` into one bounded outcome, one Task contract, one atomic
candidate, and one coherent delivery unit. Follow `governance/operating-directive.md`
and the callable `arkira:coding` skill. Choose the Definition of Done before work:
code-only, reviewed PR, merged PR, verified preview, or verified production.
Do not force a code-only task through publication or deployment.

## Contract

1. Convert the objective into observable acceptance criteria and a nonempty
   non-goal list. Declare allowed, protected, and adopted paths. Adopted paths
   must match pre-existing dirty paths exactly.
2. Reuse an approved spec or plan when one exists. Otherwise create only the
   artifact required to remove a material implementation ambiguity.
3. Create one schema-version-2 Task contract. Include the verification tier,
   one exact focused check, structured UI policy, immutable harness content
   digest, and explicit model and effort.
4. Set or resume the native platform goal with supported runtime controls and read
   back its actual active state. A prompt does not reactivate a blocked goal.
   Preserve explicit pause, cancellation, budget limits, and user-action blockers.
5. Run `bin/arkira goal <repo> prepare --contract <file> --plan <file>`. This
   binds the contract, plan, branch, HEAD, worktree tree, and harness snapshot.
   Then run `bin/arkira goal <repo> start`.

Do not pause after routine planning. Pause only for a material product decision,
an approval-gated mutation, required local UI acceptance, or terminal evidence
failure.

## Delivery

Use one writer when the work is ordered or too small to offset dispatch cost:

```text
bin/arkira task <repo> dispatch --contract <file>
bin/arkira task <repo> watch <job-id>
```

If the session is interrupted, run `bin/arkira task <repo> recover`, then watch
the recovered job. Do not duplicate a healthy run.

When two or three write units are pairwise disjoint, create a schema-version-1
swarm manifest and run:

```text
bin/arkira swarm <repo> dispatch --manifest <file>
bin/arkira swarm <repo> watch
```

Each writer starts from the exact same accepted primary snapshot in a separate
worktree. A unit may change only its declared scope and runs one exact focused
check. One failed unit gets one fresh repair attempt. A repeated failure is
terminal. Successful peer output remains isolated when any unit fails. The
combined patch applies only when the primary fingerprint is unchanged.

Read-only fan-out follows the same two-to-three-unit cap. Report actual runtime
evidence. Do not claim deterministic host-native parallelism.

## Local UI review

For `ui.mode: local-review`, the contract must contain an argv development
command and a review URL on `localhost` or `127.0.0.1`. Run:

```text
bin/arkira preview <repo> start --contract <file>
```

The runtime prints the URL after readiness. Pause for the operator to inspect
the exact local candidate, then run `accept` or `reject`. Either action stops
the complete server process group. A candidate change invalidates acceptance.
Do not add Playwright unless the contract or operator explicitly requires it.

## Verification and publication

Run the bound exact focused suite once after the final behavior change. Do not
run its group. Stage the complete intended candidate and certify it once.
Normal and Elevated local certification use the deterministic tree minimum and
one independent review. Elevated also requires its named surface proof and
tree-bound verified-gate authorization. Full local CI is explicit opt-in only.

After the gate authorizes the exact candidate, publish through
`ai-engineering/scripts/complete-candidate.sh`. It creates the pull request. Native squash auto-merge is used only where
the repository authorizes it; the standards source defaults to manual acceptance. Required pull request CI is the one broad
inventory run. GitHub requires the repository's normal remote PR CI. Watch that
pipeline without duplicating it locally. A changed head, failed check, conflict,
base drift, or missing permission leaves the pull request open and reports the
blocker. Never push directly to `main`. Human acceptance remains required before
merge when the repository requires it; publication does not grant acceptance.

For a merge or deployment target, bind the clean certified final commit using
`bin/arkira goal <repo> bind-delivery --repo owner/repo --pr N --head SHA
--target merged|preview|production --provider codex|claude --session ID`.
Deployment targets also require `--project prj_... --team team_...`.
Claude requires `--native-transcript /absolute/path/to/session.jsonl` from the
installed native session. Codex can optionally supply `--native-socket /path`
for its existing authoritative app-server owner; discovery alone is not ownership.
`goal watch` uses the existing bounded job supervisor; `goal recover` performs
one reconciliation; `goal schedule` installs local macOS recovery while awake.
All consume current provider evidence and back off on failures. No webhook
acknowledgement is deployment proof. See the delivery runtime README for native
ownership, terminal blockers, and supported continuation limits.

Keep the native owner waiting on the managed watch result when possible. Use
a shared native Codex socket only when it is already the authoritative owner.
Do not spawn another process against an interactive native session. When a
platform cannot resume safely, preserve the evidence and report that limitation.
A provider READY result advances to acceptance verification; the native goal
owner verifies remaining criteria and decides completion. Optional cleanup does
not invalidate verified delivery.

Report acceptance status, final tier, Task contract and harness digests, actual
agent count, retries, exact focused evidence, candidate tree, changed paths,
commit, pull request, remote CI, elapsed time, and operator interruptions.
