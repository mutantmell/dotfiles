"""Tests for cc_sandbox CLI tool."""
import json
import os
import time
from pathlib import Path
from unittest import mock

import pytest

import cc_sandbox


# --- Fixtures ---


@pytest.fixture
def config_dir(tmp_path):
    """Return a temp config directory and patch xdg_config_home to use it."""
    d = tmp_path / "config"
    d.mkdir()
    with mock.patch("cc_sandbox.xdg_config_home", return_value=str(d)):
        yield d


@pytest.fixture
def state_dir(tmp_path):
    """Return a temp state directory and patch xdg_state_home to use it."""
    d = tmp_path / "state"
    d.mkdir()
    with mock.patch("cc_sandbox.xdg_state_home", return_value=str(d)):
        yield d


@pytest.fixture
def tmp_state(tmp_path):
    """Return a State pointing at a temp directory."""
    return cc_sandbox.State(path=tmp_path / "state.json")


@pytest.fixture
def mock_config():
    """Return a mock Config object for API tests."""
    cfg = mock.Mock()
    cfg.api_url = "https://deployd.test/api/v1"
    cfg.client_id = "test-client"
    cfg.auth_base_url = "https://auth.test/realms/test"
    cfg.requests_verify.return_value = True
    cfg.forgejo_token = "test-token"
    cfg.forgejo_url = "https://forgejo.test"
    cfg.registry = "registry.test"
    cfg.image_name = "deployd/claude-sandbox"
    cfg.dns_servers = ""
    cfg.memory_limit = "4g"
    cfg.cpu_limit = "2"
    cfg.ca_cert = ""
    return cfg


def _write_config(config_dir, overrides=None):
    """Write a config JSON file and return the path."""
    cfg = {
        "apiUrl": "https://deployd.test/api/v1",
        "authBaseUrl": "https://auth.test/realms/test",
        "registry": "registry.test",
    }
    if overrides:
        cfg.update(overrides)
    sb_dir = config_dir / "cc-sandbox"
    sb_dir.mkdir(exist_ok=True)
    path = sb_dir / "config.json"
    path.write_text(json.dumps(cfg))
    return path


# --- parse_repo_url ---


class TestParseRepoUrl:
    def test_shorthand(self):
        assert cc_sandbox.parse_repo_url("owner/repo") == ("owner", "repo")

    def test_shorthand_git_suffix(self):
        assert cc_sandbox.parse_repo_url("owner/repo.git") == ("owner", "repo")

    def test_shorthand_trailing_slash(self):
        assert cc_sandbox.parse_repo_url("owner/repo/") == ("owner", "repo")

    def test_https(self):
        assert cc_sandbox.parse_repo_url("https://git.example.com/owner/repo") == ("owner", "repo")

    def test_https_git_suffix(self):
        assert cc_sandbox.parse_repo_url("https://git.example.com/owner/repo.git") == ("owner", "repo")

    def test_https_deep_path(self):
        assert cc_sandbox.parse_repo_url("https://host/owner/repo/extra") == ("owner", "repo")

    def test_invalid_single_component(self):
        with pytest.raises(ValueError, match="cannot parse"):
            cc_sandbox.parse_repo_url("justrepo")


# --- generate_hostname ---


class TestGenerateHostname:
    def test_returns_adjective_noun(self):
        name = cc_sandbox.generate_hostname(set())
        parts = name.split("-")
        assert len(parts) == 2
        assert parts[0] in cc_sandbox.ADJECTIVES
        assert parts[1] in cc_sandbox.NOUNS

    def test_avoids_existing(self):
        # Seed random to get deterministic first choice, put it in existing
        with mock.patch("cc_sandbox.random.choice", side_effect=["silver", "blade", "golden", "storm"]):
            name = cc_sandbox.generate_hostname({"silver-blade"})
        assert name == "golden-storm"

    def test_exhaustion_raises(self):
        with mock.patch("cc_sandbox.random.choice", return_value="x"):
            with pytest.raises(RuntimeError, match="1000 attempts"):
                cc_sandbox.generate_hostname({"x-x"})


