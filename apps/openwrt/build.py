#!/usr/bin/env python3
"""OpenWrt image builder — downloads upstream Image Builder and runs make image.

Replaces nix-openwrt-imagebuilder with a direct approach that:
1. Evaluates Nix for device config (UCI, packages, etc.)
2. Optionally decrypts sops secrets and bakes them into the image
3. Downloads the upstream OpenWrt Image Builder tarball
4. Runs `make image` with the prepared filesystem overlay

Usage:
    openwrt-build <device> [--no-secrets] [--output-dir DIR] [--cache-dir DIR]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path


def get_build_info(device, repo_root):
    """Evaluate Nix to get build info for a device."""
    result = subprocess.run(
        ["nix", "eval", "--json", f".#openwrtBuildInfo.{device}"],
        capture_output=True, text=True, cwd=repo_root,
    )
    if result.returncode != 0:
        print(f"Error: Failed to evaluate build info for '{device}'", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def decrypt_secrets(secrets_file):
    """Decrypt sops secrets file and return flat key=value dict.

    Uses sops -d to decrypt, then yq to flatten YAML to key=value lines.
    """
    if not os.path.isfile(secrets_file):
        return None

    result = subprocess.run(
        ["sops", "-d", secrets_file],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Warning: Failed to decrypt {secrets_file}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return None

    # Flatten YAML to key=value using yq
    yq_result = subprocess.run(
        ["yq", "-r", '.. | select(tag == "!!str") | (path | join(".")) + "=" + .'],
        input=result.stdout, capture_output=True, text=True,
    )
    if yq_result.returncode != 0:
        print("Warning: Failed to flatten secrets YAML", file=sys.stderr)
        return None

    secrets = {}
    for line in yq_result.stdout.strip().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            secrets[key] = value
    return secrets


def merge_secrets_into_uci(uci_script, secrets_map, secrets_kv, device_type):
    """Insert uci set commands for secrets before the uci commit line.

    Also enables radios for WiFi devices (they ship disabled without secrets).
    """
    secret_commands = []
    for secret_key, uci_paths in secrets_map.items():
        if secret_key in secrets_kv:
            value = secrets_kv[secret_key]
            for uci_path in uci_paths:
                secret_commands.append(f"uci -q set {uci_path}='{value}'")

    # Enable radios for WiFi devices
    if device_type != "switch" and secret_commands:
        secret_commands.append("uci -q set wireless.radio0.disabled=0")
        secret_commands.append("uci -q set wireless.radio1.disabled=0")

    if not secret_commands:
        return uci_script

    # Insert before the last "uci commit" line
    lines = uci_script.splitlines()
    result = []
    inserted = False
    for line in reversed(lines):
        if not inserted and line.strip() == "uci commit":
            result.append(line)
            result.append("")
            result.append("# Secrets (baked in at build time)")
            for cmd in reversed(secret_commands):
                result.append(cmd)
            inserted = True
        else:
            result.append(line)
    result.reverse()
    return "\n".join(result)


def download_imagebuilder(release, target, subtarget, cache_dir):
    """Download and extract the OpenWrt Image Builder tarball.

    Caches in cache_dir to avoid re-downloading.
    """
    ib_name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64"
    ib_dir = cache_dir / ib_name
    if ib_dir.is_dir():
        print(f"  Using cached Image Builder: {ib_dir}")
        return ib_dir

    tarball_name = f"{ib_name}.tar.zst"
    tarball_path = cache_dir / tarball_name
    url = (
        f"https://downloads.openwrt.org/releases/{release}"
        f"/targets/{target}/{subtarget}/{tarball_name}"
    )

    cache_dir.mkdir(parents=True, exist_ok=True)

    if not tarball_path.is_file():
        print(f"  Downloading {url} ...")
        try:
            urllib.request.urlretrieve(url, tarball_path)
        except Exception as e:
            tarball_path.unlink(missing_ok=True)
            print(f"Error: Failed to download Image Builder: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"  Extracting {tarball_name} ...")
    subprocess.run(
        ["tar", "--zstd", "-xf", str(tarball_path), "-C", str(cache_dir)],
        check=True,
    )

    if not ib_dir.is_dir():
        # Some tarballs have slightly different directory names
        # Try to find the extracted directory
        candidates = list(cache_dir.glob(f"openwrt-imagebuilder-{release}-{target}-{subtarget}*"))
        if candidates:
            ib_dir = candidates[0]
        else:
            print("Error: Could not find extracted Image Builder directory", file=sys.stderr)
            sys.exit(1)

    return ib_dir


def prepare_files(build_info, uci_script, tmpdir):
    """Create the FILES directory for make image.

    Contains:
    - etc/uci-defaults/99-nix-config  (UCI configuration script)
    - etc/dropbear/authorized_keys     (SSH keys)
    - etc/nix-secrets-apply            (runtime secrets script)
    """
    files_dir = Path(tmpdir) / "files"

    uci_dir = files_dir / "etc" / "uci-defaults"
    uci_dir.mkdir(parents=True)
    uci_file = uci_dir / "99-nix-config"
    uci_file.write_text(uci_script)
    uci_file.chmod(0o755)

    # Authorized keys
    if build_info.get("authorizedKeys"):
        dropbear_dir = files_dir / "etc" / "dropbear"
        dropbear_dir.mkdir(parents=True)
        keys_file = dropbear_dir / "authorized_keys"
        keys_file.write_text("\n".join(build_info["authorizedKeys"]) + "\n")
        keys_file.chmod(0o600)

    # Secrets apply script (for runtime use with openwrt-configure-secrets)
    if build_info.get("secretsApplyScript"):
        secrets_script = files_dir / "etc" / "nix-secrets-apply"
        secrets_script.write_text(build_info["secretsApplyScript"])
        secrets_script.chmod(0o755)

    return files_dir


def build_image(ib_dir, profile, packages, files_dir, output_dir):
    """Run make image in the Image Builder directory."""
    output_dir.mkdir(parents=True, exist_ok=True)

    packages_str = " ".join(packages)
    cmd = [
        "make", "image",
        f"PROFILE={profile}",
        f"PACKAGES={packages_str}",
        f"FILES={files_dir}",
        f"BIN_DIR={output_dir}",
    ]

    print(f"  Running: {' '.join(cmd[:4])} ...")
    result = subprocess.run(
        cmd, cwd=ib_dir,
        env={**os.environ, "TERM": "xterm"},
    )
    if result.returncode != 0:
        print("Error: Image build failed", file=sys.stderr)
        sys.exit(1)


def find_sysupgrade(output_dir):
    """Locate the sysupgrade image in the output directory."""
    for pattern in ["*-sysupgrade.bin", "*-sysupgrade.img.gz", "*.img.gz"]:
        matches = list(output_dir.rglob(pattern))
        if matches:
            return matches[0]
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Build OpenWrt images with baked-in configuration",
    )
    parser.add_argument("device", help="Device name (as defined in hosts/openwrt/)")
    parser.add_argument(
        "--no-secrets", action="store_true",
        help="Build without WiFi secrets (radios will be disabled)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Output directory (default: ./openwrt-images/<device>/)",
    )
    parser.add_argument(
        "--cache-dir", type=Path,
        default=Path.home() / ".cache" / "openwrt-builder",
        help="Cache directory for Image Builder tarballs",
    )
    args = parser.parse_args()

    repo_root = os.environ.get("REPO_ROOT")
    if not repo_root:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            repo_root = result.stdout.strip()
        else:
            print("Error: Could not find repository root", file=sys.stderr)
            sys.exit(1)

    output_dir = args.output_dir or Path(repo_root) / "openwrt-images" / args.device

    # Step 1: Get build info from Nix
    print(f"[1/5] Evaluating build info for {args.device}...")
    build_info = get_build_info(args.device, repo_root)
    print(f"  Device: {build_info['hostname']} ({build_info['deviceType']})")
    print(f"  Profile: {build_info['profile']}")
    print(f"  Target: {build_info['target']}/{build_info['subtarget']}")
    print(f"  Release: {build_info['release']}")

    # Step 2: Handle secrets
    uci_script = build_info["uciDefaultsScript"]
    if not args.no_secrets:
        print("[2/5] Decrypting secrets...")
        secrets_file = Path(repo_root) / "hosts" / "openwrt" / "secrets" / "wifi.yaml"
        secrets_kv = decrypt_secrets(str(secrets_file))
        if secrets_kv and build_info.get("secretsMap"):
            uci_script = merge_secrets_into_uci(
                uci_script,
                build_info["secretsMap"],
                secrets_kv,
                build_info["deviceType"],
            )
            print("  Secrets merged into UCI config.")
        else:
            print("  No secrets available (building without WiFi credentials).")
    else:
        print("[2/5] Skipping secrets (--no-secrets).")

    # Step 3: Download Image Builder
    print(f"[3/5] Preparing Image Builder...")
    ib_dir = download_imagebuilder(
        build_info["release"],
        build_info["target"],
        build_info["subtarget"],
        args.cache_dir,
    )

    # Step 4: Prepare files and build
    tmpdir = tempfile.mkdtemp(prefix="openwrt-build-")
    os.chmod(tmpdir, 0o700)
    try:
        print("[4/5] Preparing filesystem overlay...")
        files_dir = prepare_files(build_info, uci_script, tmpdir)

        print(f"[5/5] Building image...")
        build_image(
            ib_dir,
            build_info["profile"],
            build_info["packages"],
            files_dir,
            output_dir,
        )
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # Report result
    sysupgrade = find_sysupgrade(output_dir)
    print()
    if sysupgrade:
        size_mb = sysupgrade.stat().st_size / (1024 * 1024)
        print(f"Build complete: {sysupgrade} ({size_mb:.1f} MB)")
    else:
        print(f"Build complete. Output in: {output_dir}")


if __name__ == "__main__":
    main()
