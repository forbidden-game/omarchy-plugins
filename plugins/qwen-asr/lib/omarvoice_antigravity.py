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
import base64
from collections.abc import Iterator
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, BinaryIO
import uuid


SERVICE_PREFIX = "/exa.language_server_pb.LanguageServerService"
START_PATH = f"{SERVICE_PREFIX}/StreamAudioTranscription"
CHUNK_PATH = f"{SERVICE_PREFIX}/SendAudioChunk"
END_PATH = f"{SERVICE_PREFIX}/EndAudioSession"
DEFAULT_LANGUAGE_SERVER = Path("/opt/Antigravity/resources/bin/language_server")
DEFAULT_TIMEOUT_SECONDS = 120
PCM_CHUNK_BYTES = 32_000  # One second of signed 16-bit, 16 kHz mono PCM.
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
    """A short-lived, UI-free Antigravity language-server process."""

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
        if response.status != 200:
            connection.close()
            raise BridgeError(
                "engine_http_error",
                f"Antigravity 本地听写引擎返回 HTTP {response.status}",
            )
        return connection, response

    def unary(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
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

        stream_connection, stream_response = client.request(START_PATH, start_payload)
        final_text = ""
        partial_text = ""
        reader_error: list[BridgeError] = []
        completed = threading.Event()
        session_id = ""

        try:
            while not session_id:
                kind, value = read_frame(stream_response)
                if kind == "trailers":
                    grpc_message(value)
                    raise BridgeError("protocol_error", "听写会话未返回 session id")
                ready = value.get("ready") if isinstance(value, dict) else None
                if isinstance(ready, dict):
                    session_id = str(ready.get("sessionId") or "")
                transcript = transcription_text(value) if isinstance(value, dict) else None
                if transcript:
                    partial_text = transcript[0]
                    if transcript[1]:
                        final_text = transcript[0]

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
    transcribe_parser = subparsers.add_parser("transcribe", help="transcribe a WAV file")
    transcribe_parser.add_argument("wav", type=Path)
    transcribe_parser.add_argument("--pre-cursor-text", default="")
    transcribe_parser.add_argument("--post-cursor-text", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "status":
            result = status()
        elif args.command == "authorize":
            result = authorize()
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
