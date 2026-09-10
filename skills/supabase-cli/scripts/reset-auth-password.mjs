#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { randomInt } from 'node:crypto';
import https from 'node:https';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

export const EXIT = Object.freeze({
  SUCCESS: 0,
  INVALID_ARGUMENTS: 2,
  DEPENDENCY: 10,
  CLI_AUTH: 11,
  UNSUPPORTED_KEY_OUTPUT: 12,
  USER_RESOLUTION: 20,
  PASSWORD: 21,
  MUTATION_REJECTED: 30,
  INDETERMINATE: 31,
  INTERNAL: 40,
});

const WRAPPER_VERSION = '0.134.12';
const PAGE_SIZE = 1000;
const PAGE_LIMIT = 1000;
const PROJECT_REF_PATTERN = /^[a-z0-9]{20}$/;
const UUID_V4_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SECRET_KEY_PATTERN = /^sb_secret_[A-Za-z0-9_-]{32,}$/;
const JWT_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

class SafeError extends Error {
  constructor(exitCode, publicMessage) {
    super(publicMessage);
    this.name = 'SafeError';
    this.exitCode = exitCode;
  }
}

function safeError(exitCode, publicMessage) {
  return new SafeError(exitCode, publicMessage);
}

export function buildProjectOrigin(projectRef) {
  if (typeof projectRef !== 'string' || !PROJECT_REF_PATTERN.test(projectRef)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid project reference');
  }
  return `https://${projectRef}.supabase.co`;
}

export function validateUuid(value) {
  if (typeof value !== 'string' || !UUID_V4_PATTERN.test(value)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid auth user UUID');
  }
  return value.toLowerCase();
}

function validateResponseUuid(value, exitCode, message) {
  if (typeof value !== 'string' || !UUID_V4_PATTERN.test(value)) {
    throw safeError(exitCode, message);
  }
  return value.toLowerCase();
}

function validateEmail(value) {
  if (typeof value !== 'string' || value !== value.trim() || value.length > 320
    || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid auth user email');
  }
  return value;
}

export function parseArguments(argv) {
  const values = new Map();
  const allowed = new Set([
    '--project-ref',
    '--user-email',
    '--user-id',
    '--password-source',
    '--reveal-generated',
    '--confirm-action',
  ]);

  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || value === '' || values.has(flag)) {
      throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid or incomplete arguments');
    }
    values.set(flag, value);
  }

  const projectRef = values.get('--project-ref');
  buildProjectOrigin(projectRef);
  const email = values.get('--user-email');
  const userId = values.get('--user-id');
  if ((email && userId) || (!email && !userId)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'supply exactly one auth user selector');
  }

  const passwordSource = values.get('--password-source');
  const reveal = values.get('--reveal-generated');
  const confirmAction = values.get('--confirm-action');
  if (!['generate', 'prompt'].includes(passwordSource) || confirmAction !== 'reset-password') {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid password source or confirmation action');
  }
  if (passwordSource === 'generate' && reveal !== 'yes') {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'generated mode requires one warned password emission');
  }
  if (passwordSource === 'prompt' && reveal !== undefined) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'prompt mode does not reveal a password');
  }

  return {
    projectRef,
    target: email
      ? { type: 'email', value: validateEmail(email) }
      : { type: 'id', value: validateUuid(userId) },
    passwordSource,
    revealGenerated: passwordSource === 'generate',
    confirmAction,
  };
}

function decodeJwtRole(value) {
  if (typeof value !== 'string' || !JWT_PATTERN.test(value)) {
    return null;
  }
  try {
    const payload = JSON.parse(Buffer.from(value.split('.')[1], 'base64url').toString('utf8'));
    return payload && typeof payload === 'object' ? payload.role : null;
  } catch {
    return null;
  }
}

function templateRole(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value.role;
}

