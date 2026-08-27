"""Antigravity cloud-dictation adapter for Omarvoice.

The adapter owns the local protocol boundary. It asks Agent Panel to refresh
and synchronize the active long-lived credential, starts Antigravity's
language server without its Electron UI, and speaks the same gRPC-Web JSON
audio protocol as Antigravity's dictation control.

OAuth material never crosses stdout, QML, command-line arguments, or
diagnostic logs.
"""

from __future__ import annotations

import argparse
from array import array
import base64
from collections.abc import Iterator
import fcntl
import http.client
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import signal
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, BinaryIO
import uuid
import wave


SERVICE_PREFIX = "/exa.language_server_pb.LanguageServerService"
START_PATH = f"{SERVICE_PREFIX}/StreamAudioTranscription"
CHUNK_PATH = f"{SERVICE_PREFIX}/SendAudioChunk"
END_PATH = f"{SERVICE_PREFIX}/EndAudioSession"
DEFAULT_LANGUAGE_SERVER = Path("/opt/Antigravity/resources/bin/language_server")
DEFAULT_TIMEOUT_SECONDS = 120
PCM_CHUNK_BYTES = 32_000  # One second of signed 16-bit, 16 kHz mono PCM.
LIVE_PCM_CHUNK_BYTES = 6_400  # 200 ms of signed 16-bit, 16 kHz mono PCM.
PCM_BYTES_PER_SECOND = 32_000
SPEECH_RMS_THRESHOLD = 1_843  # -25 dBFS, matching the former ffmpeg probe.
MIN_AUDIO_MS = 1_000
DAEMON_PROTOCOL_VERSION = 7
HTTPS_PORT_PATTERN = re.compile(r"listening on random port at (\d+) for HTTPS")


