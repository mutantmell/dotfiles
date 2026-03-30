"""Tests for cc_sandbox CLI tool."""
import json
import os
import subprocess
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
        assert cfg.registry_user == "cc"

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
        assert data == {"image_digest": ""}

    def test_save_load_roundtrip(self, tmp_state):
        data = {"image_digest": "sha256:abc123"}
        tmp_state.save(data)
        loaded = tmp_state.load()
        assert loaded == data

    def test_save_creates_parents(self, tmp_path):
        st = cc_sandbox.State(path=tmp_path / "a" / "b" / "state.json")
        st.save({"image_digest": ""})
        assert st.path.exists()

    def test_load_preserves_extra_keys(self, tmp_state):
        data = {"image_digest": "", "extra": "kept"}
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


# --- Image management ---


class TestEnsureImage:
    def test_skips_push_when_unchanged(self, tmp_state, mock_config):
        tmp_state.save({"image_digest": "sha256:abc", "image_store_path": "/nix/store/old-image"})

        with mock.patch("cc_sandbox.build_image", return_value="/nix/store/old-image") as mock_build, \
             mock.patch("cc_sandbox.push_image") as mock_push:
            digest = cc_sandbox.ensure_image(mock_config, tmp_state)

        assert digest == "sha256:abc"
        mock_build.assert_called_once()
        mock_push.assert_not_called()

    def test_pushes_when_store_path_changed(self, tmp_state, mock_config):
        tmp_state.save({"image_digest": "sha256:old", "image_store_path": "/nix/store/old-image"})

        with mock.patch("cc_sandbox.build_image", return_value="/nix/store/new-image"), \
             mock.patch("cc_sandbox.push_image", return_value="sha256:new") as mock_push:
            digest = cc_sandbox.ensure_image(mock_config, tmp_state)

        assert digest == "sha256:new"
        mock_push.assert_called_once_with(mock_config, "/nix/store/new-image")
        saved = tmp_state.load()
        assert saved["image_digest"] == "sha256:new"
        assert saved["image_store_path"] == "/nix/store/new-image"

    def test_pushes_on_first_run(self, tmp_state, mock_config):
        with mock.patch("cc_sandbox.build_image", return_value="/nix/store/first-image"), \
             mock.patch("cc_sandbox.push_image", return_value="sha256:first") as mock_push:
            digest = cc_sandbox.ensure_image(mock_config, tmp_state)

        assert digest == "sha256:first"
        mock_push.assert_called_once()

    def test_pushes_when_digest_missing_but_path_matches(self, tmp_state, mock_config):
        tmp_state.save({"image_digest": "", "image_store_path": "/nix/store/img"})

        with mock.patch("cc_sandbox.build_image", return_value="/nix/store/img"), \
             mock.patch("cc_sandbox.push_image", return_value="sha256:new"):
            digest = cc_sandbox.ensure_image(mock_config, tmp_state)

        assert digest == "sha256:new"


# --- Dev shell management ---


