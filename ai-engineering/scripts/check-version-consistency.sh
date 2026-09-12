#!/usr/bin/env bash
# check-version-consistency.sh
#
# Asserts that the plugin version string is identical across the six
# release-coordinated files. Closes the ALS-004 / ALS-005 / ALS-006
# recurrence class where disagreeing version strings shipped silently.
#
# Sources compared:
#   1. .claude-plugin/plugin.json        -> .version
#   2. .claude-plugin/marketplace.json   -> .plugins[0].version
#   3. VERSION.md                        -> first "## vX.Y.Z" heading
#   4. README.md                         -> first "plugin-vX.Y.Z" badge token
#   5. CHANGELOG.md                      -> first released version heading
#   6. .arkira/config.json               -> .standards_version
#
# Exits 0 with a single-line OK message if all six agree.
# Exits non-zero with a tabular ERROR listing each source's reported
# version when any disagree or cannot be extracted.

set -euo pipefail

gate_mode="development"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      gate_mode="${2:-}"
      shift 2
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
case "$gate_mode" in
  development|release) ;;
  *) printf 'ERROR: mode must be development or release\n' >&2; exit 2 ;;
esac

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

plugin_json=".claude-plugin/plugin.json"
marketplace_json=".claude-plugin/marketplace.json"
version_md="VERSION.md"
readme_md="README.md"
changelog_md="CHANGELOG.md"
dogfood_json=".arkira/config.json"

for f in "$plugin_json" "$marketplace_json" "$version_md" "$readme_md" \
  "$changelog_md" "$dogfood_json"; do
  [[ -f "$f" ]] || die "expected file not found: $f"
done

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

plugin_version="$(jq -r '.version // empty' "$plugin_json")"
marketplace_version="$(jq -r '.plugins[0].version // empty' "$marketplace_json")"

if [[ -f .codex-plugin/plugin.json ]]; then
  [[ "$(jq -r '.version // empty' .codex-plugin/plugin.json)" == "$plugin_version" ]] \
    || die 'Codex and Claude plugin versions disagree'
fi

version_md_version="$(
  awk '/^## v[0-9]+\.[0-9]+\.[0-9]+/ { sub("^## v", ""); print; exit }' "$version_md"
)"

readme_version="$(
  grep -oE 'plugin-v[0-9]+\.[0-9]+\.[0-9]+' "$readme_md" \
    | head -1 \
    | sed 's/^plugin-v//'
)"
changelog_version="$(
  awk '/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ {
    gsub(/^## \[/, ""); gsub(/\].*$/, ""); print; exit
  }' "$changelog_md"
)"
dogfood_version="$(jq -r '.standards_version // empty' "$dogfood_json")"

print_table() {
  printf '  %-32s %s\n' "$plugin_json"      "${plugin_version:-<missing>}"
  printf '  %-32s %s\n' "$marketplace_json" "${marketplace_version:-<missing>}"
  printf '  %-32s %s\n' "$version_md"       "${version_md_version:-<missing>}"
  printf '  %-32s %s\n' "$readme_md"        "${readme_version:-<missing>}"
  printf '  %-32s %s\n' "$changelog_md"     "${changelog_version:-<missing>}"
  printf '  %-32s %s\n' "$dogfood_json"     "${dogfood_version:-<missing>}"
}

if [[ -z "$plugin_version" || -z "$marketplace_version" \
   || -z "$version_md_version" || -z "$readme_version" \
   || -z "$changelog_version" || -z "$dogfood_version" ]]; then
  printf 'ERROR: could not extract version from one or more sources:\n' >&2
  print_table >&2
  exit 1
fi

if ! [[ "$plugin_version" == "$marketplace_version" \
     && "$plugin_version" == "$version_md_version" \
     && "$plugin_version" == "$readme_version" \
     && "$plugin_version" == "$changelog_version" \
     && "$plugin_version" == "$dogfood_version" ]]; then
  printf 'ERROR: version sources disagree:\n' >&2
  print_table >&2
  printf '\nAlign all six sources to a single version and commit.\n' >&2
  exit 1
fi

# Publishable surfaces include plugin manifests, canonical standards, runtime
# hooks and commands, skills, workflows, governance roots, and release tooling.
release_paths=(
  .claude-plugin .codex-plugin .agents/plugins
  .gitleaks.toml .markdownlint.jsonc
  .github/SECURITY.md
  governance examples github mobile portfolio prompts react security static-web
  supabase templates theme tooling vercel
  ai-engineering commands hooks plugin-agents scripts skills
  AGENTS.md CLAUDE.md CODEX.md DEPENDENCIES.md HOW-TO-USE.md README.md
  SECURITY.md START-HERE.md VENDORED.md
)

# These are intentionally repo-only and do not trigger a plugin version bump.
# Each exclusion has a concrete ownership reason.
repo_only_exclusions=(
  ".gitignore|repository working-tree ignore rules"
  ".arkira|standards-repo dogfood configuration"
  ".claude|local repository agent settings"
  ".codebase-memory|generated local graph state"
  ".github/ISSUE_TEMPLATE|repository contribution templates"
  ".github/workflows|repository CI workflows; the published workflows are ai-engineering/github/workflows"
  ".github/scripts|repository CI implementation helpers"
  "docs|design specs and implementation plans"
  "reports|historical audit reports"
  "tests|test-only fixtures"
  "CHANGELOG.md|release history coordinated after version selection"
  "CONTRIBUTING.md|repository contribution guidance"
  "LICENSE|repository license text"
  "VERSION.md|version ledger checked separately above"
)
# Keep the explicit inventory live under shellcheck without changing behavior.
: "${repo_only_exclusions[*]}"

if [[ "$gate_mode" != "release" ]]; then
  printf 'DEVELOPMENT: publishable change comparison skipped; version bump required only in release mode.\n'
  printf 'OK: all version sources agree on %s\n' "$plugin_version"
  exit 0
fi

base_ref="${VERSION_BASE_REF:-}"
[[ -n "$base_ref" ]] || die "release mode requires explicit VERSION_BASE_REF"
git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 \
  || die "version comparison base is not a commit: $base_ref"
base_version="$(git show "$base_ref:.claude-plugin/plugin.json" 2>/dev/null \
  | jq -r '.version // empty')"
[[ -n "$base_version" ]] \
  || die "could not extract plugin version from comparison base: $base_ref"
if ! git diff --quiet "$base_ref" -- "${release_paths[@]}" \
  && [[ "$plugin_version" == "$base_version" ]]; then
  printf 'ERROR: publishable behavior changed but plugin version %s reuses the version at %s.\n' \
    "$plugin_version" "$base_ref" >&2
  exit 1
fi

printf 'OK: all version sources agree on %s\n' "$plugin_version"
