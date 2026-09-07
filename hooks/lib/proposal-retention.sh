#!/usr/bin/env bash
# Bounded retention for Arkira-generated CLAUDE.md proposal patches.
# Sourced by proposal writers and executable for background writer cleanup.
set -uo pipefail

arkira_prune_generated_proposals() {
  local prop_dir=${1:-}
  local max=${ARKIRA_PROPOSAL_MAX_GENERATED:-20}
  local ttl=${ARKIRA_PROPOSAL_TTL_DAYS:-30}

  [ -n "$prop_dir" ] && [ -d "$prop_dir" ] && [ ! -L "$prop_dir" ] || return 0
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
  [ "$max" -gt 0 ] 2>/dev/null || max=20
  [ "$ttl" -gt 0 ] 2>/dev/null || ttl=30
  command -v node >/dev/null 2>&1 || return 0

  # Delete only files produced by Arkira's two automatic proposal writers.
  # Manually named proposals remain user-owned and are never pruned here. When
  # an automatic patch is removed, remove only its exact review sidecars too so
  # accepted/rejected metadata cannot become permanent orphaned chat state.
  node - "$prop_dir" "$max" "$ttl" >/dev/null 2>&1 <<'NODE' || true
const fs = require("fs");
const path = require("path");
const [dir, maxRaw, ttlRaw] = process.argv.slice(2);
const max = Number(maxRaw);
const ttlMs = Number(ttlRaw) * 86400000;
const now = Date.now();
const generated = /^(?:ctx-.*|\d{8}T\d{6}Z-[0-9a-f]{16})\.patch$/;

try {
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) process.exit(0);
} catch { process.exit(0); }

let names = [];
try { names = fs.readdirSync(dir); } catch { process.exit(0); }
const patches = [];
for (const name of names) {
  if (!generated.test(name) || name.includes("/")) continue;
  try {
    const stat = fs.lstatSync(path.join(dir, name));
    if (stat.isFile() && !stat.isSymbolicLink()) patches.push({ name, mtime: stat.mtimeMs });
  } catch {}
}

function removeFile(name) {
  if (!name || name.includes("/")) return;
  try {
    const target = path.join(dir, name);
    const stat = fs.lstatSync(target);
    if (stat.isFile() && !stat.isSymbolicLink()) fs.unlinkSync(target);
  } catch {}
}

function removePatch(record) {
  removeFile(record.name);
  const stem = record.name.slice(0, -".patch".length);
  for (const sidecar of new Set([
    `${stem}.meta.json`, `${stem}.verdict.txt`,
    `${record.name}.meta.json`, `${record.name}.verdict.txt`,
  ])) removeFile(sidecar);
}

const survivors = [];
for (const record of patches) {
  if (now - record.mtime > ttlMs) removePatch(record);
  else survivors.push(record);
}
survivors.sort((a, b) => b.mtime - a.mtime || a.name.localeCompare(b.name));
for (const record of survivors.slice(max)) removePatch(record);
NODE
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  arkira_prune_generated_proposals "${1:-}"
fi
