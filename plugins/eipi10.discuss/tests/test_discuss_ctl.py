from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
CONTROL = PLUGIN_ROOT / "bin" / "discuss-ctl"


def load_control_module():
    loader = importlib.machinery.SourceFileLoader("discuss_ctl", str(CONTROL))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


ctl = load_control_module()


class DiscussControlTests(unittest.TestCase):
    def test_markdown_keeps_selection_and_empty_final_discussion_paired(self):
        rendered = ctl.format_markdown(
            [
                {
                    "text": "第一行\n第二行",
                    "discussion": "这是我的判断。",
                    "sourceClass": "firefox",
                    "sourceTitle": "文章",
                },
                {
                    "text": "最后一个选区",
                    "discussion": "",
                    "sourceClass": "kitty",
                    "sourceTitle": "",
                },
            ]
        )

        self.assertIn("> **引用 01 · firefox · 文章**", rendered)
        self.assertIn("> 第一行\n> 第二行", rendered)
        self.assertIn("**我的讨论：**\n这是我的判断。", rendered)
        self.assertIn("> **引用 02 · kitty**", rendered)
        self.assertTrue(rendered.endswith("**我的讨论：**\n"))

    def test_markdown_sanitizes_source_metadata_without_touching_discussion(self):
        rendered = ctl.format_markdown(
            [
                {
                    "text": "选区",
                    "discussion": "**保留我的 Markdown**",
                    "sourceClass": "odd*app",
                    "sourceTitle": "line one\nline_two",
                }
            ]
        )

        self.assertIn("odd\\*app · line one line\\_two", rendered)
        self.assertIn("**我的讨论：**\n**保留我的 Markdown**", rendered)

    def test_record_truncates_extreme_selection(self):
        with mock.patch.object(ctl, "MAX_SELECTION_CHARS", 5):
            record = ctl.capture_record("123456", {"class": "app", "title": "title"})

        self.assertEqual(record["text"], "12345")
        self.assertTrue(record["truncated"])

    def test_consume_rejects_path_outside_private_inbox(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            env = {"XDG_STATE_HOME": str(Path(temporary_home) / "state")}
            with mock.patch.dict(os.environ, env, clear=False):
                ctl.ensure_state_dirs()
                outside = Path(temporary_home) / "outside.json"
                outside.write_text("{}", encoding="utf-8")
                with self.assertRaises(ctl.DiscussError):
                    ctl.consume_record(str(outside))

    def test_consume_is_one_shot(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            env = {"XDG_STATE_HOME": str(Path(temporary_home) / "state")}
            with mock.patch.dict(os.environ, env, clear=False):
                record = ctl.capture_record("选区", {"class": "app", "title": "页面"})
                path = ctl.write_inbox_record(record)
                consumed = ctl.consume_record(str(path))

        self.assertEqual(consumed["text"], "选区")
        self.assertFalse(path.exists())

    def test_missing_inbox_record_returns_a_discuss_error(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            env = {"XDG_STATE_HOME": str(Path(temporary_home) / "state")}
            with mock.patch.dict(os.environ, env, clear=False):
                ctl.ensure_state_dirs()
                with self.assertRaisesRegex(ctl.DiscussError, "不存在"):
                    ctl.consume_record(str(ctl.inbox_root() / "missing.json"))

    def test_format_command_reads_only_discuss_state_root(self):
        with tempfile.TemporaryDirectory() as temporary_home:
            state_home = Path(temporary_home) / "state"
            discuss_root = state_home / "omarchy" / "discuss"
            discuss_root.mkdir(parents=True)
            draft = discuss_root / "draft.json"
            draft.write_text(
                json.dumps({"entries": [{"text": "A", "discussion": "B"}]}),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [str(CONTROL), "format", str(draft)],
                env={**os.environ, "XDG_STATE_HOME": str(state_home)},
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertIn("> A", completed.stdout)
        self.assertIn("**我的讨论：**\nB", completed.stdout)

    def test_clipboard_write_uses_plain_text_utf8(self):
        with mock.patch.object(ctl.subprocess, "run") as run:
            ctl.copy_to_clipboard("选区 → 讨论\n")

        run.assert_called_once_with(
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
            input="选区 → 讨论\n".encode("utf-8"),
            check=True,
            timeout=5.0,
        )

    def test_copy_stdin_consumes_one_line_memory_snapshot(self):
        snapshot = json.dumps(
            {
                "schemaVersion": 1,
                "entries": [
                    {
                        "text": "选区来自内存",
                        "discussion": "不再等待草稿保存事件",
                        "sourceClass": "app",
                    }
                ],
            },
            ensure_ascii=False,
        )
        output = io.StringIO()

        with (
            mock.patch.object(ctl.sys, "stdin", io.StringIO(snapshot + "\n")),
            mock.patch.object(ctl.sys, "stdout", output),
            mock.patch.object(ctl, "copy_to_clipboard") as copy,
        ):
            exit_code = ctl.command_copy_stdin(mock.Mock())

        self.assertEqual(exit_code, 0)
        copied_text = copy.call_args.args[0]
        self.assertIn("> 选区来自内存", copied_text)
        self.assertIn("**我的讨论：**\n不再等待草稿保存事件", copied_text)
        self.assertEqual(json.loads(output.getvalue()), {"ok": True, "count": 1})

    def test_copy_stdin_rejects_missing_snapshot(self):
        with mock.patch.object(ctl.sys, "stdin", io.StringIO("")):
            with self.assertRaisesRegex(ctl.DiscussError, "没有收到"):
                ctl.command_copy_stdin(mock.Mock())

    def test_copy_stdin_cli_streams_snapshot_without_touching_draft(self):
        with tempfile.TemporaryDirectory() as temporary_dir:
            temporary = Path(temporary_dir)
            clipboard_capture = temporary / "clipboard.txt"
            fake_wl_copy = temporary / "wl-copy"
            fake_wl_copy.write_text(
                '#!/bin/sh\ncat > "$DISCUSS_CAPTURE_PATH"\n',
                encoding="utf-8",
            )
            fake_wl_copy.chmod(0o755)
            snapshot = json.dumps(
                {
                    "schemaVersion": 1,
                    "entries": [{"text": "snapshot", "discussion": "direct"}],
                }
            )

            completed = subprocess.run(
                [str(CONTROL), "copy-stdin"],
                input=snapshot + "\n",
                env={
                    **os.environ,
                    "PATH": str(temporary) + os.pathsep + os.environ["PATH"],
                    "DISCUSS_CAPTURE_PATH": str(clipboard_capture),
                },
                check=True,
                capture_output=True,
                text=True,
            )

            copied = clipboard_capture.read_text(encoding="utf-8")

        self.assertEqual(json.loads(completed.stdout), {"ok": True, "count": 1})
        self.assertIn("> snapshot", copied)
        self.assertIn("**我的讨论：**\ndirect", copied)


if __name__ == "__main__":
    unittest.main()
