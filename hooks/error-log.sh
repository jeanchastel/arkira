#!/usr/bin/env bash
# Store bounded metadata for real tool failures in private user state.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# Successful events and malformed lookalikes do not enter the diagnostic path.
printf '%s' "$payload" \
  | grep -Eq '"hook_event_name"[[:space:]]*:[[:space:]]*"PostToolUseFailure"' \
  || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Parse once before creating state. Only bounded categorical values cross back
# into the shell. Raw input, command text, errors, paths, and environment data
# remain in memory and are never written to a temporary file.
meta="$(printf '%s' "$payload" | node -e '
let source = "";
process.stdin.on("data", chunk => { source += chunk; }).on("end", () => {
  let input;
  try { input = JSON.parse(source); } catch { return; }
  if (input == null || typeof input !== "object" ||
      input.hook_event_name !== "PostToolUseFailure") return;

  const rawTool = typeof input.tool_name === "string" ? input.tool_name : "";
  const builtin = /^(Agent|AskUserQuestion|Bash|Edit|ExitPlanMode|Glob|Grep|NotebookEdit|Read|Task|TodoWrite|WebFetch|WebSearch|Write)$/;
  const mcp = /^mcp__[A-Za-z0-9_]{1,48}__[A-Za-z0-9_]{1,48}$/;
  let tool = "unknown";
  let category = "unknown";
  if (builtin.test(rawTool)) { tool = rawTool; category = "builtin"; }
  else if (mcp.test(rawTool)) { tool = rawTool; category = "mcp"; }

  let status = "unknown";
  const candidates = [input.exit_code, input.status,
    input.tool_response && input.tool_response.exit_code];
  for (const value of candidates) {
    if (Number.isInteger(value) && value >= -255 && value <= 255) {
      status = String(value);
      break;
    }
  }

  const error = typeof input.error === "string" ? input.error : "";
  if (status === "unknown") {
    const match = error.match(/\b(?:status(?:\s+code)?|exit\s+code)\s*[:=]?\s*(-?\d{1,3})\b/i);
    if (match) {
      const parsed = Number(match[1]);
      if (Number.isInteger(parsed) && parsed >= -255 && parsed <= 255) {
        status = String(parsed);
      }
    }
  }
  let classification = "failure";
  if (input.is_interrupt === true) classification = "interrupted";
  else if (status !== "unknown") classification = "exit";
  else if (/timed?\s*out|timeout/i.test(error)) classification = "timeout";
  else if (/permission|denied|not allowed/i.test(error)) classification = "permission";

  process.stdout.write([tool, category, classification, status].join("\n") + "\n");
});' 2>/dev/null)"
[ -n "$meta" ] || exit 0

meta_lines=()
while IFS= read -r line; do
  meta_lines+=("$line")
done <<EOF
$meta
EOF
tool="${meta_lines[0]:-unknown}"
category="${meta_lines[1]:-unknown}"
classification="${meta_lines[2]:-failure}"
status="${meta_lines[3]:-unknown}"

state_home="${ARKIRA_ERROR_LOG_HOME:-$HOME}"
[ -d "$state_home" ] && [ ! -L "$state_home" ] || exit 1

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

secure_dir() {
  local path="$1"
  [ ! -L "$path" ] || return 1
  if [ ! -e "$path" ]; then
    if ! mkdir -m 700 "$path" 2>/dev/null; then
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
    fi
  fi
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(mode_of "$path")" = "700" ] || return 1
}

arkira_dir="$state_home/.arkira"
state_dir="$arkira_dir/state"
diagnostics_dir="$state_dir/diagnostics"
[ ! -L "$arkira_dir" ] || exit 1
if [ ! -e "$arkira_dir" ]; then
  if ! mkdir -m 700 "$arkira_dir" 2>/dev/null; then
    # Another concurrent first-use writer may have created it after our
    # existence check. Accept only the real directory, never a symlink.
    [ -d "$arkira_dir" ] && [ ! -L "$arkira_dir" ] || exit 1
  fi
fi
[ -d "$arkira_dir" ] && [ ! -L "$arkira_dir" ] || exit 1
secure_dir "$state_dir" || exit 1
secure_dir "$diagnostics_dir" || exit 1

key_file="$diagnostics_dir/.fingerprint-key"
[ ! -L "$key_file" ] || exit 1
if [ -e "$key_file" ]; then
  [ -f "$key_file" ] && [ "$(mode_of "$key_file")" = "600" ] || exit 1
fi

log_file="$diagnostics_dir/tool-errors.jsonl"
[ ! -L "$log_file" ] || exit 1
if [ -e "$log_file" ] && [ ! -f "$log_file" ]; then
  exit 1
