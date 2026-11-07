"""One-time local installation of the two metadata provisioning profiles."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from ValidateMetadataProfiles import decode, select_identity


def store(directory, payloads):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise ValueError("profile directory must be owned by you and not linked")
    directory.chmod(0o700)
    for name, data in payloads.items():
        destination = directory / name
        if destination.is_symlink():
            raise ValueError("refusing a linked profile destination")
        fd, staging = tempfile.mkstemp(prefix=".profile-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data); handle.flush(); os.fsync(handle.fileno())
            os.replace(staging, destination)
        finally:
            Path(staging).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_profile", type=Path)
    parser.add_argument("cli_profile", type=Path)
    parser.add_argument("--directory", type=Path, default=Path(os.environ.get("METADATA_PROFILES_DIR", Path.home() / "Library/Application Support/MacSpace/Signing/Profiles")))
    args = parser.parse_args()
    app_data, cli_data = args.app_profile.read_bytes(), args.cli_profile.read_bytes()
    app, cli = decode(args.app_profile), decode(args.cli_profile)
    if args.app_profile.read_bytes() != app_data or args.cli_profile.read_bytes() != cli_data:
        raise ValueError("profile changed during validation")
    identities = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, timeout=20, check=True).stdout
    identity = select_identity(app, cli, identities)
    store(args.directory, {"MacSpace.provisionprofile": app_data, "MacSpaceCli.provisionprofile": cli_data})
    print("Validated and stored profiles in " + str(args.directory))
    print("Signing identity: " + identity["name"])


if __name__ == "__main__": main()
