# Architecture and validation boundary

## Process model

SerialOSC is one supervisor, not one service per serial port:

```text
serialoscd
├── serialosc-detector
└── serialosc-device  (one worker per connected Monome)
```

The three executables must remain in the same directory because `serialoscd` resolves its helper paths relative to its own executable.

The rootless service therefore launches exactly one `serialoscd` from `~/.local/libexec/serialosc`. It does not use a templated `serialoscd@tty.service`.

## SteamOS boundary

SteamOS is an image-managed, read-only operating system. This project deliberately avoids:

- `steamos-readonly disable`
- `pacman`, AUR helpers, and host package upgrades
- `/usr`, `/usr/local`, and `/etc` installation
- persistent `modprobe` configuration
- hardcoded users or serial groups
- system-level daemon enablement

The Deck kernel normally loads `ftdi_sio` when an FTDI-backed Monome is connected. The desktop login session applies a `uaccess` ACL to the resulting tty. A udev rule is not installed unless separate device evidence proves it necessary.

## Build boundary

The build runs in a dedicated rootless Debian 12 Distrobox. Build-only OS packages remain in that container; CMake tooling and outputs remain in the repository's ignored `build/` directory.

Debian 12 is intentional: its older glibc produces artifacts whose highest required glibc symbol is 2.34, instead of the 2.38 requirement observed from a Debian 13 build. Private dependencies (`libuv`, `liblo`, `libmonome`, and `confuse`) are built from pinned upstream source. Runtime linkage remains limited to the host's stable `libc`, `libm`, and `libudev` interfaces. Zeroconf uses the host's DNS-SD compatibility library at runtime.

Because upstream links liblo statically, every generated distributable includes the complete corresponding SerialOSC source tree with populated submodules, the exact build script, and license texts.

## Legacy package verdict

The former ZIP is retained under `legacy/` for provenance only. It is not an installer.

Its principal defects were:

- it contained `serialoscd` but omitted `serialosc-detector` and `serialosc-device`;
- it installed a per-tty systemd template even though SerialOSC already supervises devices;
- it disabled SteamOS read-only mode and performed a host `pacman -Syu`;
- it mixed SerialOSC with unrelated virtual-MIDI module configuration;
- it hardcoded the `deck` user and `/usr/local` paths;
- it had no rollback, uninstall, artifact receipt, or failure-safe read-only restoration.

## Observed hardware proof

On 2026-08-21, a legacy Monome 128 was tested on SteamOS 3.7.20:

```text
USB vendor/product: 0403:6001
USB serial:          m1000853
driver:              ftdi_sio
device node:         /dev/ttyUSB0
desktop ACL:         deck:rw-
```

A source-identical v1.4.7 build from commit `94d457f` completed the following checks:

- detector enumerated the already-connected device;
- supervisor launched exactly one detector and one device worker;
- UDP/12002 discovery responded with `m1000853`, `monome 128`, and the assigned device port;
- `_monome-osc._udp` was advertised over IPv4, IPv6, and localhost;
- an OSC all-LEDs command lit the physical grid;
- physical key presses produced `/monome/grid/key x y 1` and release events;
- unplug removed only the device worker;
- device configuration was saved;
- replug reused the saved device port;
- supervisor shutdown left no orphan SerialOSC processes.

On 2026-08-22, the distributable's exact Debian 12-built binaries were installed and tested after a Steam Deck suspend/resume with the grid connected through a USB dock. The dock changed the physical route to `pci-0000:04:00.3-usb-0:1.1:1.0`, while the stable link remained `/dev/serial/by-id/usb-monome_monome_m1000853-if00-port0`.

That packaged-byte test confirmed:

- the enabled user service remained active across resume with zero service restarts;
- docked hotplug launched one device worker and opened `/dev/ttyUSB0` on device port 16874;
- `/serialosc/list` returned `m1000853`, `monome 128`, and port 16874;
- `/sys/info` returned the expected 16 by 8 size, identity, host, port, prefix, and rotation;
- Zeroconf advertised the device over docked IPv4, IPv6, and localhost interfaces;
- the all-LEDs command lit the physical grid, as observed by the user;
- two physical keys produced press and release pairs at `(4,5)` and `(6,5)`;
- the all-LEDs-off command was sent after the test;
- SteamOS read-only mode remained enabled.

On 2026-08-24, the same installed binary hashes were exercised after a SteamOS update with a legacy FTDI 128 and a Pico-based Zero connected simultaneously through the dock. The Zero's boot gesture changed its USB identity from the iii composite personality (`cafe:1101`, `iii_grid`, serial plus MIDI/audio interfaces) to its SerialOSC compatibility personality (`cafe:1110`, `grid`, serial `m2321590`). SerialOSC then reported it as `monome zero`, size 16 by 16, on its own saved device port.

The two-grid test exposed and corrected a workbench-only protocol error: cleanup had sent both grid and arc output commands to every device. The modern Zero tolerated the irrelevant ring messages, while the legacy grid continued to send keys but stopped accepting LED output under the test prefix. Direct LED output worked again under the restored `/monome` prefix. That observation is consistent with the cross-capability bytes disrupting the legacy device's command parser, but the firmware internals were not instrumented; the authoritative defect is that the harness sent an output family the target did not support. The workbench now classifies grid versus arc capability before changing settings, sends only the matching output family, refuses cross-capability commands, and fails closed for ambiguous devices. A repeated physical test independently lit each grid, rejected a ring command addressed to the legacy grid, restored both devices' original OSC settings, released the temporary callback port, and left both surfaces dark.

The installed binaries were byte-compared with the staged distributable before this test. Their validated SHA-256 receipts are:

```text
a97adf0fc430ddbd98bae7f1562408e5b5c048cd1b7a3a5efa07677d7c2dadea  serialoscd
5d7e47954bc1a40c06350f14c07b9d96a9b7b96357e24b9e15ba4c48c6541db3  serialosc-detector
5d2f0373541d3a182ef9c77484d6cd823047d0f9056f4d5209ce5f8b09dd5af4  serialosc-device
```

An archive claiming this hardware proof must carry these binary hashes in its internal `SHA256SUMS`.
