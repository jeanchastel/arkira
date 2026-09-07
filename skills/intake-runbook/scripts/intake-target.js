#!/usr/bin/env node
"use strict";

// Bind every intake command to the exact directory inode created by this run.
// The command runs from that already-open working directory, so replacing the
// destination pathname after validation cannot redirect the command elsewhere.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const readline = require("readline");
const {spawn, spawnSync} = require("child_process");

function fail(message, code = 1) {
  process.stderr.write(`intake-target: ${message}\n`);
  process.exit(code);
}

function lstatOrNull(value) {
  try { return fs.lstatSync(value); }
  catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

function sameIdentity(stat, dev, ino) {
  return String(stat.dev) === String(dev) && String(stat.ino) === String(ino);
}

function testPause(phase) {
  const prefix = `ARKIRA_INTAKE_TEST_${phase}`;
  const ready = process.env[`${prefix}_READY`];
  const go = process.env[`${prefix}_GO`];
  if (!ready && !go) return;
  if (!ready || !go) throw new Error(`incomplete ${phase} test pause`);
  fs.writeFileSync(ready, "ready\n", {flag: "wx", mode: 0o600});
  const waitCell = new Int32Array(new SharedArrayBuffer(4));
  const deadline = Date.now() + 10000;
  while (!lstatOrNull(go)) {
    if (Date.now() >= deadline) throw new Error(`${phase} test pause timed out`);
    Atomics.wait(waitCell, 0, 0, 10);
  }
}

function safeDirectory(value, label) {
  const absolute = path.resolve(value);
  const parsed = path.parse(absolute);
  let current = parsed.root;
  for (const part of absolute.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      fail(`${label} contains a symlink or non-directory component: ${current}`, 2);
    }
  }
  const physical = fs.realpathSync.native(absolute);
  if (physical !== absolute) fail(`${label} is not a physical path`, 2);
  return physical;
}

function parseOptions(argv) {
  const options = {};
  const command = [];
  while (argv.length > 0) {
    const token = argv.shift();
    if (token === "--") {
      command.push(...argv);
      break;
    }
    if (!token.startsWith("--") || argv.length === 0) fail(`invalid option: ${token}`, 2);
    options[token.slice(2)] = argv.shift();
  }
  return {options, command};
}

function openState(statePath) {
  const absolute = path.resolve(statePath);
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  let fd;
  try { fd = fs.openSync(absolute, flags); }
  catch { fail("state file is missing, unreadable, or a symlink", 2); }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || (stat.mode & 0o077) !== 0) {
      fail("state file must be a private regular file", 2);
    }
    const state = JSON.parse(fs.readFileSync(fd, "utf8"));
    for (const key of ["schema", "parent_physical", "parent_dev", "parent_ino",
      "target_physical", "target_dev", "target_ino", "state_parent_physical",
      "state_parent_dev", "state_parent_ino", "state_name", "run_token"]) {
      if (state[key] === undefined || state[key] === null) fail(`state is missing ${key}`, 2);
    }
    if (state.schema !== 1) fail("unsupported state schema", 2);
    if (path.dirname(absolute) !== state.state_parent_physical
      || path.basename(absolute) !== state.state_name) {
      fail("state path does not match its bound parent", 2);
    }
    const stateParentStat = fs.lstatSync(state.state_parent_physical);
    if (stateParentStat.isSymbolicLink() || !stateParentStat.isDirectory()
      || !sameIdentity(stateParentStat, state.state_parent_dev, state.state_parent_ino)) {
      fail("state parent identity changed", 2);
    }
    state.__state_path = absolute;
    state.__state_dev = String(stat.dev);
    state.__state_ino = String(stat.ino);
    return state;
  } catch (error) {
    if (error && error.message && error.message.startsWith("unsupported")) throw error;
    fail("state file is invalid", 2);
  } finally {
    fs.closeSync(fd);
  }
}

function sameTargetIdentity(state, stat) {
  return sameIdentity(stat, state.target_dev, state.target_ino);
}

