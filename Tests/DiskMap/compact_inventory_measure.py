"""Run synthetic storage/latency fixtures against the shipped encrypted implementation.
No app is launched and no real user data is scanned. All data and keys are fixture-owned.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FILTER = "DiskMapTests.DiskCompactInventoryTests|DiskMapTests.DiskEncryptionTests|DiskMapTests.DiskDatabaseMemoryTests|DiskMapTests.DiskReviewLatencyTests"
if __name__ == "__main__":
    print("Synthetic encrypted inventory fixtures; not a live-app performance measurement.", flush=True)
    sys.exit(subprocess.run(["swift", "test", "--filter", FILTER], cwd=ROOT).returncode)
