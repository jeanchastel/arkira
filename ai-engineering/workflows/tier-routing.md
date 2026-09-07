# Workflow tier routing

Arkira uses one structured policy for preliminary, candidate, documentation, and remote routing.
The evaluator lives in `ai-engineering/runtime/tier-routing.sh`. Its central policy lives in
`ai-engineering/runtime/tier-routing-policy.json`.

## Tier rule

Routing is upward only. Quick is the default. Normal remains a valid floor from a task contract or
older evidence. Any sensitive match or valid ambiguity raises the candidate to Elevated.

P1. Malformed or incomplete routing evidence blocks. It never produces Quick.

Repository configuration may add Elevated paths. It cannot remove, replace, disable, or lower a
central rule. There is no risk-acceptance flag or global vendored-sync bypass.

## Central policy

The evaluator splits paths into slash-delimited components. It tokenizes the original component at
periods, underscores, hyphens, spaces, and camel-case boundaries, then normalizes ASCII letters to
lowercase. Matching uses exact tokens and lexical forms. It does not use sensitive substrings.

The central vocabulary covers authentication, authorization, access control, identity, sessions,
billing, checkout, payments, secrets, migrations, schemas, CI, workflows, and infrastructure.
Examples include `authn`, `authz`, `rbac`, `acl`, `permissions`, and `roles`.

`AuthProvider.tsx`, `authorize.ts`, and `unauthorized.ts` route Elevated. `author.ts`,
`authority.ts`, `authorizer-note.md`, and `nauthorize.ts` remain Quick unless another rule matches.

Sensitive directories match at every monorepo depth. Root `bin/`, `hooks/`, and
`ai-engineering/runtime/` remain root-relative. A nested `packages/tool/bin/` stays Quick unless a
repository manifest raises it.

`.arkira/config.json` and `.arkira/risk-paths.json` are exact central Elevated paths. A verified
transformer may exclude its exact generated config path. An unproven config change remains
Elevated.

## Repository risk paths

A repository may own `.arkira/risk-paths.json`. The optional schema 1 file contains only stable IDs
and additive Elevated globs.

```json
{
  "schema_version": 1,
  "elevated_paths": [
    {
      "id": "regulated-member-records",
      "glob": "apps/api/src/member-records/**"
    }
  ]
}
```

The grammar supports literals, `*` within one component, and `**` as a complete component. It
rejects negation, traversal, absolute paths, unknown fields, and other metacharacters.

Candidate routing evaluates the union of rules in the trusted base and candidate tree. Deleting or
changing a base rule cannot lower the candidate that performs the change.

## Two routing stages

Preliminary routing evaluates requested and planned paths before implementation. The temporary
`arkira_route_tier` compatibility function accepts only a complete NUL-delimited path list.

Candidate routing accepts the repository, exact trusted base, exact candidate tree, tier floor,
floor source, and exact verified-path exclusions. It derives a raw `--no-renames` diff itself.
Additions, modifications, deletions, and both sides of a rename-like change are evaluated.

The candidate evaluator returns a routing receipt with the final tier, floor, policy and schema
digests, manifest state, operations, matches, exclusions, and ambiguities. Candidate attestations
embed that receipt. Publication rejects a stale policy or schema digest.

Verified transformer evidence can exclude only its exact proven path. Each exclusion records every
proving transformer receipt ID. Every unproven path in a mixed candidate still receives central and
repository evaluation.

## Delivery behavior

Quick uses deterministic validation and the configured Quick Verifier when available. Quick
Verifier failure degrades to no review. Normal keeps its existing review behavior. Elevated runs
focused trigger evidence locally. It requires a concrete independent Verifier and receives
tree-bound verified-gate authorization. A full local gate requires an explicit operator request.

The publication helper obtains the committed routing result from the candidate gate. For every
Elevated candidate, it ensures the `full-ci` label exists before applying it during initial pull
request creation. This carries intent-only task-contract increases that remote path routing cannot
reconstruct.
