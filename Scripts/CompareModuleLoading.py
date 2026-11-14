#!/usr/bin/env python3
"""Compare repeated headless reader measurements; never treat a single fast run as the 50% gate."""
import argparse
import json
import math
import statistics
from pathlib import Path

MODULES = {"disk-map", "system-data", "siri", "debloat", "other-system-files"}
SCENARIOS = [("first", "allReadySeconds"), ("cachedIndexStartup", "cachedIndexAllReadySeconds")]


def load(path):
    samples = json.loads(Path(path).read_text())
    if not isinstance(samples, list) or len(samples) < 3:
        raise ValueError(f"{path}: at least three samples are required")
    for sample in samples:
        if not isinstance(sample.get("root"), str) or sample.get("configuration") not in {"release", "debug"}:
            raise ValueError(f"{path}: root and build configuration must be recorded; regenerate legacy reports")
        if not isinstance(sample.get("requestPriority"), int):
            raise ValueError(f"{path}: request priority must be recorded; regenerate legacy reports")
        for phase, total in SCENARIOS:
            if {row["module"] for row in sample[phase]} != MODULES or len(sample[phase]) != 5:
                raise ValueError(f"{path}: {phase} must measure all five modules")
            values = [sample[total]] + [row["seconds"] for row in sample[phase]]
            if not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0 for value in values):
                raise ValueError(f"{path}: durations must be finite and positive")
            if sample[total] < max(row["seconds"] for row in sample[phase]):
                raise ValueError(f"{path}: all-ready time cannot precede module completion")
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--max-ratio", type=float, default=0.5)
    args = parser.parse_args()
    if not 0 < args.max_ratio <= 1:
        parser.error("--max-ratio must be between zero and one")
    try:
        baseline, candidate = load(args.baseline), load(args.candidate)
        if len({(sample["root"], sample["configuration"], sample["requestPriority"]) for sample in baseline + candidate}) != 1:
            raise ValueError("all samples must use the same scan root, build configuration and request priority")
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.error(str(error))
    passed = True
    for phase, total in SCENARIOS:
        before = statistics.median(sample[total] for sample in baseline)
        after = statistics.median(sample[total] for sample in candidate)
        ratio = after / before
        met = ratio <= args.max_ratio
        passed &= met
        print(f"{phase}: {before:.3f}s -> {after:.3f}s; reduction {(1 - ratio) * 100:.1f}%; {'PASS' if met else 'NOT MET'}")
        for module in sorted(MODULES):
            old = statistics.median(next(row["seconds"] for row in sample[phase] if row["module"] == module) for sample in baseline)
            new = statistics.median(next(row["seconds"] for row in sample[phase] if row["module"] == module) for sample in candidate)
            print(f"  {module}: {old:.3f}s -> {new:.3f}s ({(1 - new / old) * 100:.1f}%)")
    print("Scope: backend readers and presentation builders; helper, production Keychain and UI are excluded.")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
