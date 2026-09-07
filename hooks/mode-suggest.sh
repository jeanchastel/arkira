#!/usr/bin/env bash
# Mode-routing advisory. UserPromptSubmit hook that classifies the submitted
# prompt with high-precision heuristics and, only on an unambiguous match, prints
# ONE advisory line nudging a non-default execution mode:
#   - Workflow / ultracode  for broad fan-out work (audits, sweeps, migrations)
#   - /goal                 for a single end-to-end objective (plan->build->verify)
# It never nudges the default (plain / inline) and never calls a model, pure
# deterministic regex, zero latency, silent on the vast majority of prompts.
# Gated by the mode_routing switch (default OFF). Advisory only: the line is added
# to context; the model decides. Exit 0 always.
set -uo pipefail

HOME_DIR="${ARKIRA_MODE_HOME:-$HOME}"

# --- switch gate (default OFF: only proceed when explicitly true) -----------
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
cfg=""
[ -f "$project_dir/.arkira/config.json" ] && cfg="$project_dir/.arkira/config.json"
[ -z "$cfg" ] && [ -f "$HOME_DIR/.arkira/config.json" ] && cfg="$HOME_DIR/.arkira/config.json"
[ -n "$cfg" ] || exit 0
grep -q '"mode_routing": *true' "$cfg" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
val="unset"
val="$(jq -r 'if (.switches | type == "object") and (.switches | has("mode_routing")) then (.switches.mode_routing | tostring) else "unset" end' "$cfg" 2>/dev/null || echo unset)"
[ "$val" = "true" ] || exit 0

# --- extract the submitted prompt ------------------------------------------
payload="$(cat 2>/dev/null || true)"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -n "$prompt" ] || exit 0

lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

# --- high-precision classifiers (anchored, multi-token) --------------------
# Loose single-keyword matching is the wallpaper failure mode; require phrases.
workflow_re='(comprehensive|exhaustive).{0,20}(audit|review|sweep)|audit (the )?(whole|entire) (repo|repository|codebase|project)|review (all|every) |across (all|every) (file|module|repo|package)|find all (the )?bugs|migrate (all|every) |\bultracode\b'
goal_re='(build|implement|ship|deploy).{0,40}(and|then|,).{0,20}(ship|deploy|push|verify|release)|end[- ]to[- ]end|take this .{0,30}(to done|to production|over the line)|\bautonomously\b|plan.{0,20}build.{0,20}(verify|ship)'

note=""
if printf '%s' "$lc" | grep -Eq "$workflow_re"; then
  note="mode-routing: this reads as broad fan-out work. A Workflow (parallel multi-agent) or ultracode may fit better than a single pass. See governance/mode-routing-standard.md."
elif printf '%s' "$lc" | grep -Eq "$goal_re"; then
  note="mode-routing: this reads as one end-to-end objective. /goal runs it through plan -> review -> build -> verify. See governance/mode-routing-standard.md."
fi

[ -n "$note" ] && printf '%s\n' "$note"
exit 0
