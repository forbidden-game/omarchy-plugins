"""Unit tests for the Omarvoice Antigravity protocol boundary."""

from io import BytesIO
import http.client
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock
import wave


PLUGIN_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN_DIR / "lib"))

import omarvoice_antigravity as bridge


def framed(flags: int, payload: bytes) -> bytes:
    return bytes([flags]) + struct.pack(">I", len(payload)) + payload


class GrpcWebFrameTests(unittest.TestCase):
    def test_json_frame_round_trip(self):
        payload = {"sessionId": "session-1", "sequenceNumber": 3}

        kind, decoded = bridge.read_frame(BytesIO(bridge.encode_frame(payload)))

        self.assertEqual(kind, "message")
        self.assertEqual(decoded, payload)

    def test_trailer_frame_decodes_status(self):
        stream = BytesIO(framed(0x80, b"grpc-status: 0\r\ngrpc-message: \r\n"))

        kind, decoded = bridge.read_frame(stream)

        self.assertEqual(kind, "trailers")
        self.assertEqual(decoded["grpc-status"], "0")

    def test_scope_failure_has_actionable_error(self):
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.grpc_message({
                "grpc-status": "13",
                "grpc-message": "PermissionDenied: insufficient authentication scopes",
            })

        self.assertEqual(raised.exception.code, "reauthorize_required")
        self.assertNotIn("PermissionDenied", raised.exception.message)

    def test_truncated_frame_is_rejected(self):
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.read_frame(BytesIO(b"\x00\x00"))

        self.assertEqual(raised.exception.code, "protocol_error")

    def test_local_transport_failure_has_retryable_error_code(self):
        client = bridge.GrpcWebJsonClient(12345, "csrf")
        connection = mock.Mock()
        connection.request.side_effect = http.client.RemoteDisconnected(
            "connection closed"
        )
        with mock.patch.object(client, "connection", return_value=connection):
            with self.assertRaises(bridge.BridgeError) as raised:
                client.request(bridge.START_PATH, {})

        self.assertEqual(raised.exception.code, "engine_connection_error")
        connection.close.assert_called_once()