class TestBuildDevShell:
    def test_skips_when_no_checkout_path(self):
        data = {"checkout_path": ""}
        assert cc_sandbox.build_dev_shell(data) is None

    def test_skips_when_no_flake_nix(self, tmp_path):
        data = {"checkout_path": str(tmp_path)}
        assert cc_sandbox.build_dev_shell(data) is None

    def test_returns_cached_when_lock_unchanged(self, tmp_path, state_dir):
        (tmp_path / "flake.nix").write_text("{}")
        (tmp_path / "flake.lock").write_text('{"nodes":{}}')
        lock_hash = cc_sandbox.hashlib.sha256(b'{"nodes":{}}').hexdigest()

        # Create the cached env script where build_dev_shell expects it
        env_script = Path(state_dir) / "cc-sandbox" / "projects" / "own-rpo" / "dev-env.sh"
        env_script.parent.mkdir(parents=True, exist_ok=True)
        env_script.write_text("cached env")

        data = {
            "owner": "own", "repo": "rpo",
            "checkout_path": str(tmp_path),
            "dev_shell_path": "/nix/store/cached-shell",
            "dev_shell_flake_lock_hash": lock_hash,
        }
        result = cc_sandbox.build_dev_shell(data)
        assert result == ("/nix/store/cached-shell", lock_hash, str(env_script))

    def test_builds_when_lock_changed(self, tmp_path, state_dir):
        (tmp_path / "flake.nix").write_text("{}")
        (tmp_path / "flake.lock").write_text('{"nodes":{"new":true}}')

        data = {
            "owner": "own", "repo": "rpo",
            "checkout_path": str(tmp_path),
            "dev_shell_path": "/nix/store/old-shell",
            "dev_shell_flake_lock_hash": "oldhash",
        }

        build_result = mock.Mock()
        build_result.stdout = "/nix/store/new-shell\n"
        env_result = mock.Mock()
        env_result.stdout = "# dev env script\n"
        with mock.patch("cc_sandbox.subprocess.run", side_effect=[build_result, env_result]) as mock_run:
            result = cc_sandbox.build_dev_shell(data)

        store_path, lock_hash, env_script_path = result
        assert store_path == "/nix/store/new-shell"
        assert lock_hash != "oldhash"
        assert env_script_path.endswith("dev-env.sh")
        assert mock_run.call_count == 2
        # First call: nix build
        assert "devShells.x86_64-linux.default" in mock_run.call_args_list[0].args[0][2]
        # Second call: nix print-dev-env
        assert mock_run.call_args_list[1].args[0][0] == "nix"
        assert mock_run.call_args_list[1].args[0][1] == "print-dev-env"

    def test_builds_on_first_run(self, tmp_path, state_dir):
        (tmp_path / "flake.nix").write_text("{}")
        (tmp_path / "flake.lock").write_text("{}")

        data = {"owner": "own", "repo": "rpo", "checkout_path": str(tmp_path)}

        build_result = mock.Mock()
        build_result.stdout = "/nix/store/first-shell\n"
        env_result = mock.Mock()
        env_result.stdout = "# env\n"
        with mock.patch("cc_sandbox.subprocess.run", side_effect=[build_result, env_result]):
            result = cc_sandbox.build_dev_shell(data)

        assert result is not None
        assert result[0] == "/nix/store/first-shell"
        assert result[2].endswith("dev-env.sh")

    def test_handles_no_flake_lock(self, tmp_path, state_dir):
        (tmp_path / "flake.nix").write_text("{}")
        # No flake.lock file

        data = {"owner": "own", "repo": "rpo", "checkout_path": str(tmp_path)}

        build_result = mock.Mock()
        build_result.stdout = "/nix/store/shell\n"
        env_result = mock.Mock()
        env_result.stdout = "# env\n"
        with mock.patch("cc_sandbox.subprocess.run", side_effect=[build_result, env_result]):
            result = cc_sandbox.build_dev_shell(data)

        assert result is not None
        assert result[1] == ""  # empty lock hash
        assert result[2].endswith("dev-env.sh")


class TestWaitForSsh:
    def test_returns_true_on_connect(self):
        with mock.patch("cc_sandbox.socket.create_connection") as mock_conn:
            mock_conn.return_value = mock.Mock()
            assert cc_sandbox.wait_for_ssh("10.0.0.5", timeout=5) is True

    def test_returns_false_on_timeout(self):
        with mock.patch("cc_sandbox.socket.create_connection", side_effect=OSError):
            assert cc_sandbox.wait_for_ssh("10.0.0.5", timeout=0) is False


class TestRebuildImage:
    def test_always_pushes(self, tmp_state, mock_config):
        tmp_state.save({"image_digest": "sha256:old", "image_store_path": "/nix/store/old"})

        with mock.patch("cc_sandbox.build_image", return_value="/nix/store/old"), \
             mock.patch("cc_sandbox.push_image", return_value="sha256:refreshed") as mock_push:
            digest = cc_sandbox.rebuild_image(mock_config, tmp_state)

        assert digest == "sha256:refreshed"
        mock_push.assert_called_once()
        saved = tmp_state.load()
        assert saved["image_digest"] == "sha256:refreshed"
        assert saved["image_store_path"] == "/nix/store/old"


# --- Profile ---


