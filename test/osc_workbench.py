#!/usr/bin/env python3
"""Dependency-free OSC tooling for the SerialOSC physical test workbench."""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import select
import shlex
import signal
import socket
import struct
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


SUPERVISOR_HOST = "127.0.0.1"
SUPERVISOR_PORT = 12002


def _padded_string(value: str) -> bytes:
    raw = value.encode("utf-8") + b"\0"
    return raw + (b"\0" * ((-len(raw)) % 4))


def encode_message(path: str, types: str = "", args: Iterable[Any] = ()) -> bytes:
    values = list(args)
    if not path.startswith("/"):
        raise ValueError("OSC paths must start with /")
    if len(types) != len(values):
        raise ValueError("OSC typetag and argument counts differ")

    payload = bytearray(_padded_string(path))
    payload.extend(_padded_string("," + types))
    for tag, value in zip(types, values):
        if tag == "i":
            payload.extend(struct.pack(">i", int(value)))
        elif tag == "s":
            payload.extend(_padded_string(str(value)))
        elif tag == "f":
            payload.extend(struct.pack(">f", float(value)))
        else:
            raise ValueError(f"unsupported OSC typetag: {tag}")
    return bytes(payload)


def _read_string(payload: bytes, offset: int) -> tuple[str, int]:
    end = payload.find(b"\0", offset)
    if end < 0:
        raise ValueError("unterminated OSC string")
    value = payload[offset:end].decode("utf-8", errors="replace")
    return value, (end + 4) & ~3


def decode_message(payload: bytes) -> tuple[str, str, list[Any]]:
    path, offset = _read_string(payload, 0)
    tags, offset = _read_string(payload, offset)
    if not tags.startswith(","):
        raise ValueError("OSC typetag string is missing its comma")

    values: list[Any] = []
    for tag in tags[1:]:
        if tag == "i":
            if offset + 4 > len(payload):
                raise ValueError("truncated OSC int32")
            values.append(struct.unpack_from(">i", payload, offset)[0])
            offset += 4
        elif tag == "f":
            if offset + 4 > len(payload):
                raise ValueError("truncated OSC float32")
            values.append(struct.unpack_from(">f", payload, offset)[0])
            offset += 4
        elif tag == "s":
            value, offset = _read_string(payload, offset)
            values.append(value)
        else:
            raise ValueError(f"unsupported OSC typetag: {tag}")
    return path, tags[1:], values


def send_message(
    destination_host: str,
    destination_port: int,
    path: str,
    types: str = "",
    args: Iterable[Any] = (),
    source: socket.socket | None = None,
) -> None:
    packet = encode_message(path, types, args)
    if source is not None:
        source.sendto(packet, (destination_host, destination_port))
        return
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(packet, (destination_host, destination_port))


@dataclass(frozen=True)
class Device:
    serial: str
    name: str
    port: int


def _receive_until(
    sock: socket.socket, deadline: float, quiet_period: float = 0.2
) -> list[tuple[str, str, list[Any], tuple[str, int]]]:
    messages: list[tuple[str, str, list[Any], tuple[str, int]]] = []
    last_message: float | None = None
    while True:
        now = time.monotonic()
        if now >= deadline:
            break
        if last_message is not None and now - last_message >= quiet_period:
            break
        timeout = min(0.1, deadline - now)
        readable, _, _ = select.select([sock], [], [], timeout)
        if not readable:
            continue
        packet, peer = sock.recvfrom(65535)
        try:
            path, types, args = decode_message(packet)
        except ValueError:
            continue
        messages.append((path, types, args, peer))
        last_message = time.monotonic()
    return messages


def discover(
    supervisor_host: str = SUPERVISOR_HOST,
    supervisor_port: int = SUPERVISOR_PORT,
    timeout: float = 1.5,
) -> list[Device]:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((SUPERVISOR_HOST, 0))
        callback_port = sock.getsockname()[1]
        send_message(
            supervisor_host,
            supervisor_port,
            "/serialosc/list",
            "si",
            (SUPERVISOR_HOST, callback_port),
            source=sock,
        )
        messages = _receive_until(sock, time.monotonic() + timeout)

    devices: dict[tuple[str, int], Device] = {}
    for path, types, args, _peer in messages:
        if path != "/serialosc/device" or types != "ssi" or len(args) != 3:
            continue
        device = Device(str(args[0]), str(args[1]), int(args[2]))
        devices[(device.serial, device.port)] = device
    return sorted(devices.values(), key=lambda item: (item.serial, item.port))


