# Candidate Gate Standard

## Decision

Certify the staged tree before publication. The candidate gate classifies the exact tree, validates
it, gathers the required review, and records exact-tree authorization for delivery.

## Tier Matrix

| Tier | Validation | Review | Delivery authorization |
|---|---|---|---|
| Quick | Deterministic minimum, safe committed quick gate, and any bound focused check | The configured Quick Verifier at low effort. Failure permits no review | Verified gates for the exact tree |
| Normal | Bound focused evidence plus the deterministic tree minimum | The configured Quick Verifier at low effort. If unavailable, one tree-bound host-review record | Verified gates for the exact tree |
| Elevated | Normal evidence plus the named triggering surface proof | A concrete dispatched Verifier, independent of the author. A host-review record is never sufficient | Verified gates bound to validation and independent review |

High-assurance is out of scope and unchanged.

Report-only is a validation shape, not a tier. The exact trusted-base-to-candidate-tree raw diff is
eligible only when every entry is an addition or modification of regular non-executable Markdown
under `reports/`, `docs/specs/`, or `docs/plans/`, at any depth beneath those roots. Deletions,
renames, symlinks, submodules,
executable objects, non-Markdown paths, mixed candidates, and malformed or unresolved inputs fail
closed. Protected scope is checked first and still wins. Elevated never uses this shape.

Eligible Quick and Normal candidates run the dependency-free documentation gate and skip the
ordinary minimum and model review. The gate runs `git diff --check`, changed-document
Markdown and locally resolvable link checks, and exact-tree residue and immutability checks. Its
validation record uses the distinct `report-only` shape and an empty deferred-suite set.

Local and remote both resolve the documentation gate from the trusted base, never from the candidate
tree. The trusted entry must be a regular executable blob, and it runs from a copy extracted by
object id. The gate materializes the structured router, central policy, and risk-path schema from
regular trusted-base blobs with their expected modes. A missing, malformed, or unsafe routing
dependency blocks classification. A candidate that ships its own gate or policy cannot classify
itself as report-only and skip review.

Local certification does not install dependencies or run a broad baseline by default. Normal and
Elevated use the bound focused check, `git diff --check` against the exact tree, and the required
Verifier. Elevated also requires the named triggering surface proof and tree-bound verified-gate
authorization. Run
`candidate-gate.sh validate --repo . --full-ci` only when the operator requests a complete local
matrix. An explicit `candidate-gate.sh certify --repo . --full-ci` request also forces that gate
for every tier. Explicit full local validation installs the exact committed lockfile before running
the full inventory.

This controls local validation only. Required pull-request CI remains part of the normal delivery
sequence after publication, and merge or deployment still waits for the repository's required
remote checks. That pipeline is the single broad inventory run unless the operator explicitly asks
for a local full proof.

Remote product CI keeps one required job named `validate`. It classifies before Node setup. The
report-only branch runs only the documentation gate. Products without a trusted `.arkira/ci.json`
retain the existing package-manager setup, dependency install, release inventory, and candidate
preservation checks. Remote classification runs the same structured candidate evaluator and reports
the policy digest, routing digest, and sorted matching rule IDs. A candidate that requires Elevated
review never takes the documentation-only lane.

### Split product CI adoption

Split CI is enabled only when the trusted base contains the exact supported `.arkira/ci.json` and
the candidate leaves that file byte-identical. Missing or candidate-modified contracts fall back to
the legacy full inventory. A malformed trusted contract fails closed. The version-1 contract is:

```json
{
  "schema_version": 1,
  "build_artifact": {
    "provider": "nextjs",
    "package_script": "build",
    "directory": ".next",
    "exclude": ["cache/**", "dev/**"],
    "max_uncompressed_mb": 150
  },
  "database": {
    "provider": "supabase-local",
    "package_script": "test:db",
    "risk_paths": ["supabase/**"]
  },
  "browser": {
    "provider": "playwright",
    "package_script": "test:e2e",
    "browsers": ["chromium"],
    "shards": 4,
    "requires_database": true
  }
}
```

The pull-request workflow restores package-download caches, installs the immutable lockfile once in
each isolated job, and runs lint, typecheck, unit tests, and the build. It uploads one manifest-bound
build artifact. Database checks start Supabase only when the trusted `risk_paths` match the exact
base-to-candidate delta; rename detection is disabled so deleting or moving a database path remains
in scope. Four downstream jobs in the same pull-request workflow each restore and verify the same
build without polling, start an isolated local
Supabase stack, and run one Playwright shard with one worker. The pinned Supabase CLI, package-manager
downloads, and Playwright browser files use immutable cache keys. A path-filtered `push` workflow on
trusted main populates those caches when the contract or dependency lock changes. The low-trust
pull-request workflow restores trusted-main entries and may write only PR-scoped entries. Playwright and Supabase exit
status remain authoritative, including after cleanup. The installed trusted-main cache-support workflow
exits successfully without dependency work when the trusted split contract is absent; malformed trusted
contracts still fail closed.

