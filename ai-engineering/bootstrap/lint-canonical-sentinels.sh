#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(grep -RIl "ARKIRA:MANAGED" ai-engineering/root 2>/dev/null | sort)

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "canonical-sentinels: no managed blocks found"
  exit 1
fi

node - "${files[@]}" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const files = process.argv.slice(2);
let failed = false;

const attrRe = /\s([A-Za-z0-9_-]+)=([^\s>]+)/g;
function attrs(line) {
  const out = {};
  for (const match of line.matchAll(attrRe)) out[match[1]] = match[2];
  return out;
}
function sha(body) {
  return crypto.createHash("sha256").update(body.replace(/^\n+|\n+$/g, "")).digest("hex");
}

for (const file of files) {
  const lines = fs.readFileSync(file, "utf8").split(/\n/);
  const seen = new Set();
  const stack = [];
  let blocks = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.includes("ARKIRA:MANAGED START")) {
      const a = attrs(line);
      if (!a.id) {
        console.error(`${file}:${i + 1}: START missing id`);
        failed = true;
      }
      if (!a.v || !/^[1-9][0-9]*$/.test(a.v)) {
        console.error(`${file}:${i + 1}: START id=${a.id || "unknown"} missing positive integer v`);
        failed = true;
      }
      if (!a.sha || !/^[0-9a-f]{64}$/.test(a.sha)) {
        console.error(`${file}:${i + 1}: START id=${a.id || "unknown"} missing valid sha`);
        failed = true;
      }
      if (a.id && seen.has(a.id)) {
        console.error(`${file}:${i + 1}: duplicate id=${a.id}`);
        failed = true;
      }
      if (a.id) seen.add(a.id);
      stack.push({ attrs: a, line: i + 1, bodyStart: i + 1 });
      continue;
    }
    if (line.includes("ARKIRA:MANAGED END")) {
      const a = attrs(line);
      const start = stack.pop();
      if (!start) {
        console.error(`${file}:${i + 1}: END without START`);
        failed = true;
        continue;
      }
      if (!a.id || a.id !== start.attrs.id) {
        console.error(`${file}:${i + 1}: END id mismatch for START at ${start.line}`);
        failed = true;
        continue;
      }
      const body = lines.slice(start.bodyStart, i).join("\n").replace(/^\n+|\n+$/g, "");
      if (!body) {
        console.error(`${file}:${start.line}: block id=${a.id} has empty body`);
        failed = true;
      }
      const actual = sha(body);
      if (start.attrs.sha && start.attrs.sha !== actual) {
        console.error(`${file}:${start.line}: block id=${a.id} sha mismatch expected ${start.attrs.sha} actual ${actual}`);
        failed = true;
      }
      blocks += 1;
    }
  }
  for (const start of stack) {
    console.error(`${file}:${start.line}: START id=${start.attrs.id || "unknown"} lacks matching END`);
    failed = true;
  }
  console.log(`${file}: ${blocks} managed blocks OK`);
}

process.exit(failed ? 1 : 0);
NODE
