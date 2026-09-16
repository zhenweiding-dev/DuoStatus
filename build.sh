#!/bin/bash
# Builds DuoStatus.app. Pass --install to drop it in /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

NAME="DuoStatus"
APP="build/$NAME.app"
BUNDLE_ID="io.github.zhenweiding-dev.duostatus"

# Universal, so the same bundle runs on Apple silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)

echo "==> Building (universal)"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc; fine for local use)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  pkill -x "$NAME" 2>/dev/null || true
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/$NAME.app"
  # Opening straight after replacing the bundle races LaunchServices (error -609),
  # so register it explicitly and give it a moment.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "/Applications/$NAME.app" 2>/dev/null || true
  sleep 1
  open "/Applications/$NAME.app" || { sleep 2; open "/Applications/$NAME.app"; }
  echo "Launched — look at the right side of the menu bar."
else
  echo "Done: $APP"
  echo "Try it:  open $APP        Install:  ./build.sh --install"
fi
