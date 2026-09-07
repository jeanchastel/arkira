#!/usr/bin/env bash
# Content-bound dispatch receipts.
#
# This proves that exact file content changed during a window in which a
# dispatch ran and succeeded. It does not prove operating-system-level process
# authorship. Concurrent writes inside that window are captured in the same
# delta and are indistinguishable from dispatched-provider writes.

arkira_receipt_runtime_root() {
  printf '%s' "${ARKIRA_RUNTIME_HOME:-${ARKIRA_ROLE_HOME:-$HOME}/.arkira/runtime}"
}

arkira_receipt_sha256() {
  shasum -a 256 | awk '{print $1}'
}

arkira_receipt_repo_identity_fresh() {
  local repo=${1:-} top origin listing line primary='' verify mine theirs
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
  top="$(cd -- "$top" && pwd -P)" || return 1
  # Linked worktrees are checkouts of one repository and must share one identity.
  # git worktree list --porcelain names the main worktree first; that is Git's own
  # answer and does not depend on directory naming. Under --separate-git-dir and
  # displaced core.worktree layouts it reports the Git directory rather than a work
  # tree, so the reported path is adopted only once Git confirms it is itself a
  # work-tree root and only once it is proven to share this checkout's object store.
  # Anything that cannot be resolved and proven keeps this checkout's own top level,
  # which is exactly the previous behavior.
  listing="$(cd -- "$repo" 2>/dev/null && git worktree list --porcelain 2>/dev/null)" || listing=''
  if [[ -n "$listing" ]]; then
    while IFS= read -r line; do
      case "$line" in
        'worktree '*) primary=${line#worktree }; break ;;
      esac
    done <<< "$listing"
  fi
  if [[ -n "$primary" && "$primary" == /* && -d "$primary" ]]; then
    primary="$(cd -- "$primary" && pwd -P)" || primary=''
    verify="$(cd -- "${primary:-/nonexistent}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || verify=''
    verify="$(cd -- "${verify:-/nonexistent}" 2>/dev/null && pwd -P)" || verify=''
    mine="$(cd -- "$repo" 2>/dev/null && cd -- "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || mine=''
    theirs="$(cd -- "${primary:-/nonexistent}" 2>/dev/null && cd -- "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || theirs=''
    if [[ -n "$primary" && -n "$verify" && "$verify" == "$primary" \
      && -n "$mine" && "$mine" == "$theirs" ]]; then
      top="$primary"
    fi
  fi
  origin="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
  ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT=$repo
  ARKIRA_RECEIPT_IDENTITY_REPO=$top
  ARKIRA_RECEIPT_IDENTITY_VALUE="$(printf '%s\0%s' "$top" "$origin" | arkira_receipt_sha256)" || return 1
  export ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT ARKIRA_RECEIPT_IDENTITY_REPO \
    ARKIRA_RECEIPT_IDENTITY_VALUE
  printf '%s' "$ARKIRA_RECEIPT_IDENTITY_VALUE"
}

arkira_receipt_repo_identity() {
  local repo=${1:-}
  [[ -n "$repo" ]] || return 1
  if [[ ( "${ARKIRA_RECEIPT_IDENTITY_REPO_ARGUMENT:-}" == "$repo" || \
    "${ARKIRA_RECEIPT_IDENTITY_REPO:-}" == "$repo" ) && \
    "${ARKIRA_RECEIPT_IDENTITY_VALUE:-}" =~ ^[a-f0-9]{64}$ ]]; then
    printf '%s' "$ARKIRA_RECEIPT_IDENTITY_VALUE"
    return 0
  fi
  arkira_receipt_repo_identity_fresh "$repo"
}

arkira_receipt_reject_symlink_components() {
  [[ -n "${1:-}" && ! -L "$1" ]]
}

arkira_receipt_prepare_dirs() {
  local root receipts identity
  root="$(arkira_receipt_runtime_root)"
  identity=${1:-}
  [[ "$identity" =~ ^[a-f0-9]{64}$ ]] || return 1
  receipts="$root/receipts"
  arkira_receipt_reject_symlink_components "$root" || return 1
  arkira_receipt_reject_symlink_components "$receipts" || return 1
  arkira_receipt_reject_symlink_components "$receipts/$identity" || return 1
  mkdir -p -- "$receipts/$identity" || return 1
  [[ -d "$root" && -d "$receipts" && -d "$receipts/$identity" ]] || return 1
  arkira_receipt_reject_symlink_components "$root" || return 1
  arkira_receipt_reject_symlink_components "$receipts" || return 1
  arkira_receipt_reject_symlink_components "$receipts/$identity" || return 1
  chmod 700 "$root" "$receipts" "$receipts/$identity" || return 1
}

arkira_receipt_store_dir() {
  local repo=${1:-} identity
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  if [[ "${ARKIRA_RECEIPT_STORE_IDENTITY:-}" == "$identity" && -n "${ARKIRA_RECEIPT_STORE_DIR:-}" ]]; then
    printf '%s' "$ARKIRA_RECEIPT_STORE_DIR"
    return 0
  fi
  arkira_receipt_prepare_dirs "$identity" || return 1
  ARKIRA_RECEIPT_STORE_IDENTITY=$identity
  ARKIRA_RECEIPT_STORE_DIR="$(arkira_receipt_runtime_root)/receipts/$identity"
  export ARKIRA_RECEIPT_STORE_IDENTITY ARKIRA_RECEIPT_STORE_DIR
  printf '%s' "$ARKIRA_RECEIPT_STORE_DIR"
}

arkira_receipt_worktree_mode() {
  local path=${1:-}
  if [[ -x "$path" ]]; then printf '100755'; else printf '100644'; fi
}

arkira_receipt_snapshot() {
  local repo=${1:-} out=${2:-} top entries hash_output path record header mode blob exists changed candidate
  local arg_max hash_chunk_size index hash_index chunk_start chunk_length
  local -a changed_paths=() snapshot_paths=() snapshot_modes=() snapshot_blobs=()
  local -a snapshot_exists=() snapshot_needs_hash=() hash_paths=() hashes=()
  [[ -n "$out" && ! -L "$out" ]] || return 1
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 1
  entries="$(mktemp "$(dirname -- "$out")/.receipt-snapshot.XXXXXX")" || return 1
  : > "$entries"
  while IFS= read -r -d '' path; do
    changed_paths+=("$path")
  done < <(git -C "$top" diff-files -z --name-only)
  while IFS= read -r -d '' record; do
    header="${record%%$'\t'*}"
    path="${record#*$'\t'}"
    IFS=' ' read -r mode blob _ <<< "$header"
    changed=false
    for candidate in "${changed_paths[@]-}"; do
      [[ "$path" == "$candidate" ]] && { changed=true; break; }
    done
    exists=true
    if [[ "$changed" == true ]]; then
      if [[ -e "$top/$path" || -L "$top/$path" ]]; then
        mode="$(arkira_receipt_worktree_mode "$top/$path")"
        blob=''
      else
        blob=null
        exists=false
      fi
    fi
    snapshot_paths+=("$path")
    snapshot_modes+=("$mode")
    snapshot_blobs+=("$blob")
    snapshot_exists+=("$exists")
    if [[ "$changed" == true && "$exists" == true ]]; then
      snapshot_needs_hash+=(true)
      hash_paths+=("$path")
    else
      snapshot_needs_hash+=(false)
    fi
  done < <(git -C "$top" ls-files -s -z)
  while IFS= read -r -d '' path; do
    exists=true
    if [[ -e "$top/$path" || -L "$top/$path" ]]; then
      mode="$(arkira_receipt_worktree_mode "$top/$path")"
      blob=''
    else
      blob=null
      exists=false
    fi
    snapshot_paths+=("$path")
    snapshot_modes+=("$mode")
    snapshot_blobs+=("$blob")
    snapshot_exists+=("$exists")
    if [[ "$exists" == true ]]; then
      snapshot_needs_hash+=(true)
      hash_paths+=("$path")
    else
      snapshot_needs_hash+=(false)
    fi
  done < <(git -C "$top" ls-files -z --others --exclude-standard)
  arg_max="$(getconf ARG_MAX 2>/dev/null || printf 262144)"
  [[ "$arg_max" =~ ^[0-9]+$ ]] || arg_max=262144
  hash_chunk_size=$((arg_max / 8192))
  (( hash_chunk_size < 1 )) && hash_chunk_size=1
  (( hash_chunk_size > 128 )) && hash_chunk_size=128
  hash_output="$(mktemp "$(dirname -- "$out")/.receipt-hashes.XXXXXX")" || {
    rm -f -- "$entries"
    return 1
  }
  chunk_start=0
  while (( chunk_start < ${#hash_paths[@]} )); do
    chunk_length=$hash_chunk_size
    (( chunk_start + chunk_length > ${#hash_paths[@]} )) && \
      chunk_length=$((${#hash_paths[@]} - chunk_start))
    git -C "$top" hash-object -- "${hash_paths[@]:$chunk_start:$chunk_length}" > "$hash_output" || {
      rm -f -- "$entries" "$hash_output"
      return 1
    }
    while IFS= read -r blob; do
      hashes+=("$blob")
    done < "$hash_output"
    chunk_start=$((chunk_start + chunk_length))
  done
  rm -f -- "$hash_output"
  [[ ${#hashes[@]} -eq ${#hash_paths[@]} ]] || { rm -f -- "$entries"; return 1; }
  hash_index=0
  for ((index = 0; index < ${#snapshot_paths[@]}; index++)); do
    blob="${snapshot_blobs[$index]}"
    if [[ "${snapshot_needs_hash[$index]}" == true ]]; then
      blob="${hashes[$hash_index]}"
      hash_index=$((hash_index + 1))
    fi
    printf '%s\0%s\0%s\0%s\0' "${snapshot_paths[$index]}" "${snapshot_modes[$index]}" \
      "$blob" "${snapshot_exists[$index]}" >> "$entries" || {
      rm -f -- "$entries"
      return 1
    }
  done
  jq -Rs '
    split("\u0000") | .[:-1] |
    [range(0; length; 4) as $index |
      {path:.[$index], mode:.[$index + 1],
       blob:(if .[$index + 3] == "true" then .[$index + 2] else null end),
       exists:(.[$index + 3] == "true")}]
    | {entries:.}
  ' "$entries" > "$out" || { rm -f -- "$entries"; return 1; }
  rm -f -- "$entries"
}

arkira_receipt_new_typescript_emit_paths() {
  local pre=${1:-} post=${2:-}
  [[ -f "$pre" && ! -L "$pre" && -f "$post" && ! -L "$post" ]] || return 1
  jq -cn --slurpfile pre "$pre" --slurpfile post "$post" '
    def source_candidates:
      if endswith(".d.ts.map") then
        [sub("\\.d\\.ts\\.map$"; ".ts"), sub("\\.d\\.ts\\.map$"; ".tsx")]
      elif endswith(".d.mts.map") then [sub("\\.d\\.mts\\.map$"; ".mts")]
      elif endswith(".d.cts.map") then [sub("\\.d\\.cts\\.map$"; ".cts")]
      elif endswith(".js.map") then
        [sub("\\.js\\.map$"; ".ts"), sub("\\.js\\.map$"; ".tsx")]
      elif endswith(".jsx.map") then [sub("\\.jsx\\.map$"; ".tsx")]
      elif endswith(".mjs.map") then [sub("\\.mjs\\.map$"; ".mts")]
      elif endswith(".cjs.map") then [sub("\\.cjs\\.map$"; ".cts")]
      elif endswith(".d.ts") then
        [sub("\\.d\\.ts$"; ".ts"), sub("\\.d\\.ts$"; ".tsx")]
      elif endswith(".d.mts") then [sub("\\.d\\.mts$"; ".mts")]
      elif endswith(".d.cts") then [sub("\\.d\\.cts$"; ".cts")]
      elif endswith(".js") then [sub("\\.js$"; ".ts"), sub("\\.js$"; ".tsx")]
      elif endswith(".jsx") then [sub("\\.jsx$"; ".tsx")]
      elif endswith(".mjs") then [sub("\\.mjs$"; ".mts")]
      elif endswith(".cjs") then [sub("\\.cjs$"; ".cts")]
      else [] end;
    def as_exists_map:
      reduce .[] as $entry ({}; .[$entry.path] = ($entry.exists == true));
    ($pre[0].entries | as_exists_map) as $before |
    ($post[0].entries | as_exists_map) as $after |
    [$post[0].entries[] |
      select(.exists == true) |
      .path as $path |
      select(($before[$path] // false) != true) |
      ($path | source_candidates) as $sources |
      select($sources | map(. as $source | ($after[$source] // false) == true) | any) |
      $path] | unique
  '
}

arkira_receipt_validate() {
  local receipt=${1:-}
  [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
  jq -e '
    .schema_version == 1 and
    (.receipt_id | type == "string" and length > 0) and
    (.repo_identity | type == "string" and test("^[a-f0-9]{64}$")) and
    (.created_epoch | type == "number") and
    (.author_role | type == "string" and length > 0) and
    (.author_provider | type == "string" and length > 0) and
    (.author_model | type == "string") and
    ((.author_effort? == null) or (.author_effort | type == "string" and length > 0)) and
    ((.contract_digest? == null) or
      (.contract_digest | type == "string" and test("^[a-f0-9]{64}$"))) and
    (.job_id | type == "string" and length > 0) and
    (.entries | type == "array") and
    all(.entries[]; (.path | type == "string" and length > 0) and
      ((.deleted == true and (has("blob") | not) and (has("mode") | not)) or
       ((has("deleted") | not) and (.blob | type == "string" and test("^[a-f0-9]{40,64}$")) and
        (.mode | type == "string" and test("^100[0-7]{3}$")))))
  ' "$receipt" >/dev/null 2>&1
}

arkira_receipt_write() {
  local repo=${1:-} pre=${2:-} post=${3:-} metadata=${4:-} identity directory id target temp
  [[ -f "$pre" && ! -L "$pre" && -f "$post" && ! -L "$post" ]] || return 1
  jq -e '.entries | type == "array"' "$pre" >/dev/null || return 1
  jq -e '.entries | type == "array"' "$post" >/dev/null || return 1
  jq -e '(.author_role, .author_provider, .job_id, .author_effort |
      type == "string" and length > 0) and
    (.author_model | type == "string") and
    ((.contract_digest? == null) or
      (.contract_digest | type == "string" and test("^[a-f0-9]{64}$"))) and
    (if .author_role == "executor" then (.author_model | length > 0) else true end)' \
    <<< "$metadata" >/dev/null || return 1
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_receipt_store_dir "$repo")" || return 1
  id="receipt-$(date '+%s')-$$-${RANDOM}${RANDOM}"
  target="$directory/$id.json"
  [[ ! -e "$target" && ! -L "$target" ]] || return 1
  temp="$(mktemp "$directory/.receipt.XXXXXX")" || return 1
  if ! jq -n --slurpfile pre "$pre" --slurpfile post "$post" --argjson metadata "$metadata" \
    --arg identity "$identity" --arg id "$id" --argjson created_epoch "$(date '+%s')" '
      def as_map: reduce .[] as $entry ({}; .[$entry.path] = $entry);
      ($pre[0].entries | as_map) as $before |
      ($post[0].entries | as_map) as $after |
      [($before + $after | keys[]) as $path |
        $before[$path] as $old | $after[$path] as $new |
        if $old == null then {path:$path,blob:$new.blob,mode:$new.mode}
        elif $old.exists == true and ($new == null or $new.exists == false) then {path:$path,deleted:true}
        elif $old.exists != $new.exists or $old.blob != $new.blob or $old.mode != $new.mode
          then {path:$path,blob:$new.blob,mode:$new.mode}
        else empty end] as $entries |
      {schema_version:1,receipt_id:$id,repo_identity:$identity,created_epoch:$created_epoch,
       author_role:$metadata.author_role,author_provider:$metadata.author_provider,
       author_model:$metadata.author_model,author_effort:$metadata.author_effort,
       job_id:$metadata.job_id,entries:$entries}
       + (if ($metadata.contract_digest // "") == "" then {}
          else {contract_digest:$metadata.contract_digest} end)
    ' > "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  chmod 600 "$temp" || { rm -f -- "$temp"; return 1; }
  arkira_receipt_validate "$temp" || { rm -f -- "$temp"; return 1; }
  [[ ! -L "$target" ]] || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$target" || { rm -f -- "$temp"; return 1; }
  printf '%s\n' "$target"
}

arkira_receipt_read() {
  local repo=${1:-} id=${2:-} directory receipt
  [[ "$id" =~ ^receipt-[0-9]+-[0-9]+-[0-9]+\.json$ ]] || return 1
  directory="$(arkira_receipt_store_dir "$repo")" || return 1
  receipt="$directory/$id"
  arkira_receipt_validate "$receipt" || return 1
  cat -- "$receipt"
}

# For a deletion query, pass literal "deleted" for both blob and mode.
# Emits one compact covering-record JSON object per valid matching receipt.
arkira_receipt_covering_records() {
  local repo=${1:-} path=${2:-} blob=${3:-} mode=${4:-} identity directory
  local -a receipts=()
  identity="$(arkira_receipt_repo_identity "$repo")" || return 1
  directory="$(arkira_receipt_store_dir "$repo")" || return 1
  shopt -s nullglob
  receipts=("$directory"/receipt-*.json)
  shopt -u nullglob
  ((${#receipts[@]})) || return 0
  jq -c --arg identity "$identity" --arg path "$path" --arg blob "$blob" --arg mode "$mode" '
    def valid:
      (.schema_version == 1) and
      (.receipt_id | type == "string" and test("^receipt-[0-9]+-[0-9]+-[0-9]+$")) and
      (.repo_identity | type == "string" and test("^[a-f0-9]{64}$")) and
      (.created_epoch | type == "number") and
      (.author_role | type == "string" and length > 0) and
      (.author_provider | type == "string" and length > 0) and
      (.author_model | type == "string") and
      ((.author_effort? == null) or (.author_effort | type == "string" and length > 0)) and
      ((.contract_digest? == null) or
        (.contract_digest | type == "string" and test("^[a-f0-9]{64}$"))) and
      (.job_id | type == "string" and length > 0) and
      (.entries | type == "array") and
      all(.entries[]; (.path | type == "string" and length > 0) and
        ((.deleted == true and (has("blob") | not) and (has("mode") | not)) or
         ((has("deleted") | not) and (.blob | type == "string" and test("^[a-f0-9]{40,64}$")) and
          (.mode | type == "string" and test("^100[0-7]{3}$")))));
    select(valid and .repo_identity == $identity and
      any(.entries[]; .path == $path and
        (if $blob == "deleted" and $mode == "deleted" then .deleted == true
         else .blob == $blob and .mode == $mode end))) |
    {receipt_id,author_role,author_provider,author_model,contract_digest:(.contract_digest // null),
      author_effort:(.author_effort // "not_recorded")}
  ' "${receipts[@]}"
}

arkira_receipt_covers_entry() {
  local records
  records="$(arkira_receipt_covering_records "$@")" || return 1
  [[ -n "$records" ]]
}

arkira_receipt_prune() {
  local repo=${1:-} directory now receipt epoch
  directory="$(arkira_receipt_store_dir "$repo")" || return 1
  now="$(date '+%s')"
  for receipt in "$directory"/receipt-*.json; do
    [[ -e "$receipt" ]] || continue
    [[ -f "$receipt" && ! -L "$receipt" ]] || continue
    epoch="$(jq -r '.created_epoch // 0' "$receipt" 2>/dev/null || printf 0)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    if [[ $((now - epoch)) -gt 86400 ]]; then rm -f -- "$receipt"; fi
  done
}
