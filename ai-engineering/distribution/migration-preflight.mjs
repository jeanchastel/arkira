import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { git, assertDirectory } from './public-release.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const roots = new Set(['AGENTS.md', 'CLAUDE.md', 'CODEX.md']);
const fail = message => { throw new Error(message); };
export function relative(name) {
  if (typeof name !== 'string' || !name || name.startsWith('/') || /[\\\x00-\x20\x7f]/.test(name) ||
      name.split('/').some(part => !part || part === '.' || part === '..' || part === '.git')) fail('unsafe path');
  return name;
}
export function read(root, name) {
  relative(name);
  let current = root;
  const parts = name.split('/');
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current, { throwIfNoEntry: false });
    if (!stat) return null;
    if (stat.isSymbolicLink()) fail('symlink: ' + name);
    if (index < parts.length - 1) {
      if (!stat.isDirectory()) fail('unsafe parent: ' + name);
    } else {
      if (!stat.isFile()) fail('not a regular file: ' + name);
      return { bytes: fs.readFileSync(current), mode: stat.mode & 0o7777 };
    }
  }
}
export function manifest(root) {
  const bytes = read(root, 'ai-engineering/bootstrap/lib/sync-lib.sh')?.bytes.toString();
  const body = bytes?.match(/^SYNC_CHECKS=\(\n([\s\S]*?)^\)/m)?.[1];
  if (!body) fail('missing canonical sync inventory');
  const entries = [];
  for (const line of body.split('\n')) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const match = /^\s*"([^"$\x60]+)"\s*$/.exec(line);
    if (!match) fail('sync inventory is not literal data');
    const [source, target, profile = '*', scope = 'install', extra] = match[1].split('|');
    relative(source); relative(target);
    if (extra !== undefined || !['install', 'central'].includes(scope)) fail('invalid sync inventory row');
    entries.push({ source, target, profile });
  }
  if (new Set(entries.map(e => e.target)).size !== entries.length) fail('duplicate sync target');
  return entries;
}
function managedConflicts(name, bytes, registry, conflicts) {
  const text = bytes.toString();
  const markers = text.match(/ARKIRA:MANAGED (?:START|END)/g) || [];
  const blocks = [...text.matchAll(/^<!-- ARKIRA:MANAGED START id=([A-Za-z0-9_-]+) v=(\d+) sha=([a-f0-9]{64}) -->\r?\n([\s\S]*?)^<!-- ARKIRA:MANAGED END id=\1 -->\r?$/gm)];
  if (markers.length !== blocks.length * 2) conflicts.push(name + ': malformed managed markers');
  const seen = new Set();
  for (const block of blocks) {
    const [, id, version, expected, body] = block;
    const record = registry.files[name]?.blocks?.[id];
    if (seen.has(id) || !record || record.sha !== expected || String(record.v) !== version ||
        hash(body.replace(/^\n+|\n+$/g, '')) !== expected) {
      conflicts.push(name + ': unknown or modified managed block ' + id);
    }
    seen.add(id);
  }
}

// This is an ownership report, not an apply transaction or release authorization.
// No candidate content is executed. Unknown data is never a deletion instruction.
export function migrationPreflight(repoPath, sourcePath) {
  const repo = assertDirectory(repoPath), source = assertDirectory(sourcePath);
  if (git(repo, ['rev-parse', '--show-toplevel']).toString().trim() !== repo) fail('target must be a repository root');
  const conflicts = [], retire = [], preserve = [];
  if (git(repo, ['status', '--porcelain=v1', '--untracked-files=all']).length) {
    return { ready: false, retire, preserve, conflicts: ['dirty worktree: use a separate clean checkout'] };
  }
  const config = JSON.parse(read(repo, '.arkira/config.json')?.bytes || '{}');
  const registry = JSON.parse(read(repo, '.arkira/sync-state.json')?.bytes || '{}');
  if (registry.schema !== '1' || !registry.files || typeof registry.files !== 'object' || Array.isArray(registry.files)) {
    return { ready: false, retire, preserve, conflicts: ['missing or invalid sync ownership registry'] };
  }
  const entries = manifest(source);
  const known = new Set(entries.map(entry => entry.target));
  for (const entry of entries) {
    const { source: origin, target, profile } = entry;
    if (profile !== '*' && profile && !profile.split(',').includes(config.profile || 'app')) continue;
    try {
      const installed = read(repo, target);
      if (!installed || roots.has(target)) continue;
      // Retain deployment, repository policy, and ignore files until their own
      // replacement contract is verified. This pass cannot retire them.
      if (target.startsWith('.github/') || target === '.claudeignore' || target === '.arkira/.gitignore') {
        preserve.push(target); continue;
      }
      const record = registry.files[target];
      const canonical = read(source, origin);
      if (record?.tier !== 'pristine' || record.baseline_sha !== hash(installed.bytes) ||
          !canonical || canonical.mode !== installed.mode) {
        conflicts.push(target + ': missing ownership baseline, content drift, or mode drift'); continue;
      }
      retire.push(target);
    } catch (error) { conflicts.push(target + ': ' + error.message); }
  }
  for (const name of Object.keys(registry.files)) {
    if (!known.has(name) && !roots.has(name)) conflicts.push(name + ': unknown legacy ownership mapping; preserve and review');
  }
  for (const name of roots) {
    try {
      const file = read(repo, name);
      if (file) { managedConflicts(name, file.bytes, registry, conflicts); preserve.push(name); }
    } catch (error) { conflicts.push(name + ': ' + error.message); }
  }
  return { ready: conflicts.length === 0, retire: retire.sort(), preserve: preserve.sort(), conflicts };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [, , repo, source, ...extra] = process.argv;
    if (!repo || !source || extra.length) fail('usage: migration-preflight.mjs <repo> <trusted-harness>');
    const result = migrationPreflight(repo, source);
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.ready ? 0 : 1;
  } catch (error) {
    console.error('migration preflight: ' + error.message);
    process.exitCode = 1;
  }
}
