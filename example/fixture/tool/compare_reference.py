#!/usr/bin/env python3
"""Compare overlapping collector frames with the fixture-only engine reference."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    reference = json.loads(args.reference.read_text())["fixtureFrameReference"]
    key = lambda frame: (frame["number"], frame["startTimeMicros"])
    expected = {key(frame): frame for frame in reference}
    fields = ("buildMicros", "rasterMicros", "elapsedMicros", "vsyncOverheadMicros")
    matched = 0
    mismatches = []
    for frame in report.get("frames", []):
        other = expected.get(key(frame))
        if other is None:
            continue
        matched += 1
        for field in fields:
            if frame[field] != other[field]:
                mismatches.append({"frame": key(frame), "field": field,
                                   "captured": frame[field], "reference": other[field]})
    print(json.dumps({
        "capturedFrames": len(report.get("frames", [])),
        "referenceFrames": len(reference),
        "matchingFrames": matched,
        "mismatches": mismatches,
        "note": "Matching samples validate fidelity, not complete startup coverage.",
    }, indent=2))
    return 0 if matched and not mismatches else 1


if __name__ == "__main__":
    raise SystemExit(main())
