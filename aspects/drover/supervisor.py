#!/usr/bin/env python3
"""Run the pinned Drover serve coroutine with supervisor-visible auth semantics."""

import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import signal


REVOKED_MESSAGE = "machine revoked or credential invalid; re-enroll explicitly"


def load_drover(path):
    spec = importlib.util.spec_from_file_location("pinned_drover", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load pinned Drover source")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def is_terminal_auth_failure(exc):
    """Recognize only Drover's pinned 401/403 enrollment/control failures."""
    current = exc
    seen = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if getattr(current, "status", None) in (401, 403):
            if current is exc or str(exc) == REVOKED_MESSAGE:
                return True
        current = current.__cause__ or current.__context__
    return False


def mark_terminal(marker, enabled):
    enabled.unlink(missing_ok=True)
    marker.touch(mode=0o600, exist_ok=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--drover-source", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--terminal-marker", required=True)
    parser.add_argument("--enabled-marker", required=True)
    args = parser.parse_args()

    marker = Path(args.terminal_marker)
    enabled = Path(args.enabled_marker)
    if marker.exists():
        enabled.unlink(missing_ok=True)
        print("terminal credential gate is set; re-enroll explicitly", flush=True)
        return 0
    enabled.touch(mode=0o600, exist_ok=True)

    config = json.loads(Path(args.config).read_text())
    if not config["url"].startswith(("https://", "http://127.0.0.1:", "http://localhost:")):
        raise ValueError("control URL requires HTTPS (except loopback development)")
    drover = load_drover(args.drover_source)

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        asyncio.run(drover.serve(config))
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        if not is_terminal_auth_failure(exc):
            raise
        print(REVOKED_MESSAGE, flush=True)
        mark_terminal(marker, enabled)
        return 0

    # The pinned serve loop is infinite. A future clean return is terminal too,
    # rather than something either supervisor should churn on.
    mark_terminal(marker, enabled)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
