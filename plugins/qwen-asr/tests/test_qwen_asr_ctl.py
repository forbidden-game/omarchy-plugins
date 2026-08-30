"""Tests for Omarvoice shortcut configuration."""

from importlib.machinery import SourceFileLoader
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


PLUGIN_DIR = Path(__file__).resolve().parents[1]
LOADER = SourceFileLoader("qwen_asr_ctl", str(PLUGIN_DIR / "bin/qwen-asr-ctl"))
ctl = types.ModuleType(LOADER.name)
LOADER.exec_module(ctl)


class ShortcutTests(unittest.TestCase):
    def test_set_shortcut_collapses_legacy_duplicate_pairs(self):
        duplicate_bindings = """\
-- User bindings
-- Omarvoice push-to-talk (hold to record, release to transcribe).
o.bind("F9", "Start recording (Omarvoice push-to-talk)", "omarchy-shell qwen-asr start")
o.bind("F9", "Stop recording (Omarvoice push-to-talk)", "omarchy-shell qwen-asr stop", { release = true })
-- Copilot key explanation must survive.
o.bind("F9", "Start recording (Qwen ASR push-to-talk)", "omarchy-shell qwen-asr start")
o.bind("F9", "Stop recording (Qwen ASR push-to-talk)", "omarchy-shell qwen-asr stop", { release = true })
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindings_file = root / "bindings.lua"
            config_dir = root / "settings"
            config_file = config_dir / "qwen-asr-qt.conf"
            bindings_file.write_text(duplicate_bindings, encoding="utf-8")

            with mock.patch.object(ctl, "BINDINGS_FILE", str(bindings_file)):
                with mock.patch.object(ctl, "CONF_DIR", str(config_dir)):
                    with mock.patch.object(ctl, "CONF_FILE", str(config_file)):
                        with mock.patch.object(ctl.subprocess, "run") as reload_run:
                            first = ctl.set_shortcut("SUPER + SHIFT + F9")
                            second = ctl.set_shortcut("SUPER + SHIFT + F9")

            content = bindings_file.read_text(encoding="utf-8")

        self.assertEqual(first, (True, "SUPER + SHIFT + F9"))
        self.assertEqual(second, first)
        self.assertEqual(content.count("omarchy-shell qwen-asr start"), 1)
        self.assertEqual(content.count("omarchy-shell qwen-asr stop"), 1)
        self.assertIn("-- Copilot key explanation must survive.", content)
        self.assertEqual(reload_run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
