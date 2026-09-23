#!/usr/bin/env python3
"""Patch flutter plugin sources in PUB_CACHE so the Android build succeeds.

Background
----------
`file_picker 8.3.7` hardcodes `compileSdk 34` in its android/build.gradle.
Newer `flutter_plugin_android_lifecycle` (pulled in transitively by other
plugins) declares AAR metadata requiring compileSdk >= 36. AGP then fails with:

    :file_picker is currently compiled against android-34

The upstream fix is a major-version upgrade of file_picker (8.x -> 13.x,
federated plugin rewrite) which is out of scope for now, so we patch the
extracted plugin sources in the pub cache instead.

Notes
-----
* This only touches the pub cache, never the project sources.
* `flutter pub get` does NOT re-extract an already-cached package version,
  so the patch survives normal rebuilds. It is lost only if the package is
  re-downloaded (version bump) or the pub cache is wiped - just re-run this.
* Safe to run repeatedly (idempotent).

Usage
-----
    python tool/patch_pub_cache.py            # apply
    python tool/patch_pub_cache.py --check    # report only, no writes
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# plugin dir prefix -> {bad_compileSdk: good_compileSdk}
PATCHES: dict[str, dict[int, int]] = {
    "file_picker-": {34: 36},
}

# where to look for the pub cache, in priority order
def candidate_caches() -> list[Path]:
    caches: list[Path] = []
    env = os.environ.get("PUB_CACHE")
    if env:
        caches.append(Path(env))
    caches.append(Path(r"D:\dev\pub-cache"))
    home = Path.home()
    caches.append(home / "AppData" / "Local" / "Pub" / "Cache")
    # de-duplicate, keep order
    seen, out = set(), []
    for c in caches:
        key = str(c).lower()
        if key not in seen:
            seen.add(key)
            out.append(c)
    return out


def find_targets(cache: Path) -> list[Path]:
    """Return build.gradle files of matching extracted packages."""
    hosted = cache / "hosted"
    if not hosted.is_dir():
        return []
    targets: list[Path] = []
    for host_dir in hosted.iterdir():
        if not host_dir.is_dir():
            continue
        for pkg_dir in host_dir.iterdir():
            if not pkg_dir.is_dir():
                continue
            if not any(pkg_dir.name.startswith(p) for p in PATCHES):
                continue
            gradle = pkg_dir / "android" / "build.gradle"
            if gradle.is_file():
                targets.append(gradle)
    return targets


def patch_file(path: Path, mapping: dict[int, int], check_only: bool) -> str:
    text = path.read_text(encoding="utf-8")
    new_text = text
    applied = []
    for bad, good in mapping.items():
        # match `compileSdk 34` / `compileSdk = 34` (Groovy & Kotlin DSL)
        pattern = re.compile(rf"(compileSdk\s*=?\s*){bad}\b")
        if pattern.search(new_text):
            new_text = pattern.sub(rf"\g<1>{good}", new_text)
            applied.append(f"{bad}->{good}")
    if not applied:
        return "  [ok] already patched or not applicable: %s" % path
    if check_only:
        return "  [needs patch] %s (%s)" % (path, ", ".join(applied))
    path.write_text(new_text, encoding="utf-8")
    return "  [patched] %s (%s)" % (path, ", ".join(applied))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    args = ap.parse_args()

    total = 0
    for cache in candidate_caches():
        if not cache.is_dir():
            continue
        targets = find_targets(cache)
        if not targets:
            continue
        print(f"pub cache: {cache}")
        for t in targets:
            mapping = next(
                v for k, v in PATCHES.items() if t.parent.parent.name.startswith(k)
            )
            print(patch_file(t, mapping, args.check))
            total += 1
    if total == 0:
        print("no matching plugin sources found in any pub cache")
        return 1
    print("done (%s)" % ("check only" if args.check else "applied"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
