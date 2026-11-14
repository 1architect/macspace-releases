"""The aggregate target must never hide a slower module."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "CompareModuleLoading.py"


def samples(values):
    rows = [{"module": module, "seconds": seconds} for module, seconds in values.items()]
    sample = {"root": "/", "configuration": "release", "requestPriority": 25,
              "first": rows, "allReadySeconds": max(values.values()),
              "cachedIndexStartup": rows, "cachedIndexAllReadySeconds": max(values.values())}
    return [copy.deepcopy(sample) for _ in range(3)]


class ModuleLoadingComparisonTests(unittest.TestCase):
    def setUp(self):
        self.baseline = samples({"disk-map": 30, "system-data": 20, "siri": 4, "debloat": 8, "other-system-files": 8})
        self.candidate = samples({"disk-map": 9, "system-data": 10, "siri": 3, "debloat": 6, "other-system-files": 6})

    def compare(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = [Path(folder) / name for name in ["baseline.json", "candidate.json"]]
            for path, data in zip(paths, [self.baseline, self.candidate]):
                path.write_text(json.dumps(data))
            return subprocess.run([sys.executable, str(SCRIPT), *map(str, paths)], capture_output=True, text=True)

    def testAcceptsAggregateTargetWhenEveryModuleImproves(self):
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def testRejectsARegressionHiddenInsideAnAggregateImprovement(self):
        for sample in self.candidate:
            # Deepcopy preserves the shared rows list between the two scenarios in this fixture.
            next(row for row in sample["first"] if row["module"] == "siri")["seconds"] = 5
        result = self.compare()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("REGRESSION", result.stdout)

    def testRejectsAnAggregateMissEvenWhenEveryModuleImproves(self):
        for sample in self.candidate:
            sample["allReadySeconds"] = 20
        result = self.compare()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("NOT MET", result.stdout)

    def testRejectsMismatchedReadContext(self):
        self.candidate[0]["requestPriority"] = 17
        result = self.compare()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("same scan root, build configuration and request priority", result.stderr)


if __name__ == "__main__":
    unittest.main()
