# Test Suite Standard (Vitest + React Testing Library)

Status: canonical. Synced to product repos via `/arkira-sync`.

Scope: how a JS/TS test suite is configured so it runs fast and fails honestly.
This standard is about the harness, not about what to test.

## Rule

A slow suite is usually a suite that was configured around a bug instead of
fixing it. Before reaching for any knob that trades wall clock for stability,
find out what is actually failing. The four rules below are ordered by how much
damage the mistake causes.

### 1. Never serialize a suite to fix flakiness that isolation already prevents

Vitest's default pool (`forks`, `isolate: true`) already gives **every test file
its own process and its own DOM**. No file can leak state into another. Turning
off `fileParallelism` therefore buys **no isolation whatsoever**. It only starves
the machine.

If tests flake under parallel execution and pass serially, the cause is not
cross-file contamination. It is almost always CPU contention exposing an
assertion that was quietly depending on a fast machine. Fix the assertion.

Before setting `fileParallelism: false`, you must be able to state which shared
resource is being contended. A real one (a fixed port, a shared temp file, a live
database) justifies serializing **those files**, not the suite. If you cannot name
the resource, there isn't one.


### 2. If you use React Testing Library, set `asyncUtilTimeout` explicitly

**RTL's async queries (`findBy*`, `waitFor`) enforce their own 1000ms budget.
It is not Vitest's `testTimeout`, and raising `testTimeout` does nothing for
them.** This is the single most expensive trap in this standard: a repo raises
`testTimeout` to 20s, believes it has bought patience, and `findByRole` keeps
giving the component tree exactly one second to render and commit. On a busy
machine that is a coin flip, and the flake gets blamed on parallelism.

Set it in the setup file, sized for the heaviest tree the suite renders:

```js
import { configure } from '@testing-library/react';
configure({ asyncUtilTimeout: 5000 });
```

A test that renders a whole app shell and waits for a modal will not finish in a
second on a loaded CI box. The assertion was right; its patience was not.

### 3. Register cleanup in the setup file, never trust auto-registration

RTL only self-registers its `afterEach(cleanup)` when `afterEach` is a **global**.
With `globals: false` (the default in many configs, and correct if tests import
their own `describe`/`it`), that registration silently does not happen, and every
render leaks into `document.body` for the rest of the file.

The failure mode is not a red test. It is a file where 64 of 66 test files happen
to hand-roll a cleanup and the two that forgot pass by luck of their queries,
until someone adds a `getByRole` that now finds two matches.

Register it once, centrally, with a timer restore:

```js
import { afterEach, vi } from 'vitest';
import { cleanup } from '@testing-library/react';

afterEach(() => {
  cleanup();
  vi.useRealTimers();  // a test that dies mid-useFakeTimers freezes every test after it
});
```

And close the same class of hole in config, so a failing test cannot leave a spy
or a stubbed global behind:

```js
restoreMocks: true,
unstubGlobals: true,
```

### 4. Never let a fixed sleep guard a negative assertion

This is a correctness rule, not a performance one, and it is the most dangerous
pattern in this document because it produces **green tests that assert nothing**.

```js
// WRONG: passes precisely when the CPU is too busy to let the thing happen
await new Promise(r => setTimeout(r, 30));
expect(channelSpy).not.toHaveBeenCalled();
```

Starve the machine and the code path never gets its chance, so the assertion
passes. The test is not flaky. It is blind, and it is blind in exactly the
conditions (a loaded CI box) where you most want it watching.

Two things are required:

- **Flush deterministically** rather than sleeping: `await act(async () => { await Promise.resolve(); })`,
  or drive time with fake timers, so the code path is given its chance on purpose.
- **Add a positive control**: a sibling test proving the same anchor DOES observe
  the event when the event happens. Without it, a green negative assertion cannot
  distinguish "correctly silent" from "never looked".

## Focused runs

- Read the declared `vitest` version and existing `package.json` scripts before composing a
  command. Prefer an existing script, and take flag spellings from that version's official
  documentation rather than from memory.
- Run one directly related file through the repository's declared package manager, such as
  `pnpm vitest run path/to/file.test.ts` in a pnpm repository.
- Never use a bare repository-wide Vitest command as the ordinary default.
- Baseline CI stays capped at 180 seconds. Full local CI runs only on an explicit operator
  `--full-ci` request, and remote PR CI remains authoritative after publication.

## Local-first iteration, mandatory CI confirmation