export function selectAdminKey(rawOutput) {
  let records;
  try {
    records = JSON.parse(rawOutput);
  } catch {
    throw safeError(EXIT.UNSUPPORTED_KEY_OUTPUT, 'unsupported Supabase API-key output');
  }
  if (!Array.isArray(records) || records.length === 0) {
    throw safeError(EXIT.UNSUPPORTED_KEY_OUTPUT, 'unsupported Supabase API-key output');
  }

  const defaultSecretRecords = records.filter((record) => record
    && typeof record === 'object'
    && record.name === 'default'
    && record.type === 'secret');
  if (defaultSecretRecords.length > 0) {
    if (defaultSecretRecords.length !== 1) {
      throw safeError(EXIT.UNSUPPORTED_KEY_OUTPUT, 'ambiguous Supabase admin credential');
    }
    const record = defaultSecretRecords[0];
    if (templateRole(record.secret_jwt_template) !== 'service_role'
      || typeof record.api_key !== 'string'
      || !SECRET_KEY_PATTERN.test(record.api_key)) {
      throw safeError(EXIT.UNSUPPORTED_KEY_OUTPUT, 'unsupported Supabase admin credential');
    }
    return record.api_key;
  }

  const legacyRecords = records.filter((record) => record
    && typeof record === 'object'
    && record.name === 'service_role'
    && record.type === 'legacy');
  if (legacyRecords.length !== 1
    || decodeJwtRole(legacyRecords[0].api_key) !== 'service_role') {
    throw safeError(EXIT.UNSUPPORTED_KEY_OUTPUT, 'unsupported or ambiguous Supabase admin credential');
  }
  return legacyRecords[0].api_key;
}

export function parseNextLink(linkHeader, origin) {
  if (linkHeader === undefined || linkHeader === null || linkHeader === '') {
    return null;
  }
  if (typeof linkHeader !== 'string') {
    throw safeError(EXIT.USER_RESOLUTION, 'invalid user-list pagination evidence');
  }
  const nextMatch = linkHeader.match(/<([^>]+)>\s*;\s*rel="next"/);
  if (!nextMatch) {
    throw safeError(EXIT.USER_RESOLUTION, 'incomplete user-list pagination evidence');
  }
  const href = nextMatch[1];
  if (!href.startsWith('/auth/v1/admin/users?')) {
    throw safeError(EXIT.USER_RESOLUTION, 'unsafe user-list pagination target');
  }
  let parsed;
  try {
    parsed = new URL(href, origin);
  } catch {
    throw safeError(EXIT.USER_RESOLUTION, 'invalid user-list pagination target');
  }
  if (parsed.origin !== origin || parsed.pathname !== '/auth/v1/admin/users') {
    throw safeError(EXIT.USER_RESOLUTION, 'unsafe user-list pagination target');
  }
  return `${parsed.pathname}${parsed.search}`;
}

export async function resolveEmailUser(email, origin, fetchPage) {
  const normalized = validateEmail(email).trim().toLowerCase();
  let path = `/auth/v1/admin/users?page=1&per_page=${PAGE_SIZE}`;
  const visited = new Set();
  const matches = [];

  for (let page = 1; page <= PAGE_LIMIT; page += 1) {
    if (visited.has(path)) {
      throw safeError(EXIT.USER_RESOLUTION, 'repeated user-list pagination target');
    }
    visited.add(path);
    const response = await fetchPage(path);
    if (!response || !Array.isArray(response.users)) {
      throw safeError(EXIT.USER_RESOLUTION, 'malformed user-list response');
    }
    for (const user of response.users) {
      if (!user || typeof user !== 'object' || typeof user.email !== 'string') {
        continue;
      }
      if (user.email.trim().toLowerCase() === normalized) {
        matches.push({
          id: validateResponseUuid(user.id, EXIT.USER_RESOLUTION, 'malformed matching auth user'),
          email: user.email,
        });
      }
    }
    if (matches.length > 1) {
      throw safeError(EXIT.USER_RESOLUTION, 'auth user identity is ambiguous');
    }

    const nextPath = parseNextLink(response.link ?? '', origin);
    if (nextPath) {
      if (page === PAGE_LIMIT) {
        throw safeError(EXIT.USER_RESOLUTION, 'user-list page limit exceeded');
      }
      path = nextPath;
      continue;
    }
    if (response.users.length >= PAGE_SIZE) {
      throw safeError(EXIT.USER_RESOLUTION, 'incomplete user-list pagination evidence');
    }
    if (matches.length !== 1) {
      throw safeError(EXIT.USER_RESOLUTION, 'auth user was not resolved exactly once');
    }
    return matches[0];
  }
  throw safeError(EXIT.USER_RESOLUTION, 'user-list page limit exceeded');
}

