#!/usr/bin/env python3
"""OpenWrt image builder — downloads upstream Image Builder and runs make image.

1. Loads device config from a per-device JSON config file (--config-file)
2. Reads referenced files (UCI script, secrets-apply, authorized_keys) from Nix store paths
3. Optionally decrypts sops secrets and bakes them into the image
4. Obtains the OpenWrt Image Builder (from Nix store if pinned, else downloads)
5. Runs `make image` with the prepared filesystem overlay

Usage:
    openwrt-build --config-dir <dir> [--no-secrets] [--output-dir DIR]
    openwrt-build --update-pins --hashes-file <path> --targets <t/st> [<t/st> ...]
    openwrt-build --config-dir <dir> --update [--hashes-file <path>]

Environment variables:
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


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(config_file, uci_file, secrets_apply_file, keys_file):
    """Load build config from Nix-generated files.

    The config JSON contains metadata (hostname, profile, packages, etc.).
    The UCI script, secrets-apply script, and authorized_keys are separate
    store files passed as individual arguments.
    """
    with open(config_file) as f:
        meta = json.load(f)

    meta["uciDefaultsScript"] = Path(uci_file).read_text()
    meta["secretsApplyScript"] = Path(secrets_apply_file).read_text()
    keys_content = Path(keys_file).read_text()
    meta["authorizedKeys"] = [k for k in keys_content.splitlines() if k.strip()]

    return meta


def load_config_dir(config_dir):
    """Load build config from a bundled config directory.

    The directory contains build.json with a 'files' key mapping to
    relative paths for uci-defaults, secrets-apply, and authorized_keys.
    If the Image Builder is pinned, build.json also contains an
    'imageBuilderTarball' field with its Nix store path.
    Produced by `nix build .#openwrtConfigurations.<device>`.
    """
    config_dir = Path(config_dir)
    with open(config_dir / "build.json") as f:
        meta = json.load(f)

    files = meta.pop("files")
    base = config_dir
    meta["uciDefaultsScript"] = (base / files["uciDefaults"]).read_text()
    meta["secretsApplyScript"] = (base / files["secretsApply"]).read_text()
    keys_content = (base / files["authorizedKeys"]).read_text()
    meta["authorizedKeys"] = [k for k in keys_content.splitlines() if k.strip()]

    return meta


# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Image Builder — obtain and extract
# ---------------------------------------------------------------------------

def _imagebuilder_tar_filter(member, dest_path):
    """Tarfile extraction filter for OpenWrt Image Builder archives.

    Applies "tar" level security (blocks absolute paths, path traversal via ..,
    and special files) with one targeted exception: absolute symlink *targets*
    are permitted. The imagebuilder uses these in staging_dir/host/bin/ as
    wrappers to host tools (e.g. git -> /usr/bin/git). All other "tar" filter
    protections remain in effect.
    """
    try:
        return tarfile.tar_filter(member, dest_path)
    except tarfile.AbsoluteLinkError:
        return member


def extract_tar_zst(archive_path, dest_dir):
    """Extract a .tar.zst archive using native Python libraries."""
    dctx = zstandard.ZstdDecompressor()
    with open(archive_path, "rb") as fh:
        with dctx.stream_reader(fh) as reader:
            with tarfile.open(fileobj=reader, mode="r|") as tar:
                tar.extractall(path=dest_dir, filter=_imagebuilder_tar_filter)


def _find_ib_subdir(parent_dir, release, target, subtarget):
    """Locate the extracted Image Builder directory inside parent_dir."""
    ib_name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64"
    exact = parent_dir / ib_name
    if exact.is_dir():
        return exact
    # Tolerate minor naming variations (e.g. extra suffix)
    candidates = list(parent_dir.glob(
        f"openwrt-imagebuilder-{release}-{target}-{subtarget}*"
    ))
    if candidates:
        return candidates[0]
    return None


def prepare_imagebuilder(release, target, subtarget, cache_dir, tarball_path=None):
    """Obtain the OpenWrt Image Builder directory, ready for `make image`.

    If tarball_path is provided (a Nix store path), extract from there —
    no network access needed. The Nix store path is content-addressed, so
    it is safe to use as a cache key.

    Otherwise downloads the tarball from the upstream OpenWrt servers.

    The extracted directory is cached in cache_dir to avoid re-extraction
    on repeated builds.
    """
    if tarball_path:
        store_path = Path(tarball_path)
        # Derive a stable cache key from the Nix store hash component
        # e.g. /nix/store/abc123...-openwrt-imagebuilder-... → "abc123..."
        cache_key = store_path.parent.name  # hash-name directory name
        extract_dir = cache_dir / f"store-{cache_key}"
        ib_dir = _find_ib_subdir(extract_dir, release, target, subtarget)
        if ib_dir is not None:
            print(f"  Using cached Image Builder: {ib_dir}")
            return ib_dir
        print(f"  Extracting from Nix store: {store_path}")
        extract_dir.mkdir(parents=True, exist_ok=True)
        try:
            extract_tar_zst(store_path, extract_dir)
        except Exception as e:
            shutil.rmtree(extract_dir, ignore_errors=True)
            print(f"Error: Failed to extract Image Builder: {e}", file=sys.stderr)
            sys.exit(1)
        ib_dir = _find_ib_subdir(extract_dir, release, target, subtarget)
        if ib_dir is None:
            print("Error: Could not find extracted Image Builder directory",
                  file=sys.stderr)
            sys.exit(1)
        return ib_dir
    else:
        return _download_imagebuilder(release, target, subtarget, cache_dir)


def _download_imagebuilder(release, target, subtarget, cache_dir):
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

    ib_dir = _find_ib_subdir(cache_dir, release, target, subtarget)
    if ib_dir is None:
        print("Error: Could not find extracted Image Builder directory",
              file=sys.stderr)
        sys.exit(1)

    return ib_dir


# ---------------------------------------------------------------------------
# Image build
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# ImageBuilder version update
# ---------------------------------------------------------------------------

def fetch_latest_release():
    """Query downloads.openwrt.org to find the latest stable release version."""
    url = "https://downloads.openwrt.org/releases/"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            body = resp.read().decode()
    except Exception as e:
        print(f"Error: Failed to query OpenWrt releases: {e}", file=sys.stderr)
        return None

    # Match versioned stable release directories like 24.10.5, 23.05.6
    # Exclude RCs (which contain letters like 24.10.0-rc1)
    versions = re.findall(r'href="(\d+\.\d+\.\d+)/"', body)
    if not versions:
        return None

    return sorted(versions, key=lambda v: tuple(int(x) for x in v.split(".")))[-1]


def compute_imagebuilder_hash(release, target, subtarget):
    """Compute and return the SRI sha256 hash of an Image Builder tarball.

    Uses `nix store prefetch-file` which downloads the file into the Nix store
    (or reuses a cached copy) and returns its content hash. This also warms
    the store so the subsequent `nix build .#openwrtConfigurations.*` call
    doesn't re-download.
    """
    ib_name = f"openwrt-imagebuilder-{release}-{target}-{subtarget}.Linux-x86_64"
    url = (
        f"https://downloads.openwrt.org/releases/{release}"
        f"/targets/{target}/{subtarget}/{ib_name}.tar.zst"
    )
    print(f"  Fetching hash for {target}/{subtarget} @ {release} ...")
    print(f"    {url}")
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", url],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Error: Failed to prefetch {url}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)["hash"]
    except (json.JSONDecodeError, KeyError) as e:
        print(f"Error: Unexpected output from nix store prefetch-file: {e}",
              file=sys.stderr)
        return None


def update_hashes_json(hashes_file, release, new_hashes):
    """Update defaultRelease and imageBuilderHashes in openwrt-hashes.json.

    new_hashes: dict of { "target/subtarget": "sha256-..." }

    Updates defaultRelease to release. Adds or replaces the entry for this
    release inside imageBuilderHashes; older release entries are preserved.
    """
    hashes_file = Path(hashes_file)
    data = json.loads(hashes_file.read_text()) if hashes_file.exists() else {}

    data["defaultRelease"] = release
    release_hashes = data.setdefault("imageBuilderHashes", {}).setdefault(release, {})
    release_hashes.update(new_hashes)

    hashes_file.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(f"  Updated {hashes_file}")


def run_update(targets, hashes_file, release=None):
    """Fetch hashes for the given targets and update openwrt-hashes.json.

    targets: list of "target/subtarget" strings
    hashes_file: path to lib/common/data/openwrt-hashes.json
    release: explicit release version, or None to fetch the latest

    Returns the release version that was written, or None on failure.
    """
    if release is None:
        print("Querying latest OpenWrt release...")
        release = fetch_latest_release()
        if release is None:
            print("Error: Could not determine latest OpenWrt release.",
                  file=sys.stderr)
            return None
        print(f"  Latest release: {release}")

    print(f"Computing Image Builder hashes for release {release}...")
    new_hashes = {}
    for target_key in targets:
        parts = target_key.split("/")
        if len(parts) != 2:
            print(f"Warning: Skipping malformed target '{target_key}'",
                  file=sys.stderr)
            continue
        target, subtarget = parts
        h = compute_imagebuilder_hash(release, target, subtarget)
        if h is None:
            print(f"Error: Failed to compute hash for {target_key}", file=sys.stderr)
            return None
        new_hashes[target_key] = h
        print(f"    {target_key}: {h}")

    update_hashes_json(hashes_file, release, new_hashes)
    print(f"Hash update complete. Commit the changes to lib/common/data/openwrt-hashes.json.")
    return release


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def find_secrets_file(explicit_path):
    """Resolve the secrets file path."""
    if explicit_path:
        return explicit_path
    return None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Build OpenWrt images with baked-in configuration",
    )
    parser.add_argument(
        "--no-secrets", action="store_true",
        help="Build without WiFi secrets (radios will be disabled)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Output directory (default: ./openwrt-images/<hostname>/)",
    )
    parser.add_argument(
        "--cache-dir", type=Path,
        default=Path.home() / ".cache" / "openwrt-builder",
        help="Cache directory for Image Builder tarballs",
    )
    parser.add_argument(
        "--config-dir", type=str, default=None,
        help="Path to bundled config directory (from nix build .#openwrtConfigurations.<device>)",
    )
    parser.add_argument(
        "--config-file", type=str, default=None,
        help="Path to per-device JSON config file (generated by Nix)",
    )
    parser.add_argument(
        "--uci-file", type=str, default=None,
        help="Path to UCI defaults script (generated by Nix)",
    )
    parser.add_argument(
        "--secrets-apply-file", type=str, default=None,
        help="Path to secrets-apply script (generated by Nix)",
    )
    parser.add_argument(
        "--keys-file", type=str, default=None,
        help="Path to authorized_keys file (generated by Nix)",
    )
    parser.add_argument(
        "--secrets-file", type=str, default=None,
        help="Path to sops-encrypted secrets YAML (default: $OPENWRT_SECRETS_FILE)",
    )

    # Update flags
    parser.add_argument(
        "--update", action="store_true",
        help="Update Image Builder hashes to the latest release before building",
    )
    parser.add_argument(
        "--update-pins", action="store_true",
        help="Update Image Builder hashes and exit without building",
    )
    parser.add_argument(
        "--hashes-file", type=str, default=None,
        help="Path to lib/common/data/openwrt-hashes.json (required for --update/--update-pins)",
    )
    parser.add_argument(
        "--targets", nargs="+", default=None,
        help='Image Builder targets to update, e.g. mediatek/mt7622 realtek/rtl838x',
    )
    parser.add_argument(
        "--release", type=str, default=None,
        help="Explicit OpenWrt release version to pin (default: fetch latest from upstream)",
    )

    args = parser.parse_args()

    # --- Update-only mode ---
    if args.update_pins:
        if not args.targets:
            print("Error: --targets is required with --update-pins.", file=sys.stderr)
            sys.exit(1)
        if not args.hashes_file:
            print("Error: --hashes-file is required with --update-pins.", file=sys.stderr)
            sys.exit(1)
        result = run_update(args.targets, args.hashes_file, release=args.release)
        sys.exit(0 if result is not None else 1)

    # --- Load config ---
    secrets_file_explicit = args.secrets_file or os.environ.get("OPENWRT_SECRETS_FILE")

    if args.config_dir:
        build_info = load_config_dir(args.config_dir)
    elif args.config_file:
        for name, val in [("--uci-file", args.uci_file),
                          ("--secrets-apply-file", args.secrets_apply_file),
                          ("--keys-file", args.keys_file)]:
            if not val:
                print(f"Error: {name} is required when using --config-file.",
                      file=sys.stderr)
                sys.exit(1)
        build_info = load_config(
            args.config_file, args.uci_file, args.secrets_apply_file, args.keys_file,
        )
    else:
        print("Error: --config-dir or --config-file is required.", file=sys.stderr)
        sys.exit(1)

    # --- Determine output directory ---
    if args.output_dir:
        output_dir = args.output_dir
    else:
        output_dir = Path.cwd() / "openwrt-images" / build_info["hostname"]

    # --- Step 1: Report ---
    print(f"[1/5] Evaluating build info for {build_info['hostname']}...")
    print(f"  Device: {build_info['hostname']} ({build_info['deviceType']})")
    print(f"  Profile: {build_info['profile']}")
    print(f"  Target: {build_info['target']}/{build_info['subtarget']}")
    print(f"  Release: {build_info['release']}")

    if "imageBuilderTarball" in build_info:
        print(f"  ImageBuilder: pinned ({build_info['imageBuilderTarball']})")
    else:
        print(
            "  ImageBuilder: not pinned — will download from upstream.\n"
            "  Tip: run with --update to pin this version for reproducible builds.",
        )

    # --- Step 2: Secrets ---
    uci_script = build_info["uciDefaultsScript"]
    if not args.no_secrets:
        print("[2/5] Decrypting secrets...")
        secrets_file = find_secrets_file(secrets_file_explicit)
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

    # --- Step 3: Image Builder ---
    print("[3/5] Preparing Image Builder...")
    ib_dir = prepare_imagebuilder(
        build_info["release"],
        build_info["target"],
        build_info["subtarget"],
        args.cache_dir,
        tarball_path=build_info.get("imageBuilderTarball"),
    )

    # --- Step 4: Files ---
    tmpdir = tempfile.mkdtemp(prefix="openwrt-build-")
    os.chmod(tmpdir, 0o700)
    try:
        print("[4/5] Preparing filesystem overlay...")
        files_dir = prepare_files(build_info, uci_script, tmpdir)

        print("[5/5] Building image...")
        build_image(
            ib_dir,
            build_info["profile"],
            build_info["packages"],
            files_dir,
            output_dir,
        )
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- Report result ---
    sysupgrade = find_sysupgrade(output_dir)
    print()
    if sysupgrade:
        size_mb = sysupgrade.stat().st_size / (1024 * 1024)
        print(f"Build complete: {sysupgrade} ({size_mb:.1f} MB)")
    else:
        print(f"Build complete. Output in: {output_dir}")


if __name__ == "__main__":
    main()
