#!/usr/bin/env bash

# arkira_read_package_manager_pin [package.json]
# Prints "manager<TAB>exact-version<TAB>spec" for an exact npm, pnpm, or Yarn
# packageManager pin; fails for anything else.
arkira_read_package_manager_pin() {
  node - "${1:-package.json}" <<'NODE'
const fs = require("fs");
let value;
try { value = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); }
catch { process.exit(1); }
const spec = value && value.packageManager;
const match = typeof spec === "string"
  ? /^(npm|pnpm|yarn)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+sha(?:224|256|384|512)\.[0-9A-Za-z+/=]+)?$/.exec(spec)
  : null;
if (!match) process.exit(1);
process.stdout.write(`${match[1]}\t${match[2]}\t${spec}\n`);
NODE
}

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
