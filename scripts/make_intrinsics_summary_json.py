#!/usr/bin/env python3
"""Convert the v1 SDK text report into a compact JSON summary."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "outputs" / "orbbec_intrinsics_v1.txt"
OUTPUT = ROOT / "outputs" / "orbbec_intrinsics_summary.json"


INTR_RE = re.compile(
    r"^(?P<label>.+?) (?P<kind>depthIntrinsic|rgbIntrinsic): "
    r"(?P<width>\d+)x(?P<height>\d+) fx=(?P<fx>[-0-9.]+) fy=(?P<fy>[-0-9.]+) "
    r"cx=(?P<cx>[-0-9.]+) cy=(?P<cy>[-0-9.]+)$"
)
DIST_RE = re.compile(
    r"^(?P<label>.+?) (?P<kind>depthDistortion|rgbDistortion): "
    r"k1=(?P<k1>[-0-9.]+) k2=(?P<k2>[-0-9.]+) k3=(?P<k3>[-0-9.]+) "
    r"k4=(?P<k4>[-0-9.]+) k5=(?P<k5>[-0-9.]+) k6=(?P<k6>[-0-9.]+) "
    r"p1=(?P<p1>[-0-9.]+) p2=(?P<p2>[-0-9.]+)$"
)
DEVICE_RE = re.compile(
    r"^name=(?P<name>\S+) vid=0x(?P<vid>[0-9a-fA-F]+) pid=0x(?P<pid>[0-9a-fA-F]+) "
    r"uid=(?P<uid>\S+) serial=(?P<serial>\S+) firmware=(?P<firmware>\S+) connection=(?P<connection>\S+)$"
)


def camera_matrix(intrinsic: dict[str, float | int]) -> list[list[float]]:
    return [
        [float(intrinsic["fx"]), 0.0, float(intrinsic["cx"])],
        [0.0, float(intrinsic["fy"]), float(intrinsic["cy"])],
        [0.0, 0.0, 1.0],
    ]


def main() -> None:
    text = REPORT.read_text(encoding="utf-8")
    summary: dict[str, object] = {
        "source_report": str(REPORT),
        "device": {},
        "depth_stream_verified": False,
        "selected_parameters": {},
        "notes": [],
    }

    parameters: dict[str, dict[str, object]] = {}

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if match := DEVICE_RE.match(line):
            summary["device"] = {
                "name": match.group("name"),
                "vid": f"0x{match.group('vid')}",
                "pid": f"0x{match.group('pid')}",
                "uid": match.group("uid"),
                "serial": match.group("serial"),
                "firmware": match.group("firmware"),
                "connection": match.group("connection"),
            }
        elif line.startswith("Depth-only pipeline received frame:"):
            summary["depth_stream_verified"] = True
            summary["depth_frame"] = line.split(": ", 1)[1]
        elif "profile list SDK error" in line or "Pipeline camera param SDK error" in line:
            summary["notes"].append(line)
        elif match := INTR_RE.match(line):
            label = match.group("label")
            kind = match.group("kind")
            entry = parameters.setdefault(label, {})
            intrinsic = {
                "width": int(match.group("width")),
                "height": int(match.group("height")),
                "fx": float(match.group("fx")),
                "fy": float(match.group("fy")),
                "cx": float(match.group("cx")),
                "cy": float(match.group("cy")),
            }
            intrinsic["camera_matrix"] = camera_matrix(intrinsic)
            entry[kind] = intrinsic
        elif match := DIST_RE.match(line):
            label = match.group("label")
            kind = match.group("kind")
            parameters.setdefault(label, {})[kind] = {
                key: float(match.group(key)) for key in ("k1", "k2", "k3", "k4", "k5", "k6", "p1", "p2")
            }
        elif "depthToColor.rot:" in line:
            label, values = line.split(" depthToColor.rot:", 1)
            parameters.setdefault(label, {})["depth_to_color_rotation_row_major"] = [float(v) for v in values.split()]
        elif "depthToColor.trans_mm:" in line:
            label, values = line.split(" depthToColor.trans_mm:", 1)
            parameters.setdefault(label, {})["depth_to_color_translation_mm"] = [float(v) for v in values.split()]

    summary["selected_parameters"] = parameters.get("DepthOnlyPipeline") or parameters.get("Calibration[0]") or {}
    summary["all_camera_parameter_sets"] = parameters
    OUTPUT.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
