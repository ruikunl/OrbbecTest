#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="$ROOT/sdk_v1_10_16/OrbbecSDK_C_C++_v1.10.16_20241021_c0329e3_macos_arm64_x86/SDK"
APP="$ROOT/build/OrbbecViewer.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

if [[ ! -d "$SDK_ROOT/include" || ! -d "$SDK_ROOT/lib" ]]; then
  cat >&2 <<EOF
Missing OrbbecSDK v1.10.16.

Download the macOS arm64/x86 C/C++ SDK from Orbbec and extract it so this path exists:
$SDK_ROOT
EOF
  exit 1
fi

mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/viewer/Info.plist" "$APP/Contents/Info.plist"

clang++ -std=c++17 -ObjC++ -fobjc-arc \
  "$ROOT/src/OrbbecViewer.mm" \
  -I"$SDK_ROOT/include" \
  -L"$SDK_ROOT/lib" \
  -lOrbbecSDK \
  -framework Cocoa \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ImageIO \
  -Wl,-rpath,@executable_path \
  -o "$MACOS/OrbbecViewer"

cp "$SDK_ROOT/lib/libOrbbecSDK.1.10.16.dylib" "$MACOS/"
cp "$SDK_ROOT/lib/liblive555.dylib" "$MACOS/"
cp "$SDK_ROOT/lib/libob_usb.dylib" "$MACOS/"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$MACOS/libOrbbecSDK.1.10.dylib"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$MACOS/libOrbbecSDK.dylib"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "$APP"
