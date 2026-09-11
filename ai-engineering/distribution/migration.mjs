import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { git, assertDirectory, PUBLIC_REPOSITORY, verifyRelease } from './public-release.mjs';
import { resolveRelease } from './release-channel.mjs';
import { migrationPreflight, read, relative, manifest } from './migration-preflight.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw Error(message); };
const encode = file => file ? { bytes: file.bytes.toString('base64'), mode: file.mode } : null;
const json = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
const stripManaged = text => text.replace(/^<!-- ARKIRA:MANAGED START id=([A-Za-z0-9_-]+) v=\d+ sha=[a-f0-9]{64} -->\r?\n[\s\S]*?^<!-- ARKIRA:MANAGED END id=\1 -->\r?\n?/gm, '');
const context = '## Shared harness\n\nRun `arkira context <this-repository>` before acting. Read its verified central instructions.\nReuse the returned session ID for all Arkira commands and delegated work.\nProject-owned instructions in this file and child AGENTS.md files remain in force.\n';
const pointer = '<!-- ARKIRA:MANAGED START id=central-context v=1 sha=' + hash(context.trim()) +
  ' -->\n' + context + '<!-- ARKIRA:MANAGED END id=central-context -->\n';
const ciPath = '.github/workflows/arkira-ci.yml';
const deliveryGuardPath = '.github/workflows/arkira-auto-merge-guard.yml';
const deliveryGuardSourcePath = 'ai-engineering/github/workflows/arkira-auto-merge-guard.yml';
const legacyDeliveryGuardHashes = new Set([
  'e644206736e5e616b232be524d4133a7d2a4d0ab5924951d7603b36fcca33722',
  'a29e757db284da9c434fd7fd2e15296901de4e9e98416ce713c019e601ac219',
  '0a27ea0d6a59c5bd987af879cf1370daf3f50a3df3f2b691504417b8123ee2a8',
  '7ee55c8eb2a106ef71661d67f5ac275baea191f1f7655996f1fdf34fcff09a41',
  'a0e910e7e4203e3d7a055c6a4990a727151542d126b92c9d0f9bc5634f96d98d',
  '399445b6f77a28c3011e259db2b943aac34ea4901565edb74b5ccb681f09a4ce',
]);
const legacyChromeCleanupCi = {
  baseline_sha: '7313907918629724775304e85b138e70b278a5fa0cc6c2307274d7729cc060ce',
  current_sha: '523f7c01eaff85e1fdebdd1926b017ed7a15b40ddb8711850c6240774d7937eb',
};
const legacySeikaboValidationCi = {
  baseline_sha: '7313907918629724775304e85b138e70b278a5fa0cc6c2307274d7729cc060ce',
  current_sha: '8aeb3acf9f4755a3b5e31ced63373de63fd5e1507b4c2fc686e9595e6363610f',
  validation_environment: {
    NEXT_PUBLIC_SUPABASE_URL: 'https://example.supabase.co',
    NEXT_PUBLIC_SUPABASE_ANON_KEY: 'anon-key-fixture',
    NEXT_PUBLIC_APP_URL: 'https://example.test',
    SUPABASE_SERVICE_ROLE_KEY: 'service-role-key-fixture',
  },
};
const legacyReleaseCandidate = {
  path: '.github/workflows/arkira-release-candidate.yml',
  sha: '0ca2606cdc1427319094dab339c652261e31c46f29b43c70c003dc239edaa18d',
};
const previousCentralReleaseCandidateSha = '8bc39557b2c8b3f35257a14493c7843a89218a716aa698fb77f693db05462fd6';

