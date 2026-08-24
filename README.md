# SerialOSC for Steam Deck

This repository provides a rootless SerialOSC build and user-service workflow for x86-64 Steam Decks.

It does **not** disable SteamOS read-only mode, use `pacman`, write to `/usr` or `/etc`, install a per-device system service, or force kernel modules. SerialOSC runs as one user-level supervisor and launches its detector and device workers itself.

The pinned upstream source is SerialOSC 1.4.7 at commit `94d457f80fe3721d21df5190c99bd522c711185a`.

## Where commands run

Run every command in this README on the **SteamOS host** from Konsole in Desktop Mode (normally a `deck@steamdeck` prompt). Do not enter `chatgpt-debian` or another application container first. If the prompt shows a container name, run `exit` until it returns to the SteamOS host.

The build script creates and enters its own `serialosc-build` container automatically. Git, Distrobox, and an internet connection are required for the first build.

## Install from this repository

Run:

```bash
git clone https://github.com/kasselvania/serialOSC-steam-deck.git
cd serialOSC-steam-deck
./install.sh
```

`install.sh` builds SerialOSC in a dedicated Debian 12 Distrobox and installs only these user-owned files:

```text
~/.local/libexec/serialosc/serialoscd
~/.local/libexec/serialosc/serialosc-detector
~/.local/libexec/serialosc/serialosc-device
~/.config/systemd/user/serialoscd.service
~/.local/bin/serialosc-doctor
~/.local/bin/serialosc-hardware-test
~/.local/bin/serialosc-uninstall
~/.local/libexec/serialosc-tests/osc_workbench.py
```

The first build downloads a Debian container and build dependencies. OS packages remain inside `serialosc-build`; CMake tooling and build output remain under the repository's ignored `build/` directory. SteamOS itself stays read-only.

## Verify

```bash
serialosc-doctor
```

With a Monome connected, the report should show its `/dev/serial/by-id/...` path, read/write access, one `serialoscd` supervisor, one detector, and one device worker.

SerialOSC listens for discovery on UDP port 12002. Each connected device receives its own UDP port and is advertised as `_monome-osc._udp` through Zeroconf.

Hardware validation covers a legacy Monome 128 connected both directly and through a USB dock. The dock changes the physical USB route, but SerialOSC follows the device's stable serial identity rather than a hardcoded port. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the exact validation boundary.

## Physical hardware workbench

The repository includes a host-side, dependency-free OSC workbench for repeatable hotplug, multi-device, input/output, UDP release/conflict, dock, suspend, reboot, and post-update tests. It records machine evidence while keeping physical observations explicit.

With every Monome unplugged, start a session on the SteamOS host:

```bash
serialosc-hardware-test begin post-update-matrix
```

The command refuses to begin unless SteamOS is read-only, the exact validated binaries and user service are healthy, legacy services are not active, and no device is already under test. See [docs/HARDWARE_TESTS.md](docs/HARDWARE_TESTS.md) for the device matrix and controlled procedures.

## Remove

```bash
serialosc-uninstall
```

The uninstaller preserves device preferences under `~/.config/serialosc`. Use `serialosc-uninstall --purge-config` only when those preferences should also be removed.

## Existing legacy installation

If `install.sh` detects the former `~/.config/systemd/user/serialosc.service`, it stops without overwriting it. Preserve and disable that file first:

```bash
./migrate-legacy-user-service.sh
```

Old system-level units under `/etc/systemd/system` are reported but never changed by the rootless installer. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the exact legacy findings and cleanup boundary.

If the former installer enabled its two known system services, preserve any customized unit files and disable the obsolete boot entries before installing:

```bash
sudo systemctl disable --now serialosc.service serialoscd@ttyUSB0.service
```

That command does not delete the old unit files. `serialosc-doctor` continues to report them so they cannot be mistaken for part of the rootless installation.

## Build a distributable archive

```bash
./build.sh
```

The archive and checksum are written under `dist/`. The archive includes the pinned source (including submodules), build receipt, licenses, binaries, service, installer, uninstaller, diagnostics, and hardware workbench.

Verify the outer archive checksum from the repository root with:

```bash
(cd dist && sha256sum -c serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256)
```

## PlugData object

[`monome-object.pd`](monome-object.pd) remains available as an optional PlugData integration. It is not part of the SerialOSC daemon lifecycle and is not installed automatically.
