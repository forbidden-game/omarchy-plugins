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

    def test_token_near_expiry_requires_refresh(self):
        credential = {
            "access_token": "expiring",
            "expired": "2000-01-01T00:00:00+00:00",
        }

        self.assertTrue(controller.credential_needs_refresh(credential))


if __name__ == "__main__":
    unittest.main()
