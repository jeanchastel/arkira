import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { git, assertDirectory } from './public-release.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const roots = new Set(['AGENTS.md', 'CLAUDE.md', 'CODEX.md']);
const centralContext = '## Shared harness\n\nRun `arkira context <this-repository>` before acting. Read its verified central instructions.\n' +
  'Reuse the returned session ID for all Arkira commands and delegated work.\n' +
  'Project-owned instructions in this file and child AGENTS.md files remain in force.';
const legacyProviderOverlays = new Map([
  ['QWEN.md', { heading: '# Qwen Code via OpenRouter Context', id: 'tool-role-pointer', version: '1',
    body_sha: 'ed75012ed139a8dccbe63192e5e7d829754b1a10328ae4dcea4d13269ae02bbe' }],
]);
const legacyPristineControls = new Map([
  ['ai-engineering/adapters/qwen-code.json', { sha: '0b240d5059e9612e7bcb6068662fd9e153f64ff01a3666ecb613e071688515c0', modes: new Set([0o644]) }],
  ['AGENTS/model-selection-standard.md', { sha: '82c49cbd4384bd7976d4c7408dc076602ad807900eb2a30ffcb42f0bbe93a265', modes: new Set([0o644]) }],
  ['AGENTS/agent-swarm-standard.md', { sha: '0af83aa34b1b6db5df29a851e4ad489535171c8b87cc15350cdf9f5014dcce47', modes: new Set([0o644]) }],
  ['AGENTS/self-improving-standard.md', { sha: 'b1ab68bc0f718ecb5783f936d54a0deca478890a46b61c0a36d810f91da57b55', modes: new Set([0o644]) }],
  ['scripts/run-all-tests.sh', { sha: '8e27a06566050ef12437ebac63f4f942edeb19f0b94df6672f1865030aa3dd48', modes: new Set([0o755]) }],
  ['ai-engineering/bootstrap/lib/file-safety.sh', { sha: 'af3378cc79d7c50f91077d7a2f43c57e4539be9fc497745183aebdcacf229e50', modes: new Set([0o644, 0o755]) }],
]);
const legacyPreservedControls = new Map([
  ['scripts/install-dash-guard.sh', new Map([
    ['bf5b2738d442bd06fe07e2e0311539b8c96c91407c00690f46d997ff3bfc8795', new Set([0o644, 0o755])],
    ['c735fea941f5459730d384310ce1c0dd93cbf2fba0484a280421bbc251e60c22', new Set([0o644])],
  ])],
  ['scripts/produce-review-evidence.sh', new Map([
    ['ce3377c3dc4ec97667a897e186bb68a92d3b3e0d52e6010b11cf2a117ae16da0', new Set([0o644])],
  ])],
  ['scripts/build-review-artifact.sh', new Map([
    ['fadc7d7faa27de3e24794553155eaa21dc0bf78c832121a894e532019aa17336', new Set([0o644])],
  ])],
]);
export function legacyControlBaselines() {
  return {
    retire: [...legacyPristineControls].map(([name, { sha, modes }]) => ({ name, sha, modes: [...modes] })),
    preserve: [...legacyPreservedControls].flatMap(([name, hashes]) =>
      [...hashes].map(([sha, modes]) => ({ name, sha, modes: [...modes] }))),
  };
}
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
    const knownCentralPointer = name === 'AGENTS.md' && id === 'central-context' && version === '1' &&
      expected === hash(centralContext) && body.replace(/^\n+|\n+$/g, '') === centralContext;
    if (seen.has(id) || (!knownCentralPointer && (!record || record.sha !== expected || String(record.v) !== version ||
        hash(body.replace(/^\n+|\n+$/g, '')) !== expected))) {
      conflicts.push(name + ': unknown or modified managed block ' + id);
    }
    seen.add(id);
  }
}

