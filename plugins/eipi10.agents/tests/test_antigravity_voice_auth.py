"""Security-focused tests for the Agent Panel → Omarvoice auth handoff."""

from contextlib import redirect_stdout
import hashlib
from importlib.machinery import SourceFileLoader
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


CONTROLLER_PATH = (
    Path(__file__).resolve().parents[1] / "bin/omarchy-antigravity-ctl"
)
loader = SourceFileLoader("omarchy_antigravity_ctl", str(CONTROLLER_PATH))
controller = types.ModuleType(loader.name)
loader.exec_module(controller)


class OAuthClientBootstrapTests(unittest.TestCase):
    def test_extract_selects_only_fingerprinted_binary_values(self):
        client_id = (
            b"1234567890-abcdefghijklmnopqrstuv"
            b".apps.googleusercontent.com"
        )
        client_secret = b"GOC" + b"SPX-abcdefghijklmnopqrstuvwxyz12"
        unrelated_id = (
            b"9876543210-zyxwvutsrqponmlkjihg"
            b".apps.googleusercontent.com"
        )
        unrelated_secret = b"GOC" + b"SPX-zyxwvutsrqponmlkjihgfedcba21"
        binary = b"|".join([
            unrelated_id,
            client_secret,
            unrelated_secret,
            client_id,
        ])

        with tempfile.TemporaryDirectory() as directory:
            language_server = Path(directory) / "language_server"
            language_server.write_bytes(binary)
            extracted = controller.extract_antigravity_oauth_client(
                language_server,
                {hashlib.sha256(client_id).hexdigest()},
                {hashlib.sha256(client_secret).hexdigest()},
            )

        self.assertEqual(
            extracted,
            (client_id.decode("ascii"), client_secret.decode("ascii")),
        )

    def test_bootstrap_writes_private_config_without_printing_credentials(self):
        output = StringIO()
        client_id = "private-client-id"
        client_secret = "private-client-secret"
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "oauth.json"
            with mock.patch.object(controller, "CLIENT_ID", ""):
                with mock.patch.object(controller, "CLIENT_SECRET", ""):
                    with mock.patch.object(
                        controller,
                        "OAUTH_CONFIG_FILE",
                        config_path,
                    ):
                        with mock.patch.object(
                            controller,
                            "ensure_storage_migrated",
                        ):
                            with mock.patch.object(
                                controller,
                                "extract_antigravity_oauth_client",
                                return_value=(client_id, client_secret),
                            ):
                                with redirect_stdout(output):
                                    exit_code = controller.oauth_client_bootstrap()

            stored = json.loads(config_path.read_text(encoding="utf-8"))
            mode = os.stat(config_path).st_mode & 0o777

        self.assertEqual(exit_code, 0)
        self.assertEqual(stored["client_id"], client_id)
        self.assertEqual(stored["client_secret"], client_secret)
        self.assertEqual(mode, 0o600)
        self.assertNotIn(client_id, output.getvalue())
        self.assertNotIn(client_secret, output.getvalue())

    def test_browser_authorization_uses_omarchy_launcher(self):
        with mock.patch.object(
            controller.shutil,
            "which",
            side_effect=lambda name: (
                "/usr/bin/omarchy" if name == "omarchy" else None
            ),
        ):
            with mock.patch.object(controller.subprocess, "Popen") as popen:
                opened = controller.open_oauth_browser(
                    "https://accounts.example.test/authorize"
                )

        self.assertTrue(opened)
        self.assertEqual(
            popen.call_args.args[0],
            [
                "/usr/bin/omarchy",
                "launch",
                "browser",
                "https://accounts.example.test/authorize",
            ],
        )
        self.assertTrue(popen.call_args.kwargs["start_new_session"])


