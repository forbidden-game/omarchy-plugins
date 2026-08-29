import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "bin" / "omarchy-touchpad-ctl"
MODULE = runpy.run_path(str(SCRIPT))


class SettingsTests(unittest.TestCase):
    def test_sanitize_clamps_values_and_dependencies(self):
        sanitized = MODULE["sanitize_settings"](
            {
                "disableWhileTyping": "yes",
                "naturalScroll": True,
                "scrollFactor": 9,
                "clickfingerBehavior": False,
                "tapToClick": False,
                "tapAndDrag": True,
                "dragLock": 2,
                "sensitivity": -9,
            }
        )

        self.assertEqual(2.0, sanitized["scrollFactor"])
        self.assertEqual(-1.0, sanitized["sensitivity"])
        self.assertFalse(sanitized["tapAndDrag"])
        self.assertEqual(0, sanitized["dragLock"])

    def test_presets_are_valid_settings(self):
        for values in MODULE["PRESETS"].values():
            self.assertEqual(values, MODULE["sanitize_settings"](values))


class ManagedBlockTests(unittest.TestCase):
    def setUp(self):
        self.devices = [{"name": 'touchpad-"quoted"', "displayName": "Touchpad"}]
        self.values = MODULE["PRESETS"]["balanced"]

    def test_replace_preserves_user_content_and_is_idempotent(self):
        original = "-- user setting\nhl.config({ input = { sensitivity = 0.2 } })\n"
        block = MODULE["managed_block"](self.values, self.devices)
        first = MODULE["replace_managed_block"](original, block)
        second = MODULE["replace_managed_block"](first, block)

        self.assertEqual(first, second)
        self.assertIn("-- user setting", first)
        self.assertEqual(1, first.count(MODULE["MANAGED_START"]))
        self.assertIn(r'touchpad-\"quoted\"', first)

    def test_malformed_block_is_rejected(self):
        with self.assertRaises(MODULE["TouchpadError"]):
            MODULE["replace_managed_block"](MODULE["MANAGED_START"], "replacement")

    def test_remove_deletes_only_the_managed_block(self):
        before = "-- before\n"
        after = "-- after\n"
        block = MODULE["managed_block"](self.values, self.devices)
        content = before + block + after

        result = MODULE["replace_managed_block"](content, None)

        self.assertEqual("-- before\n-- after\n", result)


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.devices = [
            {
                "name": "test-touchpad",
                "displayName": "Test Touchpad",
                "sensitivity": 0.0,
            }
        ]

    def globals_patch(self, run_hypr):
        return mock.patch.dict(
            MODULE["persist"].__globals__,
            {
                "list_touchpads": lambda: self.devices,
                "run_hypr": run_hypr,
            },
        )

    def test_persist_keeps_backup_and_single_block(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "input.lua"
            original = "-- personal input\n"
            config.write_text(original, encoding="utf-8")
            environment = {"OMARCHY_TOUCHPAD_INPUT_FILE": str(config)}

            with mock.patch.dict(os.environ, environment, clear=False):
                with self.globals_patch(lambda *args: ""):
                    MODULE["persist"](MODULE["PRESETS"]["balanced"])
                    MODULE["persist"](MODULE["PRESETS"]["gesture"])

            updated = config.read_text(encoding="utf-8")
            backup = config.with_name("input.lua.eipi10-touchpad.bak")
            self.assertEqual(1, updated.count(MODULE["MANAGED_START"]))
            self.assertIn("natural_scroll = true", updated)
            self.assertEqual(original, backup.read_text(encoding="utf-8"))

    def test_config_error_restores_original_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "input.lua"
            original = "-- valid user config\n"
            config.write_text(original, encoding="utf-8")

            def fake_hypr(*args):
                return "bad option" if args[0] == "configerrors" else ""

            environment = {"OMARCHY_TOUCHPAD_INPUT_FILE": str(config)}
            with mock.patch.dict(os.environ, environment, clear=False):
                with self.globals_patch(fake_hypr):
                    with self.assertRaises(MODULE["TouchpadError"]):
                        MODULE["persist"](MODULE["PRESETS"]["balanced"])

            self.assertEqual(original, config.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
