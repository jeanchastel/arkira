#!/usr/bin/env bash
# Shared containment and atomic-write primitives for scaffold and sync writers.
#
# Validation alone is not enough for a mutation: a repository directory can be
# exchanged after it is checked. Mutating helpers therefore bind a subshell to
# the destination parent, verify that directory's device/inode, and perform the
# operation with basename-only paths from that bound working directory.

arkira_safe_root() {
  local root=${1:-}
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  (cd -- "$root" 2>/dev/null && pwd -P)
}

arkira_validate_relative_path() {
  local rel=${1:-}
  [ -n "$rel" ] || return 1
  case "$rel" in
    /*|.|..|../*|*/../*|*/..|./*|*//*|*/) return 1 ;;
  esac
  if printf '%s' "$rel" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
}

arkira_safe_target() {
  local root=${1:-} rel=${2:-} current part index last
  [ -n "$root" ] && arkira_validate_relative_path "$rel" || return 1
  current="$root"
  IFS='/' read -r -a arkira_path_parts <<<"$rel"
  last=$((${#arkira_path_parts[@]} - 1))
  for index in "${!arkira_path_parts[@]}"; do
    part=${arkira_path_parts[$index]}
    [ -n "$part" ] && [ "$part" != "." ] && [ "$part" != ".." ] || return 1
    current="$current/$part"
    [ ! -L "$current" ] || return 1
    if [ "$index" -lt "$last" ] && [ -e "$current" ]; then
      [ -d "$current" ] || return 1
    fi
  done
  printf '%s' "$root/$rel"
}

arkira_stat_identity() {
  if stat -f '%d:%i' -- "$1" >/dev/null 2>&1; then
    stat -f '%d:%i' -- "$1"
  else
    stat -c '%d:%i' -- "$1"
  fi
}

# Run a callback with the destination parent held as the subshell's working
# directory. The callback receives the basename followed by any extra args.
# It must use basename-only paths for every mutation.
_arkira_with_bound_parent() {
  local allow_final_link=$1
  shift
  local root=${1:-} rel=${2:-} callback=${3:-}
  local target parent base parent_rel anchor_rel expected actual checked_parent
  shift 3 || return 1
  if [[ "$allow_final_link" -eq 1 ]]; then
    arkira_validate_relative_path "$rel" || return 1
    base="$(basename -- "$rel")"
    parent_rel="$(dirname -- "$rel")"
    if [[ "$parent_rel" == "." ]]; then
      parent="$root"
      anchor_rel=".arkira-parent-anchor"
    else
      anchor_rel="$parent_rel/.arkira-parent-anchor"
      parent="$(dirname -- "$(arkira_safe_target "$root" "$anchor_rel")")" || return 1
    fi
  else
    target="$(arkira_safe_target "$root" "$rel")" || return 1
    parent="$(dirname -- "$target")"
    base="$(basename -- "$target")"
  fi
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  expected="$(arkira_stat_identity "$parent")" || return 1

  # Tests can exchange the parent at this exact boundary. A production caller
  # already has code execution, so a caller-defined hook grants no new power.
  if declare -F arkira_file_safety_before_bind >/dev/null 2>&1; then
    arkira_file_safety_before_bind "$parent"
  fi

  (
    cd -- "$parent" || exit 1
    actual="$(arkira_stat_identity .)" || exit 1
    [ "$actual" = "$expected" ] || exit 1

    # Re-resolve only to verify that the repository still names this same
    # directory. The callback never uses that re-resolved path.
    if [[ "$allow_final_link" -eq 1 ]]; then
      checked_parent="$(dirname -- "$(arkira_safe_target "$root" "$anchor_rel")")" || exit 1
    else
      checked_parent="$(dirname -- "$(arkira_safe_target "$root" "$rel")")" || exit 1
    fi
    [ "$(arkira_stat_identity "$checked_parent")" = "$actual" ] || exit 1

    # A test hook at the last possible name-resolution boundary proves that the
    # callback is anchored to this already-open working directory. If the
    # repository name is exchanged after this point, basename-only mutation
    # still lands in the bound directory inode and cannot follow the replacement.
    if declare -F arkira_file_safety_after_bind >/dev/null 2>&1; then
      arkira_file_safety_after_bind "$parent"
    fi
    "$callback" "$base" "$@"
  )
}

arkira_with_bound_parent() {
  _arkira_with_bound_parent 0 "$@"
}

arkira_with_bound_parent_allow_final_link() {
  _arkira_with_bound_parent 1 "$@"
}

_arkira_mkdir_bound() {
  local base=$1
  if [ -e "$base" ] || [ -L "$base" ]; then
    [ -d "$base" ] && [ ! -L "$base" ]
  else
    mkdir -m 755 -- "$base"
  fi
}

arkira_safe_mkdir() {
  local root=${1:-} rel=${2:-} current_rel="" part
  [ -n "$root" ] && arkira_validate_relative_path "$rel" || return 1
  IFS='/' read -r -a arkira_mkdir_parts <<<"$rel"
  for part in "${arkira_mkdir_parts[@]}"; do
    [ -n "$part" ] || return 1
    current_rel="${current_rel:+$current_rel/}$part"
    if [ -e "$root/$current_rel" ] || [ -L "$root/$current_rel" ]; then
      arkira_safe_target "$root" "$current_rel" >/dev/null || return 1
      [ -d "$root/$current_rel" ] && [ ! -L "$root/$current_rel" ] || return 1
    else
      arkira_with_bound_parent "$root" "$current_rel" _arkira_mkdir_bound || return 1
    fi
  done
}

_arkira_mkdir_new_bound() {
  local base=$1
  [ ! -e "$base" ] && [ ! -L "$base" ] || return 1
  mkdir -m 700 -- "$base"
}

# Create exactly one private directory and fail if its final name already
# exists. This is suitable for cooperative transaction locks: a caller never
# adopts or removes a directory it did not create.
arkira_safe_mkdir_new() {
  local root=${1:-} rel=${2:-}
  arkira_with_bound_parent "$root" "$rel" _arkira_mkdir_new_bound
}

_arkira_claim_regular_bound() {
  local base=$1 prefix=$2 claim
  case "$prefix" in
    ''|*/*) return 1 ;;
  esac
  [[ -f "$base" && ! -L "$base" ]] || return 1
  claim="$(mktemp "${prefix}.XXXXXX")" || return 1
  rm -f -- "$claim" || return 1
  if ! node -e '
const fs = require("fs");
const source = process.argv[1];
const destination = process.argv[2];
const stat = fs.lstatSync(source);
if (!stat.isFile() || stat.isSymbolicLink()) process.exit(1);
fs.renameSync(source, destination);
' "$base" "$claim"; then
    rm -f -- "$claim"
    return 1
  fi
  printf '%s' "$claim"
}

# Atomically take ownership of a regular target name by renaming it to an
# unpredictable sibling. The target name is absent on success, so callers can
# use a no-clobber publication primitive without a check-then-write gap.
arkira_claim_regular_file() {
  local root=${1:-} rel=${2:-} prefix=${3:-.arkira-claim} parent claim
  claim="$(arkira_with_bound_parent "$root" "$rel" \
    _arkira_claim_regular_bound "$prefix")" || return 1
  parent="$(dirname -- "$rel")"
  printf '%s' "${parent:+${parent#./}/}$claim" | sed 's#^\./##'
}

_arkira_restore_claim_new_bound() {
  local destination=$1 source=$2
  [[ -f "$source" && ! -L "$source" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  node -e '
const fs = require("fs");
fs.linkSync(process.argv[1], process.argv[2]);
fs.unlinkSync(process.argv[1]);
' "$source" "$destination"
}

# Restore a same-directory regular claim only when the destination is absent.
# The hard-link publication is atomic and cannot replace a concurrent entry.
arkira_restore_claim_new() {
  local root=${1:-} claim_rel=${2:-} destination_rel=${3:-}
  [[ "$(dirname -- "$claim_rel")" == "$(dirname -- "$destination_rel")" ]] \
    || return 1
  arkira_with_bound_parent "$root" "$destination_rel" \
    _arkira_restore_claim_new_bound "$(basename -- "$claim_rel")"
}

_arkira_exact_rename() {
  node -e '
const fs = require("fs");
fs.renameSync(process.argv[1], process.argv[2]);
' "$1" "$2"
}

_arkira_atomic_copy_bound() {
  local base=$1 source=$2 tmp
  if [ -e "$base" ] || [ -L "$base" ]; then
    [ -f "$base" ] && [ ! -L "$base" ] || return 1
  fi
  tmp="$(mktemp .arkira-write.XXXXXX)" || return 1
  if ! cp -p -- "$source" "$tmp" || ! _arkira_exact_rename "$tmp" "$base"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Copy a regular source to a contained destination using a same-directory
# unique temporary file and an exact atomic rename. Source mode is preserved.
arkira_atomic_copy() {
  local root=${1:-} rel=${2:-} source=${3:-} source_dir source_base source_abs
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  source_dir="$(cd -- "$(dirname -- "$source")" 2>/dev/null && pwd -P)" || return 1
  source_base="$(basename -- "$source")"
  source_abs="$source_dir/$source_base"
  arkira_with_bound_parent "$root" "$rel" _arkira_atomic_copy_bound "$source_abs"
}

_arkira_atomic_copy_new_bound() {
  local base=$1 source=$2 tmp identity
  [ ! -e "$base" ] && [ ! -L "$base" ] || return 1
  tmp="$(mktemp .arkira-write.XXXXXX)" || return 1
  if ! cp -p -- "$source" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  identity="$(arkira_stat_identity "$tmp")" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! node -e '
const fs = require("fs");
fs.linkSync(process.argv[1], process.argv[2]);
fs.unlinkSync(process.argv[1]);
' "$tmp" "$base"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s' "$identity"
}

arkira_atomic_copy_new_with_identity() {
  local root=${1:-} rel=${2:-} source=${3:-} source_dir source_base source_abs
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  source_dir="$(cd -- "$(dirname -- "$source")" 2>/dev/null && pwd -P)" || return 1
  source_base="$(basename -- "$source")"
  source_abs="$source_dir/$source_base"
  arkira_with_bound_parent "$root" "$rel" _arkira_atomic_copy_new_bound "$source_abs"
}

# Install a complete copy only when the destination is absent. The hard-link
# publication step is atomic and fails rather than replacing a concurrent file.
arkira_atomic_copy_new() {
  arkira_atomic_copy_new_with_identity "$@" >/dev/null
}

_arkira_unique_copy_bound() {
  local _anchor=$1 prefix=$2 source=$3 tmp
  case "$prefix" in
    ''|*/*) return 1 ;;
  esac
  tmp="$(mktemp "${prefix}.XXXXXX")" || return 1
  if ! cp -p -- "$source" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s' "$tmp"
}

# Create a uniquely named complete copy in a contained directory and print its
# repository-relative path. This is used for retained user recovery backups.
arkira_unique_copy() {
  local root=${1:-} parent_rel=${2:-} prefix=${3:-} source=${4:-} anchor name
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  if [ -n "$parent_rel" ] && [ "$parent_rel" != "." ]; then
    anchor="$parent_rel/.arkira-backup-anchor"
  else
    parent_rel=""
    anchor=".arkira-backup-anchor"
  fi
  name="$(arkira_with_bound_parent "$root" "$anchor" _arkira_unique_copy_bound "$prefix" "$source")" \
    || return 1
  printf '%s' "${parent_rel:+$parent_rel/}$name"
}

_arkira_atomic_write_bound() {
  local base=$1 mode=$2 tmp
  if [ -e "$base" ] || [ -L "$base" ]; then
    [ -f "$base" ] && [ ! -L "$base" ] || return 1
  fi
  tmp="$(mktemp .arkira-write.XXXXXX)" || return 1
  if ! (umask 077; cat >"$tmp") \
    || ! chmod "$mode" "$tmp" \
    || ! _arkira_exact_rename "$tmp" "$base"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Write stdin to a contained destination using a same-directory unique
# temporary file and exact atomic rename. Directories and non-regular final
# targets are rejected instead of being treated as move destinations.
arkira_atomic_write() {
  local root=${1:-} rel=${2:-} mode=${3:-600}
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  arkira_with_bound_parent "$root" "$rel" _arkira_atomic_write_bound "$mode"
}

_arkira_safe_read_bound() {
  local base=$1
  node -e '
const fs = require("fs");
const c = fs.constants;
const fd = fs.openSync(process.argv[1], c.O_RDONLY | (c.O_NOFOLLOW || 0));
try {
  const st = fs.fstatSync(fd);
  if (!st.isFile()) process.exitCode = 1;
  else process.stdout.write(fs.readFileSync(fd));
} finally {
  fs.closeSync(fd);
}
' "$base"
}

arkira_safe_read() {
  local root=${1:-} rel=${2:-}
  arkira_with_bound_parent "$root" "$rel" _arkira_safe_read_bound
}

_arkira_safe_file_mode_bound() {
  local base=$1
  node -e '
const fs = require("fs");
const c = fs.constants;
const fd = fs.openSync(process.argv[1], c.O_RDONLY | (c.O_NOFOLLOW || 0));
try {
  const st = fs.fstatSync(fd);
  if (!st.isFile()) process.exitCode = 1;
  else process.stdout.write((st.mode & 0o777).toString(8));
} finally {
  fs.closeSync(fd);
}
' "$base"
}

arkira_safe_file_mode() {
  local root=${1:-} rel=${2:-}
  arkira_with_bound_parent "$root" "$rel" _arkira_safe_file_mode_bound
}

_arkira_safe_remove_file_bound() {
  local base=$1
  if [ ! -e "$base" ] && [ ! -L "$base" ]; then
    return 0
  fi
  if [ ! -L "$base" ]; then
    [ -f "$base" ] || return 1
  fi
  node -e 'require("fs").unlinkSync(process.argv[1])' "$base"
}

arkira_safe_remove_file() {
  local root=${1:-} rel=${2:-}
  arkira_with_bound_parent_allow_final_link "$root" "$rel" _arkira_safe_remove_file_bound
}

_arkira_safe_rmdir_bound() {
  local base=$1
  if [ ! -e "$base" ] && [ ! -L "$base" ]; then
    return 0
  fi
  if [ -L "$base" ]; then
    node -e 'require("fs").unlinkSync(process.argv[1])' "$base"
  else
    [ -d "$base" ] || return 1
    node -e 'require("fs").rmdirSync(process.argv[1])' "$base"
  fi
}

arkira_safe_rmdir() {
  local root=${1:-} rel=${2:-}
  arkira_with_bound_parent_allow_final_link "$root" "$rel" _arkira_safe_rmdir_bound
}