class VoiceAuthTests(unittest.TestCase):
    def test_oauth_flow_requests_aicode_scope(self):
        self.assertIn(controller.AICODE_SCOPE, controller.SCOPES.split())

    def test_ready_status_never_prints_tokens(self):
        output = StringIO()
        with mock.patch.object(controller, "ensure_storage_migrated"):
            with mock.patch.object(
                controller,
                "current_account",
                return_value={"id": "account-1", "email": "voice@example.com"},
            ):
                with mock.patch.object(
                    controller,
                    "load_credential",
                    return_value={
                        "refresh_token": "private-refresh",
                        "scope": controller.AICODE_SCOPE,
                    },
                ):
                    with redirect_stdout(output):
                        exit_code = controller.voice_auth_status()

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertTrue(result["ready"])
        self.assertNotIn("private-refresh", output.getvalue())

    def test_sync_sends_secret_only_over_keyring_stdin(self):
        output = StringIO()
        stored = mock.Mock(returncode=0)
        credential = {
            "access_token": "private-access",
            "refresh_token": "private-refresh",
            "expired": "2026-08-27T22:00:00+00:00",
            "token_type": "Bearer",
        }
        with mock.patch.object(controller, "ensure_storage_migrated"):
            with mock.patch.object(
                controller,
                "current_account",
                return_value={"id": "account-1", "email": "voice@example.com"},
            ):
                with mock.patch.object(
                    controller,
                    "refresh_credential",
                    return_value=(credential, {controller.AICODE_SCOPE}),
                ):
                    with mock.patch.object(
                        controller.shutil, "which", return_value="/usr/bin/secret-tool"
                    ):
                        with mock.patch.object(
                            controller.subprocess, "run", return_value=stored
                        ) as run:
                            with redirect_stdout(output):
                                exit_code = controller.voice_auth_sync()

        self.assertEqual(exit_code, 0)
        self.assertNotIn("private-access", output.getvalue())
        self.assertNotIn("private-refresh", output.getvalue())
        keyring_input = run.call_args.kwargs["input"]
        self.assertIn("private-access", keyring_input)
        self.assertIn("private-refresh", keyring_input)
        self.assertIs(controller.subprocess.DEVNULL, run.call_args.kwargs["stdout"])
        self.assertIs(controller.subprocess.DEVNULL, run.call_args.kwargs["stderr"])

    def test_sync_reuses_access_token_with_safe_remaining_lifetime(self):
        output = StringIO()
        stored = mock.Mock(returncode=0)
        credential = {
            "access_token": "still-valid-access",
            "refresh_token": "private-refresh",
            "expired": "2999-01-01T00:00:00+00:00",
            "token_type": "Bearer",
            "scope": controller.AICODE_SCOPE,
        }
        with mock.patch.object(controller, "ensure_storage_migrated"):
            with mock.patch.object(
                controller,
                "current_account",
                return_value={"id": "account-1", "email": "voice@example.com"},
            ):
                with mock.patch.object(
                    controller, "load_credential", return_value=credential
                ):
                    with mock.patch.object(
                        controller, "refresh_credential"
                    ) as refresh:
                        with mock.patch.object(
                            controller.shutil,
                            "which",
                            return_value="/usr/bin/secret-tool",
                        ):
                            with mock.patch.object(
                                controller.subprocess, "run", return_value=stored
                            ):
                                with redirect_stdout(output):
                                    exit_code = controller.voice_auth_sync()

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertFalse(result["refreshed"])
        refresh.assert_not_called()

    def test_sync_reports_an_unresponsive_keyring_without_committing_secrets(self):
        output = StringIO()
        credential = {
            "access_token": "private-access",
            "refresh_token": "private-refresh",
            "expired": "2999-01-01T00:00:00+00:00",
            "token_type": "Bearer",
            "scope": controller.AICODE_SCOPE,
        }
        with mock.patch.object(controller, "ensure_storage_migrated"):
            with mock.patch.object(
                controller,
                "current_account",
                return_value={"id": "account-1", "email": "voice@example.com"},
            ):
                with mock.patch.object(
                    controller,
                    "load_credential",
                    return_value=credential,
                ):
                    with mock.patch.object(
                        controller.shutil,
                        "which",
                        return_value="/usr/bin/secret-tool",
                    ):
                        with mock.patch.object(
                            controller.subprocess,
                            "run",
                            side_effect=controller.subprocess.TimeoutExpired(
                                "secret-tool",
                                10,
                            ),
                        ):
                            with redirect_stdout(output):
                                exit_code = controller.voice_auth_sync()

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 1)
        self.assertEqual(result["status"], "keyring_write_failed")
        self.assertNotIn("private-access", output.getvalue())
        self.assertNotIn("private-refresh", output.getvalue())

    def test_token_near_expiry_requires_refresh(self):
        credential = {
            "access_token": "expiring",
            "expired": "2000-01-01T00:00:00+00:00",
        }

        self.assertTrue(controller.credential_needs_refresh(credential))

    def test_absorb_runtime_keyring_preserves_rotated_refresh_token(self):
        saved = {}
        existing = {
            "email": "voice@example.com",
            "access_token": "old-access",
            "refresh_token": "old-refresh",
            "scope": controller.AICODE_SCOPE,
        }
        runtime = {
            "access_token": "runtime-access",
            "refresh_token": "rotated-refresh",
            "expired": "2999-01-01T00:00:00+00:00",
        }
        with mock.patch.object(
            controller, "read_keyring_credential", return_value=runtime
        ):
            with mock.patch.object(
                controller, "load_credential", return_value=existing
            ):
                with mock.patch.object(
                    controller,
                    "access_token_email",
                    return_value="voice@example.com",
                ):
                    with mock.patch.object(
                        controller,
                        "save_credential",
                        side_effect=lambda account_id, value: saved.update(value),
                    ):
                        absorbed = controller.absorb_runtime_keyring({
                            "id": "account-1",
                            "email": "voice@example.com",
                        })

        self.assertTrue(absorbed)
        self.assertEqual(saved["access_token"], "runtime-access")
        self.assertEqual(saved["refresh_token"], "rotated-refresh")


