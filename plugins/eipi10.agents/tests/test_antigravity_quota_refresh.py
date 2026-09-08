"""Quota failures must not create recursive or concurrent refresh chains."""

from contextlib import ExitStack, redirect_stdout
import fcntl
from importlib.machinery import SourceFileLoader
from io import StringIO
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


BIN = Path(__file__).resolve().parents[1] / "bin"


def load_helper(name, filename):
    loader = SourceFileLoader(name, str(BIN / filename))
    module = types.ModuleType(name)
    module.__file__ = str(BIN / filename)
    loader.exec_module(module)
    return module


ctl = load_helper("quota_controller", "omarchy-antigravity-ctl")
collector = load_helper("quota_collector", "omarchy-agent-usage-antigravity")


class QuotaRefreshTests(unittest.TestCase):
    def setUp(self):
        stack = self.enterContext(ExitStack())
        self.directory = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        self.accounts = self.directory / "accounts"
        self.accounts.mkdir()
        index = self.directory / "accounts.json"
        index.write_text(json.dumps({"current_account_id": "a", "accounts": [{"id": "a"}]}))
        self.account = self.accounts / "a.json"
        self.account.write_text(json.dumps({"id": "a", "quota": {"last_updated": 1}}))
        for module in (ctl, collector):
            for name, value in {
                "ANTIGRAVITY_DIR": self.directory,
                "ACCOUNTS_DIR": self.accounts,
                "ACCOUNTS_INDEX": index,
            }.items():
                stack.enter_context(mock.patch.object(module, name, value))
        stack.enter_context(mock.patch.object(ctl, "ensure_storage_migrated"))
        stack.enter_context(mock.patch.object(collector, "ensure_antigravity_storage"))
        self.now = stack.enter_context(mock.patch.object(ctl.time, "time", return_value=1000))
        self.fetch = stack.enter_context(mock.patch.object(ctl, "fetch_account_quotas", return_value=False))

    def state(self):
        return json.loads((self.directory / "quota-refresh-state.json").read_text())

    def test_failure_cooldown_survives_calls_and_manual_force(self):
        self.assertFalse(ctl.refresh_all_accounts())
        self.assertEqual(self.state()["a"]["retry_after"], 1060)
        ctl.refresh_all_accounts(force=True)
        self.assertEqual(self.fetch.call_count, 1)
        self.now.return_value = 1060
        ctl.refresh_all_accounts()
        self.assertEqual(self.fetch.call_count, 2)
        self.assertEqual(self.state()["a"]["retry_after"], 1180)
        for _ in range(6):
            self.now.return_value = self.state()["a"]["retry_after"]
            ctl.refresh_all_accounts()
        self.assertEqual(self.state()["a"]["retry_after"] - self.now.return_value, 900)

    def test_interrupted_request_keeps_cooldown_and_releases_lock(self):
        self.fetch.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            ctl.refresh_all_accounts()
        self.assertEqual(self.state()["a"]["retry_after"], 1300)
        self.fetch.side_effect = None
        ctl.refresh_all_accounts()
        self.assertEqual(self.fetch.call_count, 1)
        self.now.return_value = 1300
        ctl.refresh_all_accounts()
        self.assertEqual(self.fetch.call_count, 2)

    def test_another_lock_holder_prevents_network_requests(self):
        with (self.directory / "quota-refresh.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertFalse(ctl.refresh_all_accounts(force=True))
        self.fetch.assert_not_called()
        ctl.refresh_all_accounts()
        self.fetch.assert_called_once()

    def test_success_clears_failures_and_fresh_cache_skips_network(self):
        def succeed(data, path):
            data["quota"]["last_updated"] = 1000
            path.write_text(json.dumps(data))
            return True
        self.fetch.side_effect = succeed
        self.assertTrue(ctl.refresh_all_accounts())
        self.assertEqual(self.state(), {})
        ctl.refresh_all_accounts()
        self.fetch.assert_called_once()

    def test_collector_refresh_never_schedules_another_collector(self):
        def run_controller(command, **kwargs):
            with mock.patch.object(ctl.sys, "argv", command), redirect_stdout(StringIO()):
                ctl.main()
        with mock.patch.object(collector.subprocess, "run", side_effect=run_controller):
            with mock.patch.object(ctl, "trigger_collector_update") as publish:
                collector.refresh_accounts_if_needed("a", False)
        self.fetch.assert_called_once()
        publish.assert_not_called()

    def test_cached_publication_does_not_refresh_stale_accounts(self):
        with mock.patch.object(collector, "refresh_accounts_if_needed") as refresh:
            state = collector.load_antigravity_accounts(cached_only=True)
        self.assertEqual(state["currentAccountId"], "a")
        refresh.assert_not_called()

    def test_publication_explicitly_requests_cached_data(self):
        with mock.patch.object(ctl, "HOME", self.directory):
            update = self.directory / ".config/omarchy/plugins/eipi10.agents/bin/omarchy-agent-usage-update"
            update.parent.mkdir(parents=True)
            update.touch()
            with mock.patch.object(ctl.subprocess, "Popen") as spawn:
                ctl.trigger_collector_update()
        self.assertEqual(spawn.call_args.args[0], [str(update), "antigravity", "--cached-only"])


if __name__ == "__main__":
    unittest.main()
