#!/usr/bin/env python3
"""Update the repository's pinned OpenWrt Image Builder hashes."""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path


def latest_release():
    with urllib.request.urlopen("https://downloads.openwrt.org/releases/", timeout=15) as response:
        versions = re.findall(r'href="(\d+\.\d+\.\d+)/"', response.read().decode())
    if not versions:
        raise RuntimeError("could not determine the latest stable OpenWrt release")
    return sorted(versions, key=lambda value: tuple(map(int, value.split("."))))[-1]


def prefetch(release, target_key):
    target, subtarget = target_key.split("/", 1)
    name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64.tar.zst"
    url = f"https://downloads.openwrt.org/releases/{release}/targets/{target}/{subtarget}/{name}"
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", url],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)["hash"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hashes-file", required=True, type=Path)
    parser.add_argument("--targets", nargs="+", required=True)
    parser.add_argument("--release")
    args = parser.parse_args()

    release = args.release or latest_release()
    data = json.loads(args.hashes_file.read_text())
    hashes = data.setdefault("imageBuilderHashes", {}).setdefault(release, {})
    for target in args.targets:
        if target.count("/") != 1:
            parser.error(f"invalid target {target!r}; expected target/subtarget")
        print(f"Prefetching {target} for OpenWrt {release}...")
        hashes[target] = prefetch(release, target)
    data["defaultRelease"] = release
    args.hashes_file.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(f"Updated {args.hashes_file}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