class NativeAppAuthTests(unittest.TestCase):
    def test_frontend_auth_chain_requires_valid_auth_and_matching_identity(self):
        calls = []

        def rpc(_runtime, method):
            calls.append(method)
            return {
                "HasAuthToken": {"hasToken": True},
                "GetAuthStatus": {"authResult": {"hasValidAuth": {}}},
                "GetUserStatus": {
                    "userStatus": {"email": "ready@example.com"}
                },
            }[method]

        with mock.patch.object(
            controller,
            "discover_antigravity_runtime",
            return_value={"port": 1234, "csrf_token": "test"},
        ):
            with mock.patch.object(
                controller,
                "antigravity_rpc",
                side_effect=rpc,
            ):
                result = controller.wait_for_antigravity_auth(
                    "ready@example.com",
                    timeout_seconds=1,
                )

        self.assertTrue(result["ready"])
        self.assertEqual(result["email"], "ready@example.com")
        self.assertEqual(
            calls,
            ["HasAuthToken", "GetAuthStatus", "GetUserStatus"],
        )

    def test_frontend_auth_chain_reports_ineligible_account(self):
        def rpc(_runtime, method):
            if method == "HasAuthToken":
                return {"hasToken": True}
            return {
                "authResult": {
                    "uiMessage": "not eligible",
                    "ineligible": {
                        "verificationUrl": "https://example.test/verify"
                    },
                }
            }

        with mock.patch.object(
            controller,
            "discover_antigravity_runtime",
            return_value={"port": 1234, "csrf_token": "test"},
        ):
            with mock.patch.object(
                controller,
                "antigravity_rpc",
                side_effect=rpc,
            ):
                result = controller.wait_for_antigravity_auth(
                    "blocked@example.com",
                    timeout_seconds=1,
                )

        self.assertFalse(result["ready"])
        self.assertEqual(result["status"], "account_ineligible")
        self.assertEqual(
            result["verification_url"],
            "https://example.test/verify",
        )

    def test_frontend_auth_chain_retries_transient_general_error(self):
        status_responses = iter([
            {
                "authResult": {
                    "uiMessage": "loadCodeAssist: EOF",
                    "generalError": {},
                }
            },
            {"authResult": {"hasValidAuth": {}}},
        ])

        def rpc(_runtime, method):
            if method == "HasAuthToken":
                return {"hasToken": True}
            if method == "GetAuthStatus":
                return next(status_responses)
            return {"userStatus": {"email": "ready@example.com"}}

        with mock.patch.object(
            controller,
            "discover_antigravity_runtime",
            return_value={"port": 1234, "csrf_token": "test"},
        ):
            with mock.patch.object(
                controller,
                "antigravity_rpc",
                side_effect=rpc,
            ):
                with mock.patch.object(controller.time, "sleep"):
                    result = controller.wait_for_antigravity_auth(
                        "ready@example.com",
                        timeout_seconds=1,
                    )

        self.assertTrue(result["ready"])