The final required contexts are `validate / validate`, `validate / candidate`, and
`arkira-delivery-authorization`. Apply the `product-split` branch-protection preset only after the
contract and cache-support caller are present on the trusted base and both contexts have been
observed on the onboarding pull request. The legacy `product` preset remains valid before adoption.

## Task contract binding

A validated Task contract is canonicalized with `jq -S -c .`, keyed by its SHA-256 digest, and
stored at `contracts/<repo-identity>/<digest>.json` under the local runtime root. Contract and
identity directories use mode `700`. Records use mode `600`. Symlinks are rejected. An existing
record is immutable and is never rewritten.

New dispatch requires Task contract schema version 2. It adds non-goals, adopted paths, structured
UI policy, and a 64-hex immutable harness content digest. Stored schema-version-1 contracts remain
loadable and certifiable for in-flight work. They cannot start a new dispatch.

Receipts optionally carry the 64-hex contract digest. A governed dispatch that cannot
write its receipt fails the job. An ungoverned dispatch retains the existing warning and continues.
Certification derives the governing contract only from non-null digests declared by receipts that
cover the candidate delta. The newest declaring receipt governs, selected by highest
`created_epoch` with `receipt_id` as the deterministic tie-break. The gate loads and verifies that
exact stored contract. No digest preserves the ungoverned path. A missing or corrupt governing
record fails closed. The contract author decides how tight its scope is. The gate does not combine
scope from older contracts.

Successful Executor finalization compares the pre-dispatch and post-dispatch receipt snapshots.
New JavaScript, declaration, or source-map output next to a matching TypeScript source fails the
job. The runtime reports every matching path and leaves the files for operator review. It does not
flag pre-existing output or output without a matching source in the same directory.

### Dependency-bot exemption

This path bypasses harness enforcement: Dependabot PRs never enter the local Executor or receipt
pipeline; GitHub-native branch protection and auto-merge workflow enforce it.

A pull request can merge without an Executor receipt when its author login is `dependabot[bot]` on
`opened`. On `synchronize`, auto-merge remains armed only when the pushing actor is `dependabot[bot]`.
The target branch must require a green `validate` check. Any failed condition returns the change to
the ordinary receipt-bearing path.

Naming `validate` is load-bearing. "Every required check is green" is trivially true on a branch with
no protection, so the exemption would otherwise self-satisfy on an unprotected or newly onboarded
repository. The file category of the diff is deliberately not part of the test: `package.json` carries
`postinstall` scripts, a `Dockerfile` is executable content, and a lockfile's `resolved` URLs choose
which tarball is fetched, all of which CI executes rather than guards against.

## Scope from the delta

Contract scope is enforced against the exact trusted-base-to-candidate-tree delta, including added,
modified, and deleted paths. Protected scope is evaluated first and always wins. Planner Markdown
under `docs/specs/`, `docs/plans/`, or `reports/` is exempt from allowed scope, but never from
protected scope. Every other delta path must match an allowed entry.

Matching is literal exact-or-subtree. Entry `src` matches `src` and `src/a.ts`. It does not match
`srcx/a.ts`, `xsrc/a.ts`, or `asrc`. Entry `src/a.ts` does not match `src/ab.ts`. Scope failure runs
before any focused check, validation command, or Verifier dispatch and writes no attestation.

## Contract tier floor

The contract verification tier is a floor on the tier derived from the delta. It may raise the
final tier and never lower it. This candidate gate does not support `high-assurance`. It fails
closed instead of lowering that tier.

Final routing derives the candidate diff internally with rename detection disabled. The structured
receipt records the floor source, policy and schema digests, and both manifests. It also records
every operation, match, exact transformer exclusion, and valid ambiguity. Repository risk rules are
additive. The union of base and candidate rules applies to the current candidate.

## Focused check

When a contract governs, the host runs `verification.focused_check` against the exact candidate
with the same trusted-base binding as other candidate commands. Executor-reported results are not
evidence. The focused check runs regardless of tier and has a hard 180-second budget. A larger
configured timeout fails closed unless certification is explicitly classified with `--full-ci`.

