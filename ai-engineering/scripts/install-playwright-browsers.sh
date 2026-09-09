#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

has_playwright_dependency() {
  node - package.json <<'NODE'
const fs = require("fs");
let value;
try { value = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); }
catch { process.exit(1); }
const dependencies = [value.dependencies, value.devDependencies];
process.exit(dependencies.some((group) => group && Object.prototype.hasOwnProperty.call(group, "@playwright/test")) ? 0 : 1);
NODE
}

select_package_manager() {
  local lock_entry lock_path lock_manager lock_count=0 selected_manager=""
  local lockfiles=(
    "pnpm-lock.yaml:pnpm"
    "yarn.lock:yarn"
    "package-lock.json:npm"
    "npm-shrinkwrap.json:npm"
  )

  for lock_entry in "${lockfiles[@]}"; do
    lock_path=${lock_entry%%:*}
    lock_manager=${lock_entry#*:}
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
      lock_count=$((lock_count + 1))
      selected_manager=$lock_manager
    fi
  done

  [[ "$lock_count" -eq 1 ]] || die "Playwright browser installation requires exactly one supported lockfile."
  printf '%s\n' "$selected_manager"
}

if [[ ! -f package.json ]]; then
  printf 'Skipping Playwright browser installation: package.json is absent.\n'
  exit 0
fi

if ! has_playwright_dependency; then
  printf 'Skipping Playwright browser installation: package.json does not declare @playwright/test.\n'
  exit 0
fi

manager="$(select_package_manager)"
case "$manager" in
  pnpm) playwright=(pnpm exec playwright) ;;
  npm) playwright=(npm exec -- playwright) ;;
  yarn) playwright=(yarn playwright) ;;
  *) die "Unsupported package manager: $manager" ;;
esac

if [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
  printf 'Using caller-provided PLAYWRIGHT_BROWSERS_PATH=%s\n' "$PLAYWRIGHT_BROWSERS_PATH"
else
  printf 'Using Playwright default external browser cache.\n'
fi

printf 'Resolved Playwright version: '
"${playwright[@]}" --version

if [[ "$#" -eq 0 ]]; then
  browsers=(chromium)
else
  browsers=("$@")
fi

install_args=(install "${browsers[@]}")
if [[ "${ARKIRA_PLAYWRIGHT_HEADED:-}" != 1 ]]; then
  for browser in "${browsers[@]}"; do
    if [[ "$browser" == chromium ]]; then
      install_args+=(--only-shell)
      break
    fi
  done
fi

if [[ "$(uname -s)" == Linux ]]; then
  install_args+=(--with-deps)
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    sudo rm -f -- \
      /etc/apt/sources.list.d/google-chrome.list \
      /etc/apt/sources.list.d/google-chrome.list.save
  fi
fi

status=1
for attempt in 1 2 3; do
  printf 'Playwright browser install attempt %s of 3.\n' "$attempt"
  if "${playwright[@]}" "${install_args[@]}"; then
    status=0
  else
    status=$?
  fi
  printf 'Attempt %s of 3 exited with status %s.\n' "$attempt" "$status"
  [[ "$status" -eq 0 ]] && break
  [[ "$attempt" -eq 3 ]] || sleep 1
done

[[ "$status" -eq 0 ]] || exit "$status"
printf 'Installed Playwright browsers: %s\n' "${browsers[*]}"
