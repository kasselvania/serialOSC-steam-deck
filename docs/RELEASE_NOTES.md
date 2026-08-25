# SerialOSC for Steam Deck v1.4.7-steamos.1

First public SteamOS release of the rootless SerialOSC workflow.

## Download

- `serialosc-steamos-v1.4.7-x86_64.tar.gz`
- `serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256`

Archive SHA-256:

```text
b317171096d54a81c583583002d58f74cabb41d8cabb9e6e726233d15d3f4df5
```

## Installation

Extract the archive in SteamOS Desktop Mode, double-click **Install SerialOSC.sh**, choose **Launch**, and press Enter in Konsole. The installer verifies every packaged file and retains a full log before reporting `INSTALLATION PASSED` or `INSTALLATION FAILED`.

## Included

- Upstream SerialOSC 1.4.7 at commit `94d457f80fe3721d21df5190c99bd522c711185a`.
- Three prebuilt x86-64 executables with pinned, physically validated hashes.
- Rootless `systemd --user` service.
- Click installer, command-line installer, doctor, uninstaller, and migration helper.
- Evidence-preserving OSC hardware workbench.
- Complete corresponding upstream source with populated submodules and third-party license texts.

## Physical acceptance

The exact release executables were exercised on SteamOS with a legacy FTDI Monome 128, a Pico-based 16×16 Zero/256 in SerialOSC mode, and a classic four-encoder Arc, including concurrent multi-device and port-lifecycle tests through a USB dock.

The final click path was accepted through Dolphin and Konsole. Package verification and the installed doctor reported zero failures; the rootless service was enabled and active with `NRestarts=0`; SteamOS read-only mode remained enabled.

## Safety boundary

- No `pacman`, AUR helper, host package upgrade, or read-only disable.
- No application installation into `/usr`, `/usr/local`, or `/etc`.
- No udev rule or persistent kernel configuration.
- Active or enabled legacy system services cause a hard preflight failure.
- Headless installation requires explicit `--noninteractive` intent.

## Known boundaries

- x86-64 SteamOS with KDE Plasma and Konsole is the supported click-install surface.
- SteamOS Avahi policy may prevent Zeroconf publication even when local OSC discovery and device operation work.
- A standalone clean-baseline Zero-plus-Arc pair was not separately run; that pair operated successfully as the survivors of the all-three-device test.
- The final click acceptance had no Monome attached; the exact installed executable hashes had already completed the physical hardware matrix.

Release source commit: `d49f1c3b3d8cc600898e020d6e3dea8e3ef9182e`.