export function generatePassword(length = 32) {
  if (!Number.isInteger(length) || length < 24 || length > 128) {
    throw safeError(EXIT.PASSWORD, 'invalid generated password length');
  }
  const groups = [
    'ABCDEFGHJKLMNPQRSTUVWXYZ',
    'abcdefghijkmnopqrstuvwxyz',
    '23456789',
    '!@#$%^&*()-_=+',
  ];
  const combined = groups.join('');
  const characters = groups.map((group) => group[randomInt(group.length)]);
  while (characters.length < length) {
    characters.push(combined[randomInt(combined.length)]);
  }
  for (let index = characters.length - 1; index > 0; index -= 1) {
    const swapIndex = randomInt(index + 1);
    [characters[index], characters[swapIndex]] = [characters[swapIndex], characters[index]];
  }
  return characters.join('');
}

function parseJsonObject(body, exitCode, message) {
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw safeError(exitCode, message);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw safeError(exitCode, message);
  }
  return parsed;
}

function headerValue(headers, name) {
  if (!headers || typeof headers !== 'object') {
    return '';
  }
  const entry = Object.entries(headers).find(([key]) => key.toLowerCase() === name.toLowerCase());
  return entry ? String(entry[1]) : '';
}

function safeRequestId(headers) {
  const value = headerValue(headers, 'x-request-id');
  return /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : null;
}

function makeResult(options, status, exitCode, requestId = null) {
  return {
    timestamp: options.now(),
    wrapper_version: WRAPPER_VERSION,
    project_ref: options.projectRef ?? null,
    target: options.target?.value ?? null,
    action: 'reset-password',
    password_mode: options.passwordSource ?? null,
    status,
    exit_code: exitCode,
    request_id: requestId,
  };
}

function normalizeOptions(options) {
  buildProjectOrigin(options.projectRef);
  if (options.confirmAction !== 'reset-password') {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid confirmation action');
  }
  if (!options.target || !['email', 'id'].includes(options.target.type)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid auth user selector');
  }
  if (options.target.type === 'email') {
    validateEmail(options.target.value);
  } else {
    validateUuid(options.target.value);
  }
  if (!['generate', 'prompt'].includes(options.passwordSource)) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'invalid password source');
  }
  if (options.passwordSource === 'generate' && options.revealGenerated !== true) {
    throw safeError(EXIT.INVALID_ARGUMENTS, 'generated mode requires one warned password emission');
  }
  if (options.passwordSource === 'prompt'
    && (options.revealGenerated !== false || typeof options.password !== 'string' || options.password.length === 0)) {
    throw safeError(EXIT.PASSWORD, 'hidden password input is unavailable or empty');
  }
}

