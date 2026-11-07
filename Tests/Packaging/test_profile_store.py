import importlib.util
from pathlib import Path
import os
import stat
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
spec = importlib.util.spec_from_file_location("profile_store", ROOT / "Scripts/StoreMetadataProfiles.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class ProfileStoreTests(unittest.TestCase):
    def test_store_uses_stable_private_files_and_can_replace_a_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "Signing/Profiles"
            module.store(destination, {"MacSpace.provisionprofile": b"validated-app", "MacSpaceCli.provisionprofile": b"validated-cli"})
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((destination / "MacSpace.provisionprofile").stat().st_mode), 0o600)
            module.store(destination, {"MacSpace.provisionprofile": b"renewed"})
            self.assertEqual((destination / "MacSpace.provisionprofile").read_bytes(), b"renewed")
            self.assertEqual((destination / "MacSpaceCli.provisionprofile").read_bytes(), b"validated-cli")

    def test_linked_destination_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); target = root / "original"; target.write_bytes(b"preserved")
            destination = root / "Profiles"; destination.mkdir()
            os.symlink(target, destination / "MacSpace.provisionprofile")
            with self.assertRaises(ValueError): module.store(destination, {"MacSpace.provisionprofile": b"new"})
            self.assertEqual(target.read_bytes(), b"preserved")


if __name__ == "__main__": unittest.main()
