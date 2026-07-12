import importlib.util
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("openwrt_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SecretsTests(unittest.TestCase):
    def test_complete_secrets_enable_radios(self):
        rendered = build.merge_secrets_into_uci(
            "#!/bin/sh\nuci commit",
            {"wifi.main.ssid": ["wireless.main.ssid"]},
            {"wifi.main.ssid": "example"},
            "meshAP",
        )
        self.assertIn("wireless.radio0.disabled=0", rendered)
        self.assertIn("wireless.radio1.disabled=0", rendered)

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
            with self.assertRaisesRegex(ValueError, "YAML mapping"):
                build.load_secrets(source)


if __name__ == "__main__":
    unittest.main()
