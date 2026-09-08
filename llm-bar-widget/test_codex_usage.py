import json
import stat
import tempfile
import textwrap
import unittest
from pathlib import Path

import codex_usage


class BuildPayloadTests(unittest.TestCase):
    def test_builds_existing_widget_contract(self) -> None:
        account = {
            "name": "Codex",
            "codexHome": "",
            "codexExecutable": "codex",
        }
        result = {
            "rateLimits": {
                "primary": {"usedPercent": 41.6, "resetsAt": 10_600},
                "secondary": {"usedPercent": 12, "resetsAt": 20_000},
            },
            "rateLimitsByLimitId": {
                "other": {"primary": {"usedPercent": 5, "resetsAt": 10_300}}
            },
            "rateLimitResetCredits": {
                "availableCount": 3,
                "credits": [{"id": "one"}, {"id": "two"}],
            },
        }

        payload = codex_usage.build_payload([(account, result)], now=10_000)

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["available_count"], 3)
        self.assertEqual(payload["usage_percent"], 41.6)
        self.assertEqual(payload["usage_percent_text"], "42%")
        self.assertEqual(payload["next_limit_reset_relative"], "in 5m")
        self.assertEqual(len(payload["accounts"]), 1)
        self.assertEqual(payload["accounts"][0]["credits_returned"], 2)

    def test_handles_nullable_app_server_fields(self) -> None:
        account = {
            "name": "Codex",
            "codexHome": "",
            "codexExecutable": "codex",
        }
        payload = codex_usage.build_payload(
            [(account, {"rateLimits": None, "rateLimitResetCredits": None})],
            now=10_000,
        )

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["available_count"], 0)
        self.assertEqual(payload["usage_percent_text"], "")
        self.assertEqual(payload["next_limit_reset_relative"], "")


