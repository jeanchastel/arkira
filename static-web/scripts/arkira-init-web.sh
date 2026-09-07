#!/usr/bin/env bash
# static-web/scripts/arkira-init-web.sh
#
# Apply or dry-run the static-web install for a brochure-site repo.
# Reads decisions JSON from stdin.
#
# Usage:
#   echo '<decisions json>' | arkira-init-web.sh --repo-root <path> [--dry-run|--apply] [--no-scaffold]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$(cd "$SCRIPT_DIR/../examples" && pwd)"
FILE_SAFETY="$SCRIPT_DIR/../../ai-engineering/bootstrap/lib/file-safety.sh"
[ -f "$FILE_SAFETY" ] || { echo "ERROR: file-safety library missing" >&2; exit 1; }
# shellcheck source=../ai-engineering/bootstrap/lib/file-safety.sh
. "$FILE_SAFETY"

REPO_ROOT=""
MODE=""
SCAFFOLD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)   REPO_ROOT="${2:?--repo-root needs a path}"; shift 2 ;;
    --dry-run)     MODE="dry"; shift ;;
    --apply)       MODE="apply"; shift ;;
    --no-scaffold) SCAFFOLD=false; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$REPO_ROOT" ]] && { echo "ERROR: --repo-root required" >&2; exit 2; }
[[ -z "$MODE" ]]      && { echo "ERROR: --dry-run or --apply required" >&2; exit 2; }
[[ ! -d "$REPO_ROOT" ]] && { echo "ERROR: repo root $REPO_ROOT not a directory" >&2; exit 2; }
REPO_ROOT="$(arkira_safe_root "$REPO_ROOT")" \
  || { echo "ERROR: repo root must be a regular, non-symlink directory" >&2; exit 2; }

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

DECISIONS="$(cat)"
get() { printf '%s' "$DECISIONS" | jq -r "$1"; }

# Operator-supplied display fields (repo dir name, brand) are interpolated into
# generated HTML, PHP, and markdown. Strip markup, quote, shell-interpolation, and
# control characters so a repo named or branded with e.g. a quote or a <tag> cannot
# inject into the generated files. Constrained-choice fields are validated below.
web_safe() { printf '%s' "$1" | LC_ALL=C tr -d '<>"`$\\\047\000-\037' | cut -c1-120; }

PROFILE=$(get '.profile // "static-web"')
SITE_KIND=$(get '.site_kind // "single"')
HOST_PRIMARY=$(get '.host_primary // "joshwho-ftp"')
FORM_HANDLER=$(get '.form_handler // "php"')
ENTITY_BRAND=$(web_safe "$(get '.entity_brand // ""')")
SEC_HEADERS=$(get '.switches.security_headers // true')

[[ "$PROFILE" != "static-web" ]] && { echo "ERROR: this script handles only profile=static-web" >&2; exit 2; }

REPO_NAME=$(web_safe "$(basename "$REPO_ROOT")")

# --- plan tracker --------------------------------------------------------
PLAN_LINES=()
CREATED_FILES=()
CREATED_FILE_IDENTITIES=()
CREATED_FILE_SNAPSHOTS=()
CREATED_DIRS=()
CREATED_DIR_IDENTITIES=()
CONFIG_BACKUP=""
CONFIG_EXISTED=0
CONFIG_CLAIM_REL=""
CONFIG_CLAIM_IDENTITY=""
CONFIG_PUBLISHED_IDENTITY=""
CONFIG_STAGE=""
SCAFFOLD_LOCK_IDENTITY=""
TRANSACTION_DIR=""
COMMITTED=0
ROLLBACK_DONE=0
plan_write() { PLAN_LINES+=("WRITE  $1"); }
plan_skip()  { PLAN_LINES+=("SKIP   $1 (exists)"); }
plan_dir()   { PLAN_LINES+=("MKDIR  $1"); }
plan_note()  { PLAN_LINES+=("NOTE   $1"); }

private_mode() {
  if stat -f '%Lp' -- "$1" >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1"
  else
    stat -c '%a' -- "$1"
  fi
}

