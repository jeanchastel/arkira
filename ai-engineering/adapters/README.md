# Provider adapters

Provider adapters declare identity, capabilities, authentication, and safe argument arrays. The
runtime accepts only the bounded schema subset implemented in `runtime/role-runtime.sh`, then adds
structural checks for invocation objects, capability keys, and allowed placeholders.
`host-session` is a reserved runtime provider and has no adapter file, executable, model, or
authentication command.

Invocation output is `text` or `json`. Only Claude's schema-enforced
`structured_reviewing` invocation also supports `stream-json`. Its native partial-message
events drive the bounded review supervisor; intermediate contents are not stored or displayed.

An invocation may carry an optional `env` object of string values, exported to that provider
process and its authentication check only. The one placeholder allowed in `env` values is
`{codex_review_home}`, and it is not allowed in `args`. It resolves to
`<runtime root>/codex-review-home`, a mode 700 directory whose `auth.json` is a symlink to
`${CODEX_HOME:-$HOME/.codex}/auth.json`. The runtime creates a missing link and fails closed on a
regular file or a link to another target; it never copies tokens. Codex `structured_reviewing`
sets `CODEX_HOME` to it, so the Verifier loads none of the operator's Codex context.

Where a provider CLI exposes a reasoning-effort flag, set it as a literal per capability under the
role-based realignment policy in the canonical standards repository. No adapter sets a per-call
dollar ceiling; the runtime wall-clock timeout is currently the only cost bound.
