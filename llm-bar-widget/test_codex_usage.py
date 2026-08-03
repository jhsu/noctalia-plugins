import stat
import tempfile
import textwrap
import unittest
from pathlib import Path

import codex_usage


class BuildPayloadTests(unittest.TestCase):
    def test_builds_existing_widget_contract(self) -> None:
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

        payload = codex_usage.build_payload(result, now=10_000)

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["available_count"], 3)
        self.assertEqual(payload["credits_returned"], 2)
        self.assertEqual(payload["usage_percent"], 41.6)
        self.assertEqual(payload["usage_percent_text"], "42%")
        self.assertEqual(payload["next_limit_reset_relative"], "in 5m")

    def test_handles_nullable_app_server_fields(self) -> None:
        payload = codex_usage.build_payload(
            {"rateLimits": None, "rateLimitResetCredits": None}, now=10_000
        )

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["available_count"], 0)
        self.assertEqual(payload["credits_returned"], 0)
        self.assertEqual(payload["usage_percent_text"], "")
        self.assertEqual(payload["next_limit_reset_relative"], "")


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