# --- Config ---


class TestConfig:
    def test_minimal_required_fields(self, config_dir):
        _write_config(config_dir)
        cfg = cc_sandbox.Config()
        assert cfg.api_url == "https://deployd.test/api/v1"
        assert cfg.auth_base_url == "https://auth.test/realms/test"
        assert cfg.registry == "registry.test"

    def test_defaults(self, config_dir):
        _write_config(config_dir)
        cfg = cc_sandbox.Config()
        assert cfg.image_name == "deployd/claude-sandbox"
        assert cfg.memory_limit == "4g"
        assert cfg.cpu_limit == "2"
        assert cfg.client_id == "cc-sandbox"
        assert cfg.flake_path == "."
        assert cfg.flake_attr == "claude-sandbox-image"
        assert cfg.forgejo_url == "https://registry.test"

    def test_all_fields_override_defaults(self, config_dir):
        _write_config(config_dir, {
            "forgejoUrl": "https://forgejo.custom",
            "imageName": "custom/image",
            "memoryLimit": "8g",
            "cpuLimit": "4",
            "clientId": "my-client",
            "flakePath": "/my/flake",
            "flakeAttr": "my-image",
        })
        cfg = cc_sandbox.Config()
        assert cfg.forgejo_url == "https://forgejo.custom"
        assert cfg.image_name == "custom/image"
        assert cfg.memory_limit == "8g"
        assert cfg.cpu_limit == "4"
        assert cfg.client_id == "my-client"
        assert cfg.flake_path == "/my/flake"
        assert cfg.flake_attr == "my-image"

    def test_missing_file_raises(self, config_dir):
        with pytest.raises(RuntimeError, match="config file not found"):
            cc_sandbox.Config()

    def test_missing_required_field_raises(self, config_dir):
        sb_dir = config_dir / "cc-sandbox"
        sb_dir.mkdir()
        (sb_dir / "config.json").write_text('{"registry": "x"}')
        with pytest.raises(KeyError):
            cc_sandbox.Config()

    def test_forgejo_token_from_file(self, config_dir, tmp_path):
        token_file = tmp_path / "token"
        token_file.write_text("  my-secret-token  \n")
        _write_config(config_dir, {"forgejoTokenFile": str(token_file)})
        cfg = cc_sandbox.Config()
        assert cfg.forgejo_token == "my-secret-token"

    def test_forgejo_token_missing_file(self, config_dir):
        _write_config(config_dir, {"forgejoTokenFile": "/nonexistent/token"})
        cfg = cc_sandbox.Config()
        assert cfg.forgejo_token == ""

    def test_forgejo_token_no_file_configured(self, config_dir):
        _write_config(config_dir)
        cfg = cc_sandbox.Config()
        assert cfg.forgejo_token == ""

    def test_requests_verify_with_cert(self, config_dir):
        _write_config(config_dir, {"caCert": "/etc/ssl/my-ca.pem"})
        cfg = cc_sandbox.Config()
        assert cfg.requests_verify() == "/etc/ssl/my-ca.pem"

    def test_requests_verify_without_cert(self, config_dir):
        _write_config(config_dir)
        cfg = cc_sandbox.Config()
        assert cfg.requests_verify() is True


# --- State ---


class TestState:
    def test_load_missing_file(self, tmp_state):
        data = tmp_state.load()
        assert data == {"sandboxes": {}, "image_digest": ""}

    def test_save_load_roundtrip(self, tmp_state):
        data = {
            "sandboxes": {"silver-blade": {"container_name": "cc-silver-blade", "repo": ""}},
            "image_digest": "sha256:abc123",
        }
        tmp_state.save(data)
        loaded = tmp_state.load()
        assert loaded == data

    def test_save_creates_parents(self, tmp_path):
        st = cc_sandbox.State(path=tmp_path / "a" / "b" / "state.json")
        st.save({"sandboxes": {}, "image_digest": ""})
        assert st.path.exists()

    def test_load_preserves_extra_keys(self, tmp_state):
        data = {"sandboxes": {}, "image_digest": "", "extra": "kept"}
        tmp_state.save(data)
        assert tmp_state.load()["extra"] == "kept"