INFO_PATHS = {
    "/sys/id": "id",
    "/sys/size": "size",
    "/sys/host": "host",
    "/sys/port": "port",
    "/sys/prefix": "prefix",
    "/sys/rotation": "rotation",
}


def query_info(
    device_port: int,
    device_host: str = SUPERVISOR_HOST,
    timeout: float = 1.5,
) -> dict[str, Any]:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((SUPERVISOR_HOST, 0))
        callback_port = sock.getsockname()[1]
        send_message(
            device_host,
            device_port,
            "/sys/info",
            "si",
            (SUPERVISOR_HOST, callback_port),
            source=sock,
        )
        messages = _receive_until(sock, time.monotonic() + timeout)

    info: dict[str, Any] = {}
    for path, _types, args, _peer in messages:
        key = INFO_PATHS.get(path)
        if key is None:
            continue
        info[key] = args if key == "size" else (args[0] if args else None)
    return info


def port_is_free(port: int, host: str = "0.0.0.0") -> tuple[bool, str]:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.bind((host, port))
        except OSError as exc:
            if exc.errno == errno.EADDRINUSE:
                return False, "in-use"
            return False, f"error:{exc.errno}:{exc.strerror}"
    return True, "free"


class EvidenceLog:
    def __init__(self, path: Path | None):
        self.path = path
        self.handle = None
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            self.handle = path.open("a", encoding="utf-8")

    def write(self, kind: str, **fields: Any) -> None:
        record = {
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "monotonic": time.monotonic(),
            "kind": kind,
            **fields,
        }
        if self.handle is not None:
            self.handle.write(json.dumps(record, sort_keys=True) + "\n")
            self.handle.flush()

    def close(self) -> None:
        if self.handle is not None:
            self.handle.close()


@dataclass
class SessionDevice:
    device: Device
    original: dict[str, Any]
    prefix: str


