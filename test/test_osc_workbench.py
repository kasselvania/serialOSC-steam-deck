#!/usr/bin/env python3
"""Local, hardware-free tests for the SerialOSC OSC workbench."""

from __future__ import annotations

import importlib.util
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any, Callable


MODULE_PATH = Path(__file__).with_name("osc_workbench.py")
SPEC = importlib.util.spec_from_file_location("osc_workbench", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
osc = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = osc
SPEC.loader.exec_module(osc)


class FakeUDPServer:
    def __init__(self, handler: Callable[[bytes, tuple[str, int]], None]):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.handler = handler
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        while not self.stopping.is_set():
            packet, peer = self.sock.recvfrom(65535)
            if self.stopping.is_set():
                break
            self.handler(packet, peer)

    def send(self, host: str, port: int, path: str, types: str, args: list[Any]) -> None:
        self.sock.sendto(osc.encode_message(path, types, args), (host, port))

    def close(self) -> None:
        self.stopping.set()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as wake:
            wake.sendto(b"stop", ("127.0.0.1", self.port))
        self.thread.join(timeout=2)
        self.sock.close()


class FakeDevice:
    def __init__(
        self, complete_info: bool = True, size: list[int] | None = None
    ) -> None:
        self.complete_info = complete_info
        self.state: dict[str, Any] = {
            "id": "m-test-1",
            "size": [16, 8] if size is None else size,
            "host": "127.0.0.1",
            "port": 9000,
            "prefix": "/monome",
            "rotation": 0,
        }
        self.received: list[tuple[str, str, list[Any]]] = []
        self.server = FakeUDPServer(self._handle)

    @property
    def port(self) -> int:
        return self.server.port

    def _handle(self, packet: bytes, _peer: tuple[str, int]) -> None:
        path, types, args = osc.decode_message(packet)
        self.received.append((path, types, args))
        if path == "/sys/info":
            host, port = str(args[0]), int(args[1])
            responses = [
                ("/sys/id", "s", [self.state["id"]]),
                ("/sys/size", "ii", self.state["size"]),
                ("/sys/host", "s", [self.state["host"]]),
                ("/sys/port", "i", [self.state["port"]]),
                ("/sys/prefix", "s", [self.state["prefix"]]),
                ("/sys/rotation", "i", [self.state["rotation"]]),
            ]
            if not self.complete_info:
                responses = [item for item in responses if item[0] != "/sys/rotation"]
            for response_path, response_types, response_args in responses:
                self.server.send(host, port, response_path, response_types, response_args)
        elif path == "/sys/host":
            self.state["host"] = str(args[0])
        elif path == "/sys/port":
            self.state["port"] = int(args[0])
        elif path == "/sys/prefix":
            self.state["prefix"] = str(args[0])

    def close(self) -> None:
        self.server.close()


def wait_for(predicate: Callable[[], bool], timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("condition did not become true before timeout")


class OscCodecTests(unittest.TestCase):
    def test_round_trip_supported_types(self) -> None:
        packet = osc.encode_message("/test", "isf", [42, "hello", 1.25])
        path, types, args = osc.decode_message(packet)
        self.assertEqual(path, "/test")
        self.assertEqual(types, "isf")
        self.assertEqual(args[0:2], [42, "hello"])
        self.assertAlmostEqual(args[2], 1.25)

    def test_rejects_bad_path_and_argument_count(self) -> None:
        with self.assertRaises(ValueError):
            osc.encode_message("not-a-path")
        with self.assertRaises(ValueError):
            osc.encode_message("/test", "ii", [1])


class DiscoveryTests(unittest.TestCase):
    def test_discovers_and_deduplicates_devices(self) -> None:
        server: FakeUDPServer

        def handler(packet: bytes, _peer: tuple[str, int]) -> None:
            path, types, args = osc.decode_message(packet)
            self.assertEqual((path, types), ("/serialosc/list", "si"))
            host, port = str(args[0]), int(args[1])
            for serial, name, device_port in [
                ("m2", "monome arc", 18002),
                ("m1", "monome 128", 18001),
                ("m1", "monome 128", 18001),
            ]:
                server.send(
                    host,
                    port,
                    "/serialosc/device",
                    "ssi",
                    [serial, name, device_port],
                )

        server = FakeUDPServer(handler)
        try:
            devices = osc.discover("127.0.0.1", server.port, timeout=0.5)
        finally:
            server.close()
        self.assertEqual(
            devices,
            [
                osc.Device("m1", "monome 128", 18001),
                osc.Device("m2", "monome arc", 18002),
            ],
        )


class SessionTests(unittest.TestCase):
    def test_query_configure_commands_and_restore(self) -> None:
        fake = FakeDevice()
        try:
            info = osc.query_info(fake.port, timeout=0.5)
            self.assertEqual(info["id"], "m-test-1")
            self.assertEqual(info["size"], [16, 8])

            with tempfile.TemporaryDirectory() as temporary_directory:
                session = osc.InteractiveSession(
                    [osc.Device("m-test-1", "monome 128", fake.port)],
                    Path(temporary_directory) / "events.jsonl",
                )
                session.configure()
                wait_for(
                    lambda: fake.state["port"] == session.callback_port
                    and fake.state["prefix"] == "/workbench/m-test-1"
                )
                session.grid("0", "on")
                with self.assertRaisesRegex(ValueError, "not an arc; command refused"):
                    session.ring("m-test-1", "1", "off")
                session.all_off()
                session.restore()
                wait_for(
                    lambda: fake.state["host"] == "127.0.0.1"
                    and fake.state["port"] == 9000
                    and fake.state["prefix"] == "/monome"
                )
                session.close()

            paths = [message[0] for message in fake.received]
            self.assertIn("/workbench/m-test-1/grid/led/all", paths)
            self.assertNotIn("/workbench/m-test-1/ring/all", paths)
        finally:
            fake.close()

    def test_arc_session_never_sends_grid_commands(self) -> None:
        fake = FakeDevice(size=[0, 0])
        try:
            with tempfile.TemporaryDirectory() as temporary_directory:
                session = osc.InteractiveSession(
                    [osc.Device("m-test-arc", "monome arc 4", fake.port)],
                    Path(temporary_directory) / "events.jsonl",
                )
                session.configure()
                wait_for(
                    lambda: fake.state["port"] == session.callback_port
                    and fake.state["prefix"] == "/workbench/m-test-arc"
                )
                session.all_off()
                session.ring("0", "1", "on")
                with self.assertRaisesRegex(ValueError, "not a grid; command refused"):
                    session.grid("m-test-arc", "on")
                session.all_off()
                session.restore()
                session.close()

            paths = [message[0] for message in fake.received]
            self.assertIn("/workbench/m-test-arc/ring/all", paths)
            self.assertNotIn("/workbench/m-test-arc/grid/led/all", paths)
            ring_messages = [
                message
                for message in fake.received
                if message[0] == "/workbench/m-test-arc/ring/all"
            ]
            self.assertEqual({message[2][0] for message in ring_messages}, {1})
        finally:
            fake.close()

    def test_ambiguous_device_capability_fails_closed(self) -> None:
        fake = FakeDevice(size=[0, 0])
        try:
            with tempfile.TemporaryDirectory() as temporary_directory:
                session = osc.InteractiveSession(
                    [osc.Device("m-test-unknown", "monome unknown", fake.port)],
                    Path(temporary_directory) / "events.jsonl",
                )
                with self.assertRaisesRegex(
                    RuntimeError, "unsupported or ambiguous capability"
                ):
                    session.configure()
                session.close()

            paths = [message[0] for message in fake.received]
            self.assertEqual(paths, ["/sys/info"])
        finally:
            fake.close()

    def test_partial_configuration_failure_restores_first_device(self) -> None:
        first = FakeDevice()
        incomplete = FakeDevice(complete_info=False)
        try:
            with tempfile.TemporaryDirectory() as temporary_directory:
                session = osc.InteractiveSession(
                    [
                        osc.Device("m-test-1", "monome 128", first.port),
                        osc.Device("m-test-2", "monome arc", incomplete.port),
                    ],
                    Path(temporary_directory) / "events.jsonl",
                )
                with self.assertRaisesRegex(RuntimeError, "complete /sys/info"):
                    session.run()
                wait_for(
                    lambda: first.state["host"] == "127.0.0.1"
                    and first.state["port"] == 9000
                    and first.state["prefix"] == "/monome"
                )
                self.assertTrue(session.closed)
        finally:
            first.close()
            incomplete.close()


class PortTests(unittest.TestCase):
    def test_reports_bound_and_released_udp_port(self) -> None:
        holder = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        holder.bind(("127.0.0.1", 0))
        port = holder.getsockname()[1]
        self.assertEqual(osc.port_is_free(port, "127.0.0.1"), (False, "in-use"))
        holder.close()
        self.assertEqual(osc.port_is_free(port, "127.0.0.1"), (True, "free"))


if __name__ == "__main__":
    unittest.main()
