import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { git, assertDirectory } from './public-release.mjs';

const sessionPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

// Derivation is read-only. Only the explicit context/launcher command resolves
// a release and records a binding. Delegated work retains its inherited binding.
export function nativeSession(payload, inherited = process.env.ARKIRA_RELEASE_SESSION) {
  if (inherited) {
    if (!sessionPattern.test(inherited)) throw Error('invalid inherited release session');
    return inherited;
  }
  if (!payload.session_id) return '';
  if (typeof payload.session_id !== 'string' || payload.session_id.length > 1024 ||
      typeof payload.cwd !== 'string') throw Error('invalid native session identity');
  const cwd = assertDirectory(payload.cwd);
  const repo = git(cwd, ['rev-parse', '--show-toplevel']).toString().trim();
  return 'native-' + createHash('sha256').update(repo + '\0' + payload.session_id).digest('hex');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [command, ...extra] = process.argv.slice(2);
    if (!['id', 'notice'].includes(command) || extra.length) throw Error('usage: native-session.mjs id|notice');
    const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    if (command === 'id') {
      process.stdout.write(nativeSession(payload));
    } else {
      if (typeof payload.cwd !== 'string') process.exit(0);
      const cwd = assertDirectory(payload.cwd);
      let repo;
      try {
        repo = git(cwd, ['rev-parse', '--show-toplevel'], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim();
      } catch { process.exit(0); } // Native sessions need not start in a Git repository.
      // Inspect every config path component without following repository links.
      const directory = path.join(repo, '.arkira');
      const configPath = path.join(directory, 'config.json');
      const dir = fs.lstatSync(directory, { throwIfNoEntry: false });
      if (dir && (!dir.isDirectory() || dir.isSymbolicLink())) throw Error('unsafe repository configuration');
      const stat = dir ? fs.lstatSync(configPath, { throwIfNoEntry: false }) : null;
      if (stat && (!stat.isFile() || stat.isSymbolicLink())) throw Error('unsafe repository configuration');
      const harness = stat ? JSON.parse(fs.readFileSync(configPath)).harness : null;
      if (harness?.channel === 'stable' && harness.repository === 'jeanchastel/arkira') {
        const session = nativeSession(payload);
        if (!session) throw Error('native session ID is missing; run arkira context explicitly');
        const launcher = fileURLToPath(new URL('../../bin/arkira', import.meta.url));
        console.log('Read central harness context before acting. Run: ' + quote(launcher) +
          ' --session ' + session + ' context ' + quote(repo));
        console.log('Reuse this session for every Arkira command and delegated agent. Project-owned instructions remain in force.');
      }
    }
  } catch (error) {
    console.error('Arkira native context: ' + error.message);
    process.exitCode = 1;
  }
}
