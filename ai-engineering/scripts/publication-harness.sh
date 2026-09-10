#!/usr/bin/env bash

# A publication helper launched from a verified public snapshot uses that same
# snapshot. Legacy helpers retain their existing repository/installed routing.
arkira_publication_central_gate() {
  local config=$1 script_dir=$2 root own gate
  [[ -f "$config" && ! -L "$config" ]] || return 4
  jq -e '(.harness.channel == "stable" and
    .harness.repository == "jeanchastel/arkira")' \
    "$config" >/dev/null 2>&1 || return 4
  [[ "${ARKIRA_HARNESS_VERIFIED:-}" == true && -d "${ARKIRA_HARNESS_ROOT:-}" &&
    ! -L "$ARKIRA_HARNESS_ROOT" ]] || {
    printf '%s\n' 'Error: public publication helper requires a verified harness; invoke it through arkira run.' >&2
    return 1
  }
  root="$(cd -- "$ARKIRA_HARNESS_ROOT" && pwd -P)" || return 1
  own="$(cd -- "$script_dir/../.." && pwd -P)" || return 1
  [[ "$root" == "$own" ]] || {
    printf '%s\n' 'Error: publication helper does not match the verified harness root.' >&2
    return 1
  }
  gate="$root/ai-engineering/runtime/candidate-gate.sh"
  [[ -f "$gate" && ! -L "$gate" && -r "$gate" ]] || return 1
  printf '%s' "$gate"
}
