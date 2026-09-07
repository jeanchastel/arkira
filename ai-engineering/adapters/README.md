# Provider adapters

Provider adapters declare identity, capabilities, authentication, and safe argument arrays. The
runtime accepts only the bounded schema subset implemented in `runtime/role-runtime.sh`, then adds
structural checks for invocation objects, capability keys, and allowed placeholders. Copy
`fixtures/stub-provider.json` when developing a third-provider adapter. Fixtures are never part of
production discovery. `host-session` is a reserved runtime provider and has no adapter file,
executable, model, or authentication command.

Invocation output is `text` or `json`. Only Claude's schema-enforced
`structured_reviewing` invocation also supports `stream-json`. Its native partial-message
events drive the bounded review supervisor; intermediate contents are not stored or displayed.

Where a provider CLI exposes a reasoning-effort flag, set it as a literal per capability under the
policy in `docs/specs/2026-07-25-arkira-role-based-realignment.md` section 7. No adapter sets a
per-call dollar ceiling; the runtime wall-clock timeout is currently the only cost bound.
