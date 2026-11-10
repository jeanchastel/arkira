import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { git, assertDirectory, PUBLIC_REPOSITORY, verifyRelease } from './public-release.mjs';
import { resolveRelease } from './release-channel.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw Error(message); };
function relative(name) {
  if (typeof name !== 'string' || !name || name.startsWith('/') || /[\\\x00-\x20\x7f]/.test(name) ||
      name.split('/').some(part => !part || part === '.' || part === '..' || part === '.git')) fail('unsafe path');
  return name;
}
function read(root, name) {
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
function manifest(root) {
  const bytes = read(root, 'ai-engineering/bootstrap/sync-checks.json')?.bytes.toString();
  if (!bytes) fail('missing canonical sync inventory');
  let rows;
  try { rows = JSON.parse(bytes); } catch { fail('sync inventory is not literal data'); }
  if (!Array.isArray(rows) || !rows.length) fail('missing canonical sync inventory');
  const entries = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object' || Array.isArray(row) ||
        Object.keys(row).sort().join(',') !== 'profile,scope,source,target' ||
        Object.values(row).some(value => typeof value !== 'string' || /[|"$`\r\n]/.test(value))) {
      fail('sync inventory is not literal data');
    }
    const { source, target, profile, scope } = row;
    relative(source); relative(target);
    if (!['install', 'central'].includes(scope)) fail('invalid sync inventory row');
    entries.push({ source, target, profile });
  }
  if (new Set(entries.map(e => e.target)).size !== entries.length) fail('duplicate sync target');
  return entries;
}
const encode = file => file ? { bytes: file.bytes.toString('base64'), mode: file.mode } : null;
const json = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
const context = '## Shared harness\n\nRun `arkira context <this-repository>` before acting. Read its verified central instructions.\nReuse the returned session ID for all Arkira commands and delegated work.\nProject-owned instructions in this file and child AGENTS.md files remain in force.\n';
const pointer = '<!-- ARKIRA:MANAGED START id=central-context v=1 sha=' + hash(context.trim()) +
  ' -->\n' + context + '<!-- ARKIRA:MANAGED END id=central-context -->\n';
const ciPath = '.github/workflows/arkira-ci.yml';
const deliveryGuardPath = '.github/workflows/arkira-auto-merge-guard.yml';
const deliveryGuardSourcePath = 'ai-engineering/github/workflows/arkira-auto-merge-guard.yml';
const ciSupportPath = '.github/workflows/arkira-release-candidate.yml';
const validationFixtureEnvironment = {
  NEXT_PUBLIC_SUPABASE_URL: 'https://example.supabase.co',
  NEXT_PUBLIC_SUPABASE_ANON_KEY: 'anon-key-fixture',
  NEXT_PUBLIC_APP_URL: 'https://example.test',
  SUPABASE_SERVICE_ROLE_KEY: 'service-role-key-fixture',
};

// The stable tag floats, so a template call to it leaves a downstream required
// check free to change without any downstream review. Migration writes the exact
// release SHA it already resolved and verified; comparisons unpin first so a
// pinned repository still matches the canonical template.
const channelRef = /(\/(?:\.github\/workflows\/[^/@\s]+\.yml|actions\/[^/@\s]+))@stable # /g;
const unpinChannel = text => text.replace(
  /(\/(?:\.github\/workflows\/[^/@\s]+\.yml|actions\/[^/@\s]+))@[0-9a-f]{40} # v[^ ]+ /g, '$1@stable # ');
function pinChannel(text, release) {
  if (!/^[0-9a-f]{40}$/.test(release.sha || '') ||
      !/^\d+\.\d+\.\d+$/.test(release.version || '')) fail('invalid release pin');
  const pinned = text.replace(channelRef, '$1@' + release.sha + ' # v' + release.version + ' ');
  if (pinned === text) fail('central workflow template has no pinnable channel reference');
  return pinned;
}

function callerWithValidationFixture(caller, fixture) {
  const marker = '    uses: jeanchastel/arkira/.github/workflows/validate.yml@stable # approved-channel\n';
  const markerIndex = caller.indexOf(marker);
  if (markerIndex < 0) fail('central CI caller is missing its stable validator');
  const jobHeaders = [...caller.matchAll(/^  [a-zA-Z0-9_-]+:\s*$/gm)];
  let jobStart = -1, jobEnd = caller.length;
  for (const header of jobHeaders) {
    if (header.index < markerIndex) jobStart = header.index;
    else if (header.index > markerIndex) { jobEnd = header.index; break; }
  }
  const withBlocks = jobStart < 0 ? [] :
    [...caller.slice(jobStart, jobEnd).matchAll(/^    with:\n/gm)];
  if (withBlocks.length !== 1) fail('central CI caller stable validator has no unambiguous with block');
  const insertAt = jobStart + withBlocks[0].index + withBlocks[0][0].length;
  return caller.slice(0, insertAt) + "      validation_fixture_environment: '" +
    JSON.stringify(fixture).replace(/'/g, "''") + "'\n" + caller.slice(insertAt);
}

// Pure planning against a clean accepted checkout. No scripts from the consumer
// execute. apply must resolve and verify a public release before using this plan.
export function planMigration(repoPath, sourcePath, release = null) {
  const repo = assertDirectory(repoPath), source = assertDirectory(sourcePath);
  if (git(repo, ['rev-parse', '--show-toplevel']).toString().trim() !== repo) fail('target must be a repository root');
  if (git(repo, ['status', '--porcelain=v1', '--untracked-files=all']).length) fail('dirty worktree');
  const config = JSON.parse(read(repo, '.arkira/config.json')?.bytes || '{}');
  const central = config.harness?.repository === PUBLIC_REPOSITORY && config.harness.channel === 'stable';
  const fresh = !read(repo, '.arkira/config.json') && !read(repo, '.arkira/sync-state.json');
  if (!central && !fresh) fail('only a central or fresh repository can migrate; legacy installed snapshots are retired');
  if (fresh) {
    for (const entry of manifest(source)) {
      if (!['AGENTS.md', 'CLAUDE.md', 'CODEX.md'].includes(entry.target) && read(repo, entry.target)) {
        fail('unowned control collision: ' + entry.target);
      }
    }
    for (const name of ['AGENTS.md', 'CLAUDE.md', 'CODEX.md']) {
      if (read(repo, name)?.bytes.toString().includes('ARKIRA:MANAGED')) fail('missing managed ownership: ' + name);
    }
  }
  const changes = [];
  const change = (name, bytes, mode = 0o644) => {
    const before = read(repo, name);
    const after = bytes === null ? null : { bytes: Buffer.from(bytes), mode: before?.mode ?? mode };
    if (before && after && before.bytes.equals(after.bytes) && before.mode === after.mode) return;
    if (!before && !after) return;
    changes.push({ path: name, before: encode(before), after: encode(after) });
  };
  // Without a resolved release there is nothing to pin to, so preview keeps an
  // already-pinned file as it stands instead of reporting a rollback to @stable.
  const changeChannel = (name, text) => {
    const before = read(repo, name);
    change(name, release ? pinChannel(text, release)
      : before && unpinChannel(before.bytes.toString()) === text ? before.bytes : text);
  };
  const ci = read(repo, ciPath);
  const ciCanonical = ci && unpinChannel(ci.bytes.toString());
  const template = read(source, 'ai-engineering/distribution/product-ci.yml');
  if (!template) fail('central CI template is missing');
  const caller = template.bytes.toString();
  const fixtureCaller = callerWithValidationFixture(caller, validationFixtureEnvironment);
  const ciSupportTemplate = read(source, 'ai-engineering/distribution/product-release-candidate.yml');
  if (!ciSupportTemplate) fail('central CI support template is missing');
  const deliveryGuardTemplate = read(source, deliveryGuardSourcePath);
  if (!deliveryGuardTemplate) fail('central delivery authorization workflow is missing');
  const deliveryGuard = read(repo, deliveryGuardPath);
  if (deliveryGuard && (deliveryGuard.mode !== deliveryGuardTemplate.mode ||
      !deliveryGuard.bytes.equals(deliveryGuardTemplate.bytes))) {
    fail('delivery authorization workflow ownership or drift conflict: ' + deliveryGuardPath);
  }
  const ciSupport = read(repo, ciSupportPath);
  if (ciSupport && (unpinChannel(ciSupport.bytes.toString()) !== ciSupportTemplate.bytes.toString() ||
      ciSupport.mode !== 0o644)) {
    fail('managed CI support ownership or drift conflict: ' + ciSupportPath);
  }
  let agents = read(repo, 'AGENTS.md')?.bytes.toString() || '';
  if (central) {
    const expected = ciCanonical;
    if (!ci || ![caller, fixtureCaller].includes(expected) ||
        ci.mode !== 0o644 || !agents.includes(pointer)) {
      fail('central context or CI drift; preserve and review');
    }
  }
  if (!central) {
    for (const overlay of ['CLAUDE.md', 'CODEX.md']) {
      const before = read(repo, overlay);
      if (before) {
        const outside = before.bytes.toString();
        // Only the known generated heading is disposable. Every other outside
        // byte is preserved in the shared project-owned area before replacement.
        if (!/^# (Claude Code|Codex CLI) Context\r?\n\s*$/.test(outside) && outside) {
          agents += '\n## Preserved ' + overlay + ' context\n\n' + outside;
        }
      }
      change(overlay, 'READ FIRST: `AGENTS.md` is the shared repository context.\nFollow its central harness entrypoint and project-owned instructions.\n');
    }
    change('AGENTS.md', agents + '\n' + pointer);
  }
  // Drop obsolete installed snapshot provenance, not project preferences.
  const preferences = { ...config.harness };
  delete preferences.pin; delete preferences.digest;
  config.harness = { ...preferences, channel: 'stable', repository: PUBLIC_REPOSITORY };
  // Seed transform scope once so `arkira transform` works after the repin
  // merges. An explicit list, including [], is the project's choice.
  if (!Object.hasOwn(config.authoring || {}, 'transform_paths') && read(repo, 'package.json')) {
    const lockfiles = ['pnpm-lock.yaml', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'bun.lock', 'bun.lockb'];
    config.authoring = { ...config.authoring,
      transform_paths: ['package.json', ...lockfiles.filter(name => read(repo, name))] };
  }
  change('.arkira/config.json', json(config), 0o600);
  changeChannel(ciPath, central && ciCanonical === fixtureCaller ? fixtureCaller : caller);
  changeChannel(ciSupportPath, ciSupportTemplate.bytes.toString());
  change(deliveryGuardPath, deliveryGuardTemplate.bytes, deliveryGuardTemplate.mode);
  return { schema_version: 1, ready: true, repo,
    head: git(repo, ['rev-parse', 'HEAD']).toString().trim(),
    selection: config.harness, changes };
}

function validatePlan(plan) {
  if (plan.schema_version !== 1 || !Array.isArray(plan.changes) ||
      !/^[a-f0-9]{40}$/.test(plan.head)) fail('invalid migration plan');
  const repo = assertDirectory(plan.repo);
  if (git(repo, ['rev-parse', '--show-toplevel']).toString().trim() !== repo ||
      git(repo, ['rev-parse', 'HEAD']).toString().trim() !== plan.head) fail('repository HEAD changed');
  const seen = new Set();
  for (const change of plan.changes) {
    relative(change.path);
    if (seen.has(change.path)) fail('duplicate migration target');
    seen.add(change.path);
    for (const file of [change.before, change.after]) {
      if (file !== null && (!file || typeof file.bytes !== 'string' ||
          Buffer.from(file.bytes, 'base64').toString('base64') !== file.bytes ||
          !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o777)) fail('invalid migration file');
    }
    const current = encode(read(repo, change.path));
    if (JSON.stringify(current) !== JSON.stringify(change.before)) fail('migration snapshot changed: ' + change.path);
  }
}

// The caller constructs this plan from trusted harness inputs, never consumer
// executable code. Backups remain private and provide an explicit inverse.
export async function applyPlan(plan, receiptRoot = path.join(process.env.ARKIRA_RUNTIME_HOME ||
  path.join(os.homedir(), '.arkira', 'runtime'), 'migrations')) {
  validatePlan(plan);
  if (!plan.changes.length) return null;
  receiptRoot = path.resolve(receiptRoot);
  const createPrivate = dir => {
    if (!fs.existsSync(dir)) { createPrivate(path.dirname(dir)); fs.mkdirSync(dir, { mode: 0o700 }); }
    assertDirectory(dir);
  };
  createPrivate(receiptRoot);
  if (fs.statSync(receiptRoot).mode & 0o077) fail('migration receipts must be private');
  const stage = fs.mkdtempSync(path.join(receiptRoot, 'transaction-'));
  const receipt = path.join(stage, 'receipt.json');
  fs.writeFileSync(receipt, JSON.stringify(plan), { mode: 0o600, flag: 'wx' });
  for (const [i, change] of plan.changes.entries()) {
    for (const key of ['before', 'after']) {
      if (change[key] === null) continue;
      const name = path.join(stage, i + '.' + key);
      fs.writeFileSync(name, Buffer.from(change[key].bytes, 'base64'), { mode: change[key].mode, flag: 'wx' });
      fs.chmodSync(name, change[key].mode);
    }
  }
  const script = fileURLToPath(new URL('./migration-transaction.sh', import.meta.url));
  try {
    await promisify(execFile)('bash', [script, plan.repo, stage], {
      timeout: 120000, maxBuffer: 1024 * 1024,
    });
  } catch (error) {
    // Retain the original receipt even if rollback encounters concurrent edits.
    fail('migration transaction failed; recovery receipt: ' + receipt + '\n' + (error.stderr || error.message));
  }
  return receipt;
}

export async function rollbackMigration(repoPath, receiptPath, receiptRoot) {
  const repo = assertDirectory(repoPath);
  assertDirectory(path.dirname(path.resolve(receiptPath)));
  const stat = fs.lstatSync(receiptPath);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077)) fail('unsafe migration receipt');
  const receipt = JSON.parse(fs.readFileSync(receiptPath));
  if (receipt.repo !== repo || !Array.isArray(receipt.changes)) fail('receipt does not belong to this repository');
  const inverse = { ...receipt, head: git(repo, ['rev-parse', 'HEAD']).toString().trim(),
    changes: receipt.changes.map(c => ({ path: c.path, before: c.after, after: c.before })).reverse() };
  return applyPlan(inverse, receiptRoot);
}

// The dash guard was retired in #320, but its installer appended a block to the
// local pre-commit hook that still runs. Remove every complete block and leave
// other bytes alone; an unterminated block is reported, never guessed at. The
// hook is untracked, so it stays outside the migration transaction: only a
// regular file in the common git dir's hooks is edited, and the backup beside
// it is the rollback.
export function removeLegacyDashGuard(repoPath, { apply = true } = {}) {
  const repo = assertDirectory(repoPath);
  const at = args => path.resolve(repo, git(repo, ['rev-parse', ...args]).toString().trim());
  const hook = at(['--git-path', 'hooks/pre-commit']);
  let stat;
  try { stat = fs.lstatSync(hook); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  let hooks;
  try { hooks = fs.realpathSync(path.join(at(['--git-common-dir']), 'hooks')); } catch { hooks = null; }
  if (!stat.isFile() || fs.realpathSync(path.dirname(hook)) !== hooks) {
    return { hook, warning: 'pre-commit hook is not a regular file in the git hooks directory, left untouched: ' + hook };
  }
  const original = fs.readFileSync(hook);
  const lines = original.toString('latin1').split(/(?<=\n)/);
  const kept = [];
  let inside = false;
  for (const line of lines) {
    if (inside) inside = !line.startsWith('# <<< arkira dash-guard <<<');
    else if (line.startsWith('# >>> arkira dash-guard >>>')) inside = true;
    else kept.push(line);
  }
  if (inside) return { hook, warning: 'unterminated arkira dash-guard block left in place: ' + hook };
  if (kept.length === lines.length) return null;
  if (!apply) return { hook, removed: false };
  const mode = stat.mode & 0o7777;
  const backup = hook + '.arkira-dash-guard.bak';
  const temp = hook + '.arkira-tmp-' + process.pid;
  // wx refuses an existing file or symlink at either path, so neither is followed.
  const create = (file, bytes) => {
    let fd;
    try { fd = fs.openSync(file, 'wx', mode); } catch (error) { if (error.code === 'EEXIST') return false; throw error; }
    try { fs.fchmodSync(fd, mode); fs.writeFileSync(fd, bytes); } finally { fs.closeSync(fd); }
    return true;
  };
  if (!create(temp, Buffer.from(kept.join(''), 'latin1'))) {
    return { hook, warning: 'dash-guard cleanup stopped, temp path already exists, hook left untouched: ' + temp };
  }
  if (!create(backup, original)) {
    fs.unlinkSync(temp);
    return { hook, warning: 'dash-guard cleanup stopped, backup path already exists, hook left untouched: ' + backup };
  }
  fs.renameSync(temp, hook);
  return { hook, removed: true, backup };
}

// Hook cleanup is advisory: an error here is a warning, never a lost migration result.
function reportDashGuard(repo, apply, cleanup = removeLegacyDashGuard) {
  let dashGuard;
  try { dashGuard = cleanup(repo, { apply }); } catch (error) {
    dashGuard = { warning: 'dash-guard cleanup failed, hook left as found: ' + error.message };
  }
  if (dashGuard?.warning) console.error('warning: ' + dashGuard.warning);
  else if (dashGuard?.removed) console.error('removed legacy dash-guard block: ' + dashGuard.hook + '; backup: ' + dashGuard.backup);
  else if (dashGuard) console.error('would remove legacy dash-guard block: ' + dashGuard.hook);
}

export function reportMigration({ repo, plan, receipt, release, apply }, cleanup = removeLegacyDashGuard) {
  reportDashGuard(repo, apply, cleanup);
  console.log(JSON.stringify({ applied: apply, preview_only: !apply, receipt,
    release_sha: release?.sha, head: plan.head, selection: plan.selection,
    channel_pin: apply ? 'release SHA'
      : 'preview resolves no release: --apply pins each central workflow call to the release SHA it verifies, and leaves an existing pin in place here',
    changes: plan.changes.map(c => ({ path: c.path, action: c.after === null ? 'delete' : c.before === null ? 'create' : 'update' })) }, null, 2));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, repo, ...args] = process.argv.slice(2);
    if (!repo) fail('repository is required');
    if (command === 'plan') {
      const [source, ...options] = args;
      if (!source || options.length) {
        fail('usage: migration.mjs plan <repo> <trusted-harness>');
      }
      console.log(JSON.stringify(planMigration(repo, source), null, 2));
    } else if (command === 'migrate') {
      let apply = false;
      while (args.length) {
        const arg = args.shift();
        if (arg === '--apply' && !apply) apply = true;
        else fail('usage: arkira migrate <repo> [--apply]');
      }
      let source = fileURLToPath(new URL('../../', import.meta.url));
      let release;
      if (apply) {
        // No dev override, caller URL, or offline fallback can authorize deleting
        // the old controls. Resolve and verify the replacement first.
        release = resolveRelease({ onlineRequired: true });
        verifyRelease(release.root);
        source = release.root;
      }
      const plan = planMigration(repo, source, release);
      const receipt = apply ? await applyPlan(plan) : null;
      reportMigration({ repo, plan, receipt, release, apply });
    } else if (command === 'dash-guard') {
      if (args.length > 1 || (args.length && args[0] !== '--apply')) fail('usage: migration.mjs dash-guard <repo> [--apply]');
      reportDashGuard(repo, args.length === 1);
    } else if (command === 'rollback' && args.length === 1) {
      console.log(JSON.stringify({ receipt: await rollbackMigration(repo, args[0]) }));
    } else {
      fail('usage: migration.mjs plan|migrate|dash-guard|rollback <repo> [arguments]');
    }
  } catch (error) {
    console.error('migration: ' + error.message);
    process.exitCode = 1;
  }
}
