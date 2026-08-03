#!/usr/bin/env python3
"""Fetch Codex usage through the supported Codex app-server protocol."""

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any


REQUEST_TIMEOUT_SECONDS = 30


def duration(seconds: float) -> str:
    seconds = int(max(0, seconds))
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    if days:
        return f"in {days}d {hours}h"
    if hours:
        return f"in {hours}h {minutes}m"
    return f"in {minutes}m"


def send_message(process: subprocess.Popen[str], message: dict[str, Any]) -> None:
    if process.stdin is None:
        raise RuntimeError("Codex app-server input is unavailable")
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive_response(
    responses: queue.Queue[dict[str, Any] | None], request_id: int, deadline: float
) -> dict[str, Any]:
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Codex app-server timed out")

        try:
            message = responses.get(timeout=remaining)
        except queue.Empty:
            raise TimeoutError("Codex app-server timed out")
        if message is None:
            raise RuntimeError("Codex app-server exited before replying")

        if message.get("id") != request_id:
            continue
        if message.get("error"):
            error = message["error"]
            if isinstance(error, dict):
                error = error.get("message") or "Unknown protocol error"
            raise RuntimeError(f"Codex app-server error: {error}")
        if not isinstance(message.get("result"), dict):
            raise RuntimeError("Codex app-server returned an invalid response")
        return message["result"]


def collect_messages(
    stream: Any, responses: queue.Queue[dict[str, Any] | None]
) -> None:
    for line in stream:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict):
            responses.put(message)
    responses.put(None)


def resolve_executable(configured_executable: str) -> str:
    configured_executable = configured_executable.strip() or "codex"
    if "/" in configured_executable:
        path = Path(configured_executable).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    else:
        resolved = shutil.which(configured_executable)
        if resolved:
            return resolved
    raise RuntimeError(
        "Codex CLI not found; install it or configure the widget's codexExecutable"
    )


def read_rate_limits(codex_executable: str, codex_home: str) -> dict[str, Any]:
    executable = resolve_executable(codex_executable)
    environment = os.environ.copy()
    if codex_home:
        environment["CODEX_HOME"] = str(Path(codex_home).expanduser())

    process = subprocess.Popen(
        [executable, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
        env=environment,
    )
    deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
    responses: queue.Queue[dict[str, Any] | None] = queue.Queue()
    reader = threading.Thread(
        target=collect_messages, args=(process.stdout, responses), daemon=True
    )
    reader.start()

    try:
        send_message(
            process,
            {
                "method": "initialize",
                "id": 1,
                "params": {
                    "clientInfo": {
                        "name": "noctalia-codex-usage-widget",
                        "title": "Noctalia Codex Usage",
                        "version": "1.0.4",
                    },
                    "capabilities": {},
                },
            },
        )
        receive_response(responses, 1, deadline)
        send_message(process, {"method": "initialized", "params": {}})
        send_message(
            process,
            {"method": "account/rateLimits/read", "id": 2, "params": {}},
        )
        return receive_response(responses, 2, deadline)
    finally:
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        reader.join(timeout=1)
        if process.stdout is not None:
            process.stdout.close()


def reset_timestamps(result: dict[str, Any]) -> list[float]:
    limits: list[Any] = [result.get("rateLimits")]
    by_limit_id = result.get("rateLimitsByLimitId")
    if isinstance(by_limit_id, dict):
        limits.extend(by_limit_id.values())

    timestamps: set[float] = set()
    for rate_limit in limits:
        if not isinstance(rate_limit, dict):
            continue
        for window_name in ("primary", "secondary"):
            window = rate_limit.get(window_name)
            reset_at = window.get("resetsAt") if isinstance(window, dict) else None
            if isinstance(reset_at, (int, float)):
                timestamps.add(float(reset_at))
    return sorted(timestamps)


def build_payload(result: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    rate_limits = result.get("rateLimits")
    rate_limits = rate_limits if isinstance(rate_limits, dict) else {}
    primary = rate_limits.get("primary")
    primary = primary if isinstance(primary, dict) else {}
    used_percent = primary.get("usedPercent")
    if not isinstance(used_percent, (int, float)):
        used_percent = None

    reset_credits = result.get("rateLimitResetCredits")
    reset_credits = reset_credits if isinstance(reset_credits, dict) else {}
    credits = reset_credits.get("credits")
    credits = credits if isinstance(credits, list) else []
    available_count = reset_credits.get("availableCount")
    if not isinstance(available_count, (int, float)):
        available_count = len(credits)

    future_resets = [timestamp - now for timestamp in reset_timestamps(result)]
    future_resets = [seconds for seconds in future_resets if seconds >= 0]

    return {
        "ok": True,
        "available_count": int(available_count),
        "credits_returned": len(credits),
        "usage_percent": used_percent,
        "usage_percent_text": (
            f"{used_percent:.0f}%" if used_percent is not None else ""
        ),
        "next_limit_reset_relative": (
            duration(future_resets[0]) if future_resets else ""
        ),
        "retrieved_at": datetime.now().astimezone().strftime("%H:%M"),
    }


def error_payload(error: Exception) -> dict[str, Any]:
    return {
        "ok": False,
        "error": str(error),
        "retrieved_at": datetime.now().astimezone().strftime("%H:%M"),
    }


def main() -> None:
    codex_home = sys.argv[1] if len(sys.argv) > 1 else ""
    codex_executable = sys.argv[2] if len(sys.argv) > 2 else "codex"
    try:
        payload = build_payload(read_rate_limits(codex_executable, codex_home))
    except Exception as error:
        payload = error_payload(error)
    print(json.dumps(payload, separators=(",", ":")))


if __name__ == "__main__":
    main()