function callerWithValidationFixture(caller, fixture) {
  const marker = '    uses: jeanchastel/arkira/.github/workflows/validate.yml@stable # approved-channel\n';
  if (!caller.includes(marker)) fail('central CI caller is missing its stable validator');
  return caller.replace(marker, marker + "    with:\n      validation_fixture_environment: '" +
    JSON.stringify(fixture).replace(/'/g, "''") + "'\n");
}

// Pure planning against a clean accepted checkout. No scripts from the consumer
// execute. apply must resolve and verify a public release before using this plan.
export function planMigration(repoPath, sourcePath) {
  const repo = assertDirectory(repoPath), source = assertDirectory(sourcePath);
  if (git(repo, ['rev-parse', '--show-toplevel']).toString().trim() !== repo) fail('target must be a repository root');
  if (git(repo, ['status', '--porcelain=v1', '--untracked-files=all']).length) fail('dirty worktree');
  const config = JSON.parse(read(repo, '.arkira/config.json')?.bytes || '{}');
  const central = config.harness?.repository === PUBLIC_REPOSITORY && config.harness.channel === 'stable';
  const fresh = !read(repo, '.arkira/config.json') && !read(repo, '.arkira/sync-state.json');
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
  const report = central || fresh ? { ready: true, retire: [] } : migrationPreflight(repo, source);
  if (!report.ready) fail(report.conflicts.join('\n'));
  const registry = JSON.parse(read(repo, '.arkira/sync-state.json')?.bytes || '{"files":{}}');
  if (!central && !fresh) {
    for (const entry of manifest(source).filter(e => e.target.startsWith('.github/scripts/'))) {
      const installed = read(repo, entry.target);
      if (!installed) continue;
      const canonical = read(source, entry.source);
      if (registry.files[entry.target]?.tier !== 'pristine' ||
          registry.files[entry.target].baseline_sha !== hash(installed.bytes) ||
          !canonical || canonical.mode !== installed.mode) fail('GitHub helper ownership conflict: ' + entry.target);
      report.retire.push(entry.target);
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
  const ci = read(repo, ciPath);
  const ciRecord = registry.files[ciPath];
  const pristineCi = ciRecord?.tier === 'pristine' && ciRecord.baseline_sha === hash(ci?.bytes || '') && ci?.mode === 0o644;
  // The temporary runner workaround is eligible only when both the original
  // registered CI and complete patched workflow match immutable hashes. The
  // central caller replaces it in the same transaction.
  const temporaryChromeCleanup = ciRecord?.tier === 'pristine' &&
    ciRecord.baseline_sha === legacyChromeCleanupCi.baseline_sha &&
    hash(ci?.bytes || '') === legacyChromeCleanupCi.current_sha && ci?.mode === 0o644;
  const boundedValidationEnvironment = ciRecord?.tier === 'pristine' &&
    ciRecord.baseline_sha === legacySeikaboValidationCi.baseline_sha &&
    hash(ci?.bytes || '') === legacySeikaboValidationCi.current_sha && ci?.mode === 0o644;
  if (!central && ci && !pristineCi && !temporaryChromeCleanup && !boundedValidationEnvironment) {
    fail('CI ownership or drift conflict: ' + ciPath);
  }
  const template = read(source, 'ai-engineering/distribution/product-ci.yml');
  if (!template) fail('central CI template is missing');
  const caller = template.bytes.toString();
  const fixtureCaller = callerWithValidationFixture(caller, legacySeikaboValidationCi.validation_environment);
  const ciSupportTemplate = read(source, 'ai-engineering/distribution/product-release-candidate.yml');
  if (!ciSupportTemplate) fail('central CI support template is missing');
  const deliveryGuardTemplate = read(source, deliveryGuardSourcePath);
  if (!deliveryGuardTemplate) fail('central delivery authorization workflow is missing');
  const deliveryGuard = read(repo, deliveryGuardPath);
  const knownDeliveryGuard = deliveryGuard && deliveryGuard.mode === deliveryGuardTemplate.mode &&
    (deliveryGuard.bytes.equals(deliveryGuardTemplate.bytes) ||
      legacyDeliveryGuardHashes.has(hash(deliveryGuard.bytes)));
  if (deliveryGuard && !knownDeliveryGuard) {
    fail('delivery authorization workflow ownership or drift conflict: ' + deliveryGuardPath);
  }
  const ciSupport = read(repo, legacyReleaseCandidate.path);
  if (ciSupport &&
      (!ciSupport.bytes.equals(ciSupportTemplate.bytes) || ciSupport.mode !== 0o644) &&
      (ciSupport.mode !== 0o644 || ![
        legacyReleaseCandidate.sha,
        previousCentralReleaseCandidateSha,
      ].includes(hash(ciSupport.bytes)))) {
    fail('managed CI support ownership or drift conflict: ' + legacyReleaseCandidate.path);
  }
  let agents = read(repo, 'AGENTS.md')?.bytes.toString() || '';
  if (central) {
    const expected = ci?.bytes.toString();
    if (!ci || ![caller, fixtureCaller].includes(expected) || ci.mode !== 0o644 || !agents.includes(pointer)) {
      fail('central context or CI drift; preserve and review');
    }
  }
  if (!central) {
    agents = stripManaged(agents);
    for (const overlay of ['CLAUDE.md', 'CODEX.md']) {
      const before = read(repo, overlay);
      if (before) {
        const outside = stripManaged(before.bytes.toString());
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
  change('.arkira/config.json', json(config), 0o600);
  change(ciPath, boundedValidationEnvironment || (central && ci?.bytes.toString() === fixtureCaller)
    ? fixtureCaller : caller);
  change(legacyReleaseCandidate.path, ciSupportTemplate.bytes);
  change(deliveryGuardPath, deliveryGuardTemplate.bytes, deliveryGuardTemplate.mode);
  for (const name of report.retire) change(name, null);
  change('.arkira/sync-state.json', null);
  const changed = new Set(changes.map(c => c.path));
  for (const name of git(repo, ['ls-files', '-z']).toString().split('\0').filter(Boolean)) {
    if (changed.has(name) || !/\.(?:sh|ya?ml|json|m?js|[cm]?ts)$/.test(name)) continue;
    const bytes = read(repo, name)?.bytes.toString() || '';
    for (const retired of report.retire) {
      if (bytes.includes(retired)) fail('retained ' + name + ' still references retired ' + retired);
    }
  }
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
      const plan = planMigration(repo, source);
      const receipt = apply ? await applyPlan(plan) : null;
      console.log(JSON.stringify({ applied: apply, preview_only: !apply, receipt,
        release_sha: release?.sha, head: plan.head, selection: plan.selection,
        changes: plan.changes.map(c => ({ path: c.path, action: c.after === null ? 'delete' : c.before === null ? 'create' : 'update' })) }, null, 2));
    } else if (command === 'rollback' && args.length === 1) {
      console.log(JSON.stringify({ receipt: await rollbackMigration(repo, args[0]) }));
    } else {
      fail('usage: migration.mjs plan|migrate|rollback <repo> [arguments]');
    }
  } catch (error) {
    console.error('migration: ' + error.message);
    process.exitCode = 1;
  }
}
