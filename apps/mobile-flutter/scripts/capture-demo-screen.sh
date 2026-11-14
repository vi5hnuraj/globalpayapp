#!/usr/bin/env bash
# Capture the currently visible physical-device screen into the hackathon story and the phone's
# Pictures/GlobalPayDemo folder. Usage: ./scripts/capture-demo-screen.sh 04-wallet-home
set -euo pipefail

NAME="${1:?screen name required, e.g. 04-wallet-home}"
case "$NAME" in
  *[!a-zA-Z0-9._-]*) echo "screen name may contain only letters, numbers, dot, dash and underscore" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/docs/hackathon/screenshots/story"
FILE="$OUT/$NAME.png"
PHONE_DIR="/sdcard/Pictures/GlobalPayDemo"

command -v adb >/dev/null || { echo "adb is required" >&2; exit 1; }
test "$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')" -eq 1 || {
  echo "connect exactly one unlocked Android device" >&2
  exit 1
}
adb shell dumpsys window | grep -q 'mCurrentFocus=.*com.globalpay.app' || {
  echo "GlobalPay is not the foreground app; refusing to capture another app" >&2
  exit 1
}

mkdir -p "$OUT"
adb exec-out screencap -p > "$FILE"
adb shell mkdir -p "$PHONE_DIR"
adb push "$FILE" "$PHONE_DIR/$NAME.png" >/dev/null
echo "$FILE"
echo "$PHONE_DIR/$NAME.png"
