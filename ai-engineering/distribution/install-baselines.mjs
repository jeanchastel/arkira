import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { refreshable } from './migration-preflight.mjs';

// Regenerates install-baselines.json: every committed version of each
// refreshable canonical source. Rerun after editing any of those sources.
const root = fileURLToPath(new URL('../../', import.meta.url));
const git = args => execFileSync('git', ['-C', root, ...args], { maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const rows = JSON.parse(fs.readFileSync(path.join(root, 'ai-engineering/bootstrap/sync-checks.json')))
  .filter(row => row.scope === 'install' && refreshable(row.target))
  .sort((a, b) => a.target < b.target ? -1 : 1);
const baselines = {};
for (const { source, target } of rows) {
  const digests = new Set();
  for (const commit of git(['log', '--format=%H', '--', source]).toString().split('\n').filter(Boolean)) {
    // A commit that deleted the source has no blob to hash.
    try { digests.add(hash(git(['cat-file', 'blob', commit + ':' + source]))); } catch {}
  }
  baselines[target] = [...digests].sort();
}
fs.writeFileSync(path.join(root, 'ai-engineering/distribution/install-baselines.json'),
  JSON.stringify(baselines, null, 2) + '\n');