class AccountSwitchTests(unittest.TestCase):
    def write_index(self, path):
        path.write_text(
            json.dumps({
                "version": "2.0",
                "accounts": [
                    {
                        "id": "old-account",
                        "email": "old@example.com",
                        "last_used": 1,
                    },
                    {
                        "id": "new-account",
                        "email": "new@example.com",
                        "last_used": 2,
                    },
                ],
                "current_account_id": "old-account",
                "current_target_ide": "agy",
            }),
            encoding="utf-8",
        )

    def test_switch_commits_only_after_native_app_accepts_account(self):
        output = StringIO()
        events = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = root / "accounts.json"
            accounts_dir = root / "accounts"
            accounts_dir.mkdir()
            self.write_index(index_path)

            def stop_app():
                current_id = json.loads(
                    index_path.read_text(encoding="utf-8")
                )["current_account_id"]
                events.append(("stop", current_id))
                return True

            def absorb_runtime(account):
                events.append(("absorb", account["id"]))
                return True

            def sync_account(
                account,
                force_refresh=False,
                validate_access=False,
                require_aicode=True,
            ):
                current_id = json.loads(
                    index_path.read_text(encoding="utf-8")
                )["current_account_id"]
                events.append((
                    "sync",
                    account["id"],
                    current_id,
                    force_refresh,
                    validate_access,
                    require_aicode,
                ))
                return {"status": "ready", "ready": True}, 0

            def start_app():
                current_id = json.loads(
                    index_path.read_text(encoding="utf-8")
                )["current_account_id"]
                events.append(("start", current_id))
                return True

            def wait_for_auth(expected_email):
                current_id = json.loads(
                    index_path.read_text(encoding="utf-8")
                )["current_account_id"]
                events.append(("validate", expected_email, current_id))
                return {
                    "ready": True,
                    "status": "ready",
                    "email": expected_email,
                }

            with mock.patch.object(controller, "ACCOUNTS_INDEX", index_path):
                with mock.patch.object(controller, "ACCOUNTS_DIR", accounts_dir):
                    with mock.patch.object(controller, "ensure_storage_migrated"):
                        with mock.patch.object(
                            controller,
                            "stop_antigravity_app",
                            side_effect=stop_app,
                        ):
                            with mock.patch.object(
                                controller,
                                "absorb_runtime_keyring",
                                side_effect=absorb_runtime,
                            ):
                                with mock.patch.object(
                                    controller,
                                    "read_keyring_credential",
                                    return_value={
                                        "access_token": "old-access",
                                        "refresh_token": "old-refresh",
                                    },
                                ):
                                    with mock.patch.object(
                                        controller,
                                        "start_antigravity_app",
                                        side_effect=start_app,
                                    ):
                                        with mock.patch.object(
                                            controller,
                                            "sync_account_to_keyring",
                                            side_effect=sync_account,
                                        ):
                                            with mock.patch.object(
                                                controller, "wait_for_antigravity_auth",
                                                side_effect=wait_for_auth,
                                            ):
                                                with mock.patch.object(
                                                    controller,
                                                    "trigger_collector_update",
                                                ):
                                                    with redirect_stdout(output):
                                                        exit_code = controller.switch_account(
                                                            "new-account"
                                                        )

            stored = json.loads(index_path.read_text(encoding="utf-8"))

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(stored["current_account_id"], "new-account")
        self.assertEqual(
            events,
            [
                ("stop", "old-account"),
                ("absorb", "old-account"),
                ("sync", "new-account", "old-account", False, True, False),
                ("start", "old-account"),
                ("validate", "new@example.com", "old-account"),
                ("absorb", "new-account"),
            ],
        )
        self.assertTrue(result["keyring_synced"])
        self.assertTrue(result["app_restarted"])
        self.assertTrue(result["frontend_verified"])
        self.assertTrue(result["app_was_running"])
        self.assertTrue(result["runtime_credential_absorbed"])

    def test_switch_does_not_commit_and_restores_app_when_sync_fails(self):
        output = StringIO()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = root / "accounts.json"
            accounts_dir = root / "accounts"
            accounts_dir.mkdir()
            self.write_index(index_path)

            with mock.patch.object(controller, "ACCOUNTS_INDEX", index_path):
                with mock.patch.object(controller, "ACCOUNTS_DIR", accounts_dir):
                    with mock.patch.object(controller, "ensure_storage_migrated"):
                        with mock.patch.object(
                            controller, "stop_antigravity_app", return_value=True
                        ):
                            with mock.patch.object(
                                controller,
                                "absorb_runtime_keyring",
                                return_value=False,
                            ):
                                with mock.patch.object(
                                    controller,
                                    "read_keyring_credential",
                                    return_value={
                                        "access_token": "old-access",
                                        "refresh_token": "old-refresh",
                                    },
                                ):
                                    with mock.patch.object(
                                        controller,
                                        "write_keyring_credential",
                                    ) as restore_keyring:
                                        with mock.patch.object(
                                            controller,
                                            "sync_account_to_keyring",
                                            return_value=(
                                                {
                                                    "status": "keyring_write_failed",
                                                    "message": "keyring unavailable",
                                                },
                                                1,
                                            ),
                                        ):
                                            with mock.patch.object(
                                                controller,
                                                "start_antigravity_app",
                                                return_value=True,
                                            ) as start:
                                                with redirect_stdout(output):
                                                    exit_code = controller.switch_account(
                                                        "new-account"
                                                    )

            stored = json.loads(index_path.read_text(encoding="utf-8"))

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 1)
        self.assertFalse(result["success"])
        self.assertEqual(stored["current_account_id"], "old-account")
        self.assertTrue(result["app_restored"])
        start.assert_called_once_with()
        restore_keyring.assert_called_once()

    def test_switch_rolls_back_when_native_app_rejects_account(self):
        output = StringIO()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = root / "accounts.json"
            accounts_dir = root / "accounts"
            accounts_dir.mkdir()
            self.write_index(index_path)

            previous_credential = {
                "access_token": "old-access",
                "refresh_token": "old-refresh",
            }
            with mock.patch.object(controller, "ACCOUNTS_INDEX", index_path):
                with mock.patch.object(controller, "ACCOUNTS_DIR", accounts_dir):
                    with mock.patch.object(controller, "ensure_storage_migrated"):
                        with mock.patch.object(
                            controller,
                            "stop_antigravity_app",
                            side_effect=[True, True],
                        ):
                            with mock.patch.object(
                                controller,
                                "read_keyring_credential",
                                return_value=previous_credential,
                            ):
                                with mock.patch.object(
                                    controller,
                                    "absorb_runtime_keyring",
                                    return_value=True,
                                ):
                                    with mock.patch.object(
                                        controller,
                                        "sync_account_to_keyring",
                                        return_value=(
                                            {"status": "ready", "ready": True},
                                            0,
                                        ),
                                    ):
                                        with mock.patch.object(
                                            controller,
                                            "start_antigravity_app",
                                            return_value=True,
                                        ):
                                            with mock.patch.object(
                                                controller,
                                                "wait_for_antigravity_auth",
                                                return_value={
                                                    "ready": False,
                                                    "status": "account_ineligible",
                                                    "message": "not eligible",
                                                },
                                            ):
                                                with mock.patch.object(
                                                    controller,
                                                    "write_keyring_credential",
                                                ) as restore_keyring:
                                                    with redirect_stdout(output):
                                                        exit_code = controller.switch_account(
                                                            "new-account"
                                                        )

            stored = json.loads(index_path.read_text(encoding="utf-8"))

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["status"], "account_ineligible")
        self.assertEqual(stored["current_account_id"], "old-account")
        self.assertTrue(result["auth_restored"])
        self.assertTrue(result["app_restored"])
        restore_keyring.assert_called_once_with(previous_credential)

    def test_reauthorization_does_not_overwrite_fresh_target_credential(self):
        output = StringIO()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = root / "accounts.json"
            accounts_dir = root / "accounts"
            accounts_dir.mkdir()
            self.write_index(index_path)

            with mock.patch.object(controller, "ACCOUNTS_INDEX", index_path):
                with mock.patch.object(controller, "ACCOUNTS_DIR", accounts_dir):
                    with mock.patch.object(controller, "ensure_storage_migrated"):
                        with mock.patch.object(
                            controller,
                            "stop_antigravity_app",
                            return_value=True,
                        ):
                            with mock.patch.object(
                                controller,
                                "read_keyring_credential",
                                return_value={
                                    "access_token": "stale-access",
                                    "refresh_token": "stale-refresh",
                                },
                            ):
                                with mock.patch.object(
                                    controller,
                                    "absorb_runtime_keyring",
                                    return_value=True,
                                ) as absorb:
                                    with mock.patch.object(
                                        controller,
                                        "sync_account_to_keyring",
                                        return_value=(
                                            {"status": "ready", "ready": True},
                                            0,
                                        ),
                                    ):
                                        with mock.patch.object(
                                            controller,
                                            "start_antigravity_app",
                                            return_value=True,
                                        ):
                                            with mock.patch.object(
                                                controller,
                                                "wait_for_antigravity_auth",
                                                return_value={
                                                    "ready": True,
                                                    "status": "ready",
                                                    "email": "old@example.com",
                                                },
                                            ):
                                                with mock.patch.object(
                                                    controller,
                                                    "trigger_collector_update",
                                                ):
                                                    with redirect_stdout(output):
                                                        exit_code = controller.switch_account(
                                                            "old-account"
                                                        )

        self.assertEqual(exit_code, 0)
        # Only the post-validation capture runs. The stale pre-switch keyring
        # credential is never merged into a freshly reauthorized same account.
        absorb.assert_called_once_with({
            "id": "old-account",
            "email": "old@example.com",
            "last_used": mock.ANY,
        })


