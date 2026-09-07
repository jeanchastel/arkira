#!/usr/bin/env bash
set -uo pipefail

ARKIRA_HARNESS_STORE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=ai-engineering/runtime/receipt-lib.sh
. "$ARKIRA_HARNESS_STORE_DIR/receipt-lib.sh"

arkira_harness_store_error() {
  printf 'harness store: %s\n' "$*" >&2
  return 1
}

arkira_harness_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    arkira_harness_store_error 'shasum or sha256sum is required'
  fi
}

arkira_harness_file_mode() {
  local path=$1 mode
  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s' "$mode"
  elif mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    printf '%s' "$mode"
  else
    return 1
  fi
}

arkira_harness_store_root() {
  local runtime root
  runtime="$(arkira_receipt_runtime_root)" || return 1
  root="$runtime/harnesses"
  [[ ! -L "$root" ]] || return 1
  mkdir -p -- "$root" || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  chmod 700 "$root" || return 1
  printf '%s' "$root"
}

arkira_harness_safe_relative() {
  local path=${1:-}
  [[ -n "$path" && "$path" != /* && "$path" != . && "$path" != .. \
    && "$path" != ../* && "$path" != */../* && "$path" != */.. \
    && "$path" != *$'\t'* && "$path" != *$'\n'* && "$path" != *$'\r'* ]]
}

arkira_harness_manifest() {
  local source=$1 output=$2
  [[ -d "$source" && ! -L "$source" ]] || return 1
  if ! perl -MFile::Find -MDigest::SHA -MFcntl=:mode -e '
    use strict;
    use warnings;
    my ($root, $output) = @ARGV;
    my @rows;
    find({no_chdir => 1, wanted => sub {
      my $path = $File::Find::name;
      my $relative = $path eq $root ? "" : substr($path, length($root) + 1);
      if (-d _ && ($relative eq ".git" || $relative eq ".arkira")) {
        $File::Find::prune = 1;
        return;
      }
      return if $relative eq "" || $relative eq ".arkira-harness-manifest.tsv" ||
        $relative eq ".arkira-harness-meta.json";
      my @stat = lstat $path;
      return unless @stat && S_ISREG($stat[2]) && !S_ISLNK($stat[2]);
      exit 1 if $relative =~ m{^/|(^|/)\.\.(/|$)|[\t\r\n]};
      open my $handle, "<:raw", $path or exit 1;
      my $digest = Digest::SHA->new(256);
      $digest->addfile($handle);
      close $handle;
      push @rows, join("\t", $digest->hexdigest, sprintf("%o", $stat[2] & 07777), $relative);
    }}, $root);
    open my $out, ">", $output or exit 1;
    print {$out} join("\n", sort @rows), "\n" or exit 1;
    close $out or exit 1;
  ' "$source" "$output"; then
    return 1
  fi
  [[ -s "$output" ]] || return 1
}

arkira_harness_snapshot_digest() {
  local manifest=$1 sha=$2 version=$3 channel=$4 verified=$5 identity
  identity="$(jq -cn --arg sha "$sha" --arg version "$version" --arg channel "$channel" \
    --argjson verified "$verified" \
    '{schema_version:1,source_sha:$sha,version:$version,channel:$channel,verified:$verified}')" || return 1
  { printf '%s\n' "$identity"; cat -- "$manifest"; } | arkira_receipt_sha256
}

