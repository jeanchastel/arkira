#!/usr/bin/env bash
set -euo pipefail

node <<'NODE'
const fs = require('node:fs');

function fail(message) {
  process.stderr.write(`FAIL: ${message}\n`);
  process.exit(1);
}

function parseJson(name, fallback) {
  try {
    return JSON.parse(process.env[name] ?? fallback);
  } catch {
    fail(`${name} must contain valid JSON`);
  }
}

function declaredNames(name) {
  const value = parseJson(name, '[]');
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string')) {
    fail(`${name} must be a JSON array of strings`);
  }
  return value;
}

function randomDelimiter() {
  const bytes = Buffer.alloc(16);
  const descriptor = fs.openSync('/dev/urandom', 'r');
  try {
    let offset = 0;
    while (offset < bytes.length) {
      const read = fs.readSync(descriptor, bytes, offset, bytes.length - offset, null);
      if (read === 0) fail('could not read a heredoc delimiter from /dev/urandom');
      offset += read;
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return bytes.toString('hex');
}

const secretNames = declaredNames('ARKIRA_DECLARED_SECRETS');
const variableNames = declaredNames('ARKIRA_DECLARED_VARIABLES');
if (secretNames.length > 4) fail('ARKIRA_DECLARED_SECRETS may declare at most four names');
const productVariables = parseJson('ARKIRA_PRODUCT_VARIABLES', '{}');
if (!productVariables || typeof productVariables !== 'object' || Array.isArray(productVariables)) {
  fail('ARKIRA_PRODUCT_VARIABLES must be a JSON object');
}
if (!process.env.GITHUB_ENV) fail('GITHUB_ENV is required');
if (!process.env.GITHUB_STEP_SUMMARY) fail('GITHUB_STEP_SUMMARY is required');

const exports = [];
for (const [index, name] of secretNames.entries()) {
  const slot = `PRODUCT_SECRET_${index + 1}`;
  const value = process.env[slot] ?? '';
  if (value.length === 0) fail(`${slot} is empty for declared secret ${name}`);
  exports.push({ name, value, source: slot, kind: 'Secret' });
}
for (const name of variableNames) {
  if (!Object.prototype.hasOwnProperty.call(productVariables, name)) {
    fail(`declared variable ${name} is absent from ARKIRA_PRODUCT_VARIABLES`);
  }
  if (typeof productVariables[name] !== 'string') {
    fail(`declared variable ${name} in ARKIRA_PRODUCT_VARIABLES is not a string`);
  }
  exports.push({ name, value: productVariables[name], kind: 'Variable' });
}

let environment = '';
for (const entry of exports) {
  const delimiter = randomDelimiter();
  if (entry.value.includes(delimiter)) fail(`value for ${entry.name} contains its heredoc delimiter`);
  environment += `${entry.name}<<${delimiter}\n${entry.value}\n${delimiter}\n`;
}
fs.appendFileSync(process.env.GITHUB_ENV, environment);

let summary = '### Product environment exports\n\n';
for (const entry of exports) {
  summary += entry.kind === 'Secret'
    ? `- Secret: \`${entry.name}\` from \`${entry.source}\`\n`
    : `- Variable: \`${entry.name}\`\n`;
}
fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
NODE