function validateKind(state, kind, cwd) {
  if (kind === "directory") return;
  if (kind === "empty") {
    if (fs.readdirSync(cwd).length !== 0) fail("target is not empty", 3);
    return;
  }
  if (kind === "git") {
    const check = spawnSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
      encoding: "utf8",
    });
    if (check.status !== 0) fail("target is not a Git worktree", 3);
    const top = fs.realpathSync.native(check.stdout.trim());
    const bound = fs.realpathSync.native(cwd);
    if (top !== bound) fail("target is nested inside another Git worktree", 3);
    return;
  }
  fail(`invalid target kind: ${kind}`, 2);
}

function validateNamedParent(state) {
  const stat = fs.lstatSync(state.parent_physical);
  if (stat.isSymbolicLink() || !stat.isDirectory()
    || !sameIdentity(stat, state.parent_dev, state.parent_ino)) {
    fail("destination parent no longer names the bound directory", 3);
  }
  if (fs.realpathSync.native(state.parent_physical) !== state.parent_physical) {
    fail("destination parent physical path changed", 3);
  }
}

function validateNamedTarget(state, kind) {
  validateNamedParent(state);
  const stat = fs.lstatSync(state.target_physical);
  if (stat.isSymbolicLink() || !stat.isDirectory() || !sameTargetIdentity(state, stat)) {
    fail("target path no longer names the run-created directory", 3);
  }
  if (fs.realpathSync.native(state.target_physical) !== state.target_physical) {
    fail("target physical path changed", 3);
  }
  validateKind(state, kind, state.target_physical);
}

function validateWorkerDirectory(options) {
  const expectedDev = options.dev;
  const expectedIno = options.ino;
  if (!expectedDev || !expectedIno) throw new Error("worker directory identity is missing");
  const stat = fs.statSync(".");
  if (!stat.isDirectory() || !sameIdentity(stat, expectedDev, expectedIno)) {
    throw new Error("worker directory identity changed");
  }
}

function safeStateName(name) {
  return typeof name === "string" && name.length > 0 && name.length <= 255
    && path.basename(name) === name && name !== "." && name !== "..";
}

function publishStateWorker(options, suppliedBody) {
  validateWorkerDirectory(options);
  const name = options.name;
  if (!safeStateName(name)) throw new Error("invalid state filename");
  const body = suppliedBody === undefined ? fs.readFileSync(0, "utf8") : suppliedBody;
  if (typeof body !== "string") throw new Error("invalid state body");
  let fd = null;
  let createdIdentity = null;
  try {
    fd = fs.openSync(name, fs.constants.O_WRONLY | fs.constants.O_CREAT
      | fs.constants.O_EXCL | (fs.constants.O_NOFOLLOW || 0), 0o600);
    const created = fs.fstatSync(fd);
    if (!created.isFile()) throw new Error("published state is not regular");
    createdIdentity = {dev: String(created.dev), ino: String(created.ino)};
    fs.writeFileSync(fd, body);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = null;
    const named = fs.lstatSync(name);
    if (named.isSymbolicLink() || !named.isFile()
      || !sameIdentity(named, createdIdentity.dev, createdIdentity.ino)
      || (named.mode & 0o077) !== 0) {
      throw new Error("state changed during publication");
    }
    return createdIdentity;
  } catch (error) {
    if (fd !== null) { try { fs.closeSync(fd); } catch {} }
    if (createdIdentity) {
      try {
        const named = fs.lstatSync(name);
        if (!named.isSymbolicLink() && named.isFile()
          && sameIdentity(named, createdIdentity.dev, createdIdentity.ino)) {
          fs.unlinkSync(name);
        }
      } catch {}
    }
    throw error;
  }
}

function removeStateWorker(options) {
  validateWorkerDirectory(options);
  const name = options.name;
  if (!safeStateName(name) || !options.file_dev || !options.file_ino) {
    throw new Error("invalid state cleanup identity");
  }
  const claim = `.arkira-intake-state-cleanup-${crypto.randomBytes(18).toString("hex")}`;
  if (lstatOrNull(claim)) throw new Error("state cleanup claim collision");
  fs.renameSync(name, claim);
  const claimed = fs.lstatSync(claim);
  if (!claimed.isSymbolicLink() && claimed.isFile()
    && sameIdentity(claimed, options.file_dev, options.file_ino)) {
    fs.unlinkSync(claim);
    return;
  }
  if (!lstatOrNull(name)) fs.renameSync(claim, name);
  throw new Error("state cleanup refused a replacement inode");
}

