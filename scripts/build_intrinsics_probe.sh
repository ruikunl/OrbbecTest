#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="$ROOT/sdk_v1_10_16/OrbbecSDK_C_C++_v1.10.16_20241021_c0329e3_macos_arm64_x86/SDK"

if [[ ! -d "$SDK_ROOT/include" || ! -d "$SDK_ROOT/lib" ]]; then
  cat >&2 <<EOF
Missing OrbbecSDK v1.10.16.

Download the macOS arm64/x86 C/C++ SDK from Orbbec and extract it so this path exists:
$SDK_ROOT
EOF
  exit 1
fi

mkdir -p "$ROOT/bin"

clang++ -std=c++17 \
  "$ROOT/src/read_orbbec_intrinsics_v1.cpp" \
  -I"$SDK_ROOT/include" \
  -L"$SDK_ROOT/lib" \
  -lOrbbecSDK \
  -Wl,-rpath,@executable_path \
  -o "$ROOT/bin/read_orbbec_intrinsics_v1"

cp "$SDK_ROOT/lib/libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/"
cp "$SDK_ROOT/lib/liblive555.dylib" "$ROOT/bin/"
cp "$SDK_ROOT/lib/libob_usb.dylib" "$ROOT/bin/"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/libOrbbecSDK.1.10.dylib"
ln -sf "libOrbbecSDK.1.10.16.dylib" "$ROOT/bin/libOrbbecSDK.dylib"

echo "$ROOT/bin/read_orbbec_intrinsics_v1"