class TestProfile:
    def test_save_load_roundtrip(self, state_dir):
        p = cc_sandbox.Profile("owner", "repo")
        data = {
            "owner": "owner", "repo": "repo",
            "fork_url": "https://forgejo.test/cc/repo.git",
            "upstream_url": "https://forgejo.test/owner/repo.git",
            "checkout_path": "/home/user/repo",
            "container_name": None,
            "container_ip": None,
            "created_at": None,
        }
        p.save(data)
        assert p.exists()
        assert p.load() == data

    def test_exists_false_when_missing(self, state_dir):
        p = cc_sandbox.Profile("owner", "repo")
        assert not p.exists()

    def test_list_all_empty(self, state_dir):
        assert cc_sandbox.Profile.list_all() == []

    def test_list_all_returns_profiles(self, state_dir):
        for name in ["alice-foo", "bob-bar"]:
            owner, repo = name.split("-")
            p = cc_sandbox.Profile(owner, repo)
            p.save({"owner": owner, "repo": repo, "container_name": None})
        profiles = cc_sandbox.Profile.list_all()
        assert len(profiles) == 2
        owners = {p["owner"] for p in profiles}
        assert owners == {"alice", "bob"}

    def test_list_all_skips_dirs_without_profile(self, state_dir):
        projects_dir = Path(state_dir) / "cc-sandbox" / "projects" / "empty-dir"
        projects_dir.mkdir(parents=True)
        assert cc_sandbox.Profile.list_all() == []


# --- detect_repo_from_cwd ---


class TestDetectRepoFromCwd:
    def test_returns_owner_repo(self):
        result = mock.Mock()
        result.returncode = 0
        result.stdout = "https://github.com/owner/repo.git\n"
        with mock.patch("cc_sandbox.subprocess.run", return_value=result):
            assert cc_sandbox.detect_repo_from_cwd() == ("owner", "repo")

    def test_returns_none_on_failure(self):
        result = mock.Mock()
        result.returncode = 128
        result.stdout = ""
        with mock.patch("cc_sandbox.subprocess.run", return_value=result):
            assert cc_sandbox.detect_repo_from_cwd() is None

    def test_returns_none_on_unparseable(self):
        result = mock.Mock()
        result.returncode = 0
        result.stdout = "not-a-url\n"
        with mock.patch("cc_sandbox.subprocess.run", return_value=result):
            assert cc_sandbox.detect_repo_from_cwd() is None


# --- resolve_project ---


class TestResolveProject:
    def test_with_explicit_arg(self):
        assert cc_sandbox.resolve_project("owner/repo") == ("owner", "repo")

    def test_auto_detect(self):
        with mock.patch("cc_sandbox.detect_repo_from_cwd", return_value=("owner", "repo")):
            assert cc_sandbox.resolve_project(None) == ("owner", "repo")

    def test_auto_detect_fails(self):
        with mock.patch("cc_sandbox.detect_repo_from_cwd", return_value=None):
            with pytest.raises(SystemExit):
                cc_sandbox.resolve_project(None)


# --- cmd_init ---


class TestCmdInit:
    def test_creates_profile(self, state_dir, mock_config):
        args = mock.Mock()
        args.repo = "owner/myrepo"
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.forgejo_fork", return_value="https://forgejo.test/cc/myrepo.git"):
            cc_sandbox.cmd_init(args, mock_config, state, token_mgr)

        p = cc_sandbox.Profile("owner", "myrepo")
        assert p.exists()
        data = p.load()
        assert data["owner"] == "owner"
        assert data["repo"] == "myrepo"
        assert data["fork_url"] == "https://forgejo.test/cc/myrepo.git"
        assert data["upstream_url"] == "https://forgejo.test/owner/myrepo.git"
        assert data["checkout_path"] == ""
        assert data["container_name"] is None

    def test_auto_detect_records_checkout_path(self, state_dir, mock_config):
        args = mock.Mock()
        args.repo = None
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.detect_repo_from_cwd", return_value=("owner", "repo")):
            with mock.patch("cc_sandbox.forgejo_fork", return_value="https://forgejo.test/cc/repo.git"):
                cc_sandbox.cmd_init(args, mock_config, state, token_mgr)

        data = cc_sandbox.Profile("owner", "repo").load()
        assert data["checkout_path"] == os.getcwd()

    def test_duplicate_init_fails(self, state_dir, mock_config):
        args = mock.Mock()
        args.repo = "owner/repo"
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.forgejo_fork", return_value="https://forgejo.test/cc/repo.git"):
            cc_sandbox.cmd_init(args, mock_config, state, token_mgr)

        with mock.patch("cc_sandbox.forgejo_fork"):
            with pytest.raises(SystemExit):
                cc_sandbox.cmd_init(args, mock_config, state, token_mgr)