export async function executeReset(options, dependencies) {
  normalizeOptions(options);
  let password = options.passwordSource === 'prompt' ? options.password : null;
  let adminKey = null;
  options.password = null;
  try {
  const origin = buildProjectOrigin(options.projectRef);
  let cliResult;
  try {
    cliResult = await dependencies.runSupabase('supabase', [
      'projects', 'api-keys', '--project-ref', options.projectRef, '--reveal', '--output', 'json',
    ], { shell: false });
  } catch {
    throw safeError(EXIT.DEPENDENCY, 'Supabase CLI is unavailable');
  }
  if (!cliResult || cliResult.code !== 0) {
    throw safeError(EXIT.CLI_AUTH, 'Supabase CLI authentication or project access failed');
  }

  adminKey = selectAdminKey(cliResult.stdout);
  cliResult.stdout = '';
  cliResult.stderr = '';
  cliResult = null;
  const request = async (requestOptions) => {
    try {
      return await dependencies.request({ origin, ...requestOptions });
    } catch (error) {
      if (requestOptions.method === 'PUT' && error?.transmitted === true) {
        throw safeError(EXIT.INDETERMINATE, 'password update result is indeterminate');
      }
      throw safeError(EXIT.INTERNAL, 'Supabase Auth request failed safely');
    }
  };

  const authHeaders = {
    Authorization: `Bearer ${adminKey}`,
    apikey: adminKey,
    Accept: 'application/json',
  };
  let resolved;
  if (options.target.type === 'email') {
    resolved = await resolveEmailUser(options.target.value, origin, async (path) => {
      const response = await request({ method: 'GET', path, headers: authHeaders, body: null });
      if (response.status === 401 || response.status === 403) {
        throw safeError(EXIT.CLI_AUTH, 'Supabase admin credential was rejected');
      }
      if (response.status !== 200) {
        throw safeError(EXIT.USER_RESOLUTION, 'auth user list request failed');
      }
      const parsed = parseJsonObject(response.body, EXIT.USER_RESOLUTION, 'malformed user-list response');
      if (!Array.isArray(parsed.users)) {
        throw safeError(EXIT.USER_RESOLUTION, 'malformed user-list response');
      }
      return { users: parsed.users, link: headerValue(response.headers, 'link') };
    });
  } else {
    const expectedId = validateUuid(options.target.value);
    const response = await request({
      method: 'GET',
      path: `/auth/v1/admin/users/${expectedId}`,
      headers: authHeaders,
      body: null,
    });
    if (response.status === 401 || response.status === 403) {
      throw safeError(EXIT.CLI_AUTH, 'Supabase admin credential was rejected');
    }
    if (response.status !== 200) {
      throw safeError(EXIT.USER_RESOLUTION, 'auth user lookup failed');
    }
    const parsed = parseJsonObject(response.body, EXIT.USER_RESOLUTION, 'malformed auth user response');
    if (validateResponseUuid(parsed.id, EXIT.USER_RESOLUTION, 'malformed auth user response') !== expectedId) {
      throw safeError(EXIT.USER_RESOLUTION, 'auth user identity changed during lookup');
    }
    resolved = { id: expectedId, email: parsed.email };
  }

  if (options.passwordSource === 'generate') {
    password = dependencies.randomPassword?.() ?? generatePassword();
  }
  if (typeof password !== 'string' || password.length === 0) {
    throw safeError(EXIT.PASSWORD, 'password generation or input failed');
  }

  const updateHeaders = {
    ...authHeaders,
    'Content-Type': 'application/json',
  };
  let body = JSON.stringify({ password });
  let response;
  try {
    response = await request({
      method: 'PUT',
      path: `/auth/v1/admin/users/${resolved.id}`,
      headers: updateHeaders,
      body,
    });
  } finally {
    body = null;
    adminKey = null;
    updateHeaders.Authorization = null;
    updateHeaders.apikey = null;
    authHeaders.Authorization = null;
    authHeaders.apikey = null;
  }

  if (response.status < 200 || response.status >= 300) {
    password = null;
    throw safeError(EXIT.MUTATION_REJECTED, 'Supabase Auth rejected the password update');
  }
  const updated = parseJsonObject(response.body, EXIT.INTERNAL, 'malformed password-update response');
  if (validateResponseUuid(updated.id, EXIT.INTERNAL, 'malformed password-update response') !== resolved.id) {
    password = null;
    throw safeError(EXIT.INTERNAL, 'password-update identity did not match');
  }

  const generatedPassword = options.passwordSource === 'generate' ? password : null;
  password = null;
  return {
    exitCode: EXIT.SUCCESS,
    generatedPassword,
    result: makeResult({ ...options, now: dependencies.now }, 'success', EXIT.SUCCESS, safeRequestId(response.headers)),
  };
  } finally {
    password = null;
    adminKey = null;
    options.password = null;
  }
}