arkira_harness_verify() {
  local snapshot=${1:-} canonical digest expected manifest meta sha version channel verified
  local listed actual
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  canonical="$(cd -- "$snapshot" && pwd -P)" || return 1
  digest=${canonical##*/}
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  manifest="$canonical/.arkira-harness-manifest.tsv"
  meta="$canonical/.arkira-harness-meta.json"
  [[ -f "$manifest" && ! -L "$manifest" && -f "$meta" && ! -L "$meta" ]] || return 1
  jq -e --arg digest "$digest" '
    .schema_version == 1 and .content_digest == $digest and
    (.source_sha | type == "string") and (.version | type == "string") and
    (.channel | type == "string") and (.verified | type == "boolean") and
    (.captured_epoch | type == "number")
  ' "$meta" >/dev/null 2>&1 || return 1
  sha="$(jq -r '.source_sha' "$meta")" || return 1
  version="$(jq -r '.version' "$meta")" || return 1
  channel="$(jq -r '.channel' "$meta")" || return 1
  verified="$(jq -r '.verified' "$meta")" || return 1
  expected="$(arkira_harness_snapshot_digest "$manifest" "$sha" "$version" "$channel" "$verified")" || return 1
  [[ "$expected" == "$digest" ]] || return 1
  if find "$canonical" -type l -print -quit | grep -q .; then return 1; fi
  listed="$(mktemp "${TMPDIR:-/tmp}/arkira-harness-listed.XXXXXX")" || return 1
  actual="$(mktemp "${TMPDIR:-/tmp}/arkira-harness-actual.XXXXXX")" || { rm -f -- "$listed"; return 1; }
  if ! perl -MDigest::SHA=sha256_hex -MFcntl=:mode -e '
    use strict;
    use warnings;
    my ($manifest, $root, $listed) = @ARGV;
    open my $in, "<", $manifest or exit 1;
    open my $out, ">", $listed or exit 1;
    while (my $line = <$in>) {
      chomp $line;
      my ($sha, $mode, $path) = split /\t/, $line, 3;
      exit 1 unless defined $path && $sha =~ /^[a-f0-9]{64}$/ && $mode =~ /^[0-7]{3,4}$/;
      exit 1 if $path eq "" || $path =~ m{^/|(^|/)\.\.(/|$)|[\t\r\n]};
      my $file = "$root/$path";
      my @stat = lstat $file;
      exit 1 unless @stat && S_ISREG($stat[2]) && !S_ISLNK($stat[2]);
      exit 1 unless sprintf("%o", $stat[2] & 07777) eq $mode;
      open my $handle, "<:raw", $file or exit 1;
      local $/;
      my $bytes = <$handle>;
      close $handle;
      exit 1 unless sha256_hex($bytes) eq $sha;
      print {$out} "$path\n" or exit 1;
    }
    close $out or exit 1;
  ' "$manifest" "$canonical" "$listed"; then
    rm -f -- "$listed" "$actual"
    return 1
  fi
  find "$canonical" \
    -name '.arkira-harness-manifest.tsv' -prune -o \
    -name '.arkira-harness-meta.json' -prune -o \
    -type f -print | sed "s#^$canonical/##" | LC_ALL=C sort > "$actual" || {
      rm -f -- "$listed" "$actual"; return 1;
    }
  LC_ALL=C sort "$listed" -o "$listed" || { rm -f -- "$listed" "$actual"; return 1; }
  cmp -s "$listed" "$actual"
  local status=$?
  rm -f -- "$listed" "$actual"
  return "$status"
}

arkira_harness_capture() {
  local source=${1:-} channel=${2:-installed} verified=${3:-true}
  local canonical store manifest digest target stage sha version epoch file_sha mode path
  [[ "$verified" == true || "$verified" == false ]] || return 1
  canonical="$(realpath "$source" 2>/dev/null)" || return 1
  [[ -d "$canonical" && ! -L "$canonical" ]] || return 1
  [[ -f "$canonical/.claude-plugin/plugin.json" && ! -L "$canonical/.claude-plugin/plugin.json" ]] || return 1
  version="$(jq -er '.version | select(type == "string" and length > 0)' \
    "$canonical/.claude-plugin/plugin.json" 2>/dev/null)" || return 1
  sha=${ARKIRA_HARNESS_SHA:-}
  if [[ ! "$sha" =~ ^[a-f0-9]{40}$ ]]; then
    sha="$(git -C "$canonical" rev-parse HEAD 2>/dev/null || true)"
  fi
  [[ "$sha" =~ ^[a-f0-9]{40}$ ]] || sha='unavailable'
  store="$(arkira_harness_store_root)" || return 1
  manifest="$(mktemp "$store/.manifest.XXXXXX")" || return 1
  if ! arkira_harness_manifest "$canonical" "$manifest"; then rm -f -- "$manifest"; return 1; fi
  digest="$(arkira_harness_snapshot_digest "$manifest" "$sha" "$version" "$channel" "$verified")" || {
    rm -f -- "$manifest"; return 1;
  }
  target="$store/$digest"
  [[ ! -L "$target" ]] || { rm -f -- "$manifest"; return 1; }
  if [[ -e "$target" ]]; then
    rm -f -- "$manifest"
    arkira_harness_verify "$target" || return 1
    printf '%s\n' "$digest"
    return 0
  fi
  stage="$(mktemp -d "$store/.capture.XXXXXX")" || { rm -f -- "$manifest"; return 1; }
  while IFS=$'\t' read -r file_sha mode path; do
    mkdir -p -- "$stage/$(dirname -- "$path")" || { rm -rf -- "$stage"; rm -f -- "$manifest"; return 1; }
    cp -p -- "$canonical/$path" "$stage/$path" || { rm -rf -- "$stage"; rm -f -- "$manifest"; return 1; }
    chmod "$mode" "$stage/$path" || { rm -rf -- "$stage"; rm -f -- "$manifest"; return 1; }
  done < "$manifest"
  mv -- "$manifest" "$stage/.arkira-harness-manifest.tsv" || { rm -rf -- "$stage"; return 1; }
  epoch="$(date +%s)"
  jq -n --arg digest "$digest" --arg source_sha "$sha" --arg version "$version" \
    --arg channel "$channel" --argjson verified "$verified" --argjson epoch "$epoch" \
    '{schema_version:1,content_digest:$digest,source_sha:$source_sha,version:$version,
      channel:$channel,verified:$verified,captured_epoch:$epoch}' \
    > "$stage/.arkira-harness-meta.json" || { rm -rf -- "$stage"; return 1; }
  chmod 600 "$stage/.arkira-harness-manifest.tsv" "$stage/.arkira-harness-meta.json" || {
    rm -rf -- "$stage"; return 1;
  }
  if ! mv -- "$stage" "$target" 2>/dev/null; then
    rm -rf -- "$stage"
    [[ -d "$target" ]] && arkira_harness_verify "$target" || return 1
  fi
  arkira_harness_verify "$target" || return 1
  printf '%s\n' "$digest"
}

