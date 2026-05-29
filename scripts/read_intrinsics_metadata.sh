#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/build_intrinsics_probe.sh" >/dev/null
mkdir -p "$ROOT/outputs"

(
  cd "$ROOT"
  bin/read_orbbec_intrinsics_v1 --metadata-only
  python3 scripts/make_intrinsics_summary_json.py
)
