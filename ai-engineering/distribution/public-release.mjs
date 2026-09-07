import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const PUBLIC_REPOSITORY = 'jeanchastel/arkira';
const INVENTORY = 'ai-engineering/distribution/public-files.json';
const MANIFEST = 'release.json';
const shaPattern = /^[a-f0-9]{40}$/;
const digestPattern = /^[a-f0-9]{64}$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };

export function git(repo, args, options = {}) {
  return execFileSync('git', ['-C', repo, ...args], {
    timeout: 30000, maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' },
    ...options,
  });
}

export function safePath(value) {
  if (typeof value !== 'string' || !value || value.includes('\\') ||
      /[\x00-\x20\x7f]/.test(value) || value.startsWith('/') ||
      value.split('/').some(p => p === '.' || p === '..' || !p)) {
    fail('unsafe public path');
  }
  if (/(^|\/)(\.git|\.arkira|\.claude|node_modules|reports|portfolio|logs|cache|tmp)(\/|$)/.test(value) ||
      /(^|\/)(\.env(?:\..*)?|installed_plugins\.json)$/.test(value)) {
    fail('private path cannot be exported: ' + value);
  }
  return value;
}

function publicContent(bytes, name) {
  const text = bytes.toString('utf8');
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(text) ||
      /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})/.test(text) ||
      /\/(?:Users|home)\/[A-Za-z0-9._-]+(?:\/|\b)/.test(text)) {
    fail('private content detected in ' + name);
  }
}

function publicRegions(bytes) {
  const text = bytes.toString('utf8');
  const markers = [...text.matchAll(/^<!-- ARKIRA:PRIVATE (START|END) -->\r?$/gm)];
  if ((text.match(/^<!-- ARKIRA:PRIVATE/gm) || []).length !== markers.length) fail('malformed private region marker');
  let start = null, cursor = 0, result = '';
  for (const marker of markers) {
    if (marker[1] === 'START') {
      if (start !== null) fail('nested private region');
      result += text.slice(cursor, marker.index);
      start = marker.index;
    } else {
      if (start === null) fail('unmatched private region end');
      cursor = marker.index + marker[0].length;
      if (text[cursor] === '\n') cursor++;
      start = null;
    }
  }
  if (start !== null) fail('unterminated private region');
  return markers.length ? Buffer.from(result + text.slice(cursor)) : bytes;
}

function commitBlob(repo, sha, name) {
  safePath(name);
  const row = git(repo, ['ls-tree', '-z', sha, '--', name]).toString();
  const match = /^(100644|100755) blob ([a-f0-9]{40})\t([^\0]+)\0$/.exec(row);
  if (!match || match[3] !== name) fail('missing regular committed file: ' + name);
  return {
    bytes: git(repo, ['cat-file', 'blob', match[2]]),
    mode: match[1] === '100755' ? '755' : '644',
  };
}

export function assertDirectory(value) {
  const absolute = path.resolve(value);
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split('/').filter(Boolean)) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    if (process.platform === 'darwin' && stat.isSymbolicLink() && stat.uid === 0 &&
        ['/var', '/tmp'].includes(current) && fs.realpathSync(current) === '/private' + current) continue;
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail('unsafe directory: ' + current);
  }
  // Git reports physical roots. Normalize only after rejecting untrusted links;
  // macOS's root-owned /var and /tmp aliases are the sole permitted exception.
  return fs.realpathSync(absolute);
}

