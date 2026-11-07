"""Validate profile authorization before signing metadata-enabled executables.

Profiles remain private, outside source control. Apple/OS signature and distribution
checks still run on the final product; notarization alone does not authorize entitlements.
"""
import argparse
import datetime
import hashlib
import json
import re
from pathlib import Path
import plistlib
import subprocess
import sys


class ProfileError(ValueError):
    pass


def authorizes(pattern, value):
    return isinstance(pattern, str) and (pattern == value or (
        pattern.endswith(".*") and "*" not in pattern[:-1] and value.startswith(pattern[:-1])
    ))


def validate(profile, bundle_id, team, certificate, distribution=True, now=None):
    if not isinstance(profile, dict):
        raise ProfileError("profile payload is not a dictionary")
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise ProfileError("profile has no expiration date")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= now:
        raise ProfileError("profile is expired")
    if team not in profile.get("TeamIdentifier", []):
        raise ProfileError("profile belongs to another developer team")
    if not set(profile.get("Platform", [])).intersection({"OSX", "macOS"}):
        raise ProfileError("profile is not for macOS")
    entitlements = profile.get("Entitlements", {})
    if not isinstance(entitlements, dict):
        raise ProfileError("profile entitlements are invalid")
    if not authorizes(entitlements.get("com.apple.application-identifier"), team + "." + bundle_id):
        raise ProfileError("profile does not authorize " + bundle_id)
    group = team + ".com.macspace.metadata"
    if not any(authorizes(pattern, group) for pattern in entitlements.get("keychain-access-groups", [])):
        raise ProfileError("profile does not authorize the restricted metadata Keychain group")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise ProfileError("profile entitlement team does not match")
    fingerprints = {hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", []) if isinstance(value, bytes)}
    if certificate.upper() not in fingerprints:
        raise ProfileError("profile does not authorize the selected signing certificate")
    if distribution and (profile.get("ProvisionsAllDevices") is not True or entitlements.get("get-task-allow") is True or entitlements.get("com.apple.security.get-task-allow") is True):
        raise ProfileError("a Developer ID distribution profile is required")


def decode(path):
    source = Path(path)
    if not source.is_file() or source.stat().st_size > 8 * 1024 * 1024:
        raise ProfileError("profile is missing or oversized")
    result = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(source)], capture_output=True, timeout=20)
    if result.returncode or len(result.stdout) > 8 * 1024 * 1024:
        raise ProfileError("profile CMS could not be decoded")
    try:
        return plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ProfileError("profile payload is invalid") from error


def select_identity(app, cli, identities, identity=None, team=None, distribution=True):
    """Choose a locally usable certificate authorized by both profiles, including duplicate names."""
    for line in identities.splitlines():
        match = re.search(r'([0-9A-Fa-f]{40})\s+"([^"\n]+)"', line)
        if not match:
            continue
        certificate, name = match.groups()
        if distribution and not name.startswith("Developer ID Application:"):
            continue
        if not name.startswith(("Developer ID Application:", "Apple Development:")):
            continue
        if identity and identity != name and identity.upper() != certificate.upper():
            continue
        match_team = re.search(r'\(([A-Z0-9]{10})\)$', name)
        if not match_team:
            continue
        candidate_team = team or match_team.group(1)
        try:
            validate(app, "com.macspace.app", candidate_team, certificate, distribution)
            validate(cli, "com.macspace.cli", candidate_team, certificate, distribution)
        except ProfileError:
            continue
        return {"certificate": certificate.upper(), "name": name, "team": candidate_team}
    raise ProfileError("no local signing identity is authorized by both profiles")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-profile", required=True)
    parser.add_argument("--cli-profile", required=True)
    parser.add_argument("--team")
    parser.add_argument("--certificate")
    parser.add_argument("--select-identity", action="store_true")
    parser.add_argument("--identity")
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    try:
        if args.select_identity:
            identities = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, timeout=20, check=True).stdout
            print(json.dumps(select_identity(decode(args.app_profile), decode(args.cli_profile), identities, args.identity, args.team, not args.development)))
            return 0
        if not args.team or not args.certificate:
            raise ProfileError("team and signing certificate are required")
        for path, identifier in [(args.app_profile, "com.macspace.app"), (args.cli_profile, "com.macspace.cli")]:
            validate(decode(path), identifier, args.team, args.certificate, distribution=not args.development)
            print("Validated provisioning authorization for " + identifier)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("error: metadata provisioning: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
