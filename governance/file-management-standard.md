# Scaffold and File Management Standard

Every Arkira scaffold, sync, generator, installer, and cleanup routine follows
this contract. A dry run is read-only; an apply is contained, reviewable,
repeatable, and recoverable.

## Path containment

- Resolve the declared repository root before planning writes.
- Accept repository-relative targets only. Reject absolute paths, `.` and `..`
  segments, control characters, and empty path components.
- Inspect every existing component with no-follow semantics. Reject symbolic
  links, including dangling links, in both target files and parent directories.
- Complete containment preflight for every planned target before the first
  mutation. A repository-controlled redirect must never write outside the root.

## Existing files and ownership

- Default to no-clobber. Skipping an existing file preserves its content,
  permissions, ownership, and timestamps.
- Every generated file declares one ownership model: managed region, pristine
  canonical file, or user-owned scaffold. Never mix models implicitly.
- Overwrite user-owned content only through an explicit force/replacement path
  that shows the diff and records the decision.
- Generated references name their source of truth and regeneration command.

## Writes, permissions, and rollback

- Validate all inputs before opening a destination.
- Render to a uniquely named temporary file in the destination directory, set
  an explicit mode, validate the result, then atomically rename it into place.
- Use mode `0600` for configuration or state that may contain private values;
  use `0644` for ordinary source files and `0755` only for newly created
  executables. Never chmod a skipped file.
- Multi-file scaffolds are transactions. Track files and directories created by
  the current invocation, back up any explicitly replaceable file, and on failure
  restore prior files and remove only paths created by that invocation.
- Cleanup handlers cover normal exit, errors, and termination signals. They do
  not delete untracked or pre-existing user content.

## Context and retention hygiene

- Machine-generated caches, graphs, logs, proposals, temporary files, and
  interrupted-write residue belong in `.gitignore`. Claude Code does not consume
  `.claudeignore`; keep that file compatibility-only. Use supported
  `permissions.deny` rules in Claude Code settings to deny built-in Read access;
  Claude Code applies Read deny rules to Grep and Glob on a best-effort basis.
  Canonical config and standards remain visible.
- Session hooks are silent on the healthy path. Repeat notices are fingerprinted
  or throttled; historical totals are available on demand instead of injected
  into every new conversation.
- Append-only state has an explicit retention age or count. Cleanup must cover
  every sidecar directory written by the feature, not only its primary file.

## Required adversarial tests

Test regular and dangling symlink targets, symlinked parents, existing-file mode
preservation, read-only directories, invalid relative paths, partial failure and
rollback, repeated apply, concurrent temporary names, and cleanup boundaries.
Happy-path file existence alone is not sufficient proof.