# --- cmd_up ---


class TestCmdUp:
    def _setup_profile(self, state_dir):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "https://forgejo.test/cc/repo.git",
            "upstream_url": "https://forgejo.test/owner/repo.git",
            "checkout_path": "/home/user/repo",
            "container_name": None,
            "container_ip": None,
            "created_at": None,
        })
        return p

    def test_deploys_container(self, state_dir, mock_config):
        self._setup_profile(state_dir)
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")

        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        inspect_resp = mock.Mock()
        inspect_resp.json.return_value = {"data": {"ip": "10.0.0.5"}}
        inspect_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.ensure_image", return_value="sha256:abc"), \
             mock.patch("cc_sandbox.build_dev_shell", return_value=None), \
             mock.patch("cc_sandbox.deployd_deploy") as mock_deploy, \
             mock.patch("cc_sandbox.http_requests.get", return_value=inspect_resp), \
             mock.patch("cc_sandbox.generate_hostname", return_value="silver-blade"):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

        mock_deploy.assert_called_once()
        call_kwargs = mock_deploy.call_args
        assert call_kwargs.args[2] == "cc-silver-blade"

        data = cc_sandbox.Profile("owner", "repo").load()
        assert data["container_name"] == "cc-silver-blade"
        assert data["container_ip"] == "10.0.0.5"
        assert data["created_at"] is not None

    def test_copies_dev_shell(self, state_dir, mock_config):
        self._setup_profile(state_dir)
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")

        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        inspect_resp = mock.Mock()
        inspect_resp.json.return_value = {"data": {"ip": "10.0.0.5"}}
        inspect_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.ensure_image", return_value="sha256:abc"), \
             mock.patch("cc_sandbox.build_dev_shell", return_value=("/nix/store/shell", "lockhash", "/tmp/dev-env.sh")), \
             mock.patch("cc_sandbox.wait_for_ssh", return_value=True), \
             mock.patch("cc_sandbox.copy_dev_shell") as mock_copy, \
             mock.patch("cc_sandbox.copy_dev_env_script") as mock_copy_env, \
             mock.patch("cc_sandbox.deployd_deploy"), \
             mock.patch("cc_sandbox.http_requests.get", return_value=inspect_resp), \
             mock.patch("cc_sandbox.generate_hostname", return_value="silver-blade"):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

        mock_copy.assert_called_once_with("10.0.0.5", "/nix/store/shell")
        mock_copy_env.assert_called_once_with("10.0.0.5", "/tmp/dev-env.sh")
        data = cc_sandbox.Profile("owner", "repo").load()
        assert data["dev_shell_path"] == "/nix/store/shell"
        assert data["dev_shell_flake_lock_hash"] == "lockhash"

    def test_dev_shell_cleared_on_copy_failure(self, state_dir, mock_config):
        self._setup_profile(state_dir)
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")

        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        inspect_resp = mock.Mock()
        inspect_resp.json.return_value = {"data": {"ip": "10.0.0.5"}}
        inspect_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.ensure_image", return_value="sha256:abc"), \
             mock.patch("cc_sandbox.build_dev_shell", return_value=("/nix/store/shell", "lockhash", "/tmp/dev-env.sh")), \
             mock.patch("cc_sandbox.wait_for_ssh", return_value=True), \
             mock.patch("cc_sandbox.copy_dev_shell", side_effect=subprocess.CalledProcessError(1, "nix copy")), \
             mock.patch("cc_sandbox.copy_dev_env_script"), \
             mock.patch("cc_sandbox.deployd_deploy"), \
             mock.patch("cc_sandbox.http_requests.get", return_value=inspect_resp), \
             mock.patch("cc_sandbox.generate_hostname", return_value="silver-blade"):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

        data = cc_sandbox.Profile("owner", "repo").load()
        assert "dev_shell_path" not in data
        assert "dev_shell_flake_lock_hash" not in data

    def test_no_profile_fails(self, state_dir, mock_config):
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()

        with pytest.raises(SystemExit):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

    def test_already_running_fails(self, state_dir, mock_config):
        p = self._setup_profile(state_dir)
        data = p.load()
        data["container_name"] = "cc-existing"
        p.save(data)

        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")

        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()

        with pytest.raises(SystemExit):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

    def test_env_vars_passed_to_deploy(self, state_dir, mock_config):
        self._setup_profile(state_dir)
        mock_config.dns_servers = "10.0.0.1"
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")

        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        inspect_resp = mock.Mock()
        inspect_resp.json.return_value = {"data": {"ip": "10.0.0.5"}}
        inspect_resp.raise_for_status = mock.Mock()

        with mock.patch("cc_sandbox.ensure_image", return_value="sha256:abc"), \
             mock.patch("cc_sandbox.build_dev_shell", return_value=None), \
             mock.patch("cc_sandbox.deployd_deploy") as mock_deploy, \
             mock.patch("cc_sandbox.http_requests.get", return_value=inspect_resp), \
             mock.patch("cc_sandbox.generate_hostname", return_value="silver-blade"):
            cc_sandbox.cmd_up(args, mock_config, state, token_mgr)

        env = mock_deploy.call_args.kwargs.get("env") or mock_deploy.call_args[1].get("env")
        assert env["SANDBOX_DNS"] == "10.0.0.1"
        assert env["SANDBOX_REPO_URL"] == "https://forgejo.test/cc/repo.git"
        assert env["SANDBOX_REPO_NAME"] == "repo"
        assert env["SANDBOX_GIT_TOKEN"] == "test-token"
        assert env["SANDBOX_UPSTREAM_URL"] == "https://forgejo.test/owner/repo.git"