class MultiAccountTests(unittest.TestCase):
    def make_account(self, name: str) -> dict[str, str]:
        return {"name": name, "codexHome": "", "codexExecutable": "codex"}

    def test_aggregates_worst_usage_and_soonest_reset(self) -> None:
        first = {
            "rateLimits": {"primary": {"usedPercent": 20, "resetsAt": 20_000}},
            "rateLimitResetCredits": {"availableCount": 2, "credits": []},
        }
        second = {
            "rateLimits": {"primary": {"usedPercent": 80, "resetsAt": 10_500}},
            "rateLimitResetCredits": {
                "availableCount": 4,
                "credits": [{"id": "a"}, {"id": "b"}],
            },
        }

        payload = codex_usage.build_payload(
            [
                (self.make_account("Work"), first),
                (self.make_account("Personal"), second),
            ],
            now=10_000,
        )

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["usage_percent"], 80)
        self.assertEqual(payload["usage_percent_text"], "80%")
        self.assertEqual(payload["available_count"], 6)
        self.assertEqual(payload["next_limit_reset_relative"], "in 8m")
        self.assertEqual(
            [account["name"] for account in payload["accounts"]],
            ["Work", "Personal"],
        )

    def test_survives_a_failing_account(self) -> None:
        healthy = {
            "rateLimits": {"primary": {"usedPercent": 30, "resetsAt": 10_600}},
            "rateLimitResetCredits": {"availableCount": 1, "credits": []},
        }

        payload = codex_usage.build_payload(
            [
                (self.make_account("Broken"), RuntimeError("boom")),
                (self.make_account("Healthy"), healthy),
            ],
            now=10_000,
        )

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["usage_percent_text"], "30%")
        self.assertEqual(payload["available_count"], 1)
        self.assertFalse(payload["accounts"][0]["ok"])
        self.assertEqual(payload["accounts"][0]["error"], "boom")
        self.assertTrue(payload["accounts"][1]["ok"])

    def test_all_accounts_failing_reports_error(self) -> None:
        payload = codex_usage.build_payload(
            [(self.make_account("Broken"), RuntimeError("boom"))], now=10_000
        )

        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"], "boom")
        self.assertEqual(payload["usage_percent_text"], "")

    def test_fetch_accounts_runs_each_account(self) -> None:
        scripts: dict[str, str] = {}
        with tempfile.TemporaryDirectory() as directory:
            for name, used_percent in (("alpha", 50), ("beta", 10)):
                executable = Path(directory) / f"codex-{name}"
                script = textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import json
                    import sys

                    initialize = json.loads(sys.stdin.readline())
                    print(json.dumps({"id": initialize["id"], "result": {}}), flush=True)
                    sys.stdin.readline()
                    request = json.loads(sys.stdin.readline())
                    print(json.dumps({
                        "id": request["id"],
                        "result": {
                            "rateLimits": {"primary": {"usedPercent": __USED_PERCENT__}},
                            "rateLimitResetCredits": {"availableCount": 1, "credits": []}
                        }
                    }), flush=True)
                    """
                ).replace("__USED_PERCENT__", str(used_percent))
                executable.write_text(script)
                executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
                scripts[name] = str(executable)

            accounts = [
                {"name": "Alpha", "codexHome": "", "codexExecutable": scripts["alpha"]},
                {"name": "Beta", "codexHome": "", "codexExecutable": scripts["beta"]},
            ]
            results = codex_usage.fetch_accounts(accounts)

        payload = codex_usage.build_payload(results, now=0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["usage_percent"], 50)
        self.assertEqual(payload["available_count"], 2)


class ParseAccountsTests(unittest.TestCase):
    def test_legacy_arguments_become_single_account(self) -> None:
        accounts = codex_usage.parse_accounts(["/tmp/codex", "codex-bin"])

        self.assertEqual(
            accounts,
            [
                {
                    "name": "Codex",
                    "codexHome": "/tmp/codex",
                    "codexExecutable": "codex-bin",
                }
            ],
        )

    def test_parses_account_list_json(self) -> None:
        raw = json.dumps(
            [
                {"name": "Work", "codexHome": "~/.codex-work"},
                {"codexHome": "~/.codex-personal", "codexExecutable": "codex2"},
            ]
        )

        accounts = codex_usage.parse_accounts([raw])

        self.assertEqual(accounts[0], {
            "name": "Work",
            "codexHome": "~/.codex-work",
            "codexExecutable": "codex",
        })
        self.assertEqual(accounts[1], {
            "name": "Account 2",
            "codexHome": "~/.codex-personal",
            "codexExecutable": "codex2",
        })

    def test_parses_single_account_object_json(self) -> None:
        accounts = codex_usage.parse_accounts(
            [json.dumps({"name": "Solo", "codexHome": "~/solo"})]
        )

        self.assertEqual(len(accounts), 1)
        self.assertEqual(accounts[0]["name"], "Solo")

    def test_rejects_invalid_accounts_json(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Invalid accounts JSON"):
            codex_usage.parse_accounts(["{not json"])
        with self.assertRaisesRegex(RuntimeError, "non-empty list"):
            codex_usage.parse_accounts([json.dumps([])])


class ProtocolTests(unittest.TestCase):
    def run_fake_server(self, source: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "fake-codex"
            executable.write_text(textwrap.dedent(source))
            executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
            return codex_usage.read_rate_limits(str(executable), "")

    def test_ignores_notifications_and_matches_response_ids(self) -> None:
        result = self.run_fake_server(
            """\
            #!/usr/bin/env python3
            import json
            import sys

            def receive():
                return json.loads(sys.stdin.readline())

            def send(message):
                print(json.dumps(message), flush=True)

            initialize = receive()
            send({"method": "server/notification", "params": {}})
            send({"id": initialize["id"], "result": {"serverInfo": {}}})
            receive()
            request = receive()
            send({"id": 999, "result": {}})
            send({
                "id": request["id"],
                "result": {
                    "rateLimits": {
                        "primary": {"usedPercent": 25, "resetsAt": 12345}
                    },
                    "rateLimitResetCredits": {
                        "availableCount": 2,
                        "credits": []
                    }
                }
            })
            """
        )

        self.assertEqual(result["rateLimits"]["primary"]["usedPercent"], 25)
        self.assertEqual(
            result["rateLimitResetCredits"]["availableCount"], 2
        )

    def test_large_stderr_output_cannot_block_protocol(self) -> None:
        result = self.run_fake_server(
            """\
            #!/usr/bin/env python3
            import json
            import sys

            sys.stderr.write("diagnostic" * 100000)
            initialize = json.loads(sys.stdin.readline())
            print(json.dumps({"id": initialize["id"], "result": {}}), flush=True)
            sys.stdin.readline()
            request = json.loads(sys.stdin.readline())
            print(json.dumps({
                "id": request["id"],
                "result": {"rateLimits": None, "rateLimitResetCredits": None}
            }), flush=True)
            """
        )

        self.assertIsNone(result["rateLimits"])

    def test_eof_before_response_is_an_error(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "exited before replying"):
            self.run_fake_server(
                """\
                #!/usr/bin/env python3
                print("not json")
                """
            )

    def test_timeout_terminates_unresponsive_server(self) -> None:
        previous_timeout = codex_usage.REQUEST_TIMEOUT_SECONDS
        codex_usage.REQUEST_TIMEOUT_SECONDS = 0.1
        try:
            with self.assertRaisesRegex(TimeoutError, "timed out"):
                self.run_fake_server(
                    """\
                    #!/usr/bin/env python3
                    import time
                    time.sleep(10)
                    """
                )
        finally:
            codex_usage.REQUEST_TIMEOUT_SECONDS = previous_timeout


if __name__ == "__main__":
    unittest.main()