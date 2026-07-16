#!/usr/bin/env python3
"""OpenWrt image builder — assembles an image from a pinned Nix manifest.

1. Loads device config from a build.json manifest file (--config-file)
2. Reads referenced files (UCI script, authorized_keys) from the paths in the manifest
3. Optionally reads a pre-decrypted secrets YAML and bakes secrets into the image
4. Extracts the Nix-pinned OpenWrt Image Builder
5. Runs `make image` with the prepared filesystem overlay

Usage:
    openwrt-build --config-file <build.json> [--no-secrets] [--output-dir DIR]

Environment variables:
    OPENWRT_SECRETS_FILE — path to a pre-decrypted plain secrets YAML
                           (equivalent to --secrets-file; ignored if that flag is given)
"""

import argparse
import contextlib
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml
import zstandard


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(manifest_file):
    """Load build config from a build.json manifest file.

    The manifest contains metadata (hostname, profile, packages, etc.) and
    paths for uciDefaults, secretsApply, and authorizedKeys. Paths may be
    absolute or relative to the manifest file.

    Manifests produced by `nix build .#openwrtConfigurations.<device>` use
    absolute Nix store paths. The Image Builder tarball is required to resolve
    beneath /nix/store; other referenced configuration files may be relative.
    """
    manifest_file = Path(manifest_file)
    with open(manifest_file) as f:
        meta = json.load(f)

    base = manifest_file.parent

    def resolve(p):
        path = Path(p)
        return path if path.is_absolute() else base / path

    meta["uciDefaultsScript"] = resolve(meta.pop("uciDefaults")).read_text()
    keys_content = resolve(meta.pop("authorizedKeys")).read_text()
    meta["authorizedKeys"] = [k for k in keys_content.splitlines() if k.strip()]
    meta["extraFiles"] = {
        target: resolve(source)
        for target, source in meta.get("extraFiles", {}).items()
    }

    return meta


# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

