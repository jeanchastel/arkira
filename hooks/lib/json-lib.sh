#!/usr/bin/env bash
# Shared JSON helpers for hooks. Sourced by hook scripts, not executed directly.
# Every function is best effort and returns 0 so callers can keep hook discipline.

# arkira_payload_fields <json> <dotpath>...
# Prints one value per requested dotpath. Missing values print blank lines.
arkira_payload_fields() {
  local json fields_left
  json="${1-}"
  shift || true
  fields_left="$#"

  [ "$fields_left" -gt 0 ] || return 0

  if ! command -v node >/dev/null 2>&1; then
    while [ "$fields_left" -gt 0 ]; do
      printf '\n'
      fields_left=$((fields_left - 1))
    done
    return 0
  fi

  if ! printf '%s' "$json" | node -e '
    const paths = process.argv.slice(1);
    let s = "";
    process.stdin.on("data", d => { s += d; }).on("end", () => {
      let root;
      try { root = JSON.parse(s); } catch { root = undefined; }
      const out = [];
      for (const path of paths) {
        let value = root;
        for (const key of path.split(".")) {
          value = value == null ? undefined : value[key];
        }
        // One value per line is the contract. Flatten any embedded newline
        // to a space so a multiline field (for example a multiline Bash
        // command) cannot shift the line index of later fields.
        out.push(value == null ? "" : String(value).replace(/[\r\n]+/g, " "));
      }
      process.stdout.write(out.join("\n"));
      process.stdout.write("\n");
    });' "$@" 2>/dev/null; then
    while [ "$fields_left" -gt 0 ]; do
      printf '\n'
      fields_left=$((fields_left - 1))
    done
  fi
  return 0
}

# arkira_switch <name> [default]
# Reads .switches.<name> from project config, then home config.
arkira_switch() {
  local name default project_dir home_dir
  [ "$#" -ge 1 ] || return 0
  name="$1"
  default="unset"
  [ "$#" -lt 2 ] || default="$2"
  project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  home_dir="${HOME:-}"

  if ! command -v node >/dev/null 2>&1; then
    printf '%s' "$default"
    return 0
  fi

  node -e '
    const fs = require("fs");
    const name = process.argv[1] || "";
    const fallback = process.argv[2] || "";
    const projectDir = process.argv[3] || "";
    const homeDir = process.argv[4] || "";
    const files = [];
    if (projectDir) files.push(projectDir + "/.arkira/config.json");
    if (homeDir) files.push(homeDir + "/.arkira/config.json");
    for (const file of files) {
      try {
        const obj = JSON.parse(fs.readFileSync(file, "utf8"));
        const switches = obj && obj.switches;
        if (switches && typeof switches === "object" &&
            Object.prototype.hasOwnProperty.call(switches, name)) {
          const value = switches[name];
          process.stdout.write(value === undefined ? fallback : String(value));
          process.exit(0);
        }
      } catch {}
    }
    process.stdout.write(fallback);
  ' "$name" "$default" "$project_dir" "$home_dir" 2>/dev/null || printf '%s' "$default"
  return 0
}
