#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail SDK builds when sources violate the Apache-only boundary."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


SPDX = "SPDX-License-Identifier: Apache-2.0"
SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".gradle",
    ".h",
    ".hpp",
    ".kt",
    ".kts",
    ".py",
    ".xml",
}
FORBIDDEN_SOURCE_MARKERS = (
    "#include \"aubio",
    "#include <aubio",
    "GPL-2.0",
    "GPL-3.0",
    "AGPL-",
)
SKIP_DIRS = {"build", ".cxx", ".git", ".gradle", "__pycache__"}


def iter_source_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file() or any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in SOURCE_SUFFIXES or path.name == "CMakeLists.txt":
            yield path


def check(root: Path) -> list[str]:
    errors: list[str] = []
    license_path = root / "LICENSE"
    if not license_path.exists():
        errors.append("missing LICENSE")
    else:
        license_text = license_path.read_text(encoding="utf-8")
        if "Apache License" not in license_text or "Version 2.0, January 2004" not in license_text:
            errors.append("LICENSE is not the Apache License 2.0 text")

    notices_path = root / "THIRD_PARTY_NOTICES.md"
    if not notices_path.exists():
        errors.append("missing THIRD_PARTY_NOTICES.md")

    for path in iter_source_files(root):
        text = path.read_text(encoding="utf-8")
        first_lines = "\n".join(text.splitlines()[:5])
        relative = path.relative_to(root)
        if SPDX not in first_lines:
            errors.append(f"{relative}: missing Apache-2.0 SPDX in first 5 lines")
        if path.resolve() != Path(__file__).resolve():
            for marker in FORBIDDEN_SOURCE_MARKERS:
                if marker in text:
                    errors.append(f"{relative}: forbidden SDK source marker {marker!r}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    errors = check(args.root.resolve())
    if errors:
        for error in errors:
            print(f"license-check: {error}", file=sys.stderr)
        return 1
    print("license-check: Apache-2.0 SDK boundary OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
