#!/usr/bin/env bash
# Build the game on Robert's Windows laptop and put it on his desktop.
#   tools/windows/deploy_to_robert.sh [git-ref] [--tests]
# git-ref defaults to HEAD; --tests also runs the whole suite on the laptop (slow, well over 10 min).
# Needs: Tailscale up, SSH key access (thinkpad@robert-win). Full algorithm, gotchas: docs/WINDOWS_BUILD.md.
set -euo pipefail

HOST="${ROBERT_HOST:-thinkpad@100.71.175.5}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
SCP=(scp -q -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

cd "$(git rev-parse --show-toplevel)"
REF=HEAD
TESTS=""
for arg in "$@"; do
  case "$arg" in
    --tests) TESTS="-RunTests" ;;
    *) REF="$arg" ;;
  esac
done
COMMIT="$(git rev-parse --short "$REF")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# game/ = project; tools/windows = launchers; tools/blender/env/pieces = generator specs read by the data tests.
git archive --format=zip "$REF" game tools/windows tools/blender/env/pieces -o "$TMP/fg.zip"
echo "archive: $REF ($COMMIT), $(du -h "$TMP/fg.zip" | cut -f1)"

"${SSH[@]}" "$HOST" 'if not exist C:\Godot\_deploy mkdir C:\Godot\_deploy'
"${SCP[@]}" "$TMP/fg.zip" "$HOST:C:/Godot/_deploy/fg.zip"
"${SCP[@]}" tools/windows/laptop_update.ps1 "$HOST:C:/Godot/_deploy/laptop_update.ps1"

# Foreground on purpose: a process detached from the SSH session is killed with it (Windows job object).
"${SSH[@]}" "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Godot\\_deploy\\laptop_update.ps1 $TESTS -Commit $COMMIT"