fi
if [ -e "$log_file" ] && [ "$(mode_of "$log_file")" != "600" ]; then
  exit 1
fi

# Node supplies O_NOFOLLOW for the definitive key read and final append.
# O_EXCL makes concurrent key creation safe. O_APPEND plus one writeSync call
# appends each bounded record without offset races or partial shell writes.
ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
max_log_bytes="${ARKIRA_ERROR_LOG_MAX_BYTES:-1048576}"
case "$max_log_bytes" in ''|*[!0-9]*) max_log_bytes=1048576 ;; esac
[ "$max_log_bytes" -ge 512 ] 2>/dev/null || max_log_bytes=512
(umask 077; printf '%s' "$payload" | node -e '
const fs = require("fs");
const crypto = require("crypto");
let source = "";
process.stdin.on("data", chunk => { source += chunk; }).on("end", () => {
  let keyFd = -1;
  let logFd = -1;
  let keyTemp = "";
  try {
    const nofollow = fs.constants.O_NOFOLLOW;
    if (typeof nofollow !== "number") throw new Error("O_NOFOLLOW unavailable");
    try {
      keyTemp = process.argv[1] + "." + process.pid + "." +
        crypto.randomBytes(8).toString("hex");
      keyFd = fs.openSync(keyTemp, fs.constants.O_WRONLY |
        fs.constants.O_CREAT | fs.constants.O_EXCL | nofollow, 0o600);
      const generated = crypto.randomBytes(32).toString("hex");
      const generatedBuffer = Buffer.from(generated, "utf8");
      if (fs.writeSync(keyFd, generatedBuffer, 0, generatedBuffer.length) !== generatedBuffer.length) {
        throw new Error("short key write");
      }
      fs.closeSync(keyFd); keyFd = -1;
      try { fs.linkSync(keyTemp, process.argv[1]); }
      catch (error) { if (!error || error.code !== "EEXIST") throw error; }
      fs.unlinkSync(keyTemp); keyTemp = "";
    } catch (error) {
      if (keyFd >= 0) { try { fs.closeSync(keyFd); } catch {} keyFd = -1; }
      if (keyTemp) { try { fs.unlinkSync(keyTemp); } catch {} keyTemp = ""; }
      throw error;
    }
    keyFd = fs.openSync(process.argv[1], fs.constants.O_RDONLY | nofollow);
    const keyStat = fs.fstatSync(keyFd);
    if (!keyStat.isFile() || (keyStat.mode & 0o777) !== 0o600) throw new Error("unsafe key");
    const key = fs.readFileSync(keyFd, "utf8");
    fs.closeSync(keyFd); keyFd = -1;

    const [logPath, timestamp, tool, category, classification, status, maxBytesRaw] = process.argv.slice(2);
    const maxBytes = Math.max(512, Number(maxBytesRaw) || 1048576);
    const fingerprint = crypto.createHmac("sha256", key).update(source).digest("hex");
    const row = JSON.stringify({
      timestamp, tool, category, classification,
      status: status === "unknown" ? "unknown" : Number(status),
      fingerprint
    }) + "\n";

    const flags = fs.constants.O_RDWR | fs.constants.O_APPEND |
      fs.constants.O_CREAT | nofollow;
    logFd = fs.openSync(logPath, flags, 0o600);
    const logStat = fs.fstatSync(logFd);
    if (!logStat.isFile() || (logStat.mode & 0o777) !== 0o600) throw new Error("unsafe log");
    const buffer = Buffer.from(row, "utf8");
    // Diagnostics are best-effort metadata, not an audit log. Roll the active
    // file over in place before it crosses the configured byte ceiling. This
    // prevents a permanently enabled failure hook from growing without bound.
    if (logStat.size > 0 && logStat.size + buffer.length > maxBytes) {
      fs.ftruncateSync(logFd, 0);
    }
    if (fs.writeSync(logFd, buffer, 0, buffer.length) !== buffer.length) {
      throw new Error("short append");
    }
    fs.closeSync(logFd); logFd = -1;
  } catch {
    if (keyFd >= 0) try { fs.closeSync(keyFd); } catch {}
    if (logFd >= 0) try { fs.closeSync(logFd); } catch {}
    if (keyTemp) try { fs.unlinkSync(keyTemp); } catch {}
    process.exitCode = 1;
  }
});' "$key_file" "$log_file" "$ts" "$tool" "$category" "$classification" "$status" "$max_log_bytes" 2>/dev/null) \
  || exit 1
exit 0
