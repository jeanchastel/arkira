import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const shaPattern = /^[a-f0-9]{40}$/;

function fail(message) {
  throw new Error(message);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function readJson(name) {
  try {
    return JSON.parse(fs.readFileSync(name, 'utf8'));
  } catch {
    fail(`could not read JSON: ${name}`);
  }
}

function packageMetadata(repo, buildScript) {
  const pkg = readJson(path.join(repo, 'package.json'));
  if (typeof pkg.packageManager !== 'string' ||
      !/^(?:npm|pnpm|yarn)@\d+\.\d+\.\d+/.test(pkg.packageManager)) {
    fail('package.json must declare an exact packageManager');
  }
  if (typeof pkg.scripts?.[buildScript] !== 'string' || !pkg.scripts[buildScript].trim()) {
    fail(`package.json is missing build script: ${buildScript}`);
  }
  const locks = ['pnpm-lock.yaml', 'yarn.lock', 'package-lock.json', 'npm-shrinkwrap.json']
    .filter(name => fs.existsSync(path.join(repo, name)));
  if (locks.length !== 1 || !fs.lstatSync(path.join(repo, locks[0])).isFile()) {
    fail('build artifact requires exactly one regular supported lockfile');
  }
  const lockBytes = fs.readFileSync(path.join(repo, locks[0]));
  return { packageManager: pkg.packageManager, buildCommand: pkg.scripts[buildScript],
    lockfile: locks[0], lockfileDigest: sha256(lockBytes) };
}

function walkFiles(root) {
  const files = [];
  const visit = (directory, relative = '') => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })
      .sort((a, b) => a.name.localeCompare(b.name))) {
      const absolute = path.join(directory, entry.name);
      const child = relative ? `${relative}/${entry.name}` : entry.name;
      const stat = fs.lstatSync(absolute);
      if (stat.isSymbolicLink()) fail(`build artifacts may not contain symbolic links: ${child}`);
      if (stat.isDirectory()) visit(absolute, child);
      else if (stat.isFile()) files.push({ absolute, relative: child, mode: stat.mode & 0o777, size: stat.size });
      else fail(`build artifact contains an unsupported file: ${child}`);
    }
  };
  visit(root);
  return files;
}

function treeDigest(root, maxBytes) {
  const files = walkFiles(root);
  const size = files.reduce((total, file) => total + file.size, 0);
  if (size > maxBytes) fail(`build artifact exceeds maximum size of ${maxBytes} bytes`);
  const digest = createHash('sha256');
  for (const file of files) {
    // GitHub Actions artifact transport does not preserve regular-file mode
    // bits (for example, 0664 is restored as 0644). The artifact contract is
    // therefore path/size/content based; retaining mode here would reject an
    // otherwise byte-identical build after a legitimate upload/download.
    digest.update(`${file.relative}\0${file.size}\0`);
    digest.update(fs.readFileSync(file.absolute));
  }
  return { digest: digest.digest('hex'), size, fileCount: files.length };
}

function validateOptions(options) {
  const repo = fs.realpathSync(options.repo);
  const artifactRoot = path.resolve(options.artifactRoot);
  const contains = (parent, child) => child.startsWith(parent + path.sep);
  if (artifactRoot === path.parse(artifactRoot).root ||
      artifactRoot === path.resolve(os.homedir()) || artifactRoot === path.resolve(os.tmpdir()) ||
      artifactRoot === repo || contains(repo, artifactRoot) || contains(artifactRoot, repo)) {
    fail('unsafe artifact root overlaps a broad or repository path');
  }
  if (!shaPattern.test(options.candidateSha) || !shaPattern.test(options.baseSha)) {
    fail('candidate and base must be exact commit SHAs');
  }
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repository)) fail('repository identity is invalid');
  if (!/^[A-Za-z0-9:_-]+$/.test(options.buildScript)) fail('build script is invalid');
  if (!Number.isSafeInteger(options.maxBytes) || options.maxBytes <= 0) fail('maximum size is invalid');
  return { ...options, repo, artifactRoot };
}

function expectedIdentity(options) {
  const metadata = packageMetadata(options.repo, options.buildScript);
  return {
    repository: options.repository,
    candidate_sha: options.candidateSha,
    base_sha: options.baseSha,
    node_version: process.version,
    platform: process.platform,
    architecture: process.arch,
    package_manager: metadata.packageManager,
    lockfile: metadata.lockfile,
    lockfile_sha256: metadata.lockfileDigest,
    build_script: options.buildScript,
    build_command: metadata.buildCommand,
  };
}