export function exportRelease(repo, sha, destination) {
  if (!shaPattern.test(sha) ||
      git(repo, ['rev-parse', '--verify', sha + '^{commit}']).toString().trim() !== sha) {
    fail('source must be an exact commit SHA');
  }
  const output = path.resolve(destination);
  assertDirectory(path.dirname(output));
  if (fs.existsSync(output) || fs.lstatSync(output, { throwIfNoEntry: false })) {
    fail('output already exists');
  }
  const inventory = JSON.parse(commitBlob(repo, sha, INVENTORY).bytes);
  if (inventory.schema_version !== 1 || inventory.repository !== PUBLIC_REPOSITORY ||
      !Array.isArray(inventory.files) || !inventory.files.length ||
      !Array.isArray(inventory.required)) fail('invalid public inventory');
  const payload = new Map();
  for (const entry of inventory.files) {
    const target = safePath(entry.target);
    if (target === MANIFEST || payload.has(target)) fail('duplicate/reserved target: ' + target);
    const blob = commitBlob(repo, sha, entry.source);
    blob.bytes = publicRegions(blob.bytes);
    publicContent(blob.bytes, entry.source);
    if (['.claude-plugin/plugin.json', '.codex-plugin/plugin.json'].includes(target)) {
      const metadata = JSON.parse(blob.bytes);
      metadata.homepage = metadata.repository = 'https://github.com/' + PUBLIC_REPOSITORY;
      if (metadata.interface) metadata.interface.websiteURL = metadata.homepage;
      blob.bytes = Buffer.from(JSON.stringify(metadata, null, 2) + '\n');
    }
    payload.set(target, blob);
  }
  if (inventory.licenses !== undefined && !Array.isArray(inventory.licenses)) fail('invalid license inventory');
  for (const license of inventory.licenses || []) {
    if (!Array.isArray(license.paths) || !license.paths.length ||
        !payload.has(safePath(license.notice))) fail('missing license notice');
    for (const prefix of license.paths) {
      safePath(prefix.replace(/\/$/, ''));
      if (![...payload.keys()].some(name => name === prefix || name.startsWith(prefix))) {
        fail('license inventory references absent component: ' + prefix);
      }
    }
  }
  for (const required of inventory.required) {
    if (!payload.has(safePath(required))) fail('missing public dependency: ' + required);
  }
  for (const required of ['LICENSE', '.claude-plugin/plugin.json', 'bin/arkira', 'README.md']) {
    if (!payload.has(required)) fail('missing public dependency: ' + required);
  }
  // Native relative JS imports must remain inside the explicit exported inventory.
  for (const [name, blob] of payload) {
    if (!name.endsWith('.mjs')) continue;
    for (const match of blob.bytes.toString().matchAll(/(?:from\s*|import\s*\()(['"])(\.[^'"]+)\1/g)) {
      const dependency = path.posix.normalize(path.posix.join(path.posix.dirname(name), match[2]));
      if (!payload.has(safePath(dependency))) fail('missing public dependency: ' + dependency);
    }
  }
  const plugin = JSON.parse(payload.get('.claude-plugin/plugin.json').bytes);
  if (plugin.name !== 'arkira' || !versionPattern.test(plugin.version)) fail('invalid plugin identity');
  const files = [...payload.entries()].sort(([a], [b]) => a.localeCompare(b, 'en')).map(
    ([name, { bytes, mode }]) => ({ path: name, mode, sha256: digest(bytes) }));
  const manifest = {
    schema_version: 1, repository: PUBLIC_REPOSITORY,
    source_sha: sha, version: plugin.version, files,
    content_digest: digest(JSON.stringify(files)),
  };
  const stage = fs.mkdtempSync(path.join(path.dirname(output), '.arkira-export-'));
  try {
    for (const [name, { bytes, mode }] of payload) {
      const file = path.join(stage, name);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, bytes, { flag: 'wx', mode: Number.parseInt(mode, 8) });
      fs.chmodSync(file, Number.parseInt(mode, 8));
    }
    fs.writeFileSync(path.join(stage, MANIFEST), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx' });
    verifyRelease(stage);
    if (fs.lstatSync(output, { throwIfNoEntry: false })) fail('output already exists');
    fs.renameSync(stage, output);
  } finally {
    fs.rmSync(stage, { recursive: true, force: true });
  }
  return manifest;
}

export function verifyRelease(directory) {
  const root = assertDirectory(directory);
  const manifestPath = path.join(root, MANIFEST);
  const stat = fs.lstatSync(manifestPath);
  if (!stat.isFile() || stat.isSymbolicLink()) fail('invalid release manifest');
  const manifest = JSON.parse(fs.readFileSync(manifestPath));
  if (manifest.repository !== PUBLIC_REPOSITORY) fail('unexpected release repository');
  if (manifest.schema_version !== 1 || !shaPattern.test(manifest.source_sha) ||
      !versionPattern.test(manifest.version) || !Array.isArray(manifest.files) ||
      !manifest.files.length || !digestPattern.test(manifest.content_digest) ||
      digest(JSON.stringify(manifest.files)) !== manifest.content_digest) fail('invalid release manifest');
  const expected = new Set([MANIFEST]);
  for (const file of manifest.files) {
    safePath(file.path);
    if (expected.has(file.path) || !['644', '755'].includes(file.mode) ||
        !digestPattern.test(file.sha256)) fail('invalid release file entry');
    expected.add(file.path);
  }
  const found = new Set();
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const absolute = path.join(dir, entry.name);
      const relative = path.relative(root, absolute).split(path.sep).join('/');
      // A fetched distribution can carry Git metadata, never exported payload.
      if (relative === '.git' && entry.isDirectory()) continue;
      if (entry.isSymbolicLink()) fail('release contains a symlink: ' + relative);
      if (entry.isDirectory()) { walk(absolute); continue; }
      if (!entry.isFile() || !expected.has(relative)) fail('unexpected release file: ' + relative);
      found.add(relative);
    }
  }
  walk(root);
  if (found.size !== expected.size) fail('release files are missing');
  for (const file of manifest.files) {
    const absolute = path.join(root, file.path);
    if ((fs.statSync(absolute).mode & 0o7777).toString(8) !== file.mode ||
        digest(fs.readFileSync(absolute)) !== file.sha256) fail('release file mismatch: ' + file.path);
  }
  for (const required of ['LICENSE', '.claude-plugin/plugin.json', 'bin/arkira', 'README.md']) {
    if (!found.has(required)) fail('missing public dependency: ' + required);
  }
  const plugin = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin/plugin.json')));
  if (plugin.name !== 'arkira' || plugin.version !== manifest.version) fail('release identity mismatch');
  return manifest;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, ...args] = process.argv.slice(2);
    let result;
    if (command === 'export' && args.length === 3) result = exportRelease(...args);
    else if (command === 'verify' && args.length === 1) result = verifyRelease(...args);
    else fail('usage: public-release.mjs export <repo> <exact-sha> <new-output> | verify <directory>');
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error('public release: ' + error.message);
    process.exitCode = 1;
  }
}
