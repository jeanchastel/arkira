#!/usr/bin/env bash
# Explicit-only local secret scan. This script is never called by init, CI, or
# the canonical release gate.
set -uo pipefail

usage() {
  printf 'usage: %s working-tree|history\n' "$0" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

case "$1" in
  working-tree) scan_command="dir" ;;
  history) scan_command="git" ;;
  *) usage; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'secret scan: current directory is not inside a Git repository.\n' >&2
  exit 2
}
repo_root="$(cd -P -- "$repo_root" 2>/dev/null && pwd -P)" || {
  printf 'secret scan: repository root is not readable.\n' >&2
  exit 2
}

timeout_seconds="${ARKIRA_GITLEAKS_TIMEOUT_SECONDS:-300}"
case "$timeout_seconds" in
  ''|*[!0-9]*|0)
    printf 'secret scan: ARKIRA_GITLEAKS_TIMEOUT_SECONDS must be a positive integer.\n' >&2
    exit 2
    ;;
esac

config="$repo_root/.gitleaks.toml"
if [ -e "$config" ] || [ -L "$config" ]; then
  if [ ! -f "$config" ] || [ -L "$config" ]; then
    printf 'secret scan: .gitleaks.toml must be a regular, non-symlink file.\n' >&2
    exit 2
  fi
fi

gitleaks_bin="${ARKIRA_GITLEAKS_BIN:-gitleaks}"
if ! command -v "$gitleaks_bin" >/dev/null 2>&1; then
  printf 'secret scan: Gitleaks 8.30.1 is required; install the pinned local scanner first.\n' >&2
  exit 127
fi
version_output="$("$gitleaks_bin" version 2>/dev/null)" || {
  printf 'secret scan: could not read the Gitleaks version.\n' >&2
  exit 1
}
if ! printf '%s\n' "$version_output" | \
  grep -Eq '(^|[^0-9])8\.30\.1([^0-9]|$)'; then
  printf 'secret scan: expected Gitleaks 8.30.1, found %s.\n' "$version_output" >&2
  exit 1
fi

scan_args=(
  "$scan_command"
  --no-banner
  --no-color
  --redact
  --timeout "$timeout_seconds"
)
if [ -e "$config" ] || [ -L "$config" ]; then
  scan_args+=(--config "$config")
fi
scan_args+=(.)

cd "$repo_root" || exit 2
"$gitleaks_bin" "${scan_args[@]}"
scan_status=$?
if [ "$scan_status" -ne 0 ]; then
  exit "$scan_status"
fi

printf 'Gitleaks %s scan passed.\n' "$1"
