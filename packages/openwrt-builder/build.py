#!/usr/bin/env python3
"""OpenWrt image builder — downloads upstream Image Builder and runs make image.

Replaces nix-openwrt-imagebuilder with a direct approach that:
1. Loads device config from baked-in JSON or evaluates Nix
2. Optionally decrypts sops secrets and bakes them into the image
3. Downloads the upstream OpenWrt Image Builder tarball
4. Runs `make image` with the prepared filesystem overlay

Usage:
    openwrt-build <device> [--no-secrets] [--output-dir DIR] [--cache-dir DIR]
    openwrt-build <device> --show-config
    openwrt-build --list-devices

Environment variables:
    OPENWRT_BUILD_INFO   — path to JSON file with all device build info
    OPENWRT_SECRETS_FILE — path to sops-encrypted secrets YAML
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

import yaml
import zstandard


def load_build_info_from_file(build_info_path):
    """Load all device build info from a JSON file."""
    with open(build_info_path) as f:
        return json.load(f)


def get_build_info_nix(device, repo_root):
    """Evaluate Nix to get build info for a device (fallback)."""
    result = subprocess.run(
        ["nix", "eval", "--json", f".#openwrtBuildInfo.{device}"],
        capture_output=True, text=True, cwd=repo_root,
    )
    if result.returncode != 0:
        print(f"Error: Failed to evaluate build info for '{device}'", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def get_build_info(device, build_info_path, repo_root):
    """Get build info for a device from JSON file or Nix eval."""
    if build_info_path:
        all_info = load_build_info_from_file(build_info_path)
        if device not in all_info:
            print(f"Error: Unknown device '{device}'", file=sys.stderr)
            print(f"Available devices: {', '.join(sorted(all_info.keys()))}", file=sys.stderr)
            sys.exit(1)
        return all_info[device]
    if not repo_root:
        print("Error: No --build-info file and no repository root found.", file=sys.stderr)
        print("Either set OPENWRT_BUILD_INFO or run from within the repo.", file=sys.stderr)
        sys.exit(1)
    return get_build_info_nix(device, repo_root)


def list_devices(build_info_path, repo_root):
    """List available devices."""
    if build_info_path:
        all_info = load_build_info_from_file(build_info_path)
    elif repo_root:
        result = subprocess.run(
            ["nix", "eval", "--json", ".#openwrtBuildInfo", "--apply", "builtins.attrNames"],
            capture_output=True, text=True, cwd=repo_root,
        )
        if result.returncode != 0:
            print("Error: Failed to list devices", file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            sys.exit(1)
        names = json.loads(result.stdout)
        all_info = {n: None for n in names}
    else:
        print("Error: No --build-info file and no repository root found.", file=sys.stderr)
        sys.exit(1)

    for name in sorted(all_info.keys()):
        if all_info[name] and "hostname" in all_info[name]:
            info = all_info[name]
            print(f"  {name:20s} {info.get('deviceType', ''):10s} {info.get('profile', '')}")
        else:
            print(f"  {name}")


def flatten_yaml(data, prefix=""):
    """Recursively flatten a parsed YAML dict to dot-separated key=value pairs.

    Only includes string leaf values (matching the previous yq behavior).
    """
    result = {}
    if isinstance(data, dict):
        for key, value in data.items():
            new_key = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                result.update(flatten_yaml(value, new_key))
            elif isinstance(value, str):
                result[new_key] = value
    return result


def decrypt_secrets(secrets_file):
    """Decrypt sops secrets file and return flat key=value dict."""
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

    try:
        data = yaml.safe_load(result.stdout)
    except yaml.YAMLError as e:
        print(f"Warning: Failed to parse secrets YAML: {e}", file=sys.stderr)
        return None

    if not isinstance(data, dict):
        return None

    return flatten_yaml(data)


def escape_uci_value(value):
    """Escape single quotes for shell-safe UCI values."""
    return value.replace("'", "'\\''")


def merge_secrets_into_uci(uci_script, secrets_map, secrets_kv, device_type):
    """Insert uci set commands for secrets before the uci commit line.

    Also enables radios for WiFi devices (they ship disabled without secrets).
    """
    secret_commands = []
    for secret_key, uci_paths in secrets_map.items():
        if secret_key in secrets_kv:
            value = escape_uci_value(secrets_kv[secret_key])
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


def extract_tar_zst(archive_path, dest_dir):
    """Extract a .tar.zst archive using native Python libraries."""
    dctx = zstandard.ZstdDecompressor()
    with open(archive_path, "rb") as fh:
        with dctx.stream_reader(fh) as reader:
            with tarfile.open(fileobj=reader, mode="r|") as tar:
                tar.extractall(path=dest_dir, filter="data")


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
    try:
        extract_tar_zst(tarball_path, cache_dir)
    except Exception as e:
        print(f"Error: Failed to extract Image Builder: {e}", file=sys.stderr)
        sys.exit(1)

    if not ib_dir.is_dir():
        # Some tarballs have slightly different directory names
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


def find_repo_root():
    """Try to find the repository root via git or REPO_ROOT env."""
    repo_root = os.environ.get("REPO_ROOT")
    if repo_root:
        return repo_root
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def find_secrets_file(explicit_path, repo_root):
    """Resolve the secrets file path."""
    if explicit_path:
        return explicit_path
    if repo_root:
        default = os.path.join(repo_root, "hosts", "openwrt", "secrets", "wifi.yaml")
        if os.path.isfile(default):
            return default
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Build OpenWrt images with baked-in configuration",
    )
    parser.add_argument("device", nargs="?", default=None,
                        help="Device name (as defined in hosts/openwrt/)")
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
    parser.add_argument(
        "--build-info", type=str, default=None,
        help="Path to JSON file with device build info (default: $OPENWRT_BUILD_INFO)",
    )
    parser.add_argument(
        "--secrets-file", type=str, default=None,
        help="Path to sops-encrypted secrets YAML (default: $OPENWRT_SECRETS_FILE)",
    )
    parser.add_argument(
        "--show-config", action="store_true",
        help="Print the UCI defaults script and exit",
    )
    parser.add_argument(
        "--list-devices", action="store_true",
        help="List available devices and exit",
    )
    args = parser.parse_args()

    # Resolve build-info path from flag or env
    build_info_path = args.build_info or os.environ.get("OPENWRT_BUILD_INFO")

    # Resolve secrets file from flag or env
    secrets_file_explicit = args.secrets_file or os.environ.get("OPENWRT_SECRETS_FILE")

    # Repo root is optional — only needed when build-info is not provided
    repo_root = find_repo_root() if not build_info_path else None

    # Handle --list-devices
    if args.list_devices:
        list_devices(build_info_path, repo_root)
        return

    # Device is required for all other operations
    if not args.device:
        parser.error("device is required (unless --list-devices is specified)")

    # Get build info
    build_info = get_build_info(args.device, build_info_path, repo_root)

    # Handle --show-config
    if args.show_config:
        print(build_info["uciDefaultsScript"])
        return

    # Determine output directory
    if args.output_dir:
        output_dir = args.output_dir
    elif repo_root:
        output_dir = Path(repo_root) / "openwrt-images" / args.device
    else:
        output_dir = Path.cwd() / "openwrt-images" / args.device

    # Step 1: Report build info
    print(f"[1/5] Evaluating build info for {args.device}...")
    print(f"  Device: {build_info['hostname']} ({build_info['deviceType']})")
    print(f"  Profile: {build_info['profile']}")
    print(f"  Target: {build_info['target']}/{build_info['subtarget']}")
    print(f"  Release: {build_info['release']}")

    # Step 2: Handle secrets
    uci_script = build_info["uciDefaultsScript"]
    if not args.no_secrets:
        print("[2/5] Decrypting secrets...")
        secrets_file = find_secrets_file(secrets_file_explicit, repo_root)
        if secrets_file:
            secrets_kv = decrypt_secrets(secrets_file)
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
            print("  No secrets file found (building without WiFi credentials).")
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
