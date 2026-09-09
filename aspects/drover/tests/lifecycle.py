#!/usr/bin/env python3
"""Focused executable simulation of Drover supervisor exit policies."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


class Lifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.supervisor = Path(options.supervisor).resolve()
        cls.drover_source = Path(options.drover_source).resolve()
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.config = root / "config.json"
        cls.config.write_text('{"url":"https://drover.example"}')
        cls.fake = root / "fake_drover.py"
        cls.fake.write_text(
            textwrap.dedent(
                """
                import asyncio
                import os

                class ResponseError(Exception):
                    status = 401

                async def serve(_config):
                    mode = os.environ["FAKE_MODE"]
                    if mode == "direct-auth":
                        raise ResponseError("unauthorized")
                    if mode in ("auth", "wrapped-crash"):
                        try:
                            raise ResponseError("unauthorized")
                        except ResponseError as cause:
                            message = (
                                "machine revoked or credential invalid; re-enroll explicitly"
                                if mode == "auth"
                                else "unrelated wrapped failure"
                            )
                            raise RuntimeError(message) from cause
                    if mode == "crash":
                        raise RuntimeError("unrelated process failure")
                    if mode == "return":
                        return
                    while True:
                        await asyncio.sleep(1)
                """
            )
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_supervisor(self, mode, wait=True):
        root = Path(self.temp.name)
        marker = root / (mode + ".terminal")
        enabled = root / (mode + ".enabled")
        enabled.touch()
        command = [
            sys.executable,
            str(self.supervisor),
            "--drover-source",
            str(self.fake),
            "--config",
            str(self.config),
            "--terminal-marker",
            str(marker),
            "--enabled-marker",
            str(enabled),
        ]
        process = subprocess.Popen(command, env=dict(os.environ, FAKE_MODE=mode), stderr=subprocess.DEVNULL)
        if wait:
            process.wait(timeout=10)
        return process, marker, enabled

    @staticmethod
    def systemd_on_failure(returncode):
        return returncode != 0

    @staticmethod
    def launchd_successful_exit_false(returncode):
        # launchd KeepAlive.SuccessfulExit=false keeps a job alive only after
        # an unsuccessful exit; signal death is unsuccessful too.
        return returncode != 0

    def assert_platform_policies(self, returncode, restart):
        self.assertEqual(self.systemd_on_failure(returncode), restart)
        self.assertEqual(self.launchd_successful_exit_false(returncode), restart)

    def test_auth_is_clean_terminal_and_disables_sshd(self):
        process, marker, enabled = self.run_supervisor("auth")
        self.assertEqual(process.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(enabled.exists())
        self.assert_platform_policies(process.returncode, False)

        # A boot-time RunAtLoad/start attempt remains gated until an operator
        # removes the marker as part of explicit re-enrollment.
        process, marker, enabled = self.run_supervisor("auth")
        self.assertEqual(process.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(enabled.exists())

    def test_initial_registration_auth_is_also_terminal(self):
        process, marker, enabled = self.run_supervisor("direct-auth")
        self.assertEqual(process.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(enabled.exists())
        self.assert_platform_policies(process.returncode, False)

    def test_unexpected_clean_return_is_terminal(self):
        process, marker, enabled = self.run_supervisor("return")
        self.assertEqual(process.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(enabled.exists())
        self.assert_platform_policies(process.returncode, False)

    def test_exception_is_restartable_failure(self):
        process, marker, enabled = self.run_supervisor("crash")
        self.assertEqual(process.returncode, 1)
        self.assertFalse(marker.exists())
        self.assertTrue(enabled.exists())
        self.assert_platform_policies(process.returncode, True)

    def test_unrelated_wrapped_exception_is_not_misclassified(self):
        process, marker, enabled = self.run_supervisor("wrapped-crash")
        self.assertEqual(process.returncode, 1)
        self.assertFalse(marker.exists())
        self.assertTrue(enabled.exists())
        self.assert_platform_policies(process.returncode, True)

    def test_supervisor_stop_is_clean_but_signal_crash_restarts(self):
        process, marker, enabled = self.run_supervisor("sleep", wait=False)
        time.sleep(0.2)
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertTrue(enabled.exists())
        self.assert_platform_policies(process.returncode, False)

        process, marker, enabled = self.run_supervisor("sleep", wait=False)
        time.sleep(0.2)
        process.kill()
        process.wait(timeout=10)
        self.assertLess(process.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertTrue(enabled.exists())
        self.assert_platform_policies(process.returncode, True)

    def test_pinned_loop_has_bounded_terminal_auth_distinction(self):
        source = self.drover_source.read_text()
        self.assertIn("if getattr(exc, 'status', None) in (401, 403):", source)
        self.assertIn("raise RuntimeError('machine revoked or credential invalid; re-enroll explicitly')", source)
        self.assertIn("print('control reconnect:', type(exc).__name__", source)
        self.assertIn("delay = min(delay * 2, 30)", source)
        self.assertIn("async def tunnel(config, port):", source)
        self.assertIn("while True:\n        proc = await asyncio.create_subprocess_exec('ssh'", source)


parser = argparse.ArgumentParser()
parser.add_argument("--supervisor", required=True)
parser.add_argument("--drover-source", required=True)
options, remaining = parser.parse_known_args()
unittest.main(argv=[sys.argv[0], *remaining])