# --- TokenManager cache logic ---


class TestTokenManagerCache:
    def _make_manager(self, state_dir, mock_config):
        return cc_sandbox.TokenManager(mock_config)

    def test_valid_cached_token(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        # Write a valid cache
        mgr.token_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            "access_token": "cached-token",
            "refresh_token": "refresh-tok",
            "expires_at": time.time() + 3600,
        }
        mgr.token_path.write_text(json.dumps(cache))

        with mock.patch("cc_sandbox.http_requests") as mock_http:
            token = mgr.get_token()

        assert token == "cached-token"
        mock_http.post.assert_not_called()

    def test_expired_token_refreshes(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        mgr.token_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            "access_token": "expired",
            "refresh_token": "refresh-tok",
            "expires_at": time.time() - 100,
        }
        mgr.token_path.write_text(json.dumps(cache))

        mock_resp = mock.Mock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {
            "access_token": "new-token",
            "refresh_token": "new-refresh",
            "expires_in": 300,
        }

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_resp):
            token = mgr.get_token()

        assert token == "new-token"
        # Verify token was saved
        saved = json.loads(mgr.token_path.read_text())
        assert saved["access_token"] == "new-token"
        assert saved["refresh_token"] == "new-refresh"

    def test_expired_refresh_fails_triggers_authenticate(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        mgr.token_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            "access_token": "expired",
            "refresh_token": "bad-refresh",
            "expires_at": time.time() - 100,
        }
        mgr.token_path.write_text(json.dumps(cache))

        # Refresh fails (401)
        mock_refresh_resp = mock.Mock()
        mock_refresh_resp.status_code = 401

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_refresh_resp):
            with mock.patch.object(mgr, "_authenticate", return_value="fresh-token") as mock_auth:
                token = mgr.get_token()

        assert token == "fresh-token"
        mock_auth.assert_called_once()

    def test_no_cache_triggers_authenticate(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)

        with mock.patch.object(mgr, "_authenticate", return_value="fresh-token") as mock_auth:
            token = mgr.get_token()

        assert token == "fresh-token"
        mock_auth.assert_called_once()

    def test_corrupt_cache_triggers_authenticate(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        mgr.token_path.parent.mkdir(parents=True, exist_ok=True)
        mgr.token_path.write_text("not valid json{{{")

        with mock.patch.object(mgr, "_authenticate", return_value="fresh-token") as mock_auth:
            token = mgr.get_token()

        assert token == "fresh-token"
        mock_auth.assert_called_once()

    def test_save_cache_file_permissions(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        mgr._save_cache({"access_token": "t", "refresh_token": "r", "expires_in": 300})
        mode = mgr.token_path.stat().st_mode & 0o777
        assert mode == 0o600

    def test_save_cache_expiry_computation(self, state_dir, mock_config):
        mgr = self._make_manager(state_dir, mock_config)
        before = time.time()
        mgr._save_cache({"access_token": "t", "expires_in": 300})
        after = time.time()

        saved = json.loads(mgr.token_path.read_text())
        assert before + 300 <= saved["expires_at"] <= after + 300

    def test_near_expiry_triggers_refresh(self, state_dir, mock_config):
        """Token with <30s remaining should not be treated as valid."""
        mgr = self._make_manager(state_dir, mock_config)
        mgr.token_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            "access_token": "almost-expired",
            "refresh_token": "refresh-tok",
            "expires_at": time.time() + 10,  # only 10s remaining, < 30s buffer
        }
        mgr.token_path.write_text(json.dumps(cache))

        mock_resp = mock.Mock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {
            "access_token": "refreshed",
            "expires_in": 300,
        }

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_resp):
            token = mgr.get_token()

        assert token == "refreshed"