async function stateWorkerMain(options) {
  validateWorkerDirectory(options);
  process.stdout.write(`${JSON.stringify({ok: true, ready: true})}\n`);
  const lines = readline.createInterface({input: process.stdin, crlfDelay: Infinity});
  for await (const line of lines) {
    let request;
    try {
      request = JSON.parse(line);
      if (request.action === "publish") {
        const identity = publishStateWorker({...options, name: request.name}, request.body);
        process.stdout.write(`${JSON.stringify({ok: true, identity})}\n`);
      } else if (request.action === "remove") {
        removeStateWorker({...options, name: request.name,
          file_dev: request.file_dev, file_ino: request.file_ino});
        process.stdout.write(`${JSON.stringify({ok: true})}\n`);
      } else if (request.action === "close") {
        process.stdout.write(`${JSON.stringify({ok: true})}\n`);
        break;
      } else {
        throw new Error("invalid state worker action");
      }
    } catch (error) {
      process.stdout.write(`${JSON.stringify({ok: false,
        error: error && error.message ? error.message : "state worker failed"})}\n`);
    }
  }
}

async function startStateWorker(stateParent, stateParentStat) {
  const child = spawn(process.execPath, [__filename, "__state-worker",
    "--dev", String(stateParentStat.dev), "--ino", String(stateParentStat.ino)], {
    cwd: stateParent,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let buffer = "";
  let fatal = null;
  const queued = [];
  const waiters = [];
  let stderr = "";

  function rejectWaiters(error) {
    fatal = error;
    while (waiters.length > 0) waiters.shift().reject(error);
  }

  function deliver(response) {
    if (waiters.length > 0) waiters.shift().resolve(response);
    else queued.push(response);
  }

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline === -1) break;
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      try { deliver(JSON.parse(line)); }
      catch { rejectWaiters(new Error("state worker returned invalid output")); }
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.on("error", (error) => rejectWaiters(error));
  const exited = new Promise((resolve) => {
    child.on("exit", (code, signal) => {
      if (code !== 0 || signal) {
        rejectWaiters(new Error(`state worker exited unexpectedly${stderr ? `: ${stderr.trim()}` : ""}`));
      } else if (waiters.length > 0) {
        rejectWaiters(new Error("state worker exited before replying"));
      }
      resolve({code, signal});
    });
  });

  function nextResponse() {
    if (fatal) return Promise.reject(fatal);
    if (queued.length > 0) return Promise.resolve(queued.shift());
    return new Promise((resolve, reject) => waiters.push({resolve, reject}));
  }

  async function request(message) {
    if (fatal || !child.stdin.writable) throw fatal || new Error("state worker is unavailable");
    child.stdin.write(`${JSON.stringify(message)}\n`);
    const response = await nextResponse();
    if (!response || response.ok !== true) {
      throw new Error(response && response.error ? response.error : "state worker request failed");
    }
    return response;
  }

  const ready = await nextResponse();
  if (!ready || ready.ok !== true || ready.ready !== true) {
    child.stdin.end();
    await exited;
    throw new Error("state worker failed to bind its directory");
  }

  return {
    async publish(name, state) {
      const response = await request({action: "publish", name,
        body: `${JSON.stringify(state, null, 2)}\n`});
      if (!response.identity || !response.identity.dev || !response.identity.ino) {
        throw new Error("state publication identity is missing");
      }
      return response.identity;
    },
    async remove(name, identity) {
      await request({action: "remove", name,
        file_dev: identity.dev, file_ino: identity.ino});
    },
    async close() {
      if (child.exitCode === null && !child.killed) {
        try { await request({action: "close"}); }
        finally { child.stdin.end(); }
      }
      await exited;
    },
  };
}

// A completed create no longer owns a live worker. Subsequent finish commands
// first validate the named state parent in openState, then use this one-shot
// helper for exact-inode cleanup. Create rollback never uses this pathname.
function removeStateBound(state) {
  const result = spawnSync(process.execPath, [__filename, "__remove-state",
    "--name", state.state_name, "--dev", String(state.state_parent_dev),
    "--ino", String(state.state_parent_ino), "--file_dev", String(state.__state_dev),
    "--file_ino", String(state.__state_ino)], {
    cwd: state.state_parent_physical,
    encoding: "utf8",
  });
  return !result.error && result.status === 0;
}

function rollbackTargetBound(slug, dev, ino) {
  const claim = `.arkira-intake-target-rollback-${crypto.randomBytes(18).toString("hex")}`;
  if (lstatOrNull(claim)) return false;
  try { fs.renameSync(slug, claim); }
  catch { return false; }
  try {
    const stat = fs.lstatSync(claim);
    if (!stat.isSymbolicLink() && stat.isDirectory() && sameIdentity(stat, dev, ino)
      && fs.readdirSync(claim).length === 0) {
      fs.rmdirSync(claim);
      return true;
    }
  } catch {}
  try { if (!lstatOrNull(slug)) fs.renameSync(claim, slug); } catch {}
  return false;
}

async function create(options) {
  const parent = options.parent;
  const slug = options.slug;
  const statePath = options.state;
  if (!parent || !slug || !statePath) fail("create requires --parent, --slug, and --state", 2);
  if (!/^[a-z0-9][a-z0-9._-]{0,99}$/.test(slug) || slug === "." || slug === "..") {
    fail("slug must be one safe repository path component", 2);
  }
  const parentPhysical = safeDirectory(parent, "destination parent");
  const parentStat = fs.lstatSync(parentPhysical);
  const target = path.join(parentPhysical, slug);
  if (lstatOrNull(target)) fail("target already exists", 2);
  const stateAbsolute = path.resolve(statePath);
  const stateParent = safeDirectory(path.dirname(stateAbsolute), "state parent");
  const stateParentStat = fs.lstatSync(stateParent);
  const stateName = path.basename(stateAbsolute);
  if (!safeStateName(stateName)) fail("state path needs one safe filename", 2);
  if (stateAbsolute === target || stateAbsolute.startsWith(`${target}${path.sep}`)) {
    fail("state file must be outside the intake target", 2);
  }
  if (lstatOrNull(stateAbsolute)) fail("state file already exists", 2);

  const runToken = crypto.randomBytes(24).toString("hex");
  let createdIdentity = null;
  let publishedIdentity = null;
  let state = null;
  let stateWorker = null;
  try {
    stateWorker = await startStateWorker(stateParent, stateParentStat);
    testPause("AFTER_PARENT_VALIDATE");
    process.chdir(parentPhysical);
    const boundParent = fs.statSync(".");
    if (!sameIdentity(boundParent, parentStat.dev, parentStat.ino)) {
      throw new Error("destination parent changed before binding");
    }
    const nested = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: ".",
      stdio: "ignore",
    });
    if (nested.status === 0) throw new Error("destination parent is inside an existing Git worktree");
    if (lstatOrNull(slug)) throw new Error("target already exists after parent binding");

    fs.mkdirSync(slug, {mode: 0o700});
    const stat = fs.lstatSync(slug);
    if (stat.isSymbolicLink() || !stat.isDirectory() || fs.readdirSync(target).length !== 0) {
      throw new Error("new target failed its empty-directory proof");
    }
    createdIdentity = {dev: String(stat.dev), ino: String(stat.ino)};
    const physical = fs.realpathSync.native(slug);
    if (physical !== target) throw new Error("new target physical path changed");
    state = {
      schema: 1,
      run_token: runToken,
      parent_physical: parentPhysical,
      parent_dev: String(parentStat.dev),
      parent_ino: String(parentStat.ino),
      target_physical: physical,
      target_dev: String(stat.dev),
      target_ino: String(stat.ino),
      state_parent_physical: stateParent,
      state_parent_dev: String(stateParentStat.dev),
      state_parent_ino: String(stateParentStat.ino),
      state_name: stateName,
      created_at: new Date().toISOString(),
    };

    testPause("AFTER_TARGET_CREATE");
    const namedParentBefore = fs.lstatSync(parentPhysical);
    if (namedParentBefore.isSymbolicLink() || !namedParentBefore.isDirectory()
      || !sameIdentity(namedParentBefore, parentStat.dev, parentStat.ino)
      || fs.realpathSync.native(parentPhysical) !== parentPhysical) {
      throw new Error("destination parent changed before state publication");
    }
    publishedIdentity = await stateWorker.publish(stateName, state);
    state.__state_dev = publishedIdentity.dev;
    state.__state_ino = publishedIdentity.ino;

    testPause("AFTER_STATE_PUBLISH");
    const namedParentAfter = fs.lstatSync(parentPhysical);
    if (namedParentAfter.isSymbolicLink() || !namedParentAfter.isDirectory()
      || !sameIdentity(namedParentAfter, parentStat.dev, parentStat.ino)
      || fs.realpathSync.native(parentPhysical) !== parentPhysical) {
      throw new Error("destination parent changed after state publication");
    }
    const namedTarget = fs.lstatSync(target);
    if (namedTarget.isSymbolicLink() || !namedTarget.isDirectory()
      || !sameIdentity(namedTarget, stat.dev, stat.ino)) {
      throw new Error("target changed before state handoff");
    }
    const namedState = fs.lstatSync(stateAbsolute);
    if (namedState.isSymbolicLink() || !namedState.isFile()
      || !sameIdentity(namedState, publishedIdentity.dev, publishedIdentity.ino)) {
      throw new Error("state changed before handoff");
    }
    process.stdout.write(`${physical}\n`);
  } catch (error) {
    let cleanupFailed = false;
    if (publishedIdentity && state) {
      try { await stateWorker.remove(state.state_name, publishedIdentity); }
      catch { cleanupFailed = true; }
    }
    if (createdIdentity
      && !rollbackTargetBound(slug, createdIdentity.dev, createdIdentity.ino)) {
      cleanupFailed = true;
    }
    if (cleanupFailed) throw new Error(`${error.message}; exact-inode rollback was incomplete`);
    throw error;
  } finally {
    if (stateWorker) await stateWorker.close();
  }
}