A pass records repository identity, trusted base, candidate tree, contract digest, command,
outcome, and numeric duration under `focused/<repo-identity>/`. The record key also binds the
timeout. An exact match is reused read-only. A changed candidate, command, digest, base, identity,
or timeout runs the check again. Failure, timeout, candidate movement, or residue writes no focused
record and no attestation.

The attestation embeds the resolved contract projection and focused record. Its governed branch is
selected from the newest contract-declaring receipt in `covering_entries`, not from key presence.
Zero digests requires both objects to be absent or null. One or more digests require complete
objects matching the resolved governing digest. Removing both objects from a governed attestation
therefore fails closed.

A version-2 contract with `ui.mode: local-review` also requires a preview acceptance record for the
same contract digest and exact candidate tree. A changed tree or different contract invalidates the
acceptance before validation or review begins.

## Quick Contract

Quick runs a deterministic minimum against the exact candidate tree. It runs `git diff --check`
against the trusted base and candidate tree. A non-zero result fails closed.

If `scripts/quick-gate.sh` is absent, the deterministic minimum is the defined outcome. The
attestation records that minimum-only shape. Quick never dispatches a model review and never accepts
a host claim that checks passed.

If `scripts/quick-gate.sh` is present, the gate runs it with a hard timeout. Before execution it
must be a regular non-symlink file, tracked by Git in the candidate tree, and not group or world
writable. A failed safety check is P1 and fails closed. The gate does not skip an unsafe present
quick gate.

## Review Lineage

The `dispatches` field counts schema-valid Verifier verdicts. Timeouts, provider failures, and
malformed responses do not consume the review budget. Valid `go` and `no-go` verdicts consume it.

Every dispatched outcome writes one private, atomic review record before the gate acts on it. The
record binds the reviewer, candidate, prompt and schema digests, structured verdict when valid, and
a response digest. It retains no raw stdout or stderr. A no-go names its record in the failure
output, so the finding can be resolved without a blind redispatch.

The initial valid verdict is 1. `ARKIRA_MAX_VERIFIER_ROUNDS` defaults to 2 correction rounds after
it. The default therefore permits 3 valid verdicts. `lineage-continue` grants one more and records
the grant. A successful certification closes the lineage. The gate performs no automatic retry.

## Validation evidence

A successful validation record with `outcome == passed` binds nine values:

1. Repository identity.
2. Trusted base.
3. Candidate tree.
4. Resolved gate command string.
5. Execution profile: `local` or `github-actions`.
6. Validation shape and gate mode.
7. The exact deferred-suite set as sorted `(suite_id, group, required_context)` triples,
   precomputed from the committed manifest in the candidate tree.
8. The relevant suite, legacy baseline, full-gate, and quick timeout values. The baseline timeout
   remains in schema-version-3 records for compatibility and does not trigger a default baseline.
9. The digest of the installed validation-producer source set.

The candidate tree binds the candidate runner, test inventory, and candidate configuration. The
source-set digest covers the candidate gate and loaded runtime and bootstrap dependencies. It
invalidates proof after a runtime update. A matching record is reusable across a
closed lineage. There is no time-based expiry.

`candidate-gate.sh validate --repo . --full-ci` records the full local validation of one clean
staged candidate. The command rejects residue, captures the tree before validation, and rechecks
the tree, residue, repository identity, and publication base after validation. Matching full
certification reuses that record. It prints whether it recorded or reused proof.

A reuse hit is read-only. It never rewrites, replaces, or mutates the record. A suite that reads
unversioned external state is not eligible for reuse and belongs in `remote-authoritative`.

Every managed proof function declares its evidence key, proof consumers, and invalidation
conditions. It runs once when those values match. A repeat requires changed input, changed
external state, invalid evidence, explicit fresh safety evidence, or a distinct proof claim.
Time, phase names, and gate boundaries do not invalidate deterministic local proof.

## Record schema versions

Validation records use `schema_version` 3. New attestations use `schema_version` 6 with a
`verified-gates` authorization bound to the exact tree, validation record, and review evidence.
Schema-5 accepted attestations remain readable for manual recovery. Lineage and legacy acceptance
records remain `schema_version` 1. A version-1 record is never reusable
as version-3 evidence. A version-2 record also fails reuse. The validation reuse predicate treats
both as misses.
`ai-engineering/runtime/schemas/verifier-verdict.json` is a separate artifact and does not change.

Schema 6 embeds the complete routing receipt. It records every raw delta path in `covering_entries`.
Each entry derives `provenance_kind` from its receipt roles. Zero receipts produce `unattributed`.
Executor-only and transformer-only receipt sets produce their named kinds. Every other nonempty set
produces `mixed`.

