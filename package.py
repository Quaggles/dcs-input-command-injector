#!/usr/bin/env python3
"""Build and validate an Open Mod Manager and OVGME release archive."""

import argparse
from pathlib import Path
import re
from typing import Optional, Sequence
import xml.etree.ElementTree as ET
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parent
PACKAGE_ROOT = "DCS-Input-Command-Injector-Quaggles"
HOOK_NAME = "QuagglesInputCommandInjector.lua"
VERSION_PLACEHOLDER = "__QUAGGLES_VERSION__"
DEVELOPMENT_VERSION = "9.9.9"


def modpack_xml(package_root: str) -> str:
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Open_Mod_Manager_Package>
  <install>{package_root}</install>
  <category>Script</category>
  <description>DCS Mod to add custom input commands in your user profile instead of by modding the game for each aircraft. Prevents commands from being lost when DCS updates.

Source: https://github.com/Quaggles/dcs-input-command-injector</description>
</Open_Mod_Manager_Package>
'''


def validate_package(asset: Path, version: str, dev: bool = False) -> None:
    """Reject archives whose identity, metadata, payload, or stamped version drifted."""
    expected_name = f"{PACKAGE_ROOT}_v{version}.zip"
    if asset.name != expected_name:
        raise ValueError(f"unexpected package name: {asset.name}")
    package_root = asset.stem
    hook_path = f"{package_root}/Scripts/Hooks/{HOOK_NAME}"
    expected_entries = {"modpack.xml", "VERSION.txt", f"{package_root}/", hook_path}

    with zipfile.ZipFile(asset) as archive:
        entries = set(archive.namelist())
        if entries != expected_entries:
            raise ValueError(f"unexpected package contents: {sorted(entries)}")

        root = ET.fromstring(archive.read("modpack.xml"))
        if root.tag != "Open_Mod_Manager_Package":
            raise ValueError(f"unexpected modpack root: {root.tag}")
        if root.findtext("install") != package_root or root.findtext("category") != "Script":
            raise ValueError("invalid Open Mod Manager metadata")
        if archive.read("VERSION.txt").decode("ascii") != version:
            raise ValueError("invalid OVGME version metadata")

        hook = archive.read(hook_path).decode("utf-8")
        expected_version = VERSION_PLACEHOLDER if dev else version
        if f"local quagglesVersion = '{expected_version}'" not in hook:
            raise ValueError("hook version was not packaged correctly")


def build_package(version: str, output_directory: Path, dev: bool = False) -> Path:
    """Create an Open Mod Manager/OVGME ZIP, retaining the hook placeholder for dev builds."""
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"version must use X.Y.Z numeric format: {version}")

    source = (PROJECT_ROOT / HOOK_NAME).read_text(encoding="utf-8")
    if source.count(VERSION_PLACEHOLDER) != 1:
        raise ValueError("expected exactly one release version placeholder in the hook")
    hook = source if dev else source.replace(VERSION_PLACEHOLDER, version)

    output_directory.mkdir(parents=True, exist_ok=True)
    asset = output_directory / f"{PACKAGE_ROOT}_v{version}.zip"
    package_root = asset.stem
    with zipfile.ZipFile(asset, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("modpack.xml", modpack_xml(package_root))
        archive.writestr("VERSION.txt", version)
        archive.writestr(f"{package_root}/", "")
        archive.writestr(f"{package_root}/Scripts/Hooks/{HOOK_NAME}", hook)

    validate_package(asset, version, dev)
    return asset


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--version", help="numeric X.Y.Z release version")
    mode.add_argument("--dev", action="store_true", help=f"build an unstamped v{DEVELOPMENT_VERSION} development package")
    parser.add_argument("--output", type=Path, default=Path("dist"), help="output directory (default: dist)")
    args = parser.parse_args(argv)
    print(build_package(DEVELOPMENT_VERSION if args.dev else args.version, args.output, args.dev))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