function legacyOverlayIsClean(name, bytes, registry, conflicts) {
  const definition = legacyProviderOverlays.get(name);
  if (!definition) return false;
  const before = conflicts.length;
  const text = bytes.toString();
  managedConflicts(name, bytes, registry, conflicts);
  const blocks = [...text.matchAll(/^<!-- ARKIRA:MANAGED START id=([A-Za-z0-9_-]+) v=(\d+) sha=([a-f0-9]{64}) -->\r?\n([\s\S]*?)^<!-- ARKIRA:MANAGED END id=\1 -->\r?$/gm)];
  if (blocks.length !== 1 || blocks[0][1] !== definition.id || blocks[0][2] !== definition.version ||
      blocks[0][3] !== definition.body_sha ||
      text.replace(/^<!-- ARKIRA:MANAGED START id=[A-Za-z0-9_-]+ v=\d+ sha=[a-f0-9]{64} -->\r?\n[\s\S]*?^<!-- ARKIRA:MANAGED END id=[A-Za-z0-9_-]+ -->\r?\n?/gm, '').trim() !== definition.heading) {
    conflicts.push(name + ': modified legacy provider overlay');
  }
  return conflicts.length === before;
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
      const record = registry.files[target];
      const digest = hash(installed.bytes);
      const pristine = legacyPristineControls.get(target);
      if (pristine?.sha === digest && record?.tier === 'pristine' && record.baseline_sha === digest) {
        if (pristine.modes.has(installed.mode)) retire.push(target);
        else conflicts.push(target + ': legacy control mode drift');
        continue;
      }
      const preservedModes = legacyPreservedControls.get(target)?.get(digest);
      if (preservedModes && record?.tier === 'pristine' && record.baseline_sha === digest) {
        if (preservedModes.has(installed.mode)) preserve.push(target);
        else conflicts.push(target + ': legacy control mode drift');
        continue;
      }
      // Retain deployment, repository policy, and ignore files until their own
      // replacement contract is verified. This pass cannot retire them.
      if (target.startsWith('.github/') || target === '.claudeignore' || target === '.arkira/.gitignore') {
        preserve.push(target); continue;
      }
      const canonical = read(source, origin);
      if (record?.tier !== 'pristine' || record.baseline_sha !== digest ||
          !canonical || canonical.mode !== installed.mode) {
        conflicts.push(target + ': missing ownership baseline, content drift, or mode drift'); continue;
      }
      retire.push(target);
    } catch (error) { conflicts.push(target + ': ' + error.message); }
  }
  for (const name of Object.keys(registry.files)) {
    if (known.has(name) || roots.has(name)) continue;
    try {
      relative(name);
      const installed = read(repo, name);
      if (!installed) continue;
      // Delivery and repository-policy workflows are outside the central
      // migration replacement contract. Retain registered legacy workflows
      // rather than treating their absence from the current sync manifest as
      // a deletion instruction.
      if (name.startsWith('.github/workflows/')) { preserve.push(name); continue; }
      const record = registry.files[name];
      const digest = hash(installed.bytes);
      const pristine = legacyPristineControls.get(name);
      if (pristine?.sha === digest && pristine.modes.has(installed.mode) && record?.tier === 'pristine' &&
          record.baseline_sha === digest) {
        retire.push(name); continue;
      }
      if (pristine?.sha === digest && record?.tier === 'pristine' && record.baseline_sha === digest) {
        conflicts.push(name + ': legacy control mode drift'); continue;
      }
      const preservedModes = legacyPreservedControls.get(name)?.get(digest);
      if (preservedModes?.has(installed.mode) && record?.tier === 'pristine' && record.baseline_sha === digest) {
        preserve.push(name); continue;
      }
      if (preservedModes && record?.tier === 'pristine' && record.baseline_sha === digest) {
        conflicts.push(name + ': legacy control mode drift'); continue;
      }
      if (legacyProviderOverlays.has(name) && legacyOverlayIsClean(name, installed.bytes, registry, conflicts)) {
        retire.push(name); continue;
      }
      conflicts.push(name + ': unknown legacy ownership mapping; preserve and review');
    } catch (error) { conflicts.push(name + ': ' + error.message); }
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
