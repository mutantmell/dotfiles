import importlib.util
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("openwrt_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SecretsTests(unittest.TestCase):
    def test_cli_disables_long_option_abbreviations(self):
        parser = build.create_argument_parser()
        for option in ["--config=manifest.json", "--config-f=manifest.json", "--out=output"]:
            with self.subTest(option=option), self.assertRaises(SystemExit):
                parser.parse_args([option])

    def test_cli_accepts_canonical_split_and_equal_options(self):
        parser = build.create_argument_parser()
        split = parser.parse_args([
            "--config-file", "manifest.json",
            "--output-dir", "output",
            "--secrets-file", "secrets.yaml",
        ])
        equal = parser.parse_args([
            "--config-file=manifest.json",
            "--output-dir=output",
            "--secrets-file=secrets.yaml",
        ])
        self.assertEqual("manifest.json", split.config_file)
        self.assertEqual("secrets.yaml", split.secrets_file)
        self.assertEqual("manifest.json", equal.config_file)
        self.assertEqual("secrets.yaml", equal.secrets_file)

    def test_cli_rejects_empty_secret_sources_including_duplicates(self):
        parser = build.create_argument_parser()
        cases = [
            ["--secrets-file", ""],
            ["--secrets-file="],
            ["--secrets-file", "secrets.yaml", "--secrets-file="],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                parser.parse_args(arguments)

    def test_cli_secret_modes_are_mutually_exclusive(self):
        parser = build.create_argument_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["--no-secrets", "--secrets-file", "secrets.yaml"])

    def test_complete_secrets_enable_radios(self):
        rendered = build.merge_secrets_into_uci(
            "#!/bin/sh\nuci commit",
            {"wifi.main.ssid": ["wireless.main.ssid"]},
            {"wifi.main.ssid": "example"},
            "meshAP",
        )
        self.assertIn("wireless.radio0.disabled=0", rendered)
        self.assertIn("wireless.radio1.disabled=0", rendered)

    def test_explicit_radio_list_enables_third_radio(self):
        rendered = build.merge_secrets_into_uci(
            "uci commit",
            {"bt8bridge.mesh.key": ["wireless.batmesh.key"]},
            {"bt8bridge.mesh.key": "example"},
            "wirelessBridge",
            ["radio0", "radio1", "radio2"],
        )
        self.assertIn("wireless.radio2.disabled=0", rendered)

    def test_incomplete_secrets_fail(self):
        with self.assertRaisesRegex(ValueError, "wifi.main.key"):
            build.merge_secrets_into_uci(
                "uci commit",
                {"wifi.main.ssid": ["wireless.main.ssid"], "wifi.main.key": ["wireless.main.key"]},
                {"wifi.main.ssid": "example"},
                "meshAP",
            )

    def test_malformed_secrets_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "secrets.yaml"
            source.write_text("[not, a, mapping]\n")
            with self.assertRaisesRegex(TypeError, "YAML mapping"):
                build.load_secrets(source)


class ImageBuilderTests(unittest.TestCase):
    release = "24.10.1"
    target = "mediatek"
    subtarget = "filogic"

    def _ib_name(self):
        return (
            f"openwrt-imagebuilder-{self.release}-{self.target}-"
            f"{self.subtarget}.Linux-x86_64"
        )

    @staticmethod
    def _make_workspace(path):
        path.mkdir()
        return str(path)

    def test_prepare_files_bakes_build_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            files = build.prepare_files(
                {"buildId": "evaluated-build-id", "authorizedKeys": []},
                "#!/bin/sh\n",
                directory,
            )
            identity = files / "etc" / "mmell-build-id"
            self.assertEqual("evaluated-build-id\n", identity.read_text())
            self.assertEqual(0o644, identity.stat().st_mode & 0o777)

    def test_prepare_files_copies_declarative_extra_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "host-key"
            source.write_text("fake-test-key\n")
            source.chmod(0o600)
            files = build.prepare_files(
                {"authorizedKeys": [], "extraFiles": {"/etc/dropbear/host-key": source}},
                "#!/bin/sh\n",
                Path(directory) / "work",
            )
            copied = files / "etc" / "dropbear" / "host-key"
            self.assertEqual("fake-test-key\n", copied.read_text())
            self.assertEqual(0o600, copied.stat().st_mode & 0o777)

    def test_prepare_files_rejects_unsafe_extra_file_target(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.write_text("test\n")
            with self.assertRaisesRegex(ValueError, "invalid extraFiles target"):
                build.prepare_files(
                    {"authorizedKeys": [], "extraFiles": {"/../escape": source}},
                    "#!/bin/sh\n",
                    Path(directory) / "work",
                )

    def test_tarball_must_resolve_under_nix_store(self):
        with (
            tempfile.NamedTemporaryFile() as source,
            self.assertRaisesRegex(ValueError, "under /nix/store"),
        ):
            build.validate_pinned_tarball(source.name)

    def test_concurrent_preparation_extracts_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            tarball = root / "store-hash-imagebuilder.tar.zst"
            tarball.touch()
            calls = []
            calls_lock = threading.Lock()

            def fake_extract(_archive, destination):
                with calls_lock:
                    calls.append(destination)
                time.sleep(0.05)
                (destination / self._ib_name()).mkdir()

            results = []

            def prepare():
                results.append(build.prepare_imagebuilder(
                    self.release,
                    self.target,
                    self.subtarget,
                    cache,
                    tarball,
                ))

            with (
                mock.patch.object(build, "validate_pinned_tarball", return_value=tarball),
                mock.patch.object(build, "extract_tar_zst", side_effect=fake_extract),
            ):
                threads = [threading.Thread(target=prepare) for _ in range(2)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()

            self.assertEqual(1, len(calls))
            self.assertEqual(2, len(results))
            self.assertEqual(results[0], results[1])
            self.assertTrue((results[0].parent / ".complete").is_file())

    def test_workspace_is_private_pristine_and_removed_on_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached = root / "cached"
            cached.mkdir()
            (cached / "sentinel").write_text("pristine")
            workspace_root = root / "workspace"

            def fake_run(command, **kwargs):
                if command[0] == "cp":
                    return mock.Mock(returncode=1)
                # Model secret-bearing intermediates written by `make image`.
                Path(kwargs["cwd"], "sentinel").write_text("secret build intermediate")
                Path(kwargs["cwd"], "secret-intermediate").write_text("credential")
                return mock.Mock(returncode=0)

            with (
                mock.patch.object(
                    build.tempfile,
                    "mkdtemp",
                    side_effect=lambda **_kwargs: self._make_workspace(workspace_root),
                ),
                mock.patch.object(
                    build.subprocess,
                    "run",
                    side_effect=fake_run,
                ),
                build.imagebuilder_workspace(cached) as workspace,
            ):
                self.assertEqual(0o700, workspace_root.stat().st_mode & 0o777)
                build.build_image(workspace, "profile", [], root, root / "output")

            self.assertEqual("pristine", (cached / "sentinel").read_text())
            self.assertFalse((cached / "secret-intermediate").exists())
            self.assertFalse(workspace_root.exists())

    def test_workspace_patches_env_shebangs_without_mutating_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached = root / "cached"
            cached.mkdir()
            script = cached / "script"
            script.write_text("#!/usr/bin/env python3\nprint('ok')\n")
            rules = cached / "rules.mk"
            rules.write_text("export SHELL:=/usr/bin/env bash\n")

            with (
                mock.patch.object(
                    build.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=1),
                ),
                build.imagebuilder_workspace(cached) as workspace,
            ):
                patched = (workspace / "script").read_text()
                self.assertTrue(patched.startswith(f"#!{build.shutil.which('env')} python3"))
                self.assertIn(
                    f"SHELL:={build.shutil.which('env')} bash",
                    (workspace / "rules.mk").read_text(),
                )

            self.assertTrue(script.read_text().startswith("#!/usr/bin/env python3"))
            self.assertIn("/usr/bin/env bash", rules.read_text())

    def test_workspace_is_removed_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached = root / "cached"
            cached.mkdir()
            (cached / "sentinel").touch()
            workspace_root = root / "workspace"

            with (
                mock.patch.object(
                    build.tempfile,
                    "mkdtemp",
                    side_effect=lambda **_kwargs: self._make_workspace(workspace_root),
                ),
                mock.patch.object(
                    build.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=1),
                ),
                self.assertRaisesRegex(RuntimeError, "failed"),
                build.imagebuilder_workspace(cached),
            ):
                raise RuntimeError("failed")

            self.assertFalse(workspace_root.exists())

    def test_image_build_uses_openwrt_umask_and_restores_caller_umask(self):
        observed_umasks = []

        def fake_run(*_args, **_kwargs):
            current = build.os.umask(0o022)
            build.os.umask(current)
            observed_umasks.append(current)
            return mock.Mock(returncode=0)

        original = build.os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with mock.patch.object(build.subprocess, "run", side_effect=fake_run):
                    build.build_image(root, "generic", [], root, root / "output")

            restored = build.os.umask(0o077)
            build.os.umask(restored)
            self.assertEqual([0o022], observed_umasks)
            self.assertEqual(0o077, restored)
        finally:
            build.os.umask(original)


if __name__ == "__main__":
    unittest.main()
