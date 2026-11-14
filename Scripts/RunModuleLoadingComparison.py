#!/usr/bin/env python3
"""Build two identical headless harnesses, then alternate reference/candidate native-reader measurements."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

FILTER = r"^ModuleLoadingBenchmarks[.]ModuleLoadingBenchmarks/testRealReadersFirstLoadAndCachedReopen$"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--root", default="/")
    args = parser.parse_args()
    if args.pairs < 3:
        parser.error("at least three pairs are required")
    variants = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    harness = "Tests/Performance/ModuleLoadingBenchmarks.swift"
    hashes = {name: hashlib.sha256((path / harness).read_bytes()).hexdigest() for name, path in variants.items()}
    if len(set(hashes.values())) != 1:
        parser.error("both variants must use the exact same benchmark source")
    output = args.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    metadata = {"harnessSHA256": hashes["baseline"], "root": args.root, "pairs": args.pairs, "variants": {}}
    for name, path in variants.items():
        metadata["variants"][name] = {
            "path": str(path),
            "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip(),
            "diffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=path)).hexdigest(),
        }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    command = ["swift", "test", "-c", "release", "--filter", FILTER]
    for name, path in variants.items():
        environment = dict(os.environ, MACSPACE_LOADING_BENCHMARK="0", MACSPACE_SYSTEM_DATA_DIAGNOSTIC="0")
        print(f"Building {name}", flush=True)
        with (output / f"build-{name}.log").open("wb") as log:
            subprocess.run(command, cwd=path, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    time.sleep(2)
    samples = {name: [] for name in variants}
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        for name in order:
            prefix = output / f"{name}-{pair + 1:02d}"
            report = prefix.with_suffix(".json")
            environment = dict(os.environ, MACSPACE_LOADING_BENCHMARK="1", MACSPACE_LOADING_SAMPLES="1",
                               MACSPACE_LOADING_ROOT=args.root, MACSPACE_LOADING_REPORT=str(report),
                               MACSPACE_SYSTEM_DATA_DIAGNOSTIC="0", MACSPACE_DISK_METRICS="1",
                               MACSPACE_DISK_METRICS_FILE=str(prefix) + "-disk.txt", MACSPACE_LOAD_METRICS="1",
                               MACSPACE_LOAD_METRICS_FILE=str(prefix) + "-modules.txt")
            print(f"Pair {pair + 1}/{args.pairs}: {name}", flush=True)
            with prefix.with_suffix(".log").open("wb") as log:
                subprocess.run(command + ["--skip-build"], cwd=variants[name], env=environment,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            reading = json.loads(report.read_text())
            if len(reading) != 1 or reading[0]["root"] != args.root or reading[0]["configuration"] != "release":
                raise ValueError(f"{name}: expected one complete release sample at the selected root")
            samples[name].extend(reading)
            (output / f"{name}.json").write_text(json.dumps(samples[name], indent=2) + "\n")
            sample = reading[0]
            print(f"  first={sample['allReadySeconds']:.3f}s cached={sample['cachedIndexAllReadySeconds']:.3f}s", flush=True)
    compare = Path(__file__).with_name("CompareModuleLoading.py")
    return subprocess.run(["python3", str(compare), str(output / "baseline.json"), str(output / "candidate.json")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