class TranscriptTests(unittest.TestCase):
    def test_final_transcript_is_extracted(self):
        result = bridge.transcription_text({
            "transcription": {"text": "你好 Omarvoice", "isFinal": True}
        })

        self.assertEqual(result, ("你好 Omarvoice", True))

    def test_unrelated_message_is_ignored(self):
        self.assertIsNone(bridge.transcription_text({"ready": {"sessionId": "s"}}))

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is not installed")
    def test_wav_is_converted_to_16khz_mono_pcm(self):
        with tempfile.TemporaryDirectory() as directory:
            wav_path = Path(directory) / "input.wav"
            with wave.open(str(wav_path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                output.writeframes(b"\x00\x00" * 1_600)

            chunks = list(bridge.pcm_chunks(wav_path))

        self.assertEqual(sum(map(len, chunks)), 3_200)
        self.assertTrue(all(len(chunk) <= bridge.PCM_CHUNK_BYTES for chunk in chunks))

    def test_transcribe_runs_start_chunk_end_protocol(self):
        stream = BytesIO(
            bridge.encode_frame({"ready": {"sessionId": "session-1"}})
            + bridge.encode_frame({
                "transcription": {"text": "最终文本", "isFinal": True}
            })
            + bridge.encode_frame({"complete": {}})
        )

        class FakeConnection:
            def close(self):
                pass

        class FakeServer:
            https_port = 12345
            csrf_token = "csrf"

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                pass

        class FakeClient:
            def __init__(self):
                self.calls = []

            def request(self, path, payload):
                self.calls.append((path, payload))
                return FakeConnection(), stream

            def unary(self, path, payload):
                self.calls.append((path, payload))
                return {}

        fake_client = FakeClient()
        with tempfile.TemporaryDirectory() as directory:
            wav_path = Path(directory) / "voice.wav"
            wav_path.touch()
            with mock.patch.object(bridge, "run_agent_controller"):
                with mock.patch.object(bridge, "LanguageServer", return_value=FakeServer()):
                    with mock.patch.object(
                        bridge, "GrpcWebJsonClient", return_value=fake_client
                    ):
                        with mock.patch.object(
                            bridge, "pcm_chunks", return_value=iter([b"aa", b"bb"])
                        ):
                            with mock.patch.object(
                                bridge.shutil, "which", return_value="/usr/bin/ffmpeg"
                            ):
                                result = bridge.transcribe(wav_path)

        self.assertEqual(result["text"], "最终文本")
        self.assertEqual(result["audio_bytes"], 4)
        self.assertEqual(
            [call[0] for call in fake_client.calls],
            [bridge.START_PATH, bridge.CHUNK_PATH, bridge.CHUNK_PATH, bridge.END_PATH],
        )
        self.assertEqual(fake_client.calls[1][1]["sequenceNumber"], 0)
        self.assertEqual(fake_client.calls[2][1]["sequenceNumber"], 1)
        self.assertEqual(
            fake_client.calls[0][1]["preCursorText"],
            bridge.DEFAULT_RECOGNITION_PROFILE,
        )


class RecognitionContextTests(unittest.TestCase):
    def test_default_profile_covers_chinese_developer_dictation(self):
        payload = bridge.build_transcription_start_payload()
        context = payload["preCursorText"]

        self.assertIn("中国大陆中文语境", context)
        self.assertIn("网络热词、人名、地名", context)
        self.assertIn("用户是一名软件开发者", context)
        self.assertIn("英文术语应保留标准拼写、大小写和缩写", context)
        self.assertIn("不得改变原意", context)
        self.assertNotIn("postCursorText", payload)

    def test_nearby_text_is_appended_without_replacing_profile(self):
        payload = bridge.build_transcription_start_payload(
            "const serviceName = \"Omarvoice\";",
            "return transcript;",
        )

        self.assertTrue(
            payload["preCursorText"].startswith(
                bridge.DEFAULT_RECOGNITION_PROFILE
            )
        )
        self.assertIn(
            "当前光标前文本：\nconst serviceName = \"Omarvoice\";",
            payload["preCursorText"],
        )
        self.assertEqual(payload["postCursorText"], "return transcript;")


class LiveServiceTests(unittest.TestCase):
    def test_pcm_rms_distinguishes_silence_from_speech(self):
        silence = b"\x00\x00" * 100
        speech = struct.pack("<h", 5_000) * 100

        self.assertEqual(bridge.pcm_rms(silence), 0)
        self.assertGreater(bridge.pcm_rms(speech), bridge.SPEECH_RMS_THRESHOLD)

    def test_persistent_engine_reuses_one_language_server(self):
        class FakeProcess:
            def poll(self):
                return None

        class FakeServer:
            process = FakeProcess()
            https_port = 12345
            csrf_token = "csrf"

            def __enter__(self):
                return self

            def close(self):
                pass

        fake_client = mock.Mock()
        fake_client.close = mock.Mock()
        engine = bridge.PersistentEngine()
        with mock.patch.object(
            bridge,
            "run_agent_controller",
            return_value={"ready": True, "email": "voice@example.com"},
        ) as sync:
            with mock.patch.object(bridge, "LanguageServer", return_value=FakeServer()):
                with mock.patch.object(
                    bridge, "GrpcWebJsonClient", return_value=fake_client
                ):
                    first, first_timings = engine.ensure_ready()
                    second, second_timings = engine.ensure_ready()

        self.assertIs(first, second)
        self.assertEqual(sync.call_count, 1)
        self.assertFalse(first_timings["engine_reused"])
        self.assertTrue(second_timings["engine_reused"])

    def test_cancel_detaches_recording_before_background_cleanup(self):
        class FakeRecording:
            audio_bytes = 123
            wav_path = Path("/tmp/test.wav")

            def __init__(self):
                self.stop_requested = False

            def request_stop(self):
                self.stop_requested = True

            def stop(self):
                return {"status": "error", "code": "no_speech"}

        daemon = bridge.OmarvoiceDaemon()
        recording = FakeRecording()
        daemon.recording = recording

        result = daemon._cancel_recording()

        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(recording.stop_requested)
        self.assertIsNone(daemon.recording)

    def test_duration_limit_stops_capture_when_ui_never_releases(self):
        recording = bridge.LiveRecording(mock.Mock(), Path("/tmp/timeout.wav"))

        with mock.patch.object(bridge, "MAX_RECORDING_SECONDS", 0):
            with mock.patch.object(recording, "request_stop") as request_stop:
                recording._enforce_duration_limit()

        request_stop.assert_called_once_with()

    def test_new_recording_replaces_one_already_finalized(self):
        daemon = bridge.OmarvoiceDaemon()
        finished = mock.Mock()
        finished.done = mock.Mock()
        finished.done.is_set.return_value = True
        daemon.recording = finished
        replacement = mock.Mock()
        replacement.start.return_value = {
            "status": "recording",
            "ready": True,
        }

        with mock.patch.object(
            bridge, "LiveRecording", return_value=replacement
        ):
            result = daemon._start_recording({"wav_path": "/tmp/new.wav"})

        self.assertEqual(result["status"], "recording")
        self.assertIs(daemon.recording, replacement)

    def test_cloud_final_wins_when_local_rms_is_low(self):
        stream = BytesIO(
            bridge.encode_frame({"ready": {"sessionId": "session-1"}})
            + bridge.encode_frame({
                "transcription": {"text": "低音量也应识别", "isFinal": True}
            })
            + bridge.encode_frame({"complete": {}})
        )

        class FakeConnection:
            def close(self):
                pass

        class FakeClient:
            def request(self, _path, _payload):
                return FakeConnection(), stream

            def unary(self, _path, _payload):
                return {}

            def close(self):
                pass

        class FakeEngine:
            def __init__(self):
                self.client = FakeClient()

            def ensure_ready(self):
                return self.client, {
                    "engine_reused": True,
                    "auth_sync_ms": 0,
                    "engine_start_ms": 0,
                }

            def close(self):
                pass

        recording = bridge.LiveRecording(FakeEngine(), Path("/tmp/quiet.wav"))
        recording.started_at = time.monotonic()
        recording.release_at = recording.started_at
        recording.audio_bytes = bridge.PCM_BYTES_PER_SECOND
        recording.speech_bytes = 0
        recording.audio_queue.put(b"\x00\x00")
        recording.audio_queue.put(recording._END_OF_AUDIO)

        recording._stream_audio()

        self.assertEqual(recording.result["status"], "success")
        self.assertEqual(recording.result["detected_speech_ms"], 0)


class CommandTests(unittest.TestCase):
    def test_status_output_contains_no_credential_material(self):
        with mock.patch.object(bridge, "language_server_path"):
            with mock.patch.object(
                bridge,
                "run_agent_controller",
                return_value={
                    "ready": True,
                    "email": "voice@example.com",
                    "message": "ready",
                },
            ):
                result = bridge.status()

        serialized = json.dumps(result)
        self.assertTrue(result["ready"])
        self.assertNotIn("access_token", serialized)
        self.assertNotIn("refresh_token", serialized)

    def test_controller_failure_preserves_public_error(self):
        completed = mock.Mock(
            stdout=json.dumps({
                "status": "reauthorize_required",
                "ready": False,
                "message": "重新授权",
            }),
            returncode=2,
        )
        with mock.patch.object(
            bridge, "find_agent_controller", return_value=Path("/controller")
        ):
            with mock.patch.object(bridge.subprocess, "run", return_value=completed):
                with self.assertRaises(bridge.BridgeError) as raised:
                    bridge.run_agent_controller("voice-auth-status")

        self.assertEqual(raised.exception.code, "reauthorize_required")
        self.assertEqual(raised.exception.message, "重新授权")


if __name__ == "__main__":
    unittest.main()
