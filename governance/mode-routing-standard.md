# Mode Routing Standard

Gated by the `mode_routing` switch (**default off**). When on, a `UserPromptSubmit`
hook (`hooks/mode-suggest.sh`) reads the submitted prompt and, only on an
unambiguous match, adds **one** advisory line nudging a non-default execution
mode. It is advisory: the line enters context, the model decides.

This standard governs the **execution mode** (how work is run). It is distinct
from `governance/model-selection-standard.md`, which governs the **model tier** (which
model runs it). The two are paired but separate.

## What it nudges

Only the two high-value, non-default escalations: never the default (plain /
inline), because nudging the default is pure noise:

- **Workflow / ultracode**: broad fan-out: comprehensive audits, whole-repo
  reviews, sweeps, `migrate all`, `find all bugs`. Parallel multi-agent work
  beats a single pass.
- **`/goal`**: a single end-to-end objective: `build X and ship it`,
  `end-to-end`, `autonomously`, `take this to done`. Runs plan → review → build
  → verify.

Agent swarms are already routed deterministically by `prefer_agent_swarms`
(`governance/agent-swarm-standard.md`) and are not re-nudged here.

## The quietness contract

The failure mode of any prompt-time nudge is becoming ignored wallpaper. This
hook is built to avoid it:

- **Off by default.** Opt-in per repo via `/arkira-init`.
- **Heuristic-only, no model call.** High-precision anchored phrase patterns, not
  loose single keywords. Zero latency on every prompt; silent on the vast
  majority. (A keyword like "workflow" alone never fires: only phrases like
  "audit the entire repo" do.)
- **At most one line, only on a confident, non-default match.** No match → no
  output.

If the hook ever starts firing on ordinary prompts, tighten the patterns in
`hooks/mode-suggest.sh` rather than loosening the contract.

## Switch

`mode_routing` (governance, default off). The hook reads it from
`.arkira/config.json` at runtime (repo config first, then `~/.arkira/config.json`)
and only proceeds when it is explicitly `true`.