class InteractiveSession:
    def __init__(self, devices: list[Device], evidence: Path | None):
        self.devices = devices
        self.log = EvidenceLog(evidence)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((SUPERVISOR_HOST, 0))
        self.callback_port = self.sock.getsockname()[1]
        self.session_devices: list[SessionDevice] = []
        self.running = True
        self.closed = False

    def _send(self, device: Device, path: str, types: str = "", args: Iterable[Any] = ()) -> None:
        values = list(args)
        send_message(SUPERVISOR_HOST, device.port, path, types, values, self.sock)
        self.log.write(
            "send", serial=device.serial, device_port=device.port,
            path=path, types=types, args=values,
        )

    @staticmethod
    def _safe_prefix(serial: str) -> str:
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", serial)
        return f"/workbench/{safe}"

    def configure(self) -> None:
        for device in self.devices:
            original = query_info(device.port)
            required = {"id", "size", "host", "port", "prefix", "rotation"}
            missing = sorted(required.difference(original))
            if missing:
                raise RuntimeError(
                    f"{device.serial} did not provide complete /sys/info: {', '.join(missing)}"
                )
            prefix = self._safe_prefix(device.serial)
            session_device = SessionDevice(device, original, prefix)
            self.session_devices.append(session_device)
            self.log.write(
                "device-original", device=asdict(device), original=original, prefix=prefix
            )
            self._send(device, "/sys/host", "s", (SUPERVISOR_HOST,))
            self._send(device, "/sys/port", "i", (self.callback_port,))
            self._send(device, "/sys/prefix", "s", (prefix,))

    def resolve(self, selector: str) -> SessionDevice:
        if selector.isdigit():
            index = int(selector)
            if 0 <= index < len(self.session_devices):
                return self.session_devices[index]
        matches = [item for item in self.session_devices if item.device.serial == selector]
        if len(matches) != 1:
            raise ValueError(f"unknown device selector: {selector}")
        return matches[0]

    def grid(self, selector: str, state: str) -> None:
        item = self.resolve(selector)
        value = {"on": 1, "off": 0}.get(state)
        if value is None:
            raise ValueError("grid state must be on or off")
        self._send(item.device, f"{item.prefix}/grid/led/all", "i", (value,))

    def ring(self, selector: str, ring: str, state: str) -> None:
        item = self.resolve(selector)
        value = {"on": 15, "off": 0}.get(state)
        if value is None:
            raise ValueError("ring state must be on or off")
        ring_number = int(ring)
        if not 0 <= ring_number <= 3:
            raise ValueError("ring number must be between 0 and 3")
        self._send(item.device, f"{item.prefix}/ring/all", "ii", (ring_number, value))

    def all_off(self) -> None:
        for item in self.session_devices:
            self._send(item.device, f"{item.prefix}/grid/led/all", "i", (0,))
            for ring_number in range(4):
                self._send(
                    item.device, f"{item.prefix}/ring/all", "ii", (ring_number, 0)
                )

    def restore(self) -> bool:
        restored = True
        try:
            self.all_off()
        except OSError as exc:
            self.log.write("cleanup-warning", error=str(exc))
            restored = False
        for item in reversed(self.session_devices):
            original = item.original
            try:
                self._send(item.device, "/sys/prefix", "s", (original["prefix"],))
                self._send(item.device, "/sys/host", "s", (original["host"],))
                self._send(item.device, "/sys/port", "i", (int(original["port"]),))
                time.sleep(0.05)
                current = query_info(item.device.port, timeout=0.5)
                expected = {
                    "prefix": original["prefix"],
                    "host": original["host"],
                    "port": int(original["port"]),
                }
                observed = {key: current.get(key) for key in expected}
                if observed != expected:
                    restored = False
                    self.log.write(
                        "restore-unverified",
                        serial=item.device.serial,
                        expected=expected,
                        observed=observed,
                    )
                else:
                    self.log.write("device-restored", serial=item.device.serial)
            except OSError as exc:
                restored = False
                self.log.write(
                    "restore-failed", serial=item.device.serial, error=str(exc)
                )
        return restored

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.log.close()
        self.sock.close()

    def print_devices(self) -> None:
        for index, item in enumerate(self.session_devices):
            size = item.original.get("size", ["?", "?"])
            print(
                f"DEVICE {index}: serial={item.device.serial} name={item.device.name!r} "
                f"server_port={item.device.port} size={size[0]}x{size[1]} "
                f"test_prefix={item.prefix}",
                flush=True,
            )

    @staticmethod
    def print_help() -> None:
        print("Commands:", flush=True)
        print("  devices", flush=True)
        print("  grid <index-or-serial> <on|off>", flush=True)
        print("  ring <index-or-serial> <ring-number> <on|off>", flush=True)
        print("  all-off", flush=True)
        print("  quit", flush=True)

    def _handle_command(self, line: str) -> None:
        words = shlex.split(line)
        if not words:
            return
        command = words[0]
        if command in {"help", "?"} and len(words) == 1:
            self.print_help()
        elif command == "devices" and len(words) == 1:
            self.print_devices()
        elif command == "grid" and len(words) == 3:
            self.grid(words[1], words[2])
        elif command == "ring" and len(words) == 4:
            self.ring(words[1], words[2], words[3])
        elif command == "all-off" and len(words) == 1:
            self.all_off()
        elif command in {"quit", "exit"} and len(words) == 1:
            self.running = False
        else:
            raise ValueError("invalid command; enter 'help' for syntax")

    def _handle_packet(self) -> None:
        packet, peer = self.sock.recvfrom(65535)
        try:
            path, types, args = decode_message(packet)
        except ValueError as exc:
            self.log.write("decode-error", peer=list(peer), error=str(exc))
            return
        serial = next(
            (
                item.device.serial
                for item in self.session_devices
                if item.device.port == peer[1]
            ),
            "unknown",
        )
        self.log.write(
            "receive", serial=serial, peer=list(peer), path=path, types=types, args=args
        )
        if any(token in path for token in ("/grid/key", "/enc/delta", "/enc/key", "/tilt")):
            print(f"EVENT {serial} {path} {types} {json.dumps(args)}", flush=True)

    def run(self) -> None:
        cleanup_ok = True
        try:
            self.configure()
            self.log.write(
                "session-ready",
                callback_port=self.callback_port,
                devices=[asdict(item.device) for item in self.session_devices],
            )
            print(f"READY callback_port={self.callback_port}", flush=True)
            self.print_devices()
            self.print_help()
            while self.running:
                readable, _, _ = select.select([self.sock, sys.stdin], [], [], 0.25)
                for source in readable:
                    if source is self.sock:
                        self._handle_packet()
                    else:
                        line = sys.stdin.readline()
                        if not line:
                            self.running = False
                            break
                        try:
                            self._handle_command(line)
                        except (ValueError, OSError) as exc:
                            print(f"ERROR {exc}", flush=True)
        finally:
            # configure() appends a device before changing it, so this also
            # restores devices after a partial configuration failure.
            cleanup_ok = self.restore()
            self.log.write("session-finished")
            self.close()
        if not cleanup_ok:
            raise RuntimeError(
                "device setting restoration could not be verified; inspect the evidence log"
            )


