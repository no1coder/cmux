#!/usr/bin/env python3
"""Regression test: `cmux pan-workspace` should send workspace.viewport.pan."""

from __future__ import annotations

import glob
import json
import os
import shutil
import socket
import subprocess
import threading


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class PanWorkspaceServer:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.ready = threading.Event()
        self.error: Exception | None = None
        self.request: dict[str, object] | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(1)
            server.settimeout(6.0)
            self.ready.set()

            conn, _ = server.accept()
            with conn:
                conn.settimeout(2.0)
                data = b""
                while b"\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk

                if b"\n" not in data:
                    return

                line = data.split(b"\n", 1)[0].decode("utf-8")
                self.request = json.loads(line)

                response = {
                    "ok": True,
                    "jsonrpc": "2.0",
                    "id": self.request.get("id"),
                    "result": {
                        "workspace_id": "workspace:1",
                        "workspace_ref": "workspace:1",
                        "delta": {"dx": 400, "dy": -120},
                        "viewport_origin": {"x": 400, "y": 120},
                        "canvas_bounds": {"x": 0, "y": 0, "width": 2400, "height": 1800},
                    },
                }
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        except Exception as exc:  # pragma: no cover
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    socket_path = f"/tmp/cmux-cli-pan-workspace-{os.getpid()}.sock"
    server = PanWorkspaceServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print("FAIL: socket server did not become ready")
        return 1

    if server.error is not None:
        print(f"FAIL: socket server failed to start: {server.error}")
        return 1

    env = os.environ.copy()
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    try:
        proc = subprocess.run(
            [
                cli_path,
                "--socket",
                socket_path,
                "pan-workspace",
                "--workspace",
                "workspace:1",
                "--dx",
                "400",
                "--dy",
                "-120",
            ],
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
    except Exception as exc:
        print(f"FAIL: invoking cmux pan-workspace failed: {exc}")
        return 1
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: socket server error: {server.error}")
        return 1

    if proc.returncode != 0:
        print("FAIL: cmux pan-workspace returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    request = server.request or {}
    if request.get("method") != "workspace.viewport.pan":
        print("FAIL: wrong method")
        print(f"request={request!r}")
        return 1

    params = request.get("params")
    if not isinstance(params, dict):
        print("FAIL: request params missing")
        print(f"request={request!r}")
        return 1

    expected = {
        "workspace_id": "workspace:1",
        "dx": 400,
        "dy": -120,
    }
    if params != expected:
        print("FAIL: wrong request params")
        print(f"expected={expected!r}")
        print(f"actual={params!r}")
        return 1

    if "workspace:1" not in proc.stdout:
        print("FAIL: stdout missing workspace handle")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    print("PASS: cmux pan-workspace sends workspace.viewport.pan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
