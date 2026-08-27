"""Security-focused tests for the Agent Panel → Omarvoice auth handoff."""

from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from io import StringIO
import json
from pathlib import Path
import types
import unittest
from unittest import mock


CONTROLLER_PATH = (
    Path(__file__).resolve().parents[1] / "bin/omarchy-antigravity-ctl"
)
loader = SourceFileLoader("omarchy_antigravity_ctl", str(CONTROLLER_PATH))
controller = types.ModuleType(loader.name)
loader.exec_module(controller)


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


if __name__ == "__main__":
    unittest.main()