# --- Browser availability detection ---


class TestBrowserAvailable:
    def _make_manager(self, mock_config):
        with mock.patch("cc_sandbox.xdg_state_home", return_value="/tmp"):
            return cc_sandbox.TokenManager(mock_config)

    def test_with_display(self, mock_config):
        mgr = self._make_manager(mock_config)
        env = {"DISPLAY": ":0"}
        with mock.patch.dict(os.environ, env, clear=True):
            assert mgr._browser_available() is True

    def test_with_wayland(self, mock_config):
        mgr = self._make_manager(mock_config)
        env = {"WAYLAND_DISPLAY": "wayland-0"}
        with mock.patch.dict(os.environ, env, clear=True):
            assert mgr._browser_available() is True

    def test_ssh_session_overrides_display(self, mock_config):
        mgr = self._make_manager(mock_config)
        env = {"DISPLAY": ":0", "SSH_CONNECTION": "1.2.3.4 5678 5.6.7.8 22"}
        with mock.patch.dict(os.environ, env, clear=True):
            assert mgr._browser_available() is False

    def test_no_display_no_wayland(self, mock_config):
        mgr = self._make_manager(mock_config)
        with mock.patch.dict(os.environ, {}, clear=True):
            assert mgr._browser_available() is False


# --- deployd API functions ---


class TestDeploydApi:
    def test_deploy_payload_all_fields(self, mock_config):
        mock_resp = mock.Mock()
        mock_resp.json.return_value = {"status": "ok", "data": {"ip": "10.0.0.5"}}
        mock_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_resp) as mock_post:
            ip = cc_sandbox.deployd_deploy(
                mock_config, "tok", "cc-test", "img:latest",
                env={"KEY": "val"}, memory="4g", cpus="2",
            )

        assert ip == "10.0.0.5"
        call_kwargs = mock_post.call_args
        payload = call_kwargs.kwargs["json"]
        assert payload["name"] == "cc-test"
        assert payload["image"] == "img:latest"
        assert payload["env"] == {"KEY": "val"}
        assert payload["memory"] == "4g"
        assert payload["cpus"] == "2"

    def test_deploy_no_optionals(self, mock_config):
        mock_resp = mock.Mock()
        mock_resp.json.return_value = {"status": "ok", "data": None}
        mock_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_resp) as mock_post:
            ip = cc_sandbox.deployd_deploy(mock_config, "tok", "cc-test", "img:latest")

        assert ip is None
        payload = mock_post.call_args.kwargs["json"]
        assert "env" not in payload
        assert "memory" not in payload
        assert "cpus" not in payload

    def test_deploy_no_data_in_response(self, mock_config):
        mock_resp = mock.Mock()
        mock_resp.json.return_value = {"status": "ok"}
        mock_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.http_requests.post", return_value=mock_resp):
            ip = cc_sandbox.deployd_deploy(mock_config, "tok", "cc-test", "img:latest")

        assert ip is None

    def test_inspect_returns_ip(self, mock_config):
        mock_resp = mock.Mock()
        mock_resp.json.return_value = {"data": {"ip": "10.0.0.7"}}
        mock_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.http_requests.get", return_value=mock_resp):
            ip = cc_sandbox.deployd_inspect(mock_config, "tok", "cc-test")

        assert ip == "10.0.0.7"

    def test_teardown_calls_delete(self, mock_config):
        mock_resp = mock.Mock()
        mock_resp.json.return_value = {"status": "ok"}
        mock_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.http_requests.delete", return_value=mock_resp) as mock_del:
            cc_sandbox.deployd_teardown(mock_config, "tok", "cc-test")

        mock_del.assert_called_once()
        assert "teardown/cc-test" in mock_del.call_args.args[0]