# --- cmd_down ---


class TestCmdDown:
    def _setup_running(self, state_dir):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "https://forgejo.test/cc/repo.git",
            "upstream_url": "https://forgejo.test/owner/repo.git",
            "checkout_path": "/home/user/repo",
            "container_name": "cc-silver-blade",
            "container_ip": "10.0.0.5",
            "created_at": "2025-01-01T00:00:00+00:00",
        })
        return p

    def test_tears_down_and_clears_container(self, state_dir, mock_config):
        self._setup_running(state_dir)
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        with mock.patch("cc_sandbox.deployd_teardown") as mock_td:
            cc_sandbox.cmd_down(args, mock_config, state, token_mgr)

        mock_td.assert_called_once_with(mock_config, "tok", "cc-silver-blade")
        data = cc_sandbox.Profile("owner", "repo").load()
        assert data["container_name"] is None
        assert data["container_ip"] is None
        assert data["created_at"] is None

    def test_no_active_container_fails(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "", "container_name": None,
            "container_ip": None, "created_at": None,
        })
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        args = mock.Mock()
        args.repo = "owner/repo"
        token_mgr = mock.Mock()

        with pytest.raises(SystemExit):
            cc_sandbox.cmd_down(args, mock_config, state, token_mgr)

    def test_unregistered_project_fails(self, state_dir, mock_config):
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        args = mock.Mock()
        args.repo = "owner/nonexistent"
        token_mgr = mock.Mock()

        with pytest.raises(SystemExit):
            cc_sandbox.cmd_down(args, mock_config, state, token_mgr)


# --- cmd_ssh ---


