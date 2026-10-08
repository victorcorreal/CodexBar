#!/usr/bin/env bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"

# Keep the installed identity and preferences while using the fast local build.
pkill -x CodexBar 2>/dev/null || true
CODEXBAR_SIGNING=adhoc CODEXBAR_LOCAL_PRODUCTION_ID=1 ARCHES="$(uname -m)" \
  "$TASK_ROOT/Scripts/package_app.sh" debug
# Certificate signing keeps the designated requirement stable between local builds.
# Never change Keychain ACLs or fall back silently to ad-hoc signing.
SIGNING_FILE="$HOME/Library/Application Support/CodexBar/local-signing-identity.txt"
if [[ -f "$SIGNING_FILE" ]]; then
  LOCAL_SIGNING_ID=$(cat "$SIGNING_FILE")
else
  LOCAL_SIGNING_ID=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
  if [[ ! "$LOCAL_SIGNING_ID" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo "ERROR: Exactly one Apple Development signing identity is required." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SIGNING_FILE")"
  printf '%s\n' "$LOCAL_SIGNING_ID" > "$SIGNING_FILE"
fi
codesign --force --deep --sign "$LOCAL_SIGNING_ID" --options runtime \
  --preserve-metadata=entitlements "$TASK_ROOT/CodexBar.app"
codesign --verify --deep --strict "$TASK_ROOT/CodexBar.app"
/usr/bin/open -n "$TASK_ROOT/CodexBar.app"
for _ in {1..20}; do
  if pgrep -x CodexBar >/dev/null; then
    echo "CodexBar is running."
    exit 0
  fi
  sleep 0.25
done
echo "ERROR: CodexBar did not stay running." >&2
exit 1