The attestation derives `provenance_summary` from the complete entry array. Every require and
publication operation validates the entry kinds and summary. It also compares policy and risk-path
schema digests with the current installed harness. Schema 4 attestations cannot authorize a 0.120.0
publication. Recertification writes new evidence. It does not rewrite old local attestations.

Receipt-less entries pass exact-tree require checks when their recorded path, blob, and mode match.
Receipted entries retain live receipt and contract-digest integrity checks.

## Authoring configuration

Direct host authoring is the central default. A repository can set
`authoring.executor_required: true` in `.arkira/config.json` to require Executor or trusted
transformer coverage for non-Planner paths.

Certification validates the trusted-base and candidate configuration. The effective setting is
true when either tree sets true. A candidate cannot lower a trusted-base true value. Invalid JSON,
a non-object `authoring` value, or a non-boolean `executor_required` value fails before validation.
Strict mode keeps the existing Planner artifact exception.

## Local and remote authority

`remote-authoritative` identifies a suite whose result depends on remote or otherwise unversioned
external state and is authoritative only when it runs in the remote environment. The
`auth-reference-rls`, `claude-plugin-validator`, and `claude-plugin-agent-smoke` suites are
remote-authoritative.

Under `GITHUB_ACTIONS=true`, these suites behave exactly as required and CI is unchanged. Locally,
they are not selected and are reported as `DEFERRED` with their suite id, group, and required
context. Validation evidence and attestations record the exact deferred triples and a scope of
`local-complete` or `local-partial`. Under the current manifest schema, `required_context` equals
the suite group.

The parity invariant requires every deferred context to have exactly one required check and exactly
one CI job. Remote enforcement is `validate_check_rollup` at the exact head in
`merge-current-pr.sh`.

## Review reuse

Review reuse is exact-tree only. It binds repository identity, trusted base, candidate tree, final
tier, Verifier provider, Verifier model, the verdict schema digest, and the prompt-contract digest.
A reuse hit opens no lineage, increments no dispatch counter, and preserves the prior lineage audit
data. A changed tree receives a fresh full review. There is no review chain, no delta review, and
no carried findings.

## Evaluation order

Contract resolution and scope enforcement run before tier routing. The host focused check runs
before deterministic validation. Deterministic validation runs before Verifier dispatch. Any
earlier failure spends no Verifier dispatch and no lineage budget.

## Blocking matrix

Normal blocks P0 and P1. Elevated blocks P0 and P1. P2 and P3 are advisory at both tiers.
A `no-go` stops a candidate at any tier. A `go` accompanied by a finding that blocks at the
candidate's tier is a contradiction and fails closed.

## Timeouts

| Measurement | Default | Basis |
|---|---:|---|
| Local suite timeout | 900 seconds | Deliberately generous because local contention is unmodeled. |
| Focused check timeout | 180 seconds | Hard local budget. Only explicit `--full-ci` certification can select a larger timeout. |
| Full gate timeout | 5100 seconds | `max(3 x 1646, 1800)`, rounded up to the next 300, from a measured local serial run of 1646 seconds over 112 suites. |
| Quick gate timeout | 30 seconds | Defined quick-gate limit. |
| Verifier timeout | 900 seconds | PROVISIONAL. Revisit after ten recorded dispatches. |

No CI-side timeout changed.

## Enrollment and Enforcement

A tracked `.arkira/config.json` is the operator's affirmative enrollment decision. Once an enrolled
repository receives the applicable hooks through Arkira sync, enforcement is immediate. The active
host implements directly by default and may delegate through the configured Executor. Publication
operations require the candidate-gate evidence
appropriate to their lifecycle stage. An unenrolled repository is not governed. There is no
staged-inert rollout, implicit directory enrollment, or bypass marker.

## Enforcement Boundaries

