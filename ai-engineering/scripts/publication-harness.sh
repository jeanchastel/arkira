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

# arkira_repository_class <commit>: standards when the commit ships the plugin
# manifest, product when it carries an Arkira config; fails otherwise.
arkira_repository_class() {
  if [[ "$(git cat-file -t "$1:.claude-plugin/plugin.json" 2>/dev/null)" == blob ]]; then
    printf 'standards\n'
  elif [[ "$(git cat-file -t "$1:.arkira/config.json" 2>/dev/null)" == blob ]]; then
    printf 'product\n'
  else
    return 1
  fi
}

# arkira_required_checks <standards|product>: the branch-protection contexts
# merge and protection tooling require, on one space-separated line.
arkira_required_checks() {
  case "$1" in
    standards) printf '%s\n' 'candidate-gate remote-verify arkira-delivery-authorization' ;;
    product) printf '%s\n' 'validate arkira-delivery-authorization' ;;
    *) return 1 ;;
  esac
}