Run hermetic integration and E2E suites against local containers first while
developing. CI reruns the same proof on the committed candidate. Local execution
shortens diagnosis; it is never release authority and never replaces CI.

Why: local loop is seconds, CI loop is minutes (queue + spin-up) per iteration. A
red CI run gives you a log to squint at; a local run gives real terminal, real
logs, attachable debugger. CI minutes cost money and contend on shared runners.

CI E2E stays mandatory for:

- pre-merge gate (catches what someone forgot to run locally)
- cross-service integration no single dev machine can reproduce
- environment-specific bugs (prod-parity image, secrets, DNS)

Anti-pattern: iterating by pushing commits and watching CI. Same Compose stack
CI runs should run locally; if it can't, that's the bug.

Remote preview E2E is additionally mandatory when behavior depends on a managed
service that a local container does not faithfully reproduce, including hosted
authentication, storage authorization, edge functions, deployment routing,
provider secrets, DNS, or platform networking. A local Postgres container proves
database behavior only. It does not prove the complete hosted Supabase surface.

Authority order is: local feedback, committed-candidate CI, required remote
preview E2E, then narrow non-destructive production smoke checks. Each layer adds
evidence; no earlier layer substitutes for a later required layer.

Reference implementation pattern: [Testcontainers](https://testcontainers.com)
(official, multi-language) is built on exactly this principle: the same
container definition runs local and CI. If a repo's e2e setup can't do that,
that's the gap to close, not a reason to skip local.

See `github/ci-validation-standard.md` for what CI must still run regardless.

## Browser testing

A repository that opts into Playwright declares an exact `@playwright/test` version,
with no range operator, in its own manifest. Run browser commands with
`pnpm exec playwright`, or `npm exec --` on npm repos, never `npx playwright`, which
can resolve a version unrelated to the lockfile.

Install browsers only in jobs that run browser tests, through
`scripts/install-playwright-browsers.sh`. Do not install them from init, sync, a hook,
ordinary CI, or the full gate. Use `chromium --only-shell` unless a headed or branded
browser is genuinely required. Use `--with-deps` on Linux only because it shells out to
`apt`. The script does not place browsers inside the repository, preserving
candidate-cleanliness assertions.

This repository has no Playwright dependency, so its Dependabot configuration does not
propose Playwright updates. Product repositories that opt in own update proposals
through their own dependency automation against their own manifest. No automation edits
a pin in place.

### A held port is never freed by force

A process holding a port is someone else's work, usually the operator's dev server
or a parallel worktree running its own suite. Never kill it to make room for a test
run. `lsof -ti:3000 | xargs kill`, `pkill -f next`, and answering a `--strictPort`
failure by clearing the holder are all prohibited, in scripts, in CI, and in agent
sessions. Start the test server on a free port instead.

Bind the port once and derive `baseURL`, `url`, and the server command from it, so a
single value moves the whole run. Default to a port the environment picks, and let
an explicit override win:

```ts
import { execFileSync } from "node:child_process";

// ponytail: ephemeral pick, tiny bind race between probe and server start;
// set E2E_PORT if a run needs a stable address.
const freePort = () =>
  execFileSync(process.execPath, [
    "-e",
    "const s=require('net').createServer().listen(0,()=>{console.log(s.address().port);s.close()})",
  ])
    .toString()
    .trim();

const port = process.env.E2E_PORT ?? freePort();
```

`reuseExistingServer` stays `false` for a build-and-start server: the point is a
known artifact, not whatever is already listening. It may be true only where the
suite deliberately attaches to a long-running dev server the operator started.

## What is per-repo, not standard

Do not copy these between repos; derive them:

- `maxWorkers` (a cap like `'50%'` leaves headroom so heavy renders do not starve
  each other; the right number depends on the machine and the suite).
- Which files need a DOM environment vs `node`.
- The `asyncUtilTimeout` value, sized to the heaviest tree the suite renders.

## Applying this to an existing repo

1. Measure first: run serial, then run with `--file-parallelism`. Record both.
2. Read every failure. Do not assume they are timeouts, and do not re-run until
   green. A test that passes alone and fails under load is telling you something.
3. Fix the assertions (rules 2 and 4), then delete `fileParallelism: false`.
4. Prove it with three consecutive full runs, not one.

## Rationale

The order matters. Serializing a suite is attractive because it works: the flake
goes away. But it converts a two-line test bug into an eleven-minute tax on every
run, forever, and it hides the tests that were passing for the wrong reason. The
suite gets slower **and** less honest, which is the worst trade available.
