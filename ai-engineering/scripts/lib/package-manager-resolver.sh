#!/usr/bin/env bash

# Select a package-manager command prefix without mutating the environment.
arkira_resolve_manager_runner() {
  local manager=${1-}
  local exact_version=${2-}
  local found_version=

  if command -v "$manager" >/dev/null 2>&1; then
    if found_version=$("$manager" --version 2>/dev/null); then
      if [ "$found_version" = "$exact_version" ]; then
        printf '%s\n' "$manager"
        return 0
      fi
    fi
  fi

  if command -v corepack >/dev/null 2>&1; then
    printf 'corepack %s\n' "$manager"
    return 0
  fi

  if [ -n "$found_version" ]; then
    printf 'Pinned package manager %s@%s requires version %s, but found %s. Run: npm install --global %s@%s\n' \
      "$manager" "$exact_version" "$exact_version" "$found_version" "$manager" "$exact_version" >&2
  elif command -v "$manager" >/dev/null 2>&1; then
    printf 'Pinned package manager %s@%s is installed but did not report a version. Run: npm install --global %s@%s\n' \
      "$manager" "$exact_version" "$manager" "$exact_version" >&2
  else
    printf 'Pinned package manager %s@%s is absent and Corepack is unavailable. Run: npm install --global corepack\n' \
      "$manager" "$exact_version" >&2
  fi

  return 1
}