export function formatSuccessOutput(outcome) {
  if (!outcome || outcome.exitCode !== EXIT.SUCCESS || !outcome.result) {
    throw safeError(EXIT.INTERNAL, 'invalid success output');
  }
  const lines = [];
  if (outcome.generatedPassword !== null) {
    if (typeof outcome.generatedPassword !== 'string' || outcome.generatedPassword.length === 0) {
      throw safeError(EXIT.INTERNAL, 'invalid generated password output');
    }
    lines.push(`generated_password=${outcome.generatedPassword}`);
  }
  lines.push(JSON.stringify(outcome.result));
  return `${lines.join('\n')}\n`;
}

function runSupabase(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      shell: options.shell,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env },
    });
    const stdout = [];
    const stderr = [];
    const timeout = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error('CLI timeout'));
    }, 15_000);
    child.stdout.on('data', (chunk) => stdout.push(chunk));
    child.stderr.on('data', (chunk) => stderr.push(chunk));
    child.on('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on('close', (code) => {
      clearTimeout(timeout);
      resolve({
        code,
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      });
    });
  });
}

function requestHttps({ origin, method, path, headers, body }) {
  return new Promise((resolve, reject) => {
    let transmitted = false;
    let settled = false;
    const finishReject = (error) => {
      if (settled) return;
      settled = true;
      error.transmitted = transmitted;
      reject(error);
    };
    const request = https.request(new URL(path, origin), {
      method,
      headers,
      agent: false,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        if (settled) return;
        settled = true;
        clearTimeout(totalTimeout);
        resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString('utf8'),
          transmitted,
        });
      });
    });
    const totalTimeout = setTimeout(() => {
      request.destroy(new Error('request timeout'));
    }, 30_000);
    request.setTimeout(10_000, () => request.destroy(new Error('response timeout')));
    request.on('socket', (socket) => {
      if (socket.connecting) {
        const connectTimeout = setTimeout(() => request.destroy(new Error('connect timeout')), 5_000);
        socket.once('secureConnect', () => clearTimeout(connectTimeout));
      }
    });
    request.on('finish', () => {
      transmitted = true;
    });
    request.on('error', (error) => {
      clearTimeout(totalTimeout);
      finishReject(error);
    });
    if (body !== null && body !== undefined) request.write(body);
    request.end();
  });
}

async function readPromptPassword() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const value = Buffer.concat(chunks).toString('utf8').replace(/\r?\n$/, '');
  if (value.length === 0 || value.includes('\n') || value.includes('\r')) {
    throw safeError(EXIT.PASSWORD, 'hidden password input is unavailable or empty');
  }
  return value;
}

async function main() {
  let parsed = null;
  try {
    parsed = parseArguments(process.argv.slice(2));
    if (parsed.passwordSource === 'prompt') {
      parsed.password = await readPromptPassword();
    }
    const outcome = await executeReset(parsed, {
      runSupabase,
      request: requestHttps,
      now: () => new Date().toISOString(),
    });
    process.stdout.write(formatSuccessOutput(outcome));
    process.exitCode = EXIT.SUCCESS;
  } catch (error) {
    const exitCode = error instanceof SafeError ? error.exitCode : EXIT.INTERNAL;
    const safeOptions = parsed ?? {
      projectRef: null,
      target: null,
      passwordSource: null,
    };
    process.stdout.write(`${JSON.stringify(makeResult({
      ...safeOptions,
      now: () => new Date().toISOString(),
    }, exitCode === EXIT.INDETERMINATE ? 'indeterminate' : 'failure', exitCode))}\n`);
    process.stderr.write(`${error instanceof SafeError ? error.message : 'internal reset failure'}\n`);
    process.exitCode = exitCode;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