class BridgeError(RuntimeError):
    """An expected provider failure safe to show in the Omarvoice UI."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def encode_frame(payload: dict[str, Any]) -> bytes:
    """Encode one gRPC-Web JSON data frame."""
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return b"\x00" + struct.pack(">I", len(body)) + body


def read_exact(stream: BinaryIO, size: int) -> bytes:
    """Read exactly ``size`` bytes or raise a stable protocol error."""
    parts: list[bytes] = []
    remaining = size
    while remaining:
        part = stream.read(remaining)
        if not part:
            raise BridgeError("protocol_error", "Antigravity 听写连接提前结束")
        parts.append(part)
        remaining -= len(part)
    return b"".join(parts)


def decode_trailers(payload: bytes) -> dict[str, str]:
    """Decode the HTTP/1 trailer block carried by a gRPC-Web trailer frame."""
    trailers: dict[str, str] = {}
    for line in payload.decode("utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        trailers[key.strip().lower()] = value.strip()
    return trailers


def read_frame(stream: BinaryIO) -> tuple[str, Any]:
    """Read one data or trailer frame from a gRPC-Web response."""
    header = read_exact(stream, 5)
    flags = header[0]
    length = struct.unpack(">I", header[1:])[0]
    payload = read_exact(stream, length)
    if flags & 0x80:
        return "trailers", decode_trailers(payload)
    try:
        return "message", json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError("protocol_error", "Antigravity 返回了无法解析的听写数据") from exc


def grpc_message(trailers: dict[str, str]) -> str:
    """Map provider trailers to a concise message without backend identifiers."""
    status = trailers.get("grpc-status", "0")
    if status in ("", "0"):
        return ""
    raw = trailers.get("grpc-message", "")
    message = raw.replace("+", " ")
    try:
        from urllib.parse import unquote

        message = unquote(message)
    except Exception:
        pass
    lowered = message.lower()
    if "insufficient authentication scopes" in lowered or "permissiondenied" in lowered:
        raise BridgeError(
            "reauthorize_required",
            "Agent Panel 账号缺少 Omarvoice 听写权限，请重新授权一次",
        )
    if status == "16" or "unauthenticated" in lowered:
        raise BridgeError(
            "authorization_required",
            "Agent Panel 鉴权已失效，请重新授权 Antigravity 账号",
        )
    raise BridgeError("provider_error", "Antigravity 云端听写暂时不可用")


def find_agent_controller() -> Path:
    """Locate the one credential-owning Agent Panel controller."""
    override = os.environ.get("OMARVOICE_AGENT_CONTROLLER", "").strip()
    candidates = [
        Path(override) if override else None,
        Path.home()
        / ".config/omarchy/plugins/eipi10.agents/bin/omarchy-antigravity-ctl",
        Path(__file__).resolve().parents[2]
        / "eipi10.agents/bin/omarchy-antigravity-ctl",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise BridgeError(
        "agent_panel_missing",
        "未找到 Agent Panel 鉴权控制器，请先安装 eipi10.agents",
    )


def run_agent_controller(command: str) -> dict[str, Any]:
    """Run a non-secret Agent Panel command and parse its single JSON response."""
    controller = find_agent_controller()
    completed = subprocess.run(
        [str(controller), command],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    line = completed.stdout.strip().splitlines()
    try:
        result = json.loads(line[-1]) if line else {}
    except json.JSONDecodeError as exc:
        raise BridgeError("auth_error", "Agent Panel 返回了无法解析的鉴权状态") from exc
    if result.get("ready"):
        return result
    code = str(result.get("status") or "auth_error")
    message = str(result.get("message") or "Agent Panel 鉴权尚未就绪")
    raise BridgeError(code, message)


def language_server_path() -> Path:
    """Resolve the installed Antigravity protocol engine."""
    override = os.environ.get("OMARVOICE_ANTIGRAVITY_LANGUAGE_SERVER", "").strip()
    path = Path(override) if override else DEFAULT_LANGUAGE_SERVER
    if not path.is_file() or not os.access(path, os.X_OK):
        raise BridgeError(
            "antigravity_missing",
            "未找到 Antigravity 2.11+ 听写引擎",
        )
    return path


class LanguageServer:
    """A UI-free Antigravity language-server process."""

    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.csrf_token = secrets.token_urlsafe(32)
        self.https_port = 0
        temp_root = Path("/dev/shm") if Path("/dev/shm").is_dir() else None
        self.temp_dir = Path(
            tempfile.mkdtemp(prefix="omarvoice-antigravity-", dir=temp_root)
        )
        self.temp_dir.chmod(0o700)
        self._port_ready = threading.Event()
        self._drainer: threading.Thread | None = None

    def __enter__(self) -> "LanguageServer":
        binary = language_server_path()
        command = [
            str(binary),
            "--standalone",
            "--override_ide_name",
            "antigravity",
            "--subclient_type",
            "hub",
            "--override_ide_version",
            "2.11.0",
            "--override_user_agent_name",
            "antigravity",
            "--https_server_port",
            "0",
            "--csrf_token",
            self.csrf_token,
            "--gemini_dir",
            str(self.temp_dir),
            "--app_data_dir",
            "omarvoice",
            "--api_server_url",
            "https://generativelanguage.googleapis.com",
            "--cloud_code_endpoint",
            "https://daily-cloudcode-pa.googleapis.com",
        ]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stderr is not None
        self._drainer = threading.Thread(
            target=self._drain_stderr,
            name="omarvoice-antigravity-log-drain",
            daemon=True,
        )
        self._drainer.start()
        deadline = time.monotonic() + 15
        while not self._port_ready.wait(timeout=0.05):
            if self.process.poll() is not None or time.monotonic() >= deadline:
                break
        if not self.https_port:
            self.close()
            raise BridgeError(
                "engine_start_failed",
                "Antigravity 听写引擎启动失败",
            )
        return self

    def _drain_stderr(self) -> None:
        """Prevent provider logs from blocking without surfacing OAuth material."""
        if not self.process or not self.process.stderr:
            return
        for line in self.process.stderr:
            if self.https_port:
                continue
            match = HTTPS_PORT_PATTERN.search(line)
            if match:
                self.https_port = int(match.group(1))
                self._port_ready.set()

    def close(self) -> None:
        process = self.process
        self.process = None
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()


class GrpcWebJsonClient:
    """Minimal gRPC-Web JSON client scoped to one loopback language server."""

    def __init__(self, port: int, csrf_token: str):
        self.port = port
        self.csrf_token = csrf_token
        self.ssl_context = ssl.create_default_context()
        self.ssl_context.check_hostname = False
        self.ssl_context.verify_mode = ssl.CERT_NONE

    def connection(self, timeout: int = DEFAULT_TIMEOUT_SECONDS) -> http.client.HTTPSConnection:
        return http.client.HTTPSConnection(
            "127.0.0.1",
            self.port,
            timeout=timeout,
            context=self.ssl_context,
        )

    def request(self, path: str, payload: dict[str, Any]) -> tuple[
        http.client.HTTPSConnection, http.client.HTTPResponse
    ]:
        connection = self.connection()
        try:
            connection.request(
                "POST",
                path,
                body=encode_frame(payload),
                headers={
                    "Content-Type": "application/grpc-web+json",
                    "Accept": "application/grpc-web+json",
                    "x-codeium-csrf-token": self.csrf_token,
                    "x-grpc-web": "1",
                },
            )
            response = connection.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            connection.close()
            raise BridgeError(
                "engine_connection_error",
                "Antigravity 本地听写引擎连接中断",
            ) from exc
        if response.status != 200:
            connection.close()
            raise BridgeError(
                "engine_http_error",
                f"Antigravity 本地听写引擎返回 HTTP {response.status}",
            )
        return connection, response

    def unary(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        """Run one unary request; Antigravity does not expose an HTTP EOF marker."""
        connection, response = self.request(path, payload)
        result: dict[str, Any] = {}
        try:
            while True:
                kind, value = read_frame(response)
                if kind == "message":
                    result = value if isinstance(value, dict) else {}
                    continue
                grpc_message(value)
                return result
        finally:
            connection.close()

    def close(self) -> None:
        """Match the persistent engine lifecycle; unary sockets close per call."""

    def abort(self) -> None:
        """Match the persistent engine lifecycle; unary sockets close per call."""


def pcm_chunks(wav_path: Path) -> Iterator[bytes]:
    """Convert a recording to the exact 16 kHz mono PCM stream Antigravity uses."""
    process = subprocess.Popen(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(wav_path),
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-ac",
            "1",
            "-ar",
            "16000",
            "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    completed = False
    try:
        while True:
            chunk = process.stdout.read(PCM_CHUNK_BYTES)
            if not chunk:
                break
            yield chunk
        completed = True
    finally:
        process.stdout.close()
        if not completed and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    stderr = ""
    if process.stderr:
        stderr = process.stderr.read().decode("utf-8", errors="replace")
        process.stderr.close()
    try:
        return_code = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
        raise BridgeError("audio_conversion_failed", "录音转换进程未能正常结束")
    if return_code != 0:
        raise BridgeError(
            "audio_conversion_failed",
            "录音转换失败" + (f"：{stderr.strip()[:120]}" if stderr.strip() else ""),
        )


def transcription_text(response: dict[str, Any]) -> tuple[str, bool] | None:
    """Extract a partial/final transcript from one stream response."""
    transcription = response.get("transcription")
    if not isinstance(transcription, dict):
        return None
    text = str(transcription.get("text") or "")
    return text, bool(transcription.get("isFinal"))


def open_transcription_session(
    client: GrpcWebJsonClient,
    start_payload: dict[str, Any],
) -> tuple[
    http.client.HTTPSConnection,
    http.client.HTTPResponse,
    str,
    str,
    str,
]:
    """Open a streaming session and read through its ready message."""
    connection, response = client.request(START_PATH, start_payload)
    session_id = ""
    partial_text = ""
    final_text = ""
    try:
        while not session_id:
            kind, value = read_frame(response)
            if kind == "trailers":
                grpc_message(value)
                raise BridgeError(
                    "protocol_error", "听写会话未返回 session id"
                )
            ready = value.get("ready") if isinstance(value, dict) else None
            if isinstance(ready, dict):
                session_id = str(ready.get("sessionId") or "")
            transcript = (
                transcription_text(value) if isinstance(value, dict) else None
            )
            if transcript:
                partial_text = transcript[0]
                if transcript[1]:
                    final_text = transcript[0]
        return (
            connection,
            response,
            session_id,
            partial_text,
            final_text,
        )
    except Exception:
        connection.close()
        raise


def transcribe(
    wav_path: Path,
    pre_cursor_text: str = "",
    post_cursor_text: str = "",
) -> dict[str, Any]:
    """Synchronize auth, stream one recording, and return the final transcript."""
    if not wav_path.is_file():
        raise BridgeError("recording_missing", "找不到待转写的录音文件")
    if not shutil.which("ffmpeg"):
        raise BridgeError("ffmpeg_missing", "缺少 ffmpeg，无法转换录音")

    run_agent_controller("voice-auth-sync")
    started_at = time.monotonic()
    with LanguageServer() as server:
        client = GrpcWebJsonClient(server.https_port, server.csrf_token)
        start_payload: dict[str, Any] = {
            "mimeType": "audio/pcm;rate=16000",
            "cascadeId": str(uuid.uuid4()),
            "continuous": False,
        }
        if pre_cursor_text:
            start_payload["preCursorText"] = pre_cursor_text
        if post_cursor_text:
            start_payload["postCursorText"] = post_cursor_text

        (
            stream_connection,
            stream_response,
            session_id,
            partial_text,
            final_text,
        ) = open_transcription_session(client, start_payload)
        reader_error: list[BridgeError] = []
        completed = threading.Event()

        try:
            def read_responses() -> None:
                nonlocal final_text, partial_text
                try:
                    while True:
                        kind, value = read_frame(stream_response)
                        if kind == "trailers":
                            grpc_message(value)
                            break
                        if not isinstance(value, dict):
                            continue
                        transcript = transcription_text(value)
                        if transcript:
                            partial_text = transcript[0]
                            if transcript[1]:
                                final_text = transcript[0]
                        if "complete" in value:
                            break
                except BridgeError as exc:
                    reader_error.append(exc)
                finally:
                    completed.set()

            reader = threading.Thread(
                target=read_responses,
                name="omarvoice-transcription-reader",
                daemon=True,
            )
            reader.start()

            audio_bytes = 0
            request_count = 0
            for sequence_number, chunk in enumerate(pcm_chunks(wav_path)):
                audio_bytes += len(chunk)
                client.unary(
                    CHUNK_PATH,
                    {
                        "sessionId": session_id,
                        "data": base64.b64encode(chunk).decode("ascii"),
                        "sequenceNumber": sequence_number,
                    },
                )
                request_count += 1

            client.unary(END_PATH, {"sessionId": session_id})
            request_count += 1
            if not completed.wait(timeout=30):
                raise BridgeError("provider_timeout", "Antigravity 云端听写响应超时")
            if reader_error:
                raise reader_error[0]
            text = (final_text or partial_text).strip()
            if not text:
                raise BridgeError("no_speech", "云端没有识别到可转写的语音")
            return {
                "status": "success",
                "provider": "antigravity-cloud",
                "text": text,
                "audio_bytes": audio_bytes,
                "request_count": request_count,
                "duration_ms": round((time.monotonic() - started_at) * 1000),
            }
        finally:
            stream_connection.close()


class PersistentEngine:
    """Own one authenticated language server for the Omarvoice user session."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.server: LanguageServer | None = None
        self.client: GrpcWebJsonClient | None = None
        self.auth_email = ""
        self.last_auth_sync_at = 0.0

    def ensure_ready(self, force_auth_sync: bool = False) -> tuple[
        GrpcWebJsonClient, dict[str, Any]
    ]:
        """Return a live client, starting and authenticating the engine once."""
        with self._lock:
            process = self.server.process if self.server else None
            alive = bool(process and process.poll() is None and self.client)
            timings: dict[str, Any] = {
                "engine_reused": alive,
                "auth_sync_ms": 0,
                "engine_start_ms": 0,
            }

            auth_result: dict[str, Any] | None = None
            should_sync_auth = (
                not alive
                or (
                    force_auth_sync
                    and time.monotonic() - self.last_auth_sync_at >= 2
                )
            )
            if should_sync_auth:
                auth_started_at = time.monotonic()
                auth_result = run_agent_controller("voice-auth-sync")
                self.last_auth_sync_at = time.monotonic()
                timings["auth_sync_ms"] = round(
                    (time.monotonic() - auth_started_at) * 1000
                )
            elif force_auth_sync:
                timings["auth_sync_coalesced"] = True

            requested_email = str((auth_result or {}).get("email") or "")
            if alive and requested_email and requested_email != self.auth_email:
                self.close()
                alive = False
                timings["engine_reused"] = False

            if alive and self.client:
                return self.client, timings

            self.close()
            engine_started_at = time.monotonic()
            server = LanguageServer()
            try:
                server.__enter__()
            except Exception:
                server.close()
                raise
            self.server = server
            self.client = GrpcWebJsonClient(server.https_port, server.csrf_token)
            self.auth_email = requested_email
            timings["engine_start_ms"] = round(
                (time.monotonic() - engine_started_at) * 1000
            )
            return self.client, timings

    def close(self) -> None:
        """Release the persistent client and provider process."""
        with self._lock:
            if self.client:
                self.client.close()
            if self.server:
                self.server.close()
            self.client = None
            self.server = None
            self.auth_email = ""

    def abort(self) -> None:
        """Force the local sockets and provider process down to unblock workers."""
        with self._lock:
            if self.client:
                self.client.abort()
            if self.server:
                self.server.close()
            self.client = None
            self.server = None
            self.auth_email = ""


