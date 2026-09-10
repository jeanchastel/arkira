import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const shaPattern = /^[a-f0-9]{40}$/;
const scriptPattern = /^[A-Za-z0-9:_-]+$/;
const safePathPattern = /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._/-]+(?:\/\*\*)?$/;

function fail(message) {
  throw new Error(message);
}

function git(repo, args, options = {}) {
  return execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'], ...options,
  });
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) {
    fail(`${label} has an invalid shape`);
  }
}

function packageScript(value, label) {
  if (typeof value !== 'string' || !scriptPattern.test(value)) fail(`${label} is invalid`);
}

function validateContract(value) {
  exactKeys(value, ['schema_version', 'build_artifact', 'database', 'browser'], 'CI contract');
  if (value.schema_version !== 1) fail('CI contract schema_version must be 1');

  const build = value.build_artifact;
  exactKeys(build, ['provider', 'package_script', 'directory', 'exclude', 'max_uncompressed_mb'], 'build artifact');
  if (build.provider !== 'nextjs' || build.directory !== '.next' ||
      JSON.stringify(build.exclude) !== JSON.stringify(['cache/**', 'dev/**']) ||
      build.max_uncompressed_mb !== 150) fail('build artifact contract is unsupported');
  packageScript(build.package_script, 'build artifact package_script');

  const database = value.database;
  exactKeys(database, ['provider', 'package_script', 'risk_paths'], 'database contract');
  if (database.provider !== 'supabase-local') fail('database provider is unsupported');
  packageScript(database.package_script, 'database package_script');
  if (!Array.isArray(database.risk_paths) || database.risk_paths.length === 0) {
    fail('database risk_paths must be a non-empty array');
  }
  const seen = new Set();
  for (const riskPath of database.risk_paths) {
    if (typeof riskPath !== 'string' || !safePathPattern.test(riskPath) ||
        riskPath.includes('//') || riskPath.startsWith('./')) fail(`unsafe database risk path: ${riskPath}`);
    if (seen.has(riskPath)) fail(`duplicate database risk path: ${riskPath}`);
    seen.add(riskPath);
  }

  const browser = value.browser;
  exactKeys(browser, ['provider', 'package_script', 'browsers', 'shards', 'requires_database'], 'browser contract');
  if (browser.provider !== 'playwright' ||
      JSON.stringify(browser.browsers) !== JSON.stringify(['chromium']) ||
      browser.shards !== 4 || browser.requires_database !== true) {
    fail('browser contract is unsupported');
  }
  packageScript(browser.package_script, 'browser package_script');
  return value;
}

function readTreeBlob(repo, treeish, name) {
  const listing = git(repo, ['ls-tree', '-z', treeish, '--', name], { encoding: 'buffer' });
  if (listing.length === 0) return null;
  const match = /^([0-7]{6}) blob ([a-f0-9]{40})\t[^\0]+\0$/.exec(listing.toString('utf8'));
  if (!match) fail(`${name} has an invalid Git tree entry`);
  return { mode: match[1], bytes: git(repo, ['cat-file', 'blob', match[2]]) };
}

function matchesRiskPath(file, pattern) {
  if (pattern.endsWith('/**')) return file.startsWith(pattern.slice(0, -2));
  return file === pattern;
}

export function resolveProductCiContract({ repo, base, tree }) {
  repo = fs.realpathSync(repo);
  if (!shaPattern.test(base) || !shaPattern.test(tree)) fail('base and tree must be exact Git object IDs');
  if (git(repo, ['cat-file', '-t', base]).trim() !== 'commit') fail('base must resolve to a commit');
  if (git(repo, ['cat-file', '-t', tree]).trim() !== 'tree') fail('tree must resolve to a tree');

  const trusted = readTreeBlob(repo, base, '.arkira/ci.json');
  if (trusted === null) {
    return { schema_version: 1, mode: 'legacy', reason: 'trusted-contract-missing',
      database_required: false, database_matches: [], contract: null };
  }
  if (trusted.mode !== '100644') {
    fail('trusted .arkira/ci.json must be a non-executable regular file');
  }
  let contract;
  try {
    contract = validateContract(JSON.parse(trusted.bytes));
  } catch (error) {
    fail(`invalid trusted .arkira/ci.json: ${error.message}`);
  }
  const candidate = readTreeBlob(repo, tree, '.arkira/ci.json');
  if (candidate?.mode !== trusted.mode || candidate.bytes !== trusted.bytes) {
    return { schema_version: 1, mode: 'legacy', reason: 'candidate-contract-changed',
      database_required: false, database_matches: [], contract: null };
  }
  const changed = git(repo, ['diff', '--no-renames', '--name-only', '-z', base, tree], { encoding: 'buffer' })
    .toString('utf8').split('\0').filter(Boolean);
  const databaseMatches = changed.filter(file =>
    contract.database.risk_paths.some(pattern => matchesRiskPath(file, pattern)));
  return { schema_version: 1, mode: 'split', reason: 'trusted-contract-active',
    database_required: databaseMatches.length > 0, database_matches: databaseMatches, contract };
}

function usage() {
  fail('usage: product-ci-contract.mjs resolve --repo <path> --base <sha> --tree <sha>');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.shift() !== 'resolve') usage();
    const values = {};
    while (args.length) {
      const flag = args.shift();
      const value = args.shift();
      if (!value || !['--repo', '--base', '--tree'].includes(flag) || values[flag]) usage();
      values[flag] = value;
    }
    if (!values['--repo'] || !values['--base'] || !values['--tree']) usage();
    process.stdout.write(JSON.stringify(resolveProductCiContract({
      repo: values['--repo'], base: values['--base'], tree: values['--tree'],
    })) + '\n');
  } catch (error) {
    process.stderr.write(`FAIL: ${error.message}\n`);
    process.exitCode = 1;
  }
}