| Layer | Mechanism | Can guarantee | Cannot guarantee |
|---|---|---|---|
| Agent host | `PreToolUse` hooks in `hooks/hooks.json` | Blocks or explains publication `Bash` calls inside a Claude Code session that loads this plugin, but only in a repository enrolled by a tracked `.arkira/config.json` | Authoring writes. An unenrolled repository. Anything outside that session. Another agent, plain shell, Git GUI, or disabled plugin |
| Repository local | Git hooks under the common Git directory | Advisory checks on `git commit` and `git push` from a shell that honors hooks | Defeated by `--no-verify`, by `core.hooksPath`, by any tool that writes refs directly |
| Canonical helper | `candidate-gate.sh`, `create-pr.sh`, `merge-current-pr.sh` | That a candidate published through these helpers carried a matching attestation for the exact tree, with truthful per-path receipt provenance | Nothing about a publication that did not use the helpers |
| Local evidence store | `${ARKIRA_RUNTIME_HOME:-${ARKIRA_ROLE_HOME:-$HOME}/.arkira/runtime}` | Content and exact-tree binding of contracts, receipts, focused checks, lineages, validation records, and attestations the runtime itself wrote | Not tamper proof. Any process running as the operator can write there. Discipline control against accidental bypass, not a security boundary against a hostile local actor |
| Verified-gate authorization | Exact tree, validation record, and required review evidence recorded by candidate gate | That the local candidate completed its tier-required proof before delivery | Not remotely verifiable and does not replace GitHub required checks |
| CI tier check | The `candidate-gate` suite on GitHub | Independent structured recomputation from the actual diff. Includes both manifests, policy digest, routing digest, and matching rule IDs | Cannot see local receipts, attestations, intent-only floors, or review evidence. The `full-ci` label carries an intent-only Elevated increase |
| CI objective gates | The other required jobs in `.github/workflows/ci.yml` and the `validate` job in `ai-engineering/github/workflows/arkira-ci.yml` | That the objective suites pass on GitHub's runner for the exact head commit | Cannot verify which model authored or reviewed anything |
| Classic branch protection | `PUT /repos/:owner/:repo/branches/main/protection` with `enforce_admins` | That direct pushes to `main` are rejected remotely for collaborators and for repository administrators, that a pull request is required, that named checks must pass, that conversations must be resolved, and that force push and deletion are blocked | Cannot verify agent provenance. Cannot require an approving review in a solo-author repository. Cannot stop an administrator who first turns `enforce_admins` off, which is an audited settings change rather than a silent push |

Ad hoc deletion of a squash merged branch stays blocked by the publication guard, because a squash merged tip is never an ancestor of the trusted base. The accepted route is `merge-current-pr.sh`, which owns leased deletion after it has proven reviewed tree equality, recorded candidate evidence, and remote main convergence. A deliberate one time operator exception is the only other route. A governed repository must have `delete_branch_on_merge` disabled, because GitHub deleting the head branch at merge time would bypass every one of those proofs. The merge helper asserts this before it merges.

## Evidence Limits

Receipts prove that exact content changed during a successful dispatch window. They do not prove
operating-system-level process authorship. Concurrent writes inside that window are captured in the
same delta and cannot be attributed to a particular process.

An unattributed entry proves no author identity. Candidate validation, review, acceptance, and
exact-tree publication checks remain separate evidence layers.

The local evidence store is a P1 discipline control against accidental bypass. It is not a security
boundary against a hostile local actor.
## Trusted validation-shape classification

The release gate may use the installed harness classifier at
`ai-engineering/bootstrap/classify-validation-shape.sh` to choose the minimum
validation shape for a candidate. The classifier consumes only `--repo PATH
--base SHA --tree SHA`. It resolves the exact base commit and candidate tree,
reads Git objects through a rename-disabled diff, and never executes code from
the candidate tree.

On success it emits exactly these five records, once each:

```text
VALIDATION_SHAPE=type-only|behavioral
CLASSIFIER_VERSION=<positive integer>
CANDIDATE_BASE=<resolved commit SHA>
CANDIDATE_TREE=<resolved tree SHA>
CLASSIFIER_RULES=<rules identifier>
```

`type-only` is reserved for same-mode regular-file content changes confined to
committed `*.d.ts` files. The raw Git record must be an in-place `100644`
modification with a different blob object. All `.ts`, `.tsx`, executable or
sensitive paths, mixed changes, metadata-only changes, symlinks, gitlinks,
additions, deletions, and ambiguous inputs are behavioral. The classifier uses
no source parser: anything outside this exact subset is behavioral. Malformed
base or tree input, a missing Git object, or an unreadable diff fails nonzero
without selecting `type-only`. False negatives are preferred to false
positives: a behavioral result may run more validation, while a false
`type-only` result could skip required smoke coverage.

During certification, the installed classifier is invoked with the exact
trusted base and candidate tree. The validation record and attestation store
`shape`, `classifier_version`, `classifier_rules`, `classifier_base`, and
`classifier_tree`, along with the retained validation `gate_shape`. A malformed,
missing, or contradictory classifier response records `behavioral` with smoke
still required; candidate-tree classifier content is never consulted.

`smoke_required` is true by default. It may be false only when the recorded
shape is `type-only`, the classifier metadata binds the exact trusted base and
candidate tree, and the required focused check has passed for that same tree.
