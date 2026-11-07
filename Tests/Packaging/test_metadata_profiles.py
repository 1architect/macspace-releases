import copy
import os
import subprocess
import tempfile
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("metadata_profiles", ROOT / "Scripts/ValidateMetadataProfiles.py")
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)


class MetadataProfilesTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 11, 6, tzinfo=datetime.timezone.utc)
        self.certificate = b"fixture-certificate"
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest()
        self.profile = {
            "ExpirationDate": self.now + datetime.timedelta(days=30),
            "TeamIdentifier": ["TEAM"], "Platform": ["OSX"], "ProvisionsAllDevices": True,
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {"com.apple.application-identifier": "TEAM.com.macspace.app",
                             "com.apple.developer.team-identifier": "TEAM",
                             "keychain-access-groups": ["TEAM.com.macspace.metadata"]},
        }

    def validate(self, profile, bundle="com.macspace.app"):
        profiles.validate(profile, bundle, "TEAM", self.fingerprint, now=self.now)

    def test_matching_profiles_authorize_each_bundle(self):
        self.validate(self.profile)
        worker = copy.deepcopy(self.profile)
        worker["Entitlements"]["com.apple.application-identifier"] = "TEAM.com.macspace.cli"
        self.validate(worker, "com.macspace.cli")

    def test_valid_apple_wildcards_remain_narrow_in_actual_entitlements(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "TEAM.com.macspace.*"
        self.profile["Entitlements"]["keychain-access-groups"] = ["TEAM.*"]
        self.validate(self.profile)

    def test_bad_identity_scope_or_expiry_refuses(self):
        mutations = [
            lambda p: p.update(ExpirationDate=self.now - datetime.timedelta(seconds=1)),
            lambda p: p.update(TeamIdentifier=["OTHER"]),
            lambda p: p.update(Platform=["iOS"]),
            lambda p: p.update(DeveloperCertificates=[b"different"]),
            lambda p: p.update(ProvisionsAllDevices=False),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": "TEAM.com.other.app"}),
            lambda p: p["Entitlements"].update({"com.apple.developer.team-identifier": "OTHER"}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": ["TEAM.com.other.metadata"]}),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                profile = copy.deepcopy(self.profile); mutation(profile)
                with self.assertRaises(profiles.ProfileError): self.validate(profile)

    def test_profile_for_gui_does_not_authorize_worker_identity(self):
        with self.assertRaises(profiles.ProfileError): self.validate(self.profile, "com.macspace.cli")

    def test_selection_disambiguates_duplicate_certificate_names_using_profiles(self):
        self.profile["ExpirationDate"] = datetime.datetime(2044, 1, 1, tzinfo=datetime.timezone.utc)
        self.profile["TeamIdentifier"] = ["ABCDE12345"]
        self.profile["Entitlements"].update({"com.apple.application-identifier": "ABCDE12345.com.macspace.*", "com.apple.developer.team-identifier": "ABCDE12345", "keychain-access-groups": ["ABCDE12345.*"]})
        identities = ('1) ' + '0' * 40 + ' "Developer ID Application: Fixture (ABCDE12345)"\n'
                      '2) ' + self.fingerprint + ' "Developer ID Application: Fixture (ABCDE12345)"')
        selected = profiles.select_identity(self.profile, self.profile, identities)
        self.assertEqual(selected["certificate"], self.fingerprint.upper())
        self.assertEqual(selected["team"], "ABCDE12345")
        with self.assertRaises(profiles.ProfileError): profiles.select_identity(self.profile, self.profile, identities, identity="0" * 40)

    def test_missing_profiles_stop_assembly_before_replacing_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Build"
            app = output / "MacSpace.app"
            app.mkdir(parents=True)
            sentinel = app / "preserved"
            sentinel.write_text("previous build")
            environment = dict(os.environ, SIGN_IDENTITY="0" * 40, TEAM_ID="ABCDE12345", NOTARY_PROFILE="MacSpace", OUT_DIR=str(output), INSTALL="0", METADATA_PROFILES_DIR=str(Path(temporary) / "missing-profiles"))
            environment.pop("METADATA_APP_PROFILE", None)
            environment.pop("METADATA_CLI_PROFILE", None)
            result = subprocess.run(["/bin/bash", "Scripts/Assemble.sh"], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("METADATA_APP_PROFILE", result.stderr)
            self.assertEqual(sentinel.read_text(), "previous build")
            self.assertFalse((output / ".staging").exists())


if __name__ == "__main__": unittest.main()
