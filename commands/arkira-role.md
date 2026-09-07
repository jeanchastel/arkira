---
description: Inspect, test, or change Arkira role providers
argument-hint: status|doctor|set|test|reset|repair
allowed-tools: Bash
---

# Arkira role management

Run `${CLAUDE_PLUGIN_ROOT}/ai-engineering/runtime/role-manage.sh` with the exact user arguments.
`status`, `doctor`, and `test` are read-only. Status reports configured provider, model, effort,
authentication, RTK path, automatic Claude-hook health, and measured savings when the RTK ledger is
readable. Doctor fails when a configured RTK hook cannot resolve the PATH binary. When RTK is not
installed, status and doctor report it as optional and unavailable and still succeed.
`set <role> <provider> [model]` validates the full role configuration before writing; omit the model
or pass `default` to use the adapter or provider default. `reset` writes the mission default.
`repair` preserves one stable `.arkira/roles.json.corrupt` recovery copy before replacing malformed
configuration. Show the script output verbatim and do not invoke a provider prompt.