export function prepareProductBuildArtifact(rawOptions) {
  const options = validateOptions(rawOptions);
  const source = path.join(options.repo, '.next');
  if (!fs.existsSync(source) || !fs.lstatSync(source).isDirectory()) fail('.next build output is missing or unsafe');
  walkFiles(source);
  fs.rmSync(options.artifactRoot, { recursive: true, force: true });
  const payload = path.join(options.artifactRoot, 'payload/.next');
  fs.mkdirSync(path.dirname(payload), { recursive: true });
  fs.cpSync(source, payload, {
    recursive: true,
    filter: name => {
      const relative = path.relative(source, name).split(path.sep).join('/');
      return relative !== 'cache' && !relative.startsWith('cache/') &&
        relative !== 'dev' && !relative.startsWith('dev/');
    },
  });
  const tree = treeDigest(path.join(options.artifactRoot, 'payload'), options.maxBytes);
  const manifest = {
    schema_version: 1,
    ...expectedIdentity(options),
    payload_sha256: tree.digest,
    payload_bytes: tree.size,
    payload_files: tree.fileCount,
  };
  fs.writeFileSync(path.join(options.artifactRoot, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n',
    { mode: 0o644, flag: 'wx' });
  return manifest;
}

export function verifyProductBuildArtifact(rawOptions) {
  const options = validateOptions(rawOptions);
  const manifest = readJson(path.join(options.artifactRoot, 'manifest.json'));
  if (manifest.schema_version !== 1) fail('artifact schema version is invalid');
  const expected = expectedIdentity(options);
  const labels = {
    repository: 'repository', candidate_sha: 'candidate SHA', base_sha: 'base SHA',
    node_version: 'Node version', platform: 'platform', architecture: 'architecture',
    package_manager: 'package manager', lockfile: 'lockfile', lockfile_sha256: 'lockfile digest',
    build_script: 'build script', build_command: 'build command',
  };
  for (const [key, value] of Object.entries(expected)) {
    if (manifest[key] !== value) fail(`artifact ${labels[key]} mismatch`);
  }
  const payload = path.join(options.artifactRoot, 'payload');
  if (!fs.existsSync(payload) || !fs.lstatSync(payload).isDirectory()) fail('artifact payload is missing or unsafe');
  const tree = treeDigest(payload, options.maxBytes);
  if (manifest.payload_sha256 !== tree.digest || manifest.payload_bytes !== tree.size ||
      manifest.payload_files !== tree.fileCount) fail('artifact digest mismatch');
  return manifest;
}

export function restoreProductBuildArtifact(rawOptions) {
  const options = validateOptions(rawOptions);
  const manifest = verifyProductBuildArtifact(options);
  const target = path.join(options.repo, '.next');
  if (fs.existsSync(target) && fs.lstatSync(target).isSymbolicLink()) fail('refusing to replace a symbolic .next path');
  fs.rmSync(target, { recursive: true, force: true });
  fs.cpSync(path.join(options.artifactRoot, 'payload/.next'), target, { recursive: true });
  return manifest;
}

function usage() {
  fail('usage: product-build-artifact.mjs <prepare|verify|restore> --repo <path> --artifact-root <path> --repository <owner/name> --candidate <sha> --base <sha> --build-script <name> --max-mb <integer>');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const command = args.shift();
    if (!['prepare', 'verify', 'restore'].includes(command)) usage();
    const values = {};
    while (args.length) {
      const flag = args.shift();
      const value = args.shift();
      if (!value || !['--repo', '--artifact-root', '--repository', '--candidate', '--base', '--build-script', '--max-mb'].includes(flag) || values[flag]) usage();
      values[flag] = value;
    }
    const maxMb = Number(values['--max-mb']);
    const options = {
      repo: values['--repo'], artifactRoot: values['--artifact-root'], repository: values['--repository'],
      candidateSha: values['--candidate'], baseSha: values['--base'], buildScript: values['--build-script'],
      maxBytes: maxMb * 1024 * 1024,
    };
    if (Object.values(options).some(value => value === undefined) || !Number.isSafeInteger(options.maxBytes)) usage();
    const functionByCommand = {
      prepare: prepareProductBuildArtifact,
      verify: verifyProductBuildArtifact,
      restore: restoreProductBuildArtifact,
    };
    process.stdout.write(JSON.stringify(functionByCommand[command](options)) + '\n');
  } catch (error) {
    process.stderr.write(`FAIL: ${error.message}\n`);
    process.exitCode = 1;
  }
}
