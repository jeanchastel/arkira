import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const shaPattern = /^[a-f0-9]{40}$/;
const scriptPattern = /^[A-Za-z0-9:_-]+$/;
const safePathPattern = /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._/-]+(?:\/\*\*)?$/;
const supabaseVersionPattern = /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/;
const environmentNamePattern = /^[A-Z][A-Z0-9_]{0,63}$/;
const environmentNameDeniedPrefixes = [
  'GITHUB_', 'RUNNER_', 'ACTIONS_', 'INPUT_', 'ARKIRA_', 'NPM_CONFIG_', 'DYLD_', 'LD_',
];
const environmentNameDenylist = new Set([
  'PATH', 'HOME', 'SHELL', 'ENV', 'BASH_ENV', 'CI', 'NODE_OPTIONS', 'NODE_PATH',
  'PLAYWRIGHT_BROWSERS_PATH', 'SUPABASE_HOME',
]);

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

function validateRiskPaths(value, label) {
  if (!Array.isArray(value) || value.length === 0) {
    fail(`${label} risk_paths must be a non-empty array`);
  }
  const seen = new Set();
  for (const riskPath of value) {
    if (typeof riskPath !== 'string' || !safePathPattern.test(riskPath) ||
        riskPath.includes('//') || riskPath.startsWith('./')) fail(`unsafe ${label} risk path: ${riskPath}`);
    if (seen.has(riskPath)) fail(`duplicate ${label} risk path: ${riskPath}`);
    seen.add(riskPath);
  }
}

function validateEnvironmentNames(value, label, maximum, declared) {
  if (!Array.isArray(value) || value.length > maximum) fail(`${label} has an invalid shape`);
  const seen = new Set();
  for (const name of value) {
    if (typeof name !== 'string' || !environmentNamePattern.test(name) ||
        environmentNameDenylist.has(name) ||
        environmentNameDeniedPrefixes.some(prefix => name.startsWith(prefix))) {
      fail(`invalid ${label} name: ${name}`);
    }
    if (seen.has(name) || declared.has(name)) fail(`duplicate environment name: ${name}`);
    seen.add(name);
    declared.add(name);
  }
}

function validateContract(value) {
  if (value?.schema_version !== 1 && value?.schema_version !== 2) {
    fail('CI contract schema_version must be 1 or 2');
  }
  const version = value.schema_version;
  exactKeys(value, version === 1
    ? ['schema_version', 'build_artifact', 'database', 'browser']
    : ['schema_version', 'supabase_cli_version', 'build_artifact', 'database', 'browser', 'environment'],
  'CI contract');
  if (version === 2 && !supabaseVersionPattern.test(value.supabase_cli_version)) {
    fail('supabase_cli_version is invalid');
  }

  const build = value.build_artifact;
  exactKeys(build, ['provider', 'package_script', 'directory', 'exclude', 'max_uncompressed_mb'], 'build artifact');
  if (build.provider !== 'nextjs' || (version === 1 && build.directory !== '.next') ||
      JSON.stringify(build.exclude) !== JSON.stringify(['cache/**', 'dev/**']) ||
      build.max_uncompressed_mb !== 150) fail('build artifact contract is unsupported');
  if (version === 2 && (typeof build.directory !== 'string' ||
      !safePathPattern.test(build.directory) || path.posix.basename(build.directory) !== '.next')) {
    fail('build artifact directory is unsupported');
  }
  packageScript(build.package_script, 'build artifact package_script');

  const database = value.database;
  exactKeys(database, ['provider', 'package_script', 'risk_paths'], 'database contract');
  if (database.provider !== 'supabase-local') fail('database provider is unsupported');
  packageScript(database.package_script, 'database package_script');
  validateRiskPaths(database.risk_paths, 'database');

  const browser = value.browser;
  exactKeys(browser, version === 1
    ? ['provider', 'package_script', 'browsers', 'shards', 'requires_database']
    : ['provider', 'package_script', 'browsers', 'shards', 'requires_database', 'risk_paths'],
  'browser contract');
  if (browser.provider !== 'playwright' ||
      JSON.stringify(browser.browsers) !== JSON.stringify(['chromium']) ||
      (version === 1 ? browser.shards !== 4 : !Number.isInteger(browser.shards) ||
        browser.shards < 1 || browser.shards > 4) || browser.requires_database !== true) {
    fail('browser contract is unsupported');
  }
  packageScript(browser.package_script, 'browser package_script');
  if (version === 2) {
    validateRiskPaths(browser.risk_paths, 'browser');
    const environment = value.environment;
    exactKeys(environment, ['secrets', 'variables'], 'environment');
    const declared = new Set();
    validateEnvironmentNames(environment.secrets, 'environment secret', 4, declared);
    validateEnvironmentNames(environment.variables, 'environment variable', 8, declared);
  }
  return value;
}

function legacyResult(reason) {
  return {
    schema_version: 1,
    mode: 'legacy',
    reason,
    database_required: false,
    database_matches: [],
    supabase_cli_version: '2.109.1',
    build_directory: '.next',
    shards: 4,
    browser_required: true,
    browser_matches: [],
    environment: { secrets: [], variables: [] },
    contract: null,
  };
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
    return legacyResult('trusted-contract-missing');
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
    return legacyResult('candidate-contract-changed');
  }
  const changed = git(repo, ['diff', '--no-renames', '--name-only', '-z', base, tree], { encoding: 'buffer' })
    .toString('utf8').split('\0').filter(Boolean);
  const databaseMatches = [];
  const browserMatches = [];
  for (const file of changed) {
    if (contract.database.risk_paths.some(pattern => matchesRiskPath(file, pattern))) {
      databaseMatches.push(file);
    }
    if (contract.schema_version === 2 &&
        contract.browser.risk_paths.some(pattern => matchesRiskPath(file, pattern))) {
      browserMatches.push(file);
    }
  }
  return {
    schema_version: contract.schema_version,
    mode: 'split',
    reason: 'trusted-contract-active',
    database_required: databaseMatches.length > 0,
    database_matches: databaseMatches,
    supabase_cli_version: contract.supabase_cli_version ?? '2.109.1',
    build_directory: contract.build_artifact.directory,
    shards: contract.browser.shards,
    browser_required: contract.schema_version === 1 || browserMatches.length > 0,
    browser_matches: browserMatches,
    environment: contract.environment ?? { secrets: [], variables: [] },
    contract,
  };
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