arkira_harness_binding_dir() {
  local runtime directory
  runtime="$(arkira_receipt_runtime_root)" || return 1
  directory="$runtime/harness-bindings"
  [[ ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  chmod 700 "$directory" || return 1
  printf '%s' "$directory"
}

arkira_harness_bind() {
  local repo=${1:-} digest=${2:-} identity directory target stage
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  arkira_harness_verify "$(arkira_harness_store_root)/$digest" || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_harness_binding_dir)" || return 1
  target="$directory/$identity.json"
  [[ ! -L "$target" ]] || return 1
  stage="$(mktemp "$directory/.binding.XXXXXX")" || return 1
  jq -n --arg identity "$identity" --arg digest "$digest" \
    '{schema_version:1,repo_identity:$identity,content_digest:$digest}' > "$stage" || {
      rm -f -- "$stage"; return 1;
    }
  chmod 600 "$stage" && mv -f -- "$stage" "$target" || { rm -f -- "$stage"; return 1; }
}

arkira_harness_resolve_digest() {
  local repo=$1 fallback=${2:-} rollback_digest=${3:-} rollback_sha=${4:-}
  local identity runtime active binding digest channel verified snapshot
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  runtime="$(arkira_receipt_runtime_root)" || return 1
  active="$runtime/goals/$identity/active.json"
  if [[ -e "$active" || -L "$active" ]]; then
    [[ -f "$active" && ! -L "$active" ]] || return 1
    digest="$(jq -er --arg identity "$identity" '
      if .schema_version == 1 and
        ((.repo_identity // $identity) == $identity) and
        (.state | IN("prepared","running","sealed")) and
        (.harness.content_digest | type == "string" and test("^[a-f0-9]{64}$"))
      then .harness.content_digest else empty end
    ' "$active" 2>/dev/null)" || return 1
    printf '%s' "$digest"
    return 0
  fi
  if [[ -n "$rollback_digest" || -n "$rollback_sha" ]]; then
    [[ "$rollback_digest" =~ ^[a-f0-9]{64}$ \
      && ( "$rollback_sha" =~ ^[a-f0-9]{40}$ || "$rollback_sha" == unavailable ) ]] \
      || return 1
    snapshot="$(arkira_harness_store_root)/$rollback_digest"
    arkira_harness_verify "$snapshot" || return 1
    jq -e --arg sha "$rollback_sha" \
      '.source_sha == $sha and .channel == "installed" and .verified == true' \
      "$snapshot/.arkira-harness-meta.json" >/dev/null 2>&1 || return 1
    arkira_harness_bind "$repo" "$rollback_digest" || return 1
    printf '%s' "$rollback_digest"
    return 0
  fi
  if [[ -n "$fallback" ]]; then
    channel=${ARKIRA_HARNESS_CHANNEL:-installed}
    verified=${ARKIRA_HARNESS_VERIFIED:-true}
    digest="$(arkira_harness_capture "$fallback" "$channel" "$verified")" || return 1
    arkira_harness_bind "$repo" "$digest" || return 1
    printf '%s' "$digest"
    return 0
  fi
  binding="$(arkira_harness_binding_dir)/$identity.json"
  if [[ -e "$binding" || -L "$binding" ]]; then
    [[ -f "$binding" && ! -L "$binding" ]] || return 1
    digest="$(jq -er --arg identity "$identity" '
      if .schema_version == 1 and .repo_identity == $identity and
        (.content_digest | type == "string" and test("^[a-f0-9]{64}$"))
      then .content_digest else empty end
    ' "$binding" 2>/dev/null)" || return 1
    printf '%s' "$digest"
    return 0
  fi
  return 1
}

arkira_harness_resolve() {
  local repo=${1:-} fallback=${2:-} rollback_digest=${3:-} rollback_sha=${4:-} digest snapshot
  digest="$(arkira_harness_resolve_digest "$repo" "$fallback" "$rollback_digest" "$rollback_sha")" \
    || return 1
  snapshot="$(arkira_harness_store_root)/$digest"
  arkira_harness_verify "$snapshot" || return 1
  printf '%s\n' "$snapshot"
}

arkira_harness_gc() {
  local keep=${1:-3} store runtime refs listing rank=0 digest epoch path target
  [[ "$keep" =~ ^[0-9]+$ ]] || return 1
  store="$(arkira_harness_store_root)" || return 1
  runtime="$(arkira_receipt_runtime_root)" || return 1
  refs="$(mktemp "$store/.refs.XXXXXX")" || return 1
  listing="$(mktemp "$store/.listing.XXXXXX")" || { rm -f -- "$refs"; return 1; }
  while IFS= read -r path; do
    jq -r '.. | objects | .content_digest? // empty | select(type == "string" and test("^[a-f0-9]{64}$"))' \
      "$path" 2>/dev/null || true
  done < <(find "$runtime/harness-bindings" "$runtime/goals" -type f -name '*.json' -print 2>/dev/null) \
    | LC_ALL=C sort -u > "$refs"
  for target in "$store"/[a-f0-9]*; do
    [[ -d "$target" && ! -L "$target" ]] || continue
    digest=${target##*/}
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || continue
    epoch="$(jq -r '.captured_epoch // 0' "$target/.arkira-harness-meta.json" 2>/dev/null || printf 0)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    printf '%020d\t%s\n' "$epoch" "$digest" >> "$listing" || { rm -f -- "$refs" "$listing"; return 1; }
  done
  LC_ALL=C sort -r "$listing" -o "$listing" || { rm -f -- "$refs" "$listing"; return 1; }
  while IFS=$'\t' read -r epoch digest; do
    rank=$((rank + 1))
    if (( rank <= keep )) || grep -Fxq -- "$digest" "$refs"; then continue; fi
    target="$store/$digest"
    [[ "$target" == "$store"/[a-f0-9]* && "$digest" =~ ^[a-f0-9]{64}$ && -d "$target" && ! -L "$target" ]] || {
      rm -f -- "$refs" "$listing"; return 1;
    }
    rm -rf -- "$target" || { rm -f -- "$refs" "$listing"; return 1; }
    printf 'removed %s\n' "$digest"
  done < "$listing"
  rm -f -- "$refs" "$listing"
}

arkira_harness_store_usage() {
  printf 'usage: harness-store.sh capture <source> [channel verified] | verify <snapshot> | bind <repo> <digest> | resolve <repo> <fallback> [rollback-digest rollback-sha] | gc [keep]\n' >&2
  return 2
}

arkira_harness_store_main() {
  local command=${1:-}
  case "$command" in
    capture) [[ "$#" -ge 2 && "$#" -le 4 ]] || { arkira_harness_store_usage; return; }; arkira_harness_capture "$2" "${3:-installed}" "${4:-true}" ;;
    verify) [[ "$#" -eq 2 ]] || { arkira_harness_store_usage; return; }; arkira_harness_verify "$2" ;;
    bind) [[ "$#" -eq 3 ]] || { arkira_harness_store_usage; return; }; arkira_harness_bind "$2" "$3" ;;
    resolve) [[ "$#" -eq 3 || "$#" -eq 5 ]] || { arkira_harness_store_usage; return; }; arkira_harness_resolve "$2" "$3" "${4:-}" "${5:-}" ;;
    gc) [[ "$#" -le 2 ]] || { arkira_harness_store_usage; return; }; arkira_harness_gc "${2:-3}" ;;
    *) arkira_harness_store_usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then arkira_harness_store_main "$@"; fi
