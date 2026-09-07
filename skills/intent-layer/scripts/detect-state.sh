#!/usr/bin/env bash
# Intent Layer: report context-file state of a directory tree.
# Usage: detect-state.sh [dir]   (default .)
# Stdout: "state=none|partial|complete" then one "node=<path>" line per context file.
# Exit: 0 ok; 2 bad path.
set -euo pipefail

root="${1:-.}"
if [ ! -d "$root" ]; then
  echo "usage: detect-state.sh [dir]" >&2
  exit 2
fi

nodes="$(find "$root" \
  \( -name .git -o -name .arkira -o -name node_modules -o -name dist -o -name build -o -name .next -o -name vendor -o -name __pycache__ \) -prune \
  -o -type f \( -name AGENTS.md -o -name CLAUDE.md \) -print | sort)"

root_ctx=0
child=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  if [ "$(dirname "$n")" = "$root" ]; then root_ctx=1; else child=1; fi
done <<EOF
$nodes
EOF

if [ "$root_ctx" -eq 0 ]; then
  state=none
elif [ "$child" -eq 1 ]; then
  state=complete
else
  state=partial
fi

echo "state=$state"
while IFS= read -r n; do
  [ -n "$n" ] && echo "node=$n"
done <<EOF
$nodes
EOF

exit 0
