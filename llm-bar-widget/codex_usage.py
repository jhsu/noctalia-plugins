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
from concurrent.futures import ThreadPoolExecutor
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


def parse_accounts(args: list[str]) -> list[dict[str, str]]:
    """Resolve accounts from argv.

    Accepts either a JSON list (or single object) of account configs in the
    first argument, or the legacy two-argument form (codexHome, executable).
    """
    if args and args[0].lstrip().startswith(("[", "{")):
        try:
            parsed = json.loads(args[0])
        except json.JSONDecodeError as error:
            raise RuntimeError(f"Invalid accounts JSON: {error}")
        if isinstance(parsed, dict):
            parsed = [parsed]
        if not isinstance(parsed, list) or not parsed:
            raise RuntimeError("Accounts JSON must be a non-empty list")

        accounts: list[dict[str, str]] = []
        for index, entry in enumerate(parsed, start=1):
            if not isinstance(entry, dict):
                entry = {"codexHome": str(entry)}
            accounts.append(
                {
                    "name": str(entry.get("name") or f"Account {index}"),
                    "codexHome": str(entry.get("codexHome") or ""),
                    "codexExecutable": str(entry.get("codexExecutable") or "codex"),
                }
            )
        return accounts

    codex_home = args[0] if len(args) > 0 else ""
    codex_executable = args[1] if len(args) > 1 else "codex"
    return [
        {
            "name": "Codex",
            "codexHome": codex_home,
            "codexExecutable": codex_executable,
        }
    ]


def fetch_accounts(accounts: list[dict[str, str]]) -> list[tuple[dict[str, str], Any]]:
    """Query every account in parallel, keeping failures as exceptions."""
    with ThreadPoolExecutor(max_workers=min(4, len(accounts))) as pool:
        futures = [
            pool.submit(read_rate_limits, account["codexExecutable"], account["codexHome"])
            for account in accounts
        ]
        results: list[tuple[dict[str, str], Any]] = []
        for account, future in zip(accounts, futures):
            try:
                results.append((account, future.result()))
            except Exception as error:  # noqa: BLE001 - reported per account
                results.append((account, error))
        return results


def build_account_payload(
    name: str, result: dict[str, Any], now: float
) -> dict[str, Any]:
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
        "name": name,
        "available_count": int(available_count),
        "credits_returned": len(credits),
        "usage_percent": used_percent,
        "usage_percent_text": (
            f"{used_percent:.0f}%" if used_percent is not None else ""
        ),
        "next_limit_reset_in": future_resets[0] if future_resets else None,
        "next_limit_reset_relative": (
            duration(future_resets[0]) if future_resets else ""
        ),
    }


def build_payload(
    account_results: list[tuple[dict[str, str], Any]], now: float | None = None
) -> dict[str, Any]:
    """Aggregate per-account results into the widget payload.

    The top-level fields keep the single-account contract (worst usage across
    accounts, summed reset credits, soonest reset) while every account also
    appears in the "accounts" list for the tooltip.
    """
    now = time.time() if now is None else now
    accounts: list[dict[str, Any]] = []
    for account, outcome in account_results:
        if isinstance(outcome, Exception):
            accounts.append(
                {
                    "ok": False,
                    "name": account["name"],
                    "available_count": 0,
                    "credits_returned": 0,
                    "usage_percent": None,
                    "usage_percent_text": "",
                    "next_limit_reset_in": None,
                    "next_limit_reset_relative": "",
                    "error": str(outcome),
                }
            )
        else:
            accounts.append(build_account_payload(account["name"], outcome, now))

    ok_accounts = [account for account in accounts if account["ok"]]
    percents = [
        account["usage_percent"]
        for account in ok_accounts
        if account["usage_percent"] is not None
    ]
    resets = [
        account["next_limit_reset_in"]
        for account in ok_accounts
        if account["next_limit_reset_in"] is not None
    ]

    payload: dict[str, Any] = {
        "ok": bool(ok_accounts),
        "accounts": accounts,
        "available_count": sum(account["available_count"] for account in ok_accounts),
        "usage_percent": max(percents) if percents else None,
        "usage_percent_text": f"{max(percents):.0f}%" if percents else "",
        "next_limit_reset_relative": duration(min(resets)) if resets else "",
        "retrieved_at": datetime.now().astimezone().strftime("%H:%M"),
    }
    if not payload["ok"]:
        payload["error"] = "; ".join(
            account["error"] for account in accounts if account["error"]
        )
    return payload


def main() -> None:
    try:
        accounts = parse_accounts(sys.argv[1:])
        payload = build_payload(fetch_accounts(accounts))
    except Exception as error:
        payload = {
            "ok": False,
            "error": str(error),
            "accounts": [],
            "retrieved_at": datetime.now().astimezone().strftime("%H:%M"),
        }
    print(json.dumps(payload, separators=(",", ":")))


if __name__ == "__main__":
    main()