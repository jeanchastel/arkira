import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { PUBLIC_REPOSITORY, git, verifyRelease, assertDirectory } from './public-release.mjs';

const shaPattern = /^[a-f0-9]{40}$/;
const fail = message => { throw new Error(message); };
const remote = 'https://github.com/' + PUBLIC_REPOSITORY + '.git';

function privateDirectory(directory) {
  if (!fs.existsSync(directory)) {
    const parent = path.dirname(directory);
    if (parent !== directory) privateDirectory(parent);
    fs.mkdirSync(directory, { mode: 0o700 });
  }
  assertDirectory(directory);
}

function readRecord(file) {
  const stat = fs.lstatSync(file, { throwIfNoEntry: false });
  if (!stat) return null;
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077)) fail('unsafe release state');
  return JSON.parse(fs.readFileSync(file));
}

function writeRecord(file, data) {
  if (fs.lstatSync(file, { throwIfNoEntry: false })) readRecord(file);
  const stage = file + '.' + randomUUID();
  fs.writeFileSync(stage, JSON.stringify(data) + '\n', { flag: 'wx', mode: 0o600 });
  try { fs.renameSync(stage, file); } finally { fs.rmSync(stage, { force: true }); }
}

const transport = {
  head(ref = 'stable') {
    if (ref !== 'stable') fail('unsupported release channel');
    const result = git(os.tmpdir(), ['ls-remote', '--refs', remote, 'refs/tags/stable']).toString().trim();
    const match = /^([a-f0-9]{40})\s+refs\/tags\/stable$/.exec(result);
    // An online response without the approved tag is not an offline condition.
    return match ? match[1] : '';
  },
  fetch(sha, output) {
    git(path.dirname(output), ['init', '--quiet', output]);
    git(output, ['fetch', '--quiet', '--no-tags', '--depth=1', remote, sha]);
    const actual = git(output, ['rev-parse', 'FETCH_HEAD^{commit}']).toString().trim();
    if (actual !== sha) fail('fetched release SHA mismatch');
    git(output, ['-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', sha]);
    // Only the verified exported payload goes into the download cache.
    fs.rmSync(path.join(output, '.git'), { recursive: true });
    return actual;
  },
};

function locked(state, run) {
  const lock = path.join(state, 'resolve.lock');
  try {
    fs.writeFileSync(lock, JSON.stringify({ pid: process.pid }), { flag: 'wx', mode: 0o600 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const stat = fs.lstatSync(lock);
    const owner = readRecord(lock);
    if (!Number.isInteger(owner?.pid) || owner.pid < 1) fail('invalid release resolver lock');
    let alive = true;
    try { process.kill(owner.pid, 0); } catch (probe) {
      if (probe.code === 'ESRCH') alive = false;
    }
    if (alive) fail('release resolution is already running in process ' + owner.pid);
    if (fs.lstatSync(lock).ino !== stat.ino) fail('release resolver lock changed');
    fs.unlinkSync(lock);
    fs.writeFileSync(lock, JSON.stringify({ pid: process.pid }), { flag: 'wx', mode: 0o600 });
  }
  try { return run(); } finally { fs.unlinkSync(lock); }
}

export function resolveRelease(options = {}, source = transport) {
  const runtime = process.env.ARKIRA_RUNTIME_HOME ||
    path.join(process.env.ARKIRA_ROLE_HOME || os.homedir(), '.arkira', 'runtime');
  const state = path.resolve(options.state || path.join(runtime, 'public'));
  const session = options.session || '';
  if (session && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(session)) fail('invalid release session');
  if (Object.hasOwn(options, 'pin')) fail('public pin selection is unsupported');
  if (options.goalSha && !shaPattern.test(options.goalSha)) fail('goal must name an exact public release SHA');
  privateDirectory(state);
  if (fs.statSync(state).mode & 0o077) fail('release state directory must be private');
  return locked(state, () => {
    const releases = path.join(state, 'releases');
    const sessions = path.join(state, 'sessions');
    privateDirectory(releases); privateDirectory(sessions);
    const lastPath = path.join(state, 'last.json');
    const last = readRecord(lastPath);
    const bindingPath = session ? path.join(sessions, session + '.json') : '';
    const binding = bindingPath ? readRecord(bindingPath) : null;
    if (binding && options.goalSha && binding.sha !== options.goalSha) {
      fail('session release conflicts with the active goal; use a new session');
    }
    let sha = binding?.sha || options.goalSha;
    let offline = false;
    if (!binding || options.onlineRequired) {
      let current;
      try {
        current = source.head();
      } catch (error) {
        if (options.onlineRequired) fail('online release verification required: ' + error.message);
        offline = true;
        if (!sha) sha = last?.sha;
      }
      if (!offline) {
        if (!shaPattern.test(current)) fail('invalid channel SHA');
        if (!sha) sha = current;
      }
    }
    if (!shaPattern.test(sha || '')) fail('no verified release is available');
    const root = path.join(releases, sha);
    let metadata;
    if (!fs.lstatSync(root, { throwIfNoEntry: false })) {
      if (offline) fail('no verified cached release is available');
      const stage = path.join(releases, '.fetch-' + randomUUID());
      try {
        const fetched = source.fetch(sha, stage);
        if (fetched !== sha) fail('fetched release SHA mismatch');
        metadata = verifyRelease(stage);
        fs.renameSync(stage, root);
      } finally {
        fs.rmSync(stage, { recursive: true, force: true });
      }
    }
    metadata = verifyRelease(root);
    if (binding && (binding.digest !== metadata.content_digest || binding.version !== metadata.version)) {
      fail('bound release content mismatch');
    }
    if (last?.sha === sha && last.digest !== metadata.content_digest) fail('cached release content mismatch');
    let notice = '';
    const major = Number(metadata.version.split('.')[0]);
    const previousMajor = last ? Number(last.version?.split('.')[0]) : major;
    const noticedPath = path.join(state, 'notices.json');
    const noticed = readRecord(noticedPath) || { majors: [] };
    if (!Array.isArray(noticed.majors)) fail('invalid release notice state');
    if (!binding && !options.goalSha && major > previousMajor && !noticed.majors.includes(major)) {
      notice = 'Arkira major update ' + metadata.version +
        ': https://github.com/' + PUBLIC_REPOSITORY + '/releases/tag/v' + metadata.version +
        '. Existing repository setup remains supported.';
      writeRecord(noticedPath, { majors: [...noticed.majors, major] });
    }
    const record = { sha, digest: metadata.content_digest, version: metadata.version };
    if (!binding) {
      if (bindingPath) writeRecord(bindingPath, record);
      if (!offline && !options.goalSha) writeRecord(lastPath, record);
    }
    return { root, sha, version: metadata.version, digest: metadata.content_digest,
      channel: 'stable', session, offline, notice };
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = {};
    const args = process.argv.slice(2);
    while (args.length) {
      const arg = args.shift();
      if (arg === '--online') options.onlineRequired = true;
      else if (arg === '--session') options.session = args.shift();
      else if (arg === '--goal-sha') options.goalSha = args.shift();
      else fail('usage: release-channel.mjs [--online] [--session ID] [--goal-sha SHA]');
      if ((arg === '--session' && !options.session) ||
          (arg === '--goal-sha' && !options.goalSha)) fail('missing argument');
    }
    console.log(JSON.stringify(resolveRelease(options)));
  } catch (error) {
    console.error('release channel: ' + error.message);
    process.exitCode = 1;
  }
}