function runBound(state, before, after, command) {
  if (command.length === 0) fail("run requires a command after --", 2);
  validateNamedTarget(state, before);
  process.chdir(state.target_physical);
  const bound = fs.statSync(".");
  if (!sameTargetIdentity(state, bound)) fail("failed to bind target working directory", 3);
  validateKind(state, before, ".");

  const result = spawnSync(command[0], command.slice(1), {
    cwd: ".",
    env: {...process.env, ARKIRA_INTAKE_TARGET: "."},
    stdio: "inherit",
  });
  if (result.error) fail(`command could not start: ${result.error.message}`, 4);
  if (result.status !== 0) process.exit(result.status || 4);

  const afterBound = fs.statSync(".");
  if (!sameTargetIdentity(state, afterBound)) fail("bound target identity changed", 3);
  validateNamedTarget(state, after);
}

function finishState(state, kind) {
  validateNamedTarget(state, kind);
  if (!removeStateBound(state)) fail("state file changed before cleanup", 3);
}

async function main() {
  const action = process.argv[2];
  const {options, command} = parseOptions(process.argv.slice(3));
  if (action === "__publish-state") {
    const identity = publishStateWorker(options);
    process.stdout.write(`${identity.dev}\x1f${identity.ino}`);
  } else if (action === "__remove-state") removeStateWorker(options);
  else if (action === "__state-worker") await stateWorkerMain(options);
  else if (action === "create") await create(options);
  else if (action === "assert") {
    const state = openState(options.state || "");
    validateNamedTarget(state, options.kind || "git");
  } else if (action === "run") {
    const state = openState(options.state || "");
    runBound(state, options.before || options.kind || "git",
      options.after || options.kind || "git", command);
  } else if (action === "path") {
    const state = openState(options.state || "");
    validateNamedTarget(state, options.kind || "git");
    process.stdout.write(`${state.target_physical}\n`);
  } else if (action === "finish") {
    const state = openState(options.state || "");
    finishState(state, options.kind || "git");
  } else {
    fail("expected create, assert, run, path, or finish", 2);
  }
}

main().catch((error) => {
  fail(error && error.message ? error.message : "operation failed");
});