def flatten_yaml(data, prefix=""):
    """Recursively flatten a parsed YAML dict to dot-separated key=value pairs.

    Only includes string leaf values.
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


def load_secrets(secrets_file):
    """Load a plain (pre-decrypted) YAML secrets file and return flat key=value dict.

    Pass '-' to read from stdin. The caller is responsible for decryption;
    this function only reads and flattens the YAML.
    """
    try:
        if secrets_file == "-":
            data = yaml.safe_load(sys.stdin)
        else:
            with open(secrets_file) as f:
                data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        raise ValueError(f"failed to read secrets: {e}") from e

    if not isinstance(data, dict):
        raise ValueError("secrets input must be a YAML mapping")

    return flatten_yaml(data)


def escape_uci_value(value):
    """Escape single quotes for shell-safe UCI values."""
    return value.replace("'", "'\\''")


def merge_secrets_into_uci(uci_script, secrets_map, secrets_kv, device_type):
    """Insert uci set commands for secrets before the uci commit line.

    Also enables radios for WiFi devices (they ship disabled without secrets).
    """
    missing = [key for key in secrets_map if not secrets_kv.get(key)]
    if missing:
        raise ValueError(
            "secrets input is missing required non-empty values: " + ", ".join(missing)
        )

    secret_commands = []
    for secret_key, uci_paths in secrets_map.items():
        value = escape_uci_value(secrets_kv[secret_key])
        for uci_path in uci_paths:
            secret_commands.append(f"uci -q set {uci_path}='{value}'")

    # Enable radios for WiFi devices
    if device_type != "switch" and secrets_map:
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


def validate_pinned_tarball(tarball_path):
    """Resolve and validate an Image Builder tarball pinned by Nix."""
    store_root = Path("/nix/store").resolve()
    try:
        store_path = Path(tarball_path).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError(
            f"pinned Image Builder tarball does not exist: {tarball_path}"
        ) from error
    if not store_path.is_file() or not store_path.is_relative_to(store_root):
        raise ValueError(
            "imageBuilderTarball must resolve to a regular file under /nix/store"
        )
    return store_path


def prepare_imagebuilder(release, target, subtarget, cache_dir, tarball_path):
    """Obtain the OpenWrt Image Builder directory, ready for `make image`.

    tarball_path is a Nix store path. Its content-addressed store name is used
    as the cache key.

    The extracted directory is cached in cache_dir to avoid re-extraction
    on repeated builds.
    """
    store_path = validate_pinned_tarball(tarball_path)
    # Derive a stable cache key from the Nix store hash component.
    cache_key = store_path.name.split("-", 1)[0]
    extract_dir = cache_dir / f"store-{cache_key}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.chmod(0o700)
    lock_path = cache_dir / f".{extract_dir.name}.lock"
    with open(lock_path, "a+") as lock_file:
        lock_path.chmod(0o600)
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        complete = extract_dir / ".complete"
        ib_dir = _find_ib_subdir(extract_dir, release, target, subtarget)
        if complete.is_file() and ib_dir is not None:
            print(f"  Using cached Image Builder: {ib_dir}")
            return ib_dir

        # Only the lock holder may migrate an incomplete legacy entry. New
        # extractors never write to the shared destination before promotion.
        if extract_dir.exists():
            shutil.rmtree(extract_dir)

        temp_dir = Path(tempfile.mkdtemp(prefix=f".{extract_dir.name}-", dir=cache_dir))
        print(f"  Extracting from Nix store: {store_path}")
        try:
            extract_tar_zst(store_path, temp_dir)
            temp_ib = _find_ib_subdir(temp_dir, release, target, subtarget)
            if temp_ib is None:
                raise ValueError(
                    "archive did not contain the expected Image Builder directory"
                )
            (temp_dir / ".complete").touch()
            temp_dir.rename(extract_dir)
        finally:
            if temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)

        ib_dir = _find_ib_subdir(extract_dir, release, target, subtarget)
        if not (extract_dir / ".complete").is_file() or ib_dir is None:
            raise ValueError("Image Builder extraction did not complete")
        return ib_dir


@contextlib.contextmanager
def imagebuilder_workspace(cached_ib_dir):
    """Copy a pristine cached Image Builder into a private temporary workspace."""
    workspace_root = Path(tempfile.mkdtemp(prefix="openwrt-imagebuilder-"))
    workspace_root.chmod(0o700)
    workspace = workspace_root / "imagebuilder"
    try:
        # GNU cp can make cheap reflink copies where supported. Fall back to
        # shutil for environments without that extension.
        try:
            result = subprocess.run(
                ["cp", "-a", "--reflink=auto", f"{cached_ib_dir}/.", workspace],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            result = None
        if result is None or result.returncode != 0:
            shutil.rmtree(workspace, ignore_errors=True)
            shutil.copytree(cached_ib_dir, workspace, symlinks=True)
        patch_env_shebangs(workspace)
        yield workspace
    finally:
        shutil.rmtree(workspace_root, ignore_errors=True)


def patch_env_shebangs(workspace):
    """Make upstream tools runnable when /usr/bin is absent in a Nix sandbox."""
    env = shutil.which("env")
    if env is None:
        raise ValueError("env is required to prepare the Image Builder workspace")

    old_prefix = b"#!/usr/bin/env"
    new_prefix = f"#!{env}".encode()
    rules = workspace / "rules.mk"
    try:
        rules.write_text(rules.read_text().replace("/usr/bin/env", env))
    except OSError:
        pass

    for path in workspace.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as source:
                first_line = source.readline()
                if not first_line.startswith(old_prefix):
                    continue
                remainder = source.read()
            path.write_bytes(new_prefix + first_line[len(old_prefix):] + remainder)
        except OSError:
            continue


# ---------------------------------------------------------------------------
# Image build
# ---------------------------------------------------------------------------

def prepare_files(build_info, uci_script, tmpdir):
    """Create the FILES directory for make image.

    Contains:
    - etc/uci-defaults/99-nix-config  (UCI configuration script)
    - etc/dropbear/authorized_keys     (SSH keys)
    """
    files_dir = Path(tmpdir) / "files"

    if build_info.get("buildId"):
        etc_dir = files_dir / "etc"
        etc_dir.mkdir(parents=True)
        build_id_file = etc_dir / "mmell-build-id"
        build_id_file.write_text(build_info["buildId"] + "\n")
        build_id_file.chmod(0o644)

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

    for target, source in build_info.get("extraFiles", {}).items():
        relative = Path(target.lstrip("/"))
        if not target.startswith("/") or ".." in relative.parts or relative == Path("."):
            raise ValueError(f"invalid extraFiles target: {target}")
        if not source.is_file() or source.is_symlink():
            raise ValueError(f"extraFiles source must be a regular file: {source}")
        destination = files_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(source.stat().st_mode & 0o777)

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
    # OpenWrt rejects other umasks because they can produce images with broken
    # file modes. Do not rely on the caller (or a CI runner) to provide 022.
    previous_umask = os.umask(0o022)
    try:
        result = subprocess.run(
            cmd, cwd=ib_dir,
            env={**os.environ, "TERM": "xterm"},
        )
    finally:
        os.umask(previous_umask)
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
        "--config-file", type=str, default=None,
        help="Path to build.json manifest (from nix build .#openwrtConfigurations.<device>)",
    )
    parser.add_argument(
        "--secrets-file", type=str, default=None,
        help="Path to plain (pre-decrypted) secrets YAML, or '-' to read from stdin "
             "(default: $OPENWRT_SECRETS_FILE). Decryption is the caller's responsibility.",
    )

    args = parser.parse_args()
    if args.no_secrets and args.secrets_file:
        parser.error("--no-secrets cannot be combined with --secrets-file")

    # --- Load config ---
    secrets_file_explicit = args.secrets_file or os.environ.get("OPENWRT_SECRETS_FILE")

    if not args.config_file:
        parser.error("--config-file is required; builds are manifest-only")
    build_info = load_config(args.config_file)

    # --- Validate required fields ---
    missing = [
        flag for field, flag in [
            ("target",    "--target"),
            ("subtarget", "--subtarget"),
            ("profile",   "--profile"),
            ("release",   "manifest release"),
            ("imageBuilderTarball", "manifest imageBuilderTarball"),
        ]
        if not build_info.get(field)
    ]
    if missing:
        print(f"Error: Missing required fields: {', '.join(missing)}", file=sys.stderr)
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

    print(f"  ImageBuilder: pinned ({build_info['imageBuilderTarball']})")

    # --- Step 2: Secrets ---
    uci_script = build_info["uciDefaultsScript"]
    if not args.no_secrets:
        print("[2/5] Loading secrets...")
        if secrets_file_explicit:
            try:
                secrets_kv = load_secrets(secrets_file_explicit)
                if build_info.get("secretsMap"):
                    uci_script = merge_secrets_into_uci(
                        uci_script,
                        build_info["secretsMap"],
                        secrets_kv,
                        build_info["deviceType"],
                    )
            except ValueError as e:
                print(f"Error: {e}", file=sys.stderr)
                sys.exit(1)
            if build_info.get("secretsMap"):
                print("  Secrets merged into UCI config.")
            else:
                print("  Manifest does not require secrets.")
        else:
            print("  No secrets file provided (building without WiFi credentials).")
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
        with imagebuilder_workspace(ib_dir) as workspace:
            build_image(
                workspace,
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
