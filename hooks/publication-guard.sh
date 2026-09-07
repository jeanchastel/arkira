#!/usr/bin/env bash
# Defense in depth for a Claude Code session that loads this plugin. It checks
# host-session publication calls, but is bypassable outside that session.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[[ -n "$payload" ]] || exit 0
tool="$(printf '%s' "$payload" | jq -er '.tool_name // empty' 2>/dev/null || true)"
command="$(printf '%s' "$payload" | jq -er '.tool_input.command // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -er '.cwd // empty' 2>/dev/null || true)"
[[ "$tool" == Bash && -n "$command" && -n "$cwd" ]] || exit 0

stage_a_reason="Publication commands must run as standalone simple commands. This command mixes a publication operation with an unsupported shell construct in one segment. Move the substitution into its own segment, for example: msg=\$(...); git commit -m \"\$msg\""

contains_word() {
  local text=$1 word=$2 pattern
  pattern="(^|[^[:alnum:]_])${word}([^[:alnum:]_]|$)"
  [[ "$text" =~ $pattern ]]
}

has_publication_verb() {
  local segment=$1
  if contains_word "$segment" git && { contains_word "$segment" push || contains_word "$segment" commit; }; then
    return 0
  fi
  [[ "$segment" =~ (^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+merge([^[:alnum:]_]|$) ]]
}

normalize_ref() {
  local ref=$1
  if [[ "$ref" == refs/* ]]; then
    printf '%s\n' "$ref"
  else
    printf 'refs/heads/%s\n' "$ref"
  fi
}

classify_push() {
  local segment=$1 token remote='' refspec delete_requested=0 push_seen=0
  local lease_value lease_ref lease_sha deleted_ref
  local -a tokens=() refspecs=()
  read -r -a tokens <<< "$segment"

  for token in "${tokens[@]+"${tokens[@]}"}"; do
    if [[ "$push_seen" -eq 0 ]]; then
      [[ "$token" == push ]] && push_seen=1
      continue
    fi
    if [[ "$token" == *\"* || "$token" == *"'"* || "$token" == *'$'* || "$token" == *\`* || "$token" == *'*'* || "$token" == *'?'* || "$token" == *'['* ]]; then
      decision=require-committed
      return
    fi
  done
  [[ "$push_seen" -eq 1 ]] || { decision=require-committed; return; }

  push_seen=0
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    if [[ "$push_seen" -eq 0 ]]; then
      [[ "$token" == push ]] && push_seen=1
      continue
    fi
    case "$token" in
      --mirror|--all|--tags|--follow-tags)
        decision=require-committed
        return
        ;;
      --delete|-d)
        delete_requested=1
        ;;
      --force-with-lease)
        decision=block
        block_reason='Deletion lease must use --force-with-lease=<ref>:<40-lowercase-hex-sha>.'
        return
        ;;
      --force-with-lease=*)
        ;;
      -*)
        decision=require-committed
        return
        ;;
      *)
        if [[ -z "$remote" ]]; then
          remote=$token
        else
          refspecs+=("$token")
        fi
        ;;
    esac
  done

  if [[ -z "$remote" || "${#refspecs[@]}" -eq 0 ]]; then
    decision=require-committed
    return
  fi

  for refspec in "${refspecs[@]+"${refspecs[@]}"}"; do
    if [[ "$delete_requested" -eq 0 && "$refspec" != :* ]]; then
      decision=require-committed
      return
    fi
  done

  decision=deletion
  deleted_refs=()
  lease_refs=()
  lease_shas=()
  for refspec in "${refspecs[@]+"${refspecs[@]}"}"; do
    if [[ "$refspec" == :* ]]; then
      deleted_refs+=("$(normalize_ref "${refspec#:}")")
    else
      deleted_refs+=("$(normalize_ref "$refspec")")
    fi
  done
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    [[ "$token" == --force-with-lease=* ]] || continue
    lease_value=${token#--force-with-lease=}
    if [[ "$lease_value" != *:* ]]; then
      decision=block
      block_reason='Deletion lease must use --force-with-lease=<ref>:<40-lowercase-hex-sha>.'
      return
    fi
    lease_ref=${lease_value%%:*}
    lease_sha=${lease_value#*:}
    if [[ -z "$lease_ref" || ! "$lease_sha" =~ ^[0-9a-f]{40}$ ]]; then
      decision=block
      block_reason='Deletion lease must use --force-with-lease=<ref>:<40-lowercase-hex-sha>.'
      return
    fi
    lease_refs+=("$(normalize_ref "$lease_ref")")
    lease_shas+=("$lease_sha")
  done
  for lease_ref in "${lease_refs[@]+"${lease_refs[@]}"}"; do
    for deleted_ref in "${deleted_refs[@]+"${deleted_refs[@]}"}"; do
      [[ "$lease_ref" == "$deleted_ref" ]] && break
    done
    if [[ "$lease_ref" != "$deleted_ref" ]]; then
      decision=block
      block_reason="Deletion lease for $lease_ref does not name a deleted ref."
      return
    fi
  done
}

resolve_command_target() {
  local segment=$1 target=$2 token next_is_c=0
  local -a tokens=()
  read -r -a tokens <<< "$segment"

  for token in "${tokens[@]+"${tokens[@]}"}"; do
    if [[ "$next_is_c" -eq 1 ]]; then
      if [[ "$token" == /* ]]; then
        target=$token
      else
        target="$target/$token"
      fi
      next_is_c=0
      continue
    fi
    [[ "$token" == -C ]] && next_is_c=1
  done
  [[ "$next_is_c" -eq 0 ]] || return 1
  printf '%s\n' "$target"
}

normalize_repo_name() {
  local value=$1 path
  case "$value" in
    *://*)
      path=${value#*://}
      [[ "$path" == */* ]] || return 1
      path=${path#*/}
      ;;
    *:*)
      path=${value#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  [[ "$path" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$ ]] || return 1
  printf '%s\n' "$path"
}

parse_merge_repo() {
  local segment=$1 token merge_seen=0 expect_repo=0
  local -a tokens=()
  read -r -a tokens <<< "$segment"

  merge_repo=''
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    if [[ "$merge_seen" -eq 0 ]]; then
      [[ "$token" == merge ]] && merge_seen=1
      continue
    fi
    if [[ "$expect_repo" -eq 1 ]]; then
      [[ -z "$merge_repo" ]] || return 1
      [[ "$token" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
      merge_repo=$token
      expect_repo=0
      continue
    fi
    case "$token" in
      -R|--repo) expect_repo=1 ;;
    esac
  done
  [[ "$expect_repo" -eq 0 ]]
}

decision=''
block_reason=''
target_segment=''
merge_repo=''
deleted_refs=()
lease_refs=()
lease_shas=()
while IFS= read -r segment || [[ -n "$segment" ]]; do
  while [[ "$segment" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+ ]]; do
    segment=${segment#"${BASH_REMATCH[0]}"}
  done
  has_publication_verb "$segment" || continue
  if [[ "$segment" == *'|'* || "$segment" == *"\$("* || "$segment" == *\`* || "$segment" == *'<('* || "$segment" == *'>('* ]]; then
    decision=block
    block_reason=$stage_a_reason
    break
  fi
  if [[ "$segment" =~ ^[[:space:]]*git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$) ]]; then
    decision=require-staged
    target_segment=$segment
    break
  fi
  if [[ "$segment" =~ ^[[:space:]]*git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$) ]]; then
    classify_push "$segment"
    target_segment=$segment
    break
  fi
  if [[ "$segment" =~ ^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    decision=require-committed
    target_segment=$segment
    if ! parse_merge_repo "$segment"; then
      decision=block
      block_reason='Pull-request merge target does not match this repository. Run the merge from the target repository.'
    fi
    break
  fi
done < <(printf '%s\n' "$command" | awk '{gsub(/&&|\|\||;/, "\n"); print}')
[[ -n "$decision" ]] || exit 0

target="$(resolve_command_target "$target_segment" "$cwd" 2>/dev/null || true)"
[[ -n "$target" ]] || exit 0
has_explicit_c=0
if [[ "$target_segment" =~ (^|[[:space:]])-C([[:space:]]|$) ]]; then
  has_explicit_c=1
fi
repo="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo" ]]; then
  [[ "$has_explicit_c" -eq 1 ]] || exit 0
  block_reason="Command target $target could not be resolved as a work tree. Run the command from the target repository."
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}' >/dev/null || exit 0
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}'
  exit 0
fi
if [[ -n "$merge_repo" ]]; then
  origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  origin_name="$(normalize_repo_name "$origin_url" 2>/dev/null || true)"
  merge_name="$(printf '%s' "$merge_repo" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$origin_name" || "$merge_name" != "$origin_name" ]]; then
    block_reason='Pull-request merge target does not match this repository. Run the merge from the target repository.'
    decision=block
  fi
fi
# Arkira is opt-in. A repository is governed only when it carries a tracked
# .arkira/config.json, established by an explicit Arkira init or sync. This
# reads the index, not the filesystem, so an untracked config cannot enroll a
# repository, and a tracked config that is missing or malformed in the working
# tree still enrolls it and fails closed.
git -C "$repo" ls-files --error-unmatch .arkira/config.json >/dev/null 2>&1 || exit 0
config="$repo/.arkira/config.json"
route=''
force_public_stable=false
has_central_history() {
  local commit historical
  while IFS= read -r commit; do
    historical="$(git -C "$repo" show "$commit:.arkira/config.json" 2>/dev/null || true)"
    jq -e '.harness.channel == "stable" and .harness.repository == "jeanchastel/arkira"' \
      <<<"$historical" >/dev/null 2>&1 && return 0
  done < <(git -C "$repo" rev-list HEAD -- .arkira/config.json)
  return 1
}
if [[ ! -f "$config" || ! -r "$config" ]]; then
  decision=block
  block_reason='Target repository .arkira/config.json is missing or unreadable.'
elif ! pin_state="$(jq -er '
  if .harness == null then
    "disabled"
  elif (.harness | type) != "object" then
    "invalid:\(.harness | type)"
  elif .harness.channel == "stable" and .harness.repository == "jeanchastel/arkira" then
    "configured"
  elif (.harness | has("pin")) and (.harness.pin != null) then
    "configured"
  else
    "disabled"
  end
' "$config" 2>/dev/null)"; then
  decision=block
  block_reason='Target repository .arkira/config.json is not valid JSON.'
elif [[ "$pin_state" == invalid:* ]]; then
  decision=block
  block_reason="Target repository .arkira/config.json .harness must be an object; found ${pin_state#invalid:}."
elif [[ "$pin_state" == configured ]]; then
  route=central
  central_locator="$(dirname "${BASH_SOURCE[0]}")/../bin/arkira"
  if [[ ! -f "$central_locator" || ! -r "$central_locator" ]]; then
    decision=block
    block_reason='Configured Arkira harness locator is missing or unreadable.'
  fi
elif [[ "$pin_state" == disabled ]] && has_central_history; then
  route=central
  force_public_stable=true
  central_locator="$(dirname "${BASH_SOURCE[0]}")/../bin/arkira"
  if [[ ! -f "$central_locator" || ! -r "$central_locator" ]]; then
    decision=block
    block_reason='Configured Arkira harness locator is missing or unreadable.'
  fi
elif [[ "$pin_state" == disabled ]]; then
  route=legacy
  gate="$repo/ai-engineering/runtime/candidate-gate.sh"
  [[ -f "$gate" && ! -L "$gate" ]] || exit 0
else
  decision=block
  block_reason='Target repository .arkira/config.json did not resolve one harness route.'
fi

if [[ "$decision" == block ]]; then
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}' >/dev/null || exit 0
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}'
  exit 0
fi

if [[ "$decision" == deletion ]]; then
  trusted_base="$(git -C "$repo" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
  if [[ -z "$trusted_base" ]]; then
    block_reason='Deletion lease cannot be verified because the trusted base does not resolve.'
  else
    for index in "${!deleted_refs[@]}"; do
      deleted_ref=${deleted_refs[$index]}
      lease_sha=''
      for lease_index in "${!lease_refs[@]}"; do
        if [[ "${lease_refs[$lease_index]}" == "$deleted_ref" ]]; then
          lease_sha=${lease_shas[$lease_index]}
          break
        fi
      done
      if [[ -z "$lease_sha" ]]; then
        block_reason="Deletion of $deleted_ref requires --force-with-lease=${deleted_ref}:<40-lowercase-hex-sha>."
        break
      fi
      if ! git -C "$repo" rev-parse --verify "${lease_sha}^{commit}" >/dev/null 2>&1; then
        block_reason="Deletion lease SHA does not resolve to a commit in the target repository for $deleted_ref."
        break
      fi
      if ! git -C "$repo" merge-base --is-ancestor "$lease_sha" "$trusted_base" >/dev/null 2>&1; then
        block_reason="Deletion lease for $deleted_ref is not proven merged into the trusted base."
        break
      fi
    done
  fi
  if [[ -z "$block_reason" ]]; then
    exit 0
  fi
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}' >/dev/null || exit 0
  jq -cn --arg reason "$block_reason" '{decision:"block",reason:$reason}'
  exit 0
fi

if [[ "$route" == central ]]; then
  # Native hooks are separate processes, so derive the same read-only session
  # identity emitted at SessionStart. Delegated inherited bindings take priority.
  if jq -e '.harness.channel == "stable" and .harness.repository == "jeanchastel/arkira"' \
    "$config" >/dev/null 2>&1 || [[ "$force_public_stable" == true ]]; then
    if ! native_session="$(node "$(dirname "${BASH_SOURCE[0]}")/../ai-engineering/distribution/native-session.mjs" id <<<"$payload")"; then
      jq -cn '{decision:"block",reason:"Native Arkira release session could not be resolved."}'
      exit 0
    fi
    [[ -z "$native_session" ]] || export ARKIRA_RELEASE_SESSION="$native_session"
  fi
  if [[ "$force_public_stable" == true ]]; then
    gate_output="$(ARKIRA_FORCE_PUBLIC_STABLE=true "$central_locator" gate "$repo" "$decision" 2>&1)"
  else
    gate_output="$("$central_locator" gate "$repo" "$decision" 2>&1)"
  fi
  gate_status=$?
else
  gate_output="$(/bin/bash "$gate" "$decision" --repo "$repo" 2>&1)"
  gate_status=$?
fi
[[ "$gate_status" -eq 0 ]] && exit 0
reason="Candidate gate $decision rejected this publication call: ${gate_output:-candidate gate returned exit $gate_status}"
jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}' >/dev/null || exit 0
jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}'
exit 0
