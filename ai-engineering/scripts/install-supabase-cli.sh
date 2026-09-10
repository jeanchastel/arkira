#!/usr/bin/env bash
set -euo pipefail

version=2.109.1

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$#" -eq 2 && "$1" == --prefix ]] \
  || die 'usage: install-supabase-cli.sh --prefix <absolute-path>'
prefix=$2
[[ "$prefix" == /* && "$prefix" != */ && "$(basename -- "$prefix")" == "$version" \
  && "$(basename -- "$(dirname -- "$prefix")")" == arkira-supabase ]] \
  || die 'Supabase CLI prefix must be a narrow absolute path'
cache_root=$(dirname -- "$prefix")
if [[ -e "$cache_root" || -L "$cache_root" ]]; then
  [[ -d "$cache_root" && ! -L "$cache_root" ]] \
    || die 'Supabase CLI cache root is not a regular directory'
fi
if [[ -e "$prefix" || -L "$prefix" ]]; then
  [[ -d "$prefix" && ! -L "$prefix" ]] || die 'Supabase CLI prefix is not a regular directory'
fi

binary="$prefix/node_modules/.bin/supabase"
if [[ -x "$binary" ]] && installed_version="$("$binary" --version 2>/dev/null)" \
  && [[ "$installed_version" == "$version" ]]; then
  printf 'Using cached Supabase CLI %s from %s\n' "$version" "$prefix"
else
  rm -rf -- "$prefix"
  mkdir -p "$prefix"
  npm install --prefix "$prefix" --no-audit --no-fund "supabase@$version"
  [[ -x "$binary" ]] || die 'Supabase CLI installation did not produce an executable'
  installed_version="$("$binary" --version)" \
    || die 'could not determine installed Supabase CLI version'
  [[ "$installed_version" == "$version" ]] \
    || die "Supabase CLI version $installed_version does not match $version"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$prefix/node_modules/.bin" >> "$GITHUB_PATH"
fi
printf '%s\n' "$prefix/node_modules/.bin"