class AntigravityProcessTests(unittest.TestCase):
    def test_main_process_detection_excludes_helpers_and_omarvoice(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc_root = root / "proc"
            app = root / "antigravity"
            language_server = root / "language_server"
            app.write_text("", encoding="utf-8")
            language_server.write_text("", encoding="utf-8")

            processes = {
                "101": (app, b"/opt/Antigravity/antigravity\0"),
                "102": (
                    app,
                    b"/opt/Antigravity/antigravity\0--type=renderer\0",
                ),
                "103": (
                    language_server,
                    b"/opt/Antigravity/resources/bin/language_server\0",
                ),
            }
            for pid, (executable, cmdline) in processes.items():
                process_dir = proc_root / pid
                process_dir.mkdir(parents=True)
                (process_dir / "exe").symlink_to(executable)
                (process_dir / "cmdline").write_bytes(cmdline)

            detected = controller.antigravity_main_pids(proc_root, app)

        self.assertEqual(detected, [101])

    def test_language_server_detection_excludes_omarvoice(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc_root = root / "proc"
            app = root / "antigravity"
            language_server = root / "language_server"
            app.write_text("", encoding="utf-8")
            language_server.write_text("", encoding="utf-8")

            processes = {
                "101": (
                    app,
                    b"/opt/Antigravity/antigravity\0",
                    "PPid:\t1\n",
                ),
                "102": (
                    language_server,
                    (
                        b"/opt/Antigravity/resources/bin/language_server\0"
                        b"--app_data_dir\0antigravity\0"
                    ),
                    "PPid:\t101\n",
                ),
                "103": (
                    language_server,
                    (
                        b"/opt/Antigravity/resources/bin/language_server\0"
                        b"--app_data_dir\0omarvoice\0"
                    ),
                    "PPid:\t101\n",
                ),
                "104": (
                    language_server,
                    (
                        b"/opt/Antigravity/resources/bin/language_server\0"
                        b"--app_data_dir\0antigravity\0"
                    ),
                    "PPid:\t1\n",
                ),
            }
            for pid, (executable, cmdline, status) in processes.items():
                process_dir = proc_root / pid
                process_dir.mkdir(parents=True)
                (process_dir / "exe").symlink_to(executable)
                (process_dir / "cmdline").write_bytes(cmdline)
                (process_dir / "status").write_text(status, encoding="utf-8")

            with mock.patch.object(controller, "ANTIGRAVITY_APP", app):
                detected = controller.antigravity_language_server_pids(
                    proc_root,
                    language_server,
                )

        self.assertEqual(detected, [102])

    def test_restart_terminates_main_process_then_launches_detached(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "antigravity"
            app.write_text("", encoding="utf-8")
            with mock.patch.object(controller, "ANTIGRAVITY_APP", app):
                with mock.patch.object(
                    controller,
                    "antigravity_main_pids",
                    side_effect=[[44], [], [55]],
                ):
                    with mock.patch.object(controller.os, "kill") as kill:
                        with mock.patch.object(
                            controller.subprocess,
                            "Popen",
                        ) as popen:
                            result = controller.restart_antigravity_app()

        kill.assert_called_once_with(44, controller.signal.SIGTERM)
        self.assertEqual(popen.call_args.args[0], [str(app)])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertTrue(result["was_running"])
        self.assertTrue(result["started"])


if __name__ == "__main__":
    unittest.main()