scaffold_file_matches() {
  local rel=$1 snapshot=$2 compare mode expected_mode matches=1
  compare="$(mktemp "$TRANSACTION_DIR/compare.XXXXXX")" || return 1
  if ! arkira_safe_read "$REPO_ROOT" "$rel" > "$compare"; then
    rm -f -- "$compare"
    return 1
  fi
  mode="$(arkira_safe_file_mode "$REPO_ROOT" "$rel")" || matches=0
  expected_mode="$(private_mode "$snapshot")" || matches=0
  cmp -s "$compare" "$snapshot" || matches=0
  rm -f -- "$compare"
  [[ "$matches" -eq 1 && "$mode" == "$expected_mode" ]]
}

preflight_scaffold() {
  local rel target
  local -a dirs=(".arkira")
  local -a files=(".arkira/config.json" "AGENTS.md" "CLAUDE.md" "CODEX.md")
  if $SCAFFOLD; then
    dirs+=("styles" "scripts" "assets" "assets/fonts" "assets/images" \
      "assets/icons" ".claude")
    files+=("README.md" "assets/fonts/.gitkeep" "assets/images/.gitkeep" \
      "assets/icons/.gitkeep" "index.html" "styles/main.css" \
      "scripts/main.js" ".gitignore" ".claudeignore" \
      ".claude/settings.json" "sitemap.xml" "robots.txt")
    case "$HOST_PRIMARY" in
      joshwho-ftp)
        dirs+=("deploy")
        files+=("deploy/deploy.sh" "deploy/.env.example")
        ;;
    esac
    case "$FORM_HANDLER" in
      php)
        dirs+=("forms")
        files+=("forms/contact.php" "thank-you.html")
        ;;
    esac
    if [[ "$SEC_HEADERS" == "true" ]]; then
      case "$HOST_PRIMARY" in
        joshwho-ftp) files+=(".htaccess") ;;
        netlify) files+=("_headers") ;;
      esac
    fi
  fi
  for rel in "${dirs[@]}"; do
    target="$(arkira_safe_target "$REPO_ROOT" "$rel")" \
      || { echo "ERROR: unsafe scaffold directory: $rel" >&2; return 1; }
    if [[ -e "$target" || -L "$target" ]]; then
      [[ -d "$target" && ! -L "$target" ]] \
        || { echo "ERROR: scaffold directory is not a regular directory: $rel" >&2; return 1; }
    fi
  done
  for rel in "${files[@]}"; do
    target="$(arkira_safe_target "$REPO_ROOT" "$rel")" \
      || { echo "ERROR: unsafe scaffold file: $rel" >&2; return 1; }
    if [[ -e "$target" || -L "$target" ]]; then
      [[ -f "$target" && ! -L "$target" ]] \
        || { echo "ERROR: scaffold target is not a regular file: $rel" >&2; return 1; }
    fi
  done
}

# Resolve and type-check the complete dynamic target set before the first
# repository mutation. Later publication still uses no-clobber claims because
# preflight alone cannot prevent a concurrent creator.
preflight_scaffold

if [[ "$MODE" == "apply" ]]; then
  TRANSACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arkira-init-web.XXXXXX")"
  chmod 700 "$TRANSACTION_DIR"
  TRANSACTION_DIR="$(cd -P -- "$TRANSACTION_DIR" && pwd -P)"
  arkira_safe_mkdir_new "$REPO_ROOT" ".arkira-init-web.lock" \
    || { echo "ERROR: another static scaffold transaction is active" >&2; exit 1; }
  SCAFFOLD_LOCK_IDENTITY="$(arkira_stat_identity \
    "$REPO_ROOT/.arkira-init-web.lock")"
fi

