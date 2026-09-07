#!/usr/bin/env node
// Supervise only native Claude structured-review streams. Never display event content.
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const [total, idle, input, output, errors, summary, executable, ...args] = process.argv.slice(2);
if (![total, idle].every(v => /^[1-9][0-9]{0,4}$/.test(v)) || !executable) {
  process.stderr.write('review: invalid bounded supervisor arguments\n');
  process.exit(2);
}
// The shell supplies its PID so a startup race cannot adopt an already-orphaned run.
const owner = Number(process.env.ARKIRA_REVIEW_OWNER_PID);
if (!Number.isSafeInteger(owner) || owner <= 1 || process.ppid !== owner) {
  process.stderr.write('review: owner already exited before startup\n');
  process.exit(17);
}
const started = performance.now();
const maxEventBytes = 1024 * 1024;
let lastActivity = started, lastReport = started, phase = 'starting', events = 0;
let buffer = '', terminal = null, diagnostic = '', failure = null;
let closing = false, closed = false, cleanupDone = false, exitCode = null, exitSignal = null;
const elapsed = () => (performance.now() - started) / 1000;
const inactive = () => (performance.now() - lastActivity) / 1000;
function report(kind) {
  process.stderr.write(`review: ${kind}; elapsed=${elapsed().toFixed(1)}s inactivity=${inactive().toFixed(1)}s phase=${phase} events=${events}\n`);
  lastReport = performance.now();
}
const fd = fs.openSync(input, 'r');
const child = spawn(executable, args, { detached: true, stdio: [fd, 'pipe', 'pipe'] });
fs.closeSync(fd);
function signalGroup(signal) {
  if (child.pid) {
    try { process.kill(-child.pid, signal); } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
  }
}
function cleanup() {
  if (closing) return;
  closing = true;
  signalGroup('SIGTERM');
  setTimeout(() => {
    signalGroup('SIGKILL');
    cleanupDone = true;
    finish();
  }, 250);
}
function fail(termination, message, code = 15) {
  if (!failure) failure = { termination, message, code };
  cleanup();
}
function activity(event) {
  if (event.type === 'result') return 'result';
  if (event.type === 'assistant') return 'assistant';
  if (event.type === 'user') return 'tool-result';
  if (event.type === 'system' && ['init', 'status', 'thinking_tokens', 'api_retry'].includes(event.subtype)) {
    return event.subtype;
  }
  if (event.type === 'stream_event' && [
    'message_start', 'message_delta', 'message_stop',
    'content_block_start', 'content_block_delta', 'content_block_stop'
  ].includes(event.event?.type)) return 'stream';
  return null;
}
function parseLine(line) {
  if (!line.trim() || failure) return;
  let event;
  try { event = JSON.parse(line); } catch {
    fail('protocol_error', 'malformed provider stream');
    return;
  }
  if (!event || typeof event !== 'object' || Array.isArray(event)) {
    fail('protocol_error', 'invalid provider event');
    return;
  }
  const nextPhase = activity(event);
  if (nextPhase) {
    lastActivity = performance.now();
    phase = nextPhase;
    if (++events === 1 || performance.now() - lastReport >= 15000) report('progress');
  }
  if (event.type === 'result') {
    if (terminal) {
      fail('protocol_error', 'duplicate provider result');
    } else {
      terminal = event;
      if (event.subtype !== 'success' || event.is_error !== false) {
        fail('provider_error', 'provider reported an unsuccessful review');
      }
    }
  }
}
child.stdout.setEncoding('utf8');
child.stdout.on('data', chunk => {
  if (failure) return;
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (Buffer.byteLength(line) > maxEventBytes) {
      fail('protocol_error', 'provider event exceeds size limit');
      buffer = '';
      return;
    }
    parseLine(line);
    if (failure) { buffer = ''; return; }
  }
  if (Buffer.byteLength(buffer) > maxEventBytes) {
    buffer = '';
    fail('protocol_error', 'provider event exceeds size limit');
  }
});
child.stderr.setEncoding('utf8');
child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-65536); });
child.on('error', () => fail('provider_error', 'could not start provider', 17));
child.on('exit', (code, signal) => {
  exitCode = code;
  exitSignal = signal;
  // Kill descendants even after a normal exit; inherited pipes must not keep us alive.
  cleanup();
});
child.on('close', (code, signal) => {
  exitCode = code;
  exitSignal = signal;
  closed = true;
  if (!failure && buffer.trim()) parseLine(buffer);
  buffer = '';
  cleanup();
  finish();
});
const timer = setInterval(() => {
  if (process.ppid !== owner) {
    fail('parent_exit', 'review owner exited', 17);
  } else if (elapsed() >= Number(total)) {
    fail('total_timeout', `review exceeded total deadline (${total}s)`, 14);
  } else if (inactive() >= Number(idle)) {
    fail('idle_timeout', `review exceeded inactivity limit (${idle}s)`, 14);
  } else if (!closing && performance.now() - lastReport >= 15000) {
    report('waiting');
  }
}, 100);
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => fail('interrupted', 'review interrupted', 17));
}
function finish() {
  if (!closed || !cleanupDone) return;
  clearInterval(timer);
  if (!failure && (exitCode !== 0 || exitSignal)) {
    failure = { termination: 'provider_error', message: 'provider exited unsuccessfully', code: 17 };
  }
  if (!failure && !terminal) {
    failure = { termination: 'protocol_error', message: 'provider exited without a complete result', code: 15 };
  }
  const termination = failure?.termination ?? 'completed';
  report(termination);
  // The shell owns these private files. Parent loss may already have removed them.
  try {
    fs.writeFileSync(output, !failure ? JSON.stringify(terminal) + '\n' : '', { mode: 0o600 });
    fs.writeFileSync(errors, diagnostic + (failure ? `\nArkira error ${failure.code}: ${failure.message}\n` : ''), { mode: 0o600 });
    fs.writeFileSync(summary, JSON.stringify({
      termination, elapsed_seconds: elapsed(), idle_seconds: inactive(), last_phase: phase, event_count: events
    }), { mode: 0o600 });
  } catch {
    process.stderr.write('review: could not persist private result\n');
    process.exitCode = 17;
    return;
  }
  process.exitCode = failure?.code ?? 0;
}
report('started');
