#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="$ROOT/sdk_v1_10_16/OrbbecSDK_C_C++_v1.10.16_20241021_c0329e3_macos_arm64_x86/SDK"

if [[ ! -d "$SDK_ROOT/include" || ! -d "$SDK_ROOT/lib" ]]; then
  cat >&2 <<EOF
Missing OrbbecSDK v1.10.16.

Expected SDK path:
$SDK_ROOT
EOF
  exit 1
fi

mkdir -p "$ROOT/bin"

clang++ -std=c++17 \
  "$ROOT/src/test_sdk_rgb.cpp" \
  -I"$SDK_ROOT/include" \
  -L"$SDK_ROOT/lib" \
  -lOrbbecSDK \
  -Wl,-rpath,@executable_path \
  -o "$ROOT/bin/test_sdk_rgb"

cp "$SDK_ROOT/lib/libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/"
cp "$SDK_ROOT/lib/liblive555.dylib" "$ROOT/bin/"
cp "$SDK_ROOT/lib/libob_usb.dylib" "$ROOT/bin/"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/libOrbbecSDK.1.10.dylib"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/libOrbbecSDK.dylib"

exec "$ROOT/bin/test_sdk_rgb"