ensure_dir() {
  local d="$1"
  local target
  target="$(arkira_safe_target "$REPO_ROOT" "$d")" \
    || { echo "ERROR: unsafe scaffold path: $d" >&2; return 1; }
  if [[ -e "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] \
      || { echo "ERROR: scaffold directory is not a regular directory: $d" >&2; return 1; }
  else
    plan_dir "$d"
    if [[ "$MODE" == "apply" ]]; then
      arkira_safe_mkdir_new "$REPO_ROOT" "$d" || return 1
      CREATED_DIRS+=("$d")
      CREATED_DIR_IDENTITIES+=("$(arkira_stat_identity "$REPO_ROOT/$d")")
    fi
  fi
}

# write_if_new <target>; content comes from stdin (heredoc).
write_if_new() {
  local rel="$1" mode="${2:-644}" target
  local content stage identity
  content="$(cat)"
  target="$(arkira_safe_target "$REPO_ROOT" "$rel")" \
    || { echo "ERROR: unsafe scaffold path: $rel" >&2; return 1; }
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || { echo "ERROR: scaffold target is not a regular file: $rel" >&2; return 1; }
    plan_skip "$rel"
  else
    plan_write "$rel"
    if [[ "$MODE" == "apply" ]]; then
      stage="$(mktemp "$TRANSACTION_DIR/write.XXXXXX")" || return 1
      printf '%s' "$content" > "$stage"
      chmod "$mode" "$stage"
      if [[ "${ARKIRA_INIT_WEB_TEST_CREATE_BEFORE_REL:-}" == "$rel" ]]; then
        printf 'concurrent creator\n' > "$REPO_ROOT/$rel"
        unset ARKIRA_INIT_WEB_TEST_CREATE_BEFORE_REL
      fi
      identity="$(arkira_atomic_copy_new_with_identity \
        "$REPO_ROOT" "$rel" "$stage")" || return 1
      CREATED_FILES+=("$rel")
      CREATED_FILE_IDENTITIES+=("$identity")
      CREATED_FILE_SNAPSHOTS+=("$stage")
      if [[ "${ARKIRA_INIT_WEB_TEST_MUTATE_AFTER_CREATE_REL:-}" == "$rel" ]]; then
        printf 'concurrent edit after create\n' >> "$REPO_ROOT/$rel"
        unset ARKIRA_INIT_WEB_TEST_MUTATE_AFTER_CREATE_REL
        return 1
      fi
    fi
  fi
}

copy_if_new() {
  local src="$1" rel="$2" target stage identity
  target="$(arkira_safe_target "$REPO_ROOT" "$rel")" \
    || { echo "ERROR: unsafe scaffold path: $rel" >&2; return 1; }
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || { echo "ERROR: scaffold target is not a regular file: $rel" >&2; return 1; }
    plan_skip "$rel"
  else
    plan_write "$rel"
    if [[ "$MODE" == "apply" ]]; then
      stage="$(mktemp "$TRANSACTION_DIR/copy.XXXXXX")" || return 1
      cp -p -- "$src" "$stage" || return 1
      if [[ "${ARKIRA_INIT_WEB_TEST_CREATE_BEFORE_REL:-}" == "$rel" ]]; then
        printf 'concurrent creator\n' > "$REPO_ROOT/$rel"
        unset ARKIRA_INIT_WEB_TEST_CREATE_BEFORE_REL
      fi
      identity="$(arkira_atomic_copy_new_with_identity \
        "$REPO_ROOT" "$rel" "$stage")" || return 1
      CREATED_FILES+=("$rel")
      CREATED_FILE_IDENTITIES+=("$identity")
      CREATED_FILE_SNAPSHOTS+=("$stage")
      if [[ "${ARKIRA_INIT_WEB_TEST_MUTATE_AFTER_CREATE_REL:-}" == "$rel" ]]; then
        printf 'concurrent edit after create\n' >> "$REPO_ROOT/$rel"
        unset ARKIRA_INIT_WEB_TEST_MUTATE_AFTER_CREATE_REL
        return 1
      fi
    fi
  fi
}

rollback_scaffold() {
  local i rel claim identity target failed=0
  [[ "$MODE" == "apply" && "$COMMITTED" -eq 0 ]] || return 0
  [[ "$ROLLBACK_DONE" -eq 0 ]] || return 0
  ROLLBACK_DONE=1

  if [[ -n "$CONFIG_PUBLISHED_IDENTITY" ]]; then
    claim="$(arkira_claim_regular_file "$REPO_ROOT" ".arkira/config.json" \
      ".arkira-web-config-rollback" 2>/dev/null || true)"
    if [[ -n "$claim" ]]; then
      identity="$(arkira_stat_identity "$REPO_ROOT/$claim" 2>/dev/null || true)"
      if [[ "$identity" == "$CONFIG_PUBLISHED_IDENTITY" ]] \
        && scaffold_file_matches "$claim" "$CONFIG_STAGE"; then
        if [[ "$CONFIG_EXISTED" -eq 1 ]]; then
          arkira_restore_claim_new "$REPO_ROOT" "$CONFIG_CLAIM_REL" \
            ".arkira/config.json" || failed=1
        fi
        arkira_safe_remove_file "$REPO_ROOT" "$claim" || failed=1
      else
        arkira_restore_claim_new "$REPO_ROOT" "$claim" \
          ".arkira/config.json" || failed=1
        echo "ERROR: scaffold rollback preserved concurrent config edit" >&2
        failed=1
      fi
    else
      target="$(arkira_safe_target "$REPO_ROOT" ".arkira/config.json" \
        2>/dev/null || true)"
      if [[ "$CONFIG_EXISTED" -eq 1 && -n "$target" \
        && ! -e "$target" && ! -L "$target" ]]; then
        arkira_restore_claim_new "$REPO_ROOT" "$CONFIG_CLAIM_REL" \
          ".arkira/config.json" || failed=1
      else
        failed=1
      fi
    fi
  elif [[ "$CONFIG_EXISTED" -eq 1 && -n "$CONFIG_CLAIM_REL" ]]; then
    target="$(arkira_safe_target "$REPO_ROOT" ".arkira/config.json" \
      2>/dev/null || true)"
    if [[ -n "$target" && ! -e "$target" && ! -L "$target" ]]; then
      arkira_restore_claim_new "$REPO_ROOT" "$CONFIG_CLAIM_REL" \
        ".arkira/config.json" || failed=1
    else
      failed=1
    fi
  fi

  for ((i=${#CREATED_FILES[@]}-1; i>=0; i--)); do
    rel="${CREATED_FILES[$i]}"
    [[ "$rel" == ".arkira/config.json" ]] && continue
    target="$(arkira_safe_target "$REPO_ROOT" "$rel" 2>/dev/null || true)"
    if [[ -z "$target" ]] \
      || { [[ ! -e "$target" ]] && [[ ! -L "$target" ]]; }; then
      continue
    fi
    claim="$(arkira_claim_regular_file "$REPO_ROOT" "$rel" \
      ".arkira-web-created-rollback" 2>/dev/null || true)"
    if [[ -z "$claim" ]]; then
      failed=1
      continue
    fi
    identity="$(arkira_stat_identity "$REPO_ROOT/$claim" 2>/dev/null || true)"
    if [[ "$identity" == "${CREATED_FILE_IDENTITIES[$i]}" ]] \
      && scaffold_file_matches "$claim" "${CREATED_FILE_SNAPSHOTS[$i]}"; then
      arkira_safe_remove_file "$REPO_ROOT" "$claim" || failed=1
    else
      arkira_restore_claim_new "$REPO_ROOT" "$claim" "$rel" || failed=1
      printf 'ERROR: scaffold rollback preserved concurrent edit: %s\n' "$rel" >&2
      failed=1
    fi
  done
  for ((i=${#CREATED_DIRS[@]}-1; i>=0; i--)); do
    rel="${CREATED_DIRS[$i]}"
    if [[ "$(arkira_stat_identity "$REPO_ROOT/$rel" 2>/dev/null || true)" \
      == "${CREATED_DIR_IDENTITIES[$i]}" ]]; then
      arkira_safe_rmdir "$REPO_ROOT" "$rel" 2>/dev/null || failed=1
    fi
  done
  return "$failed"
}

cleanup_scaffold() {
  local lock_target
  lock_target="$(arkira_safe_target "$REPO_ROOT" ".arkira-init-web.lock" \
    2>/dev/null || true)"
  if [[ -n "$lock_target" && -d "$lock_target" && ! -L "$lock_target" \
    && "$(arkira_stat_identity "$lock_target" 2>/dev/null || true)" \
      == "$SCAFFOLD_LOCK_IDENTITY" ]]; then
    arkira_safe_rmdir "$REPO_ROOT" ".arkira-init-web.lock" \
      || echo "WARNING: could not remove owned scaffold lock" >&2
  elif [[ -n "$SCAFFOLD_LOCK_IDENTITY" ]]; then
    echo "WARNING: owned scaffold lock changed; refusing to remove it" >&2
  fi
  [[ -z "$TRANSACTION_DIR" ]] || rm -rf -- "$TRANSACTION_DIR"
  TRANSACTION_DIR=""
}

scaffold_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  rollback_scaffold || echo "ERROR: scaffold rollback was incomplete" >&2
  cleanup_scaffold
  exit "$rc"
}

handle_scaffold_signal() {
  local signal=$1
  trap - "$signal" EXIT HUP INT TERM
  rollback_scaffold || echo "ERROR: scaffold rollback was incomplete" >&2
  cleanup_scaffold
  kill -s "$signal" "$$"
  exit 1
}

if [[ "$MODE" == "apply" ]]; then
  trap scaffold_exit EXIT
  trap 'handle_scaffold_signal HUP' HUP
  trap 'handle_scaffold_signal INT' INT
  trap 'handle_scaffold_signal TERM' TERM
fi

# --- always: .arkira/config.json (overwrites) ----------------------------
ensure_dir ".arkira"
plan_write ".arkira/config.json"
if [[ "$MODE" == "apply" ]]; then
  CONFIG_STAGE="$TRANSACTION_DIR/config.after"
  printf '%s\n' "$DECISIONS" | jq '.' > "$CONFIG_STAGE"
  chmod 600 "$CONFIG_STAGE"
  if [[ -e "$REPO_ROOT/.arkira/config.json" \
    || -L "$REPO_ROOT/.arkira/config.json" ]]; then
    [[ -f "$REPO_ROOT/.arkira/config.json" && ! -L "$REPO_ROOT/.arkira/config.json" ]] \
      || { echo "ERROR: config target is not a regular file" >&2; exit 1; }
    CONFIG_EXISTED=1
    CONFIG_BACKUP="$TRANSACTION_DIR/config.before"
    arkira_safe_read "$REPO_ROOT" ".arkira/config.json" >"$CONFIG_BACKUP"
    chmod "$(arkira_safe_file_mode "$REPO_ROOT" ".arkira/config.json")" "$CONFIG_BACKUP"
    CONFIG_CLAIM_REL="$(arkira_claim_regular_file "$REPO_ROOT" \
      ".arkira/config.json" ".arkira-web-config-original")" \
      || { echo "ERROR: could not claim config target" >&2; exit 1; }
    CONFIG_CLAIM_IDENTITY="$(arkira_stat_identity \
      "$REPO_ROOT/$CONFIG_CLAIM_REL")"
    scaffold_file_matches "$CONFIG_CLAIM_REL" "$CONFIG_BACKUP" \
      || { echo "ERROR: config changed before atomic claim" >&2; exit 1; }
  else
    CONFIG_EXISTED=0
  fi
  CONFIG_PUBLISHED_IDENTITY="$(arkira_atomic_copy_new_with_identity \
    "$REPO_ROOT" ".arkira/config.json" "$CONFIG_STAGE")" \
    || { echo "ERROR: concurrent config creator blocked scaffold" >&2; exit 1; }
  if [[ -n "${ARKIRA_INIT_WEB_PAUSE_AFTER_CONFIG:-}" ]]; then
    sleep "$ARKIRA_INIT_WEB_PAUSE_AFTER_CONFIG"
  fi
fi

# --- shared project brief and pointer overlays (never overwrite) ----------
write_if_new "AGENTS.md" <<EOF
# ${REPO_NAME} Project Context

READ FIRST: This file is the shared project brief and normative context for all agents working in this repository.

Static brochure site. Follows STATIC-WEB v1 (\`arkira-labs-standards/static-web/static-web-standard.md\`).

## Profile

- profile: static-web
- site_kind: ${SITE_KIND}
- host_primary: ${HOST_PRIMARY}
- form_handler: ${FORM_HANDLER}
- entity_brand: ${ENTITY_BRAND}

## Project Brief

Replace this paragraph with the purpose, audience, design direction, and content requirements for this specific site. Keep the profile block above so future tooling can read it.

## Local preview

\`\`\`
python3 -m http.server 8000
\`\`\`

## Deploy

See \`README.md\`.
EOF

copy_if_new "$SCRIPT_DIR/../../ai-engineering/root/CLAUDE.md" "CLAUDE.md"
copy_if_new "$SCRIPT_DIR/../../ai-engineering/root/CODEX.md" "CODEX.md"

if $SCAFFOLD; then
# --- README.md (never overwrites) ----------------------------------------
write_if_new "README.md" <<EOF
# ${REPO_NAME}

Static brochure site. See \`AGENTS.md\` for the shared project brief.

## Local preview

\`\`\`
python3 -m http.server 8000
\`\`\`

## Deploy

Host: ${HOST_PRIMARY}. Form handler: ${FORM_HANDLER}.

See \`deploy/deploy.sh\` (FTP) or the Netlify dashboard, per host.
EOF

# --- scaffold ------------------------------------------------------------
  ensure_dir "styles"
  ensure_dir "scripts"
  ensure_dir "assets"
  ensure_dir "assets/fonts"
  ensure_dir "assets/images"
  ensure_dir "assets/icons"

  for d in assets/fonts assets/images assets/icons; do
    write_if_new "$d/.gitkeep" </dev/null
  done

  # index.html
  BRAND_ATTR=""
  [[ -n "$ENTITY_BRAND" ]] && BRAND_ATTR=" data-brand=\"$ENTITY_BRAND\""
  write_if_new "index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${REPO_NAME}</title>
  <meta name="description" content="">
  <link rel="canonical" href="https://example.com/">
  <link rel="stylesheet" href="/styles/main.css">
</head>
<body${BRAND_ATTR}>
  <main>
    <h1>${REPO_NAME}</h1>
    <p>Static-web scaffold. See <code>AGENTS.md</code> for the project brief.</p>
  </main>
  <script src="/scripts/main.js" defer></script>
</body>
</html>
EOF

  # styles/main.css
  write_if_new "styles/main.css" <<'EOF'
/* Token layer. Edit primitives to match the entity brand kit. */
:root {
  --color-bg: #ffffff;
  --color-fg: #111111;
  --color-accent: #000000;
  --color-muted: #666666;
  --color-link: var(--color-accent);
  --target-min: 44px;
}

/* Reset and base */
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  background: var(--color-bg);
  color: var(--color-fg);
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  line-height: 1.5;
  padding: 2rem;
}
a { color: var(--color-link); }

/* Honeypot: hide regardless of form handler */
input[name="website"] { display: none; }
EOF

  # scripts/main.js
  write_if_new "scripts/main.js" <<'EOF'
// Keep this minimal. Static brochure sites do not need a framework.
EOF

  # .gitignore
  write_if_new ".gitignore" <<'EOF'
# OS
.DS_Store
Thumbs.db
# Editor
.vscode/
.idea/
*.swp
# Logs
*.log
# Env / secrets
.env
.env.local
deploy/.env
# Build / tooling (if added later)
node_modules/
dist/
.cache/
EOF

  # Compatibility-only ignore file. Claude Code does not consume
  # .claudeignore; the supported exclusions live in project settings below.
  copy_if_new "$SCRIPT_DIR/../../templates/.claudeignore" ".claudeignore"

  # Supported Claude Code context controls. This is a no-clobber scaffold:
  # existing project settings are user-owned and remain byte-identical.
  ensure_dir ".claude"
  copy_if_new "$SCRIPT_DIR/../../templates/claude-settings.baseline.json" ".claude/settings.json"

  # sitemap.xml
  write_if_new "sitemap.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://example.com/</loc></url>
</urlset>
EOF

  # robots.txt
  write_if_new "robots.txt" <<'EOF'
User-agent: *
Allow: /
Sitemap: https://example.com/sitemap.xml
EOF

  # host-specific: deploy
  case "$HOST_PRIMARY" in
    joshwho-ftp)
      ensure_dir "deploy"
      write_if_new "deploy/deploy.sh" 755 <<'EOF'
#!/usr/bin/env bash
# FTP deploy script for cPanel-style hosts (e.g., JoshWho).
# Reads credentials from deploy/.env. Mirrors the project root to FTP_REMOTE_DIR.
# Requires lftp (macOS: brew install lftp).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then set -a; . "$SCRIPT_DIR/.env"; set +a; fi
: "${FTP_HOST:?FTP_HOST not set in deploy/.env}"
: "${FTP_USER:?FTP_USER not set in deploy/.env}"
: "${FTP_PASS:?FTP_PASS not set in deploy/.env}"
: "${FTP_REMOTE_DIR:=/public_html}"
# Verify the TLS certificate by default. Some cPanel hosts serve a self-signed or
# mismatched cert; only then set FTP_SSL_VERIFY=no in deploy/.env, knowing it
# disables MITM protection for the credentials and the uploaded content.
: "${FTP_SSL_VERIFY:=yes}"
echo "Deploying $PROJECT_DIR -> $FTP_HOST:$FTP_REMOTE_DIR"
lftp -u "$FTP_USER","$FTP_PASS" "$FTP_HOST" <<LFTP
set ftp:ssl-allow yes
set ssl:verify-certificate $FTP_SSL_VERIFY
mirror -R --delete --verbose \
  --exclude-glob '.git*' \
  --exclude-glob 'deploy/*' \
  --exclude-glob 'CLAUDE.md' \
  --exclude-glob 'CODEX.md' \
  --exclude-glob 'AGENTS.md' \
  --exclude-glob 'README.md' \
  --exclude-glob '.arkira/*' \
  --exclude-glob '.DS_Store' \
  --exclude-glob 'node_modules/*' \
  --exclude-glob '.env*' \
  "$PROJECT_DIR" "$FTP_REMOTE_DIR"
bye
LFTP
echo "Deploy complete."
EOF

      write_if_new "deploy/.env.example" <<'EOF'
# Copy to deploy/.env (gitignored) and fill in.
FTP_HOST=
FTP_USER=
FTP_PASS=
FTP_REMOTE_DIR=/public_html
EOF
      ;;
    netlify)
      plan_note "host=netlify: deploy via Netlify dashboard or Git connect, no deploy/ folder needed"
      ;;
    formspree-only)
      plan_note "host=formspree-only: no scaffolded deploy script; configure your host separately"
      ;;
  esac

  # form handler
  case "$FORM_HANDLER" in
    php)
      ensure_dir "forms"
      write_if_new "forms/contact.php" <<EOF
<?php
// Contact form handler for cPanel/PHP hosts.
// EDIT TO_EMAIL before going live.
declare(strict_types=1);

const TO_EMAIL       = "you@example.com";
const SUBJECT_PREFIX = "[${REPO_NAME}] Inquiry from ";

if (\$_SERVER["REQUEST_METHOD"] !== "POST") {
    http_response_code(405);
    exit("Method not allowed");
}

\$name    = trim((string)(\$_POST["name"]    ?? ""));
\$email   = trim((string)(\$_POST["email"]   ?? ""));
\$message = trim((string)(\$_POST["message"] ?? ""));
\$hp      = trim((string)(\$_POST["website"] ?? ""));

if (\$hp !== "") { http_response_code(200); exit("OK"); }
if (\$name === "" || \$message === "" || !filter_var(\$email, FILTER_VALIDATE_EMAIL)) {
    http_response_code(400);
    exit("Please complete your name, a valid email, and a message.");
}

\$safeEmail = str_replace(["\\r","\\n"], "", \$email);
\$safeName  = str_replace(["\\r","\\n"], "", \$name);

\$subject = SUBJECT_PREFIX . \$safeName;
\$body    = "Name: {\$safeName}\\nEmail: {\$safeEmail}\\n\\n{\$message}\\n";
\$headers = "From: site@" . (\$_SERVER["HTTP_HOST"] ?? "localhost") . "\\r\\n"
         . "Reply-To: {\$safeEmail}\\r\\n"
         . "Content-Type: text/plain; charset=UTF-8\\r\\n";

if (mail(TO_EMAIL, \$subject, \$body, \$headers)) {
    header("Location: /thank-you.html");
    exit;
}

http_response_code(500);
exit("Sorry, the message could not be sent. Please email us directly.");
EOF
      write_if_new "thank-you.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Thank you</title>
  <link rel="stylesheet" href="/styles/main.css">
</head>
<body>
  <main>
    <h1>Thank you</h1>
    <p>We received your message and will be in touch shortly.</p>
  </main>
</body>
</html>
EOF
      ;;
    netlify)
      plan_note "form_handler=netlify: add data-netlify=\"true\" and a hidden form-name input to your <form>; no PHP file needed"
      ;;
    formspree)
      plan_note "form_handler=formspree: point your <form action> to the Formspree endpoint and add an _gotcha input"
      ;;
    none)
      plan_note "form_handler=none: no contact form scaffolded"
      ;;
  esac

  # security headers (per host, if switch on)
  if [[ "$SEC_HEADERS" == "true" ]]; then
    case "$HOST_PRIMARY" in
      joshwho-ftp)
        copy_if_new "$EXAMPLES_DIR/htaccess.example" ".htaccess"
        ;;
      netlify)
        copy_if_new "$EXAMPLES_DIR/netlify-headers.example" "_headers"
        ;;
    esac
  fi
fi

# --- print plan ----------------------------------------------------------
printf '\n--- arkira-init-web (%s) for %s ---\n' "$MODE" "$REPO_ROOT"
for line in "${PLAN_LINES[@]}"; do echo "  $line"; done
echo

if [[ "$MODE" == "apply" ]]; then
  if [[ -n "${ARKIRA_INIT_WEB_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL:-}" ]]; then
    printf 'concurrent edit before scaffold commit\n' \
      >> "$REPO_ROOT/$ARKIRA_INIT_WEB_TEST_MUTATE_BEFORE_FINAL_VALIDATE_REL"
  fi
  [[ "$(arkira_stat_identity "$REPO_ROOT/.arkira/config.json" \
      2>/dev/null || true)" == "$CONFIG_PUBLISHED_IDENTITY" ]] \
    && scaffold_file_matches ".arkira/config.json" "$CONFIG_STAGE" \
    || { echo "ERROR: config changed before scaffold commit" >&2; false; }
  for ((created_index=0; created_index<${#CREATED_FILES[@]}; created_index++)); do
    rel="${CREATED_FILES[$created_index]}"
    [[ "$(arkira_stat_identity "$REPO_ROOT/$rel" 2>/dev/null || true)" \
        == "${CREATED_FILE_IDENTITIES[$created_index]}" ]] \
      && scaffold_file_matches "$rel" \
        "${CREATED_FILE_SNAPSHOTS[$created_index]}" \
      || { printf 'ERROR: scaffold target changed before commit: %s\n' \
          "$rel" >&2; false; }
  done
  COMMITTED=1
  trap - EXIT HUP INT TERM
  cleanup_failed=0
  if [[ -n "$CONFIG_CLAIM_REL" ]]; then
    if [[ "$(arkira_stat_identity "$REPO_ROOT/$CONFIG_CLAIM_REL" \
        2>/dev/null || true)" == "$CONFIG_CLAIM_IDENTITY" ]] \
      && scaffold_file_matches "$CONFIG_CLAIM_REL" "$CONFIG_BACKUP"; then
      arkira_safe_remove_file "$REPO_ROOT" "$CONFIG_CLAIM_REL" \
        || cleanup_failed=1
    else
      cleanup_failed=1
    fi
  fi
  cleanup_scaffold
  [[ "$cleanup_failed" -eq 0 ]] \
    || { echo "ERROR: scaffold applied but owned recovery state remains" >&2; exit 1; }
  echo "Arkira static-web configured for $REPO_ROOT."
else
  echo "Dry run. No changes made. Re-run with --apply to write."
fi
