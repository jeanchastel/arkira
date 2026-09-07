# Governance

Canonical AI-agent operating instructions and governance standards. Product
repositories receive these under lowercase `governance/`; the root context file
remains the conventional `AGENTS.md`.

- [role-contracts.md](./role-contracts.md): Planner, Executor, and Verifier contracts and the Git boundary
- [operating-directive.md](./operating-directive.md): prime directive, stop rule, and verification budget
- [root-agents.md](./root-agents.md)
- [agent-swarm-standard.md](./agent-swarm-standard.md): `prefer_agent_swarms` policy
- [harness-review-standard.md](./harness-review-standard.md): harness review cadence
- [next-steps-standard.md](./next-steps-standard.md): `verbose_next_steps` policy
- [checkpoint-standard.md](./checkpoint-standard.md): `time_checkpoint` policy
- [session-segmentation-standard.md](./session-segmentation-standard.md): semantic conversation boundaries and provider-neutral handoffs
- [sync-standard.md](./sync-standard.md): `/arkira-sync` two-tier merge policy
- [model-selection-standard.md](./model-selection-standard.md): `model_selection_policy` (whole-task quality, time, and tokens)
- [mode-routing-standard.md](./mode-routing-standard.md): `mode_routing` execution-mode nudge policy (default off)
- [eval-standard.md](./eval-standard.md): `eval_gate_enforcement` eval gate policy (default off)
- [self-improving-standard.md](./self-improving-standard.md): `self_improving_claude_md` propose-only reflection policy
- [intent-layer-standard.md](./intent-layer-standard.md): hierarchical `AGENTS.md` context standard
- [file-management-standard.md](./file-management-standard.md): contained, atomic, recoverable scaffold and file operations
- [rtk-token-killer-standard.md](./rtk-token-killer-standard.md): `rtk` token-optimizing CLI proxy (reference, not synced)