class TestCmdSsh:
    def test_plain_ssh_without_dev_shell(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "",
            "container_name": "cc-test",
            "container_ip": "10.0.0.5",
            "created_at": "2025-01-01T00:00:00+00:00",
        })
        args = mock.Mock()
        args.repo = "owner/repo"
        args.no_develop = False
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.os.execvp") as mock_exec:
            cc_sandbox.cmd_ssh(args, mock_config, state, token_mgr)

        mock_exec.assert_called_once_with("ssh", [
            "ssh"] + cc_sandbox.SSH_OPTS + ["claude@10.0.0.5",
        ])

    def test_nix_develop_when_dev_shell_set(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "/home/user/repo",
            "container_name": "cc-test",
            "container_ip": "10.0.0.5",
            "created_at": "2025-01-01T00:00:00+00:00",
            "dev_shell_path": "/nix/store/shell",
        })
        args = mock.Mock()
        args.repo = "owner/repo"
        args.no_develop = False
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.os.execvp") as mock_exec:
            cc_sandbox.cmd_ssh(args, mock_config, state, token_mgr)

        mock_exec.assert_called_once_with("ssh",
            ["ssh"] + cc_sandbox.SSH_OPTS + [
            "-t", "claude@10.0.0.5",
            "cd /workspace/repo && source /workspace/.dev-env.sh && exec bash",
        ])

    def test_no_develop_flag_skips_nix_develop(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "/home/user/repo",
            "container_name": "cc-test",
            "container_ip": "10.0.0.5",
            "created_at": "2025-01-01T00:00:00+00:00",
            "dev_shell_path": "/nix/store/shell",
        })
        args = mock.Mock()
        args.repo = "owner/repo"
        args.no_develop = True
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with mock.patch("cc_sandbox.os.execvp") as mock_exec:
            cc_sandbox.cmd_ssh(args, mock_config, state, token_mgr)

        mock_exec.assert_called_once_with("ssh", [
            "ssh"] + cc_sandbox.SSH_OPTS + ["claude@10.0.0.5",
        ])

    def test_no_container_fails(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "",
            "container_name": None, "container_ip": None, "created_at": None,
        })
        args = mock.Mock()
        args.repo = "owner/repo"
        args.no_develop = False
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()

        with pytest.raises(SystemExit):
            cc_sandbox.cmd_ssh(args, mock_config, state, token_mgr)

    def test_polls_for_ip_when_not_cached(self, state_dir, mock_config):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x", "upstream_url": "x",
            "checkout_path": "",
            "container_name": "cc-test",
            "container_ip": None,
            "created_at": "2025-01-01T00:00:00+00:00",
        })
        args = mock.Mock()
        args.repo = "owner/repo"
        args.no_develop = False
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        token_mgr = mock.Mock()
        token_mgr.get_token.return_value = "tok"

        with mock.patch("cc_sandbox.deployd_inspect", return_value="10.0.0.9") as mock_insp, \
             mock.patch("cc_sandbox.os.execvp") as mock_exec:
            cc_sandbox.cmd_ssh(args, mock_config, state, token_mgr)

        mock_insp.assert_called_once_with(mock_config, "tok", "cc-test")
        mock_exec.assert_called_once_with("ssh", [
            "ssh"] + cc_sandbox.SSH_OPTS + ["claude@10.0.0.9",
        ])
        # Verify IP was persisted to profile
        data = cc_sandbox.Profile("owner", "repo").load()
        assert data["container_ip"] == "10.0.0.9"


# --- cmd_list ---


class TestCmdList:
    def test_empty(self, state_dir, capsys):
        args = mock.Mock()
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        cc_sandbox.cmd_list(args, mock.Mock(), state, mock.Mock())
        assert "No registered projects" in capsys.readouterr().out

    def test_shows_running_project(self, state_dir, capsys):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x",
            "upstream_url": "https://forgejo.test/owner/repo.git",
            "checkout_path": "",
            "container_name": "cc-test",
            "container_ip": "10.0.0.5",
            "created_at": "2025-01-01T00:00:00+00:00",
        })
        args = mock.Mock()
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        cc_sandbox.cmd_list(args, mock.Mock(), state, mock.Mock())
        out = capsys.readouterr().out
        assert "owner/repo" in out
        assert "running" in out
        assert "10.0.0.5" in out

    def test_shows_stopped_project(self, state_dir, capsys):
        p = cc_sandbox.Profile("owner", "repo")
        p.save({
            "owner": "owner", "repo": "repo",
            "fork_url": "x",
            "upstream_url": "https://forgejo.test/owner/repo.git",
            "checkout_path": "",
            "container_name": None,
            "container_ip": None,
            "created_at": None,
        })
        args = mock.Mock()
        state = cc_sandbox.State(path=Path(state_dir) / "cc-sandbox" / "state.json")
        cc_sandbox.cmd_list(args, mock.Mock(), state, mock.Mock())
        out = capsys.readouterr().out
        assert "owner/repo" in out
        assert "stopped" in out
