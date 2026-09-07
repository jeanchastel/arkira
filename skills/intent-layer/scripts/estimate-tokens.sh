#!/usr/bin/env bash
# Intent Layer: estimate per-subdir token weight (chars / 4 heuristic).
# Usage: estimate-tokens.sh [dir]   (default .)
# Stdout: TSV "tokens\tdir" per immediate child dir, sorted desc.
# Exit: 0 ok; 2 bad path.
set -euo pipefail

root="${1:-.}"
if [ ! -d "$root" ]; then
  echo "usage: estimate-tokens.sh [dir]" >&2
  exit 2
fi

for d in "$root"/*/; do
  [ -d "$d" ] || continue
  case "$(basename "$d")" in
    .git|.arkira|node_modules|dist|build|.next|vendor|__pycache__) continue ;;
  esac
  chars=$(find "$d" \
    \( -name .git -o -name .arkira -o -name node_modules -o -name dist -o -name build -o -name .next -o -name vendor -o -name __pycache__ \) -prune \
    -o -type f -print0 | xargs -0 wc -c 2>/dev/null | tail -1 | awk '{print $1}')
  chars=${chars:-0}
  printf '%s\t%s\n' "$(( chars / 4 ))" "$d"
done | sort -rn
