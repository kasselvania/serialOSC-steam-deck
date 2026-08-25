# SerialOSC for Steam Deck

Rootless, click-to-install [SerialOSC](https://github.com/monome/serialosc) packaging for x86-64 Steam Decks.

[Download the latest release](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest) · [Installation guide](docs/INSTALLATION.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Hardware evidence](docs/ARCHITECTURE.md#observed-hardware-proof)

This project packages unmodified SerialOSC 1.4.7 from upstream commit `94d457f80fe3721d21df5190c99bd522c711185a` with a SteamOS-safe installer, user-level service, diagnostics, and physical test tooling. It does not replace SteamOS packages or install a system daemon.

## Quick install

1. Download both release assets:
   - [`serialosc-steamos-v1.4.7-x86_64.tar.gz`](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest/download/serialosc-steamos-v1.4.7-x86_64.tar.gz)
   - [`serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256`](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest/download/serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256)
2. In Desktop Mode, open the archive in Dolphin and extract its folder.
3. Open the extracted folder and double-click **Install SerialOSC.sh**.
4. When Dolphin offers **Launch** or **Open with Kate**, choose **Launch**.
5. Press Enter in Konsole and wait for `INSTALLATION PASSED`.

The release contains prebuilt, hardware-validated binaries. A normal install does not need Git, Distrobox, a compiler, CMake, `sudo`, `pacman`, AUR tooling, or disabled SteamOS read-only mode.

For checksum verification, legacy-install migration, command-line installation, and removal, use the [complete installation guide](docs/INSTALLATION.md).

## What it installs

Everything installed by the normal path is owned by the current user:

| Purpose | Location |
|---|---|
| Supervisor and device processes | `~/.local/libexec/serialosc/` |
| User service | `~/.config/systemd/user/serialoscd.service` |
| Diagnostics | `~/.local/bin/serialosc-doctor` |
| Physical test workbench | `~/.local/bin/serialosc-hardware-test` |
| Uninstaller | `~/.local/bin/serialosc-uninstall` |
| Installer logs | `~/.local/state/serialosc-steamos/` |

The installer verifies every packaged file before changing user state. A graphical launch always opens an interactive Konsole; deliberate headless automation must opt in with `./install.sh --noninteractive`.

## Tested hardware

The exact release binaries were physically exercised through a USB dock with:

- a legacy FTDI Monome 128;
- a Pico-based 16×16 Zero/256 in SerialOSC compatibility mode;
- a classic four-encoder Arc;
- legacy+Zero and legacy+Arc pairs;
- Zero+Arc as the surviving pair after legacy-grid removal;
- all three devices concurrently.

Testing covered discovery, independent LED/ring output, key/encoder input, saved-port reuse, port conflict and release, removal order, reconnect, dock resets, and survivor-device continuity. The supervisor remained active with zero restarts. See the [architecture and validation boundary](docs/ARCHITECTURE.md) for the exact matrix, evidence, and untested cases.

## SteamOS safety boundary

This project deliberately does not:

- run `steamos-readonly disable`;
- install or upgrade host packages;
- write application files into `/usr`, `/usr/local`, or `/etc`;
- install udev rules or persistent kernel-module configuration;
- create one system service per serial port;
- silently replace an older SerialOSC installation.

Known legacy services must be inactive and disabled before installation. Their unit files may remain preserved for audit or rollback. SteamOS host policy can also prevent Zeroconf service publication; the project reports that boundary and does not rewrite `/etc` to bypass it.

## Documentation

- [Installation and migration](docs/INSTALLATION.md)
- [Troubleshooting and support evidence](docs/TROUBLESHOOTING.md)
- [Architecture, exact hardware proof, and known boundaries](docs/ARCHITECTURE.md)
- [Physical hardware test workbench](docs/HARDWARE_TESTS.md)
- [Third-party source and license notice](docs/THIRD_PARTY_LICENSES.md)
- [Current release notes](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest)

## Build from source

Development builds run inside a dedicated rootless Debian 12 Distrobox so build dependencies never become SteamOS host packages:

```bash
git clone https://github.com/kasselvania/serialOSC-steam-deck.git
cd serialOSC-steam-deck
./install.sh
```

The build pins upstream SerialOSC and every private dependency. A release build also refuses to package binaries whose hashes differ from the physically validated set. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full build boundary.

## Optional PlugData object

[`monome-object.pd`](monome-object.pd) is retained as an optional PlugData integration. It is not part of the SerialOSC service lifecycle and is not installed automatically.