def pcm_rms(chunk: bytes) -> int:
    """Compute signed 16-bit PCM RMS without exposing or retaining samples."""
    even_length = len(chunk) - (len(chunk) % 2)
    if even_length <= 0:
        return 0
    samples = array("h")
    samples.frombytes(chunk[:even_length])
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return 0
    mean_square = sum(sample * sample for sample in samples) / len(samples)
    return round(mean_square**0.5)


class LiveRecording:
    """Capture one microphone stream, save its WAV, and transcribe it live."""

    _END_OF_AUDIO = object()

    def __init__(
        self,
        engine: PersistentEngine,
        wav_path: Path,
        pre_cursor_text: str = "",
        post_cursor_text: str = "",
    ) -> None:
        self.engine = engine
        self.wav_path = wav_path
        self.pre_cursor_text = pre_cursor_text
        self.post_cursor_text = post_cursor_text
        self.audio_queue: queue.Queue[bytes | object] = queue.Queue()
        self.recorder: subprocess.Popen[bytes] | None = None
        self.capture_thread: threading.Thread | None = None
        self.cloud_thread: threading.Thread | None = None
        self.done = threading.Event()
        self.release_at = 0.0
        self.started_at = 0.0
        self.audio_bytes = 0
        self.speech_bytes = 0
        self.result: dict[str, Any] = {}
        self._stop_lock = threading.Lock()

    def start(self) -> dict[str, Any]:
        """Start capture immediately; cloud setup proceeds on a worker thread."""
        recorder_binary = shutil.which("pw-record")
        if not recorder_binary:
            raise BridgeError("recorder_missing", "缺少 pw-record，无法录音")

        self.wav_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.wav_path.parent.chmod(0o700)
        self.started_at = time.monotonic()
        self.recorder = subprocess.Popen(
            [
                recorder_binary,
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "s16",
                "--latency",
                "100ms",
                "--raw",
                "-",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        assert self.recorder.stdout is not None
        time.sleep(0.03)
        if self.recorder.poll() is not None:
            raise BridgeError("recording_failed", "无法启动麦克风录音")

        self.capture_thread = threading.Thread(
            target=self._capture_audio,
            name="omarvoice-live-capture",
            daemon=True,
        )
        self.cloud_thread = threading.Thread(
            target=self._stream_audio,
            name="omarvoice-live-cloud",
            daemon=True,
        )
        self.capture_thread.start()
        self.cloud_thread.start()
        return {
            "status": "recording",
            "ready": True,
            "provider": "antigravity-cloud",
            "wav_path": str(self.wav_path),
            "start_ms": round((time.monotonic() - self.started_at) * 1000),
        }

    def _capture_audio(self) -> None:
        recorder = self.recorder
        assert recorder and recorder.stdout
        try:
            with wave.open(str(self.wav_path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                while True:
                    chunk = recorder.stdout.read(LIVE_PCM_CHUNK_BYTES)
                    if not chunk:
                        break
                    output.writeframesraw(chunk)
                    self.audio_bytes += len(chunk)
                    if pcm_rms(chunk) >= SPEECH_RMS_THRESHOLD:
                        self.speech_bytes += len(chunk)
                    self.audio_queue.put(chunk)
        except Exception:
            if not self.result:
                self.result = {
                    "status": "error",
                    "code": "recording_failed",
                    "ready": False,
                    "message": "录音数据写入失败",
                }
        finally:
            recorder.stdout.close()
            self.audio_queue.put(self._END_OF_AUDIO)

    def _stream_audio(self) -> None:
        client: GrpcWebJsonClient | None = None
        stream_connection: http.client.HTTPSConnection | None = None
        timings: dict[str, Any] = {}
        request_count = 0
        final_text = ""
        partial_text = ""
        reader_error: list[BridgeError] = []
        completed = threading.Event()
        try:
            setup_started_at = time.monotonic()
            start_payload: dict[str, Any] = {
                "mimeType": "audio/pcm;rate=16000",
                "cascadeId": str(uuid.uuid4()),
                "continuous": False,
            }
            if self.pre_cursor_text:
                start_payload["preCursorText"] = self.pre_cursor_text
            if self.post_cursor_text:
                start_payload["postCursorText"] = self.post_cursor_text

            session_id = ""
            stream_response: http.client.HTTPResponse
            for attempt in range(2):
                if attempt:
                    start_payload["cascadeId"] = str(uuid.uuid4())
                client, engine_timings = self.engine.ensure_ready()
                if attempt == 0:
                    timings.update(engine_timings)
                else:
                    timings["retry_auth_sync_ms"] = engine_timings.get(
                        "auth_sync_ms", 0
                    )
                    timings["retry_engine_start_ms"] = engine_timings.get(
                        "engine_start_ms", 0
                    )
                try:
                    (
                        stream_connection,
                        stream_response,
                        session_id,
                        partial_text,
                        final_text,
                    ) = open_transcription_session(client, start_payload)
                    timings["session_attempts"] = attempt + 1
                    break
                except BridgeError as exc:
                    if attempt > 0 or exc.code not in {
                        "protocol_error",
                        "engine_http_error",
                        "engine_connection_error",
                    }:
                        raise
                    timings["first_session_error"] = exc.code
                    self.engine.close()
            timings["session_ready_ms"] = round(
                (time.monotonic() - setup_started_at) * 1000
            )

            def read_responses() -> None:
                nonlocal final_text, partial_text
                try:
                    while True:
                        kind, value = read_frame(stream_response)
                        if kind == "trailers":
                            grpc_message(value)
                            break
                        if not isinstance(value, dict):
                            continue
                        transcript = transcription_text(value)
                        if transcript:
                            partial_text = transcript[0]
                            if transcript[1]:
                                final_text = transcript[0]
                        if "complete" in value:
                            break
                except BridgeError as exc:
                    reader_error.append(exc)
                finally:
                    completed.set()

            threading.Thread(
                target=read_responses,
                name="omarvoice-live-response",
                daemon=True,
            ).start()

            sequence_number = 0
            while True:
                chunk = self.audio_queue.get()
                if chunk is self._END_OF_AUDIO:
                    break
                assert isinstance(chunk, bytes)
                client.unary(
                    CHUNK_PATH,
                    {
                        "sessionId": session_id,
                        "data": base64.b64encode(chunk).decode("ascii"),
                        "sequenceNumber": sequence_number,
                    },
                )
                sequence_number += 1
                request_count += 1

            audio_duration_ms = round(
                self.audio_bytes * 1000 / PCM_BYTES_PER_SECOND
            )
            detected_speech_ms = round(
                self.speech_bytes * 1000 / PCM_BYTES_PER_SECOND
            )
            final_started_at = time.monotonic()
            client.unary(END_PATH, {"sessionId": session_id})
            request_count += 1

            if audio_duration_ms < MIN_AUDIO_MS:
                raise BridgeError("no_speech", "未检测到有效语音")

            if not completed.wait(timeout=30):
                raise BridgeError(
                    "provider_timeout", "Antigravity 云端听写响应超时"
                )
            timings["final_wait_ms"] = round(
                (time.monotonic() - final_started_at) * 1000
            )
            if reader_error:
                raise reader_error[0]
            text = (final_text or partial_text).strip()
            if not text:
                raise BridgeError("no_speech", "云端没有识别到可转写的语音")
            timings["post_release_ms"] = (
                round((time.monotonic() - self.release_at) * 1000)
                if self.release_at
                else 0
            )
            self.result = {
                "status": "success",
                "provider": "antigravity-cloud",
                "text": text,
                "audio_bytes": self.audio_bytes,
                "audio_duration_ms": audio_duration_ms,
                "detected_speech_ms": detected_speech_ms,
                "request_count": request_count,
                "duration_ms": round(
                    (time.monotonic() - self.started_at) * 1000
                ),
                "timings": timings,
                "wav_path": str(self.wav_path),
            }
        except BridgeError as exc:
            timings["post_release_ms"] = (
                round((time.monotonic() - self.release_at) * 1000)
                if self.release_at
                else 0
            )
            self.result = {
                "status": "error",
                "code": exc.code,
                "ready": False,
                "message": exc.message,
                "audio_bytes": self.audio_bytes,
                "audio_duration_ms": round(
                    self.audio_bytes * 1000 / PCM_BYTES_PER_SECOND
                ),
                "detected_speech_ms": round(
                    self.speech_bytes * 1000 / PCM_BYTES_PER_SECOND
                ),
                "request_count": request_count,
                "timings": timings,
                "wav_path": str(self.wav_path),
            }
        except Exception:
            self.engine.close()
            self.result = {
                "status": "error",
                "code": "internal_error",
                "ready": False,
                "message": "Omarvoice 实时听写服务发生内部错误",
                "audio_bytes": self.audio_bytes,
                "request_count": request_count,
                "timings": timings,
                "wav_path": str(self.wav_path),
            }
        finally:
            if stream_connection:
                stream_connection.close()
            if client:
                client.close()
            self.done.set()

    def stop(self) -> dict[str, Any]:
        """Stop microphone capture and wait only for the cloud finalization."""
        self.request_stop()
        if self.capture_thread:
            self.capture_thread.join(timeout=5)
        if not self.done.wait(timeout=DEFAULT_TIMEOUT_SECONDS):
            raise BridgeError(
                "provider_timeout", "Omarvoice 实时听写服务响应超时"
            )
        timings = self.result.get("timings")
        if isinstance(timings, dict):
            timings["post_release_ms"] = round(
                (time.monotonic() - self.release_at) * 1000
            )
        return self.result

    def request_stop(self) -> None:
        """Signal capture to stop without waiting for cloud cleanup."""
        with self._stop_lock:
            if not self.release_at:
                self.release_at = time.monotonic()
                recorder = self.recorder
                if recorder and recorder.poll() is None:
                    recorder.terminate()
                    threading.Thread(
                        target=self._reap_recorder,
                        name="omarvoice-recorder-reaper",
                        daemon=True,
                    ).start()

    def _reap_recorder(self) -> None:
        recorder = self.recorder
        if not recorder:
            return
        try:
            recorder.wait(timeout=3)
        except subprocess.TimeoutExpired:
            recorder.kill()
            recorder.wait(timeout=2)

    def close(self) -> None:
        """Best-effort cleanup used during daemon shutdown."""
        recorder = self.recorder
        if recorder and recorder.poll() is None:
            recorder.kill()
        self.engine.abort()
        self.done.wait(timeout=5)


class OmarvoiceDaemon:
    """Serialize UI commands around one warm engine and one live recording."""

    def __init__(self) -> None:
        self.engine = PersistentEngine()
        self._recording_lock = threading.Lock()
        self.recording: LiveRecording | None = None
        self.server: socketserver.UnixStreamServer | None = None

    def dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        command = str(request.get("command") or "")
        if command == "ping":
            return {
                "status": "ready",
                "ready": True,
                "protocol_version": DAEMON_PROTOCOL_VERSION,
                "recording": bool(self.recording and not self.recording.done.is_set()),
            }
        if command == "warmup":
            _, timings = self.engine.ensure_ready(force_auth_sync=True)
            return {
                "status": "ready",
                "ready": True,
                "provider": "antigravity-cloud",
                "protocol_version": DAEMON_PROTOCOL_VERSION,
                "timings": timings,
            }
        if command == "record-start":
            return self._start_recording(request)
        if command == "record-stop":
            return self._stop_recording()
        if command == "record-cancel":
            return self._cancel_recording()
        if command == "shutdown":
            threading.Thread(target=self._shutdown, daemon=True).start()
            return {"status": "stopping", "ready": True}
        raise BridgeError("invalid_command", "Omarvoice 服务收到了未知命令")

    def _start_recording(self, request: dict[str, Any]) -> dict[str, Any]:
        raw_path = str(request.get("wav_path") or "")
        if not raw_path:
            raise BridgeError("recording_missing", "未指定录音文件路径")
        with self._recording_lock:
            if self.recording:
                raise BridgeError("recording_busy", "Omarvoice 已有录音正在进行")
            recording = LiveRecording(
                self.engine,
                Path(raw_path),
                pre_cursor_text=str(request.get("pre_cursor_text") or ""),
                post_cursor_text=str(request.get("post_cursor_text") or ""),
            )
            result = recording.start()
            self.recording = recording
            return result

    def _stop_recording(self) -> dict[str, Any]:
        with self._recording_lock:
            recording = self.recording
        if not recording:
            raise BridgeError("not_recording", "Omarvoice 当前没有进行中的录音")
        result = recording.stop()
        with self._recording_lock:
            if self.recording is recording:
                self.recording = None
        return result

    def _cancel_recording(self) -> dict[str, Any]:
        with self._recording_lock:
            recording = self.recording
            if recording:
                self.recording = None
        if not recording:
            raise BridgeError("not_recording", "Omarvoice 当前没有进行中的录音")
        recording.request_stop()
        threading.Thread(
            target=self._finish_cancelled_recording,
            args=(recording,),
            name="omarvoice-cancel-cleanup",
            daemon=True,
        ).start()
        return {
            "status": "cancelled",
            "ready": True,
            "audio_bytes": recording.audio_bytes,
            "wav_path": str(recording.wav_path),
        }

    def _finish_cancelled_recording(self, recording: LiveRecording) -> None:
        try:
            recording.stop()
        except Exception:
            pass
        finally:
            with self._recording_lock:
                if self.recording is recording:
                    self.recording = None

    def _shutdown(self) -> None:
        if self.server:
            self.server.shutdown()

    def close(self) -> None:
        with self._recording_lock:
            recording = self.recording
            self.recording = None
        if recording:
            recording.close()
        self.engine.close()


def daemon_runtime_dir() -> Path:
    """Return a private runtime directory for the current desktop user."""
    configured = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    runtime_dir = (
        Path(configured) / "omarvoice"
        if configured
        else Path("/tmp") / f"omarvoice-{os.getuid()}"
    )
    runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime_dir.chmod(0o700)
    return runtime_dir


def daemon_socket_path() -> Path:
    return daemon_runtime_dir() / "antigravity.sock"


def daemon_lock_path() -> Path:
    return daemon_runtime_dir() / "antigravity.lock"


def _daemon_request_once(request: dict[str, Any]) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(DEFAULT_TIMEOUT_SECONDS)
        client.connect(str(daemon_socket_path()))
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        client.sendall(payload + b"\n")
        response_parts: list[bytes] = []
        while True:
            chunk = client.recv(65_536)
            if not chunk:
                break
            response_parts.append(chunk)
            if b"\n" in chunk:
                break
    raw = b"".join(response_parts).split(b"\n", 1)[0]
    try:
        result = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError(
            "service_protocol_error", "Omarvoice 服务返回了无法解析的数据"
        ) from exc
    if not isinstance(result, dict):
        raise BridgeError(
            "service_protocol_error", "Omarvoice 服务返回了无效数据"
        )
    return result


def _start_daemon() -> None:
    """Start exactly one detached daemon, even if QML races two commands."""
    lock_path = daemon_lock_path()
    with lock_path.open("a+", encoding="utf-8") as lock_file:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            ping = _daemon_request_once({"command": "ping"})
            if ping.get("protocol_version") == DAEMON_PROTOCOL_VERSION:
                return
            _daemon_request_once({"command": "shutdown"})
        except (BridgeError, OSError):
            pass

        socket_path = daemon_socket_path()
        deadline = time.monotonic() + 2
        old_daemon_alive = False
        while socket_path.exists() and time.monotonic() < deadline:
            try:
                ping = _daemon_request_once({"command": "ping"})
                if ping.get("protocol_version") == DAEMON_PROTOCOL_VERSION:
                    return
                old_daemon_alive = True
            except (BridgeError, OSError):
                old_daemon_alive = False
                break
            time.sleep(0.05)
        if old_daemon_alive:
            raise BridgeError(
                "service_upgrade_failed",
                "旧版 Omarvoice 服务未能及时退出",
            )
        if socket_path.exists():
            socket_path.unlink()

        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "serve"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                ping = _daemon_request_once({"command": "ping"})
                if ping.get("protocol_version") == DAEMON_PROTOCOL_VERSION:
                    return
            except (BridgeError, OSError):
                time.sleep(0.05)
        raise BridgeError("service_start_failed", "Omarvoice 常驻服务启动失败")


def daemon_request(command: str, **fields: Any) -> dict[str, Any]:
    """Send one safe JSON command, starting the per-user daemon on demand."""
    request = {"command": command, **fields}
    try:
        ping = _daemon_request_once({"command": "ping"})
        if ping.get("protocol_version") != DAEMON_PROTOCOL_VERSION:
            _start_daemon()
    except (BridgeError, OSError):
        _start_daemon()
    try:
        return _daemon_request_once(request)
    except OSError as exc:
        raise BridgeError(
            "service_unavailable", "无法连接 Omarvoice 常驻服务"
        ) from exc


class _DaemonRequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        try:
            raw = self.rfile.readline(1_048_576)
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict):
                raise ValueError
            result = self.server.omarvoice.dispatch(request)  # type: ignore[attr-defined]
        except BridgeError as exc:
            result = {
                "status": "error",
                "code": exc.code,
                "ready": False,
                "message": exc.message,
            }
        except Exception:
            result = {
                "status": "error",
                "code": "internal_error",
                "ready": False,
                "message": "Omarvoice 常驻服务发生内部错误",
            }
        payload = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
        self.wfile.write(payload.encode("utf-8") + b"\n")


class _ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve_daemon() -> int:
    """Run the private per-user service until asked to shut down."""
    socket_path = daemon_socket_path()
    if socket_path.exists():
        socket_path.unlink()
    omarvoice = OmarvoiceDaemon()
    server = _ThreadingUnixServer(str(socket_path), _DaemonRequestHandler)
    server.omarvoice = omarvoice  # type: ignore[attr-defined]
    omarvoice.server = server
    os.chmod(socket_path, 0o600)
    socket_stat = socket_path.stat()
    socket_identity = (socket_stat.st_dev, socket_stat.st_ino)

    def request_shutdown(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        omarvoice.close()
        try:
            current_stat = socket_path.stat()
            current_identity = (current_stat.st_dev, current_stat.st_ino)
            if current_identity == socket_identity:
                socket_path.unlink()
        except FileNotFoundError:
            pass
    return 0


def status() -> dict[str, Any]:
    """Return readiness for the panel without changing authentication state."""
    language_server_path()
    result = run_agent_controller("voice-auth-status")
    return {
        "status": "ready",
        "ready": True,
        "provider": "antigravity-cloud",
        "email": result.get("email") or "",
        "message": result.get("message") or "Agent Panel 长期鉴权已就绪",
    }


def authorize() -> dict[str, Any]:
    """Start Agent Panel's loopback OAuth flow without blocking the QML process."""
    controller = find_agent_controller()
    subprocess.Popen(
        [str(controller), "oauth-start"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {
        "status": "authorization_started",
        "ready": False,
        "message": "授权链接已复制；完成登录后请刷新状态",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Omarvoice adapter for Antigravity cloud dictation"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="check engine and Agent Panel auth")
    subparsers.add_parser("authorize", help="start Agent Panel OAuth")
    subparsers.add_parser(
        "warmup", help="start and authenticate the resident service"
    )
    record_start_parser = subparsers.add_parser(
        "record-start", help="start live microphone capture and cloud streaming"
    )
    record_start_parser.add_argument("wav", type=Path)
    record_start_parser.add_argument("--pre-cursor-text", default="")
    record_start_parser.add_argument("--post-cursor-text", default="")
    subparsers.add_parser(
        "record-stop", help="stop capture and return the final transcript"
    )
    subparsers.add_parser(
        "record-cancel",
        help="discard a short capture and clean up asynchronously",
    )
    subparsers.add_parser("daemon-status", help="inspect the resident service")
    subparsers.add_parser("shutdown", help=argparse.SUPPRESS)
    subparsers.add_parser("serve", help=argparse.SUPPRESS)
    transcribe_parser = subparsers.add_parser(
        "transcribe", help="transcribe a WAV file"
    )
    transcribe_parser.add_argument("wav", type=Path)
    transcribe_parser.add_argument("--pre-cursor-text", default="")
    transcribe_parser.add_argument("--post-cursor-text", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "serve":
        return serve_daemon()
    try:
        if args.command == "status":
            result = status()
        elif args.command == "authorize":
            result = authorize()
        elif args.command == "warmup":
            result = daemon_request("warmup")
        elif args.command == "record-start":
            result = daemon_request(
                "record-start",
                wav_path=str(args.wav),
                pre_cursor_text=args.pre_cursor_text,
                post_cursor_text=args.post_cursor_text,
            )
        elif args.command == "record-stop":
            result = daemon_request("record-stop")
        elif args.command == "record-cancel":
            result = daemon_request("record-cancel")
        elif args.command == "daemon-status":
            result = daemon_request("ping")
        elif args.command == "shutdown":
            try:
                result = _daemon_request_once({"command": "shutdown"})
            except OSError:
                result = {"status": "stopped", "ready": True}
        else:
            result = transcribe(
                args.wav,
                pre_cursor_text=args.pre_cursor_text,
                post_cursor_text=args.post_cursor_text,
            )
    except BridgeError as exc:
        print(json.dumps({
            "status": "error",
            "code": exc.code,
            "ready": False,
            "message": exc.message,
        }, ensure_ascii=False))
        return 1
    except KeyboardInterrupt:
        print(json.dumps({
            "status": "error",
            "code": "cancelled",
            "ready": False,
            "message": "听写已取消",
        }, ensure_ascii=False))
        return 130
    except Exception:
        print(json.dumps({
            "status": "error",
            "code": "internal_error",
            "ready": False,
            "message": "Omarvoice 听写服务发生内部错误",
        }, ensure_ascii=False))
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("status") not in ("error", "failed") else 1


if __name__ == "__main__":
    sys.exit(main())