def _coerce_cli_arg(tag: str, value: str) -> Any:
    if tag == "i":
        return int(value)
    if tag == "f":
        return float(value)
    if tag == "s":
        return value
    raise ValueError(f"unsupported OSC typetag: {tag}")


def _print_json(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--supervisor-host", default=SUPERVISOR_HOST)
    parser.add_argument("--supervisor-port", type=int, default=SUPERVISOR_PORT)
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover_parser = subparsers.add_parser("discover")
    discover_parser.add_argument("--timeout", type=float, default=1.5)
    discover_parser.add_argument(
        "--format", choices=("json", "tsv", "count"), default="json"
    )

    info_parser = subparsers.add_parser("info")
    info_parser.add_argument("--device-host", default=SUPERVISOR_HOST)
    info_parser.add_argument("--device-port", type=int, required=True)
    info_parser.add_argument("--timeout", type=float, default=1.5)

    send_parser = subparsers.add_parser("send")
    send_parser.add_argument("--device-host", default=SUPERVISOR_HOST)
    send_parser.add_argument("--device-port", type=int, required=True)
    send_parser.add_argument("--path", required=True)
    send_parser.add_argument("--types", default="")
    send_parser.add_argument("args", nargs="*")

    port_parser = subparsers.add_parser("port-status")
    port_parser.add_argument("--host", default="0.0.0.0")
    port_parser.add_argument("--port", type=int, required=True)

    hold_parser = subparsers.add_parser("hold-port")
    hold_parser.add_argument("--host", default="0.0.0.0")
    hold_parser.add_argument("--port", type=int, required=True)

    tty_parser = subparsers.add_parser("tty-open")
    tty_parser.add_argument("--path", required=True)

    session_parser = subparsers.add_parser("session")
    session_parser.add_argument("--evidence", type=Path)
    session_parser.add_argument("--timeout", type=float, default=1.5)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "discover":
        devices = discover(args.supervisor_host, args.supervisor_port, args.timeout)
        if args.format == "json":
            _print_json([asdict(device) for device in devices])
        elif args.format == "tsv":
            for device in devices:
                print(f"{device.serial}\t{device.name}\t{device.port}")
        else:
            print(len(devices))
        return 0

    if args.command == "info":
        _print_json(query_info(args.device_port, args.device_host, args.timeout))
        return 0

    if args.command == "send":
        if len(args.types) != len(args.args):
            raise SystemExit("typetag and argument counts differ")
        values = [_coerce_cli_arg(tag, value) for tag, value in zip(args.types, args.args)]
        send_message(args.device_host, args.device_port, args.path, args.types, values)
        return 0

    if args.command == "port-status":
        free, status = port_is_free(args.port, args.host)
        print(status)
        return 0 if free else 1

    if args.command == "hold-port":
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.bind((args.host, args.port))
        except OSError as exc:
            sock.close()
            print(f"ERROR could not hold {args.host}:{args.port}: {exc}", file=sys.stderr)
            return 1
        print(f"HELD {args.host}:{args.port}; press Ctrl-C to release", flush=True)
        try:
            signal.pause()
        except KeyboardInterrupt:
            pass
        finally:
            sock.close()
        print("RELEASED", flush=True)
        return 0

    if args.command == "tty-open":
        flags = os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK
        try:
            descriptor = os.open(args.path, flags)
        except OSError as exc:
            print(f"open-failed:{exc.errno}:{exc.strerror}")
            return 1
        os.close(descriptor)
        print("open-succeeded-without-read-write-or-termios-change")
        return 0

    if args.command == "session":
        devices = discover(args.supervisor_host, args.supervisor_port, args.timeout)
        if not devices:
            print("ERROR no SerialOSC-managed devices discovered", file=sys.stderr)
            return 2
        session = InteractiveSession(devices, args.evidence)
        try:
            session.run()
        except KeyboardInterrupt:
            print(
                "INTERRUPTED; cleanup attempted—inspect evidence if a device was unplugged",
                file=sys.stderr,
            )
            return 130
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"ERROR {exc}", file=sys.stderr)
            return 2
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
