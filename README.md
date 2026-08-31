# SerialOSC for Steam Deck

Rootless, click-to-install [SerialOSC](https://github.com/monome/serialosc) packaging for x86-64 Steam Decks.

[Latest accepted release](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest) · [Installation guide](docs/INSTALLATION.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Architecture](docs/ARCHITECTURE.md)

This development branch packages the opt-in leased-destination fork at exact revision `7187832c349202b1a94a9b10080ae57d40069946`. The lease protocol lets an aware client renew its ownership of a Grid or Arc callback. If the client or plug-in host dies, SerialOSC expires the lease, darkens that device, and frees its destination. Clients that never send `/sys/lease/*` retain the traditional SerialOSC behavior.

The fork has completed macOS standalone and Bitwig host-death acceptance. The exact x86-64 SteamOS candidate has also passed direct-protocol and complete single-device PlugData standalone slices for the legacy 128, Zero/256, and four-ring Arc, including hotplug and host death. It remains deliberately labeled `lease-candidate` until simultaneous operation, Bitwig, and the remaining Deck lifecycle matrix pass. The latest public release remains the previously accepted upstream SerialOSC 1.4.7 package.

## Script contract

The build and install jobs are intentionally separate:

| Command | Job |
|---|---|
| `./build.sh` | Build the pinned source, run its tests, and create a verified archive. It does not install. |
| `./install.sh` | Install an already-built payload. It never downloads source or invokes a compiler. |
| `./build.sh --install` | Build and test first, then run the installer only after success. |
| `Install SerialOSC.sh` | Compatibility-friendly clickable wrapper included in archives. |

This resolves the former ambiguity where `install.sh` could silently begin a build.

## Build the lease candidate on a Deck

Run these commands on the SteamOS host in Desktop Mode, not inside a ChatGPT or build container:

```bash
git clone https://github.com/kasselvania/serialOSC-steam-deck.git
cd serialOSC-steam-deck
git switch codex/lease-candidate-packaging
./build.sh
```

The build uses a dedicated rootless Debian 12 Distrobox. Build dependencies remain in that container; SteamOS remains read-only. The output is:

```text
dist/serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz
dist/serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz.sha256
```

Install the successfully built candidate with:

```bash
./install.sh
```

Or perform both explicit jobs in sequence:

```bash
./build.sh --install
```

The installer verifies the complete bundle before stopping the old user service. Replacement is transactional: if staging, activation, or post-install verification fails, it restores the previous user-owned installation and service state. A successful replacement retains the previous installation under `~/.local/state/serialosc-steamos/rollback-*` while the candidate is being accepted.

## Install a published archive

An accepted release archive contains prebuilt binaries, so ordinary users do not need Git, Distrobox, a compiler, CMake, `sudo`, `pacman`, an AUR helper, or disabled SteamOS read-only mode.

1. Download both archive and `.sha256` assets from the [latest accepted release](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest).
2. Verify and extract the archive.
3. Open its folder in Dolphin.
4. Double-click `install.sh` and choose **Launch**.
5. Press Enter in Konsole and wait for `INSTALLATION PASSED`.

`Install SerialOSC.sh` remains in the archive as a compatibility launcher for the earlier public instructions. Both clickable names reach the same verified installer.

## What it installs

Everything installed by the normal path is owned by the current user:

| Purpose | Location |
|---|---|
| Supervisor, device processes, and build receipt | `~/.local/libexec/serialosc/` |
| User service | `~/.config/systemd/user/serialoscd.service` |
| Diagnostics | `~/.local/bin/serialosc-doctor` |
| Physical test workbench | `~/.local/bin/serialosc-hardware-test` |
| Uninstaller | `~/.local/bin/serialosc-uninstall` |
| Installer logs and rollback snapshots | `~/.local/state/serialosc-steamos/` |

Run `~/.local/bin/serialosc-doctor` after installation. The explicit path works in Desktop Mode and over SSH even when `~/.local/bin` is not part of the shell's `PATH`. A candidate install is reported honestly as a candidate; that warning remains until the exact SteamOS bytes complete physical acceptance.

## Existing hardware evidence

The accepted 1.4.7 package was physically exercised through a USB dock with a legacy FTDI Monome 128, a Pico-based 16×16 Zero/256 in SerialOSC mode, a classic four-encoder Arc, device pairs, and all three devices concurrently. Testing covered discovery, independent output and input, saved-port reuse, port conflict and release, removal order, reconnect, dock resets, and survivor-device continuity.

That evidence does not automatically transfer to the new lease candidate. Its Deck acceptance must separately cover ordinary discovery, legacy-client compatibility, lease claim/renew/release/expiry, standalone PlugData, PlugData hosted in Bitwig, abrupt host death, hotplug, and multiple simultaneous devices. See [the validation boundary](docs/ARCHITECTURE.md) and [hardware protocol](docs/HARDWARE_TESTS.md).

On 2026-08-31, the pinned x86-64 candidate bytes passed the first bounded Deck
lease slices with legacy Grid `m1000853`: direct expiry and renew/release,
PlugData fail-closed startup, explicit claim and renewal, full-surface output,
exact top-left input, orderly dark release, automatic dark/free recovery after
abrupt PlugData death, fresh fail-closed restart plus explicit reclaim, and
active-lease unplug/reconnect with same-ID/same-port return as dark/free before
explicit reselection and reclaim. SteamOS remained read-only and
`serialoscd.service` did not restart. This is partial candidate evidence, not
release acceptance; the untested rows above remain required.

The isolated Pico Zero/256 then passed as USB `cafe:1110`, SerialOSC ID
`m2321590`, `monome zero`, 16 by 16, on saved device port `19536`. An unbound
saved legacy destination required explicit takeover; direct expiry and
renew/release visibly darkened and freed the device. PlugData then passed
fail-closed probe, explicit claim and renewal, full-surface output, exact
bottom-right press/release input, orderly release, automatic expiry after
abrupt host death, fresh fail-closed restart, and active-lease hotplug with
same-ID/same-port dark/free recovery before explicit reclaim. A repeated
fresh-callback trace recorded exactly one add and one remove. SerialOSC again
remained active with zero restarts.

The isolated classic four-ring Arc then passed as USB `0403:6001`, SerialOSC
ID `m1001113`, padded model `monome arc`, valid Arc size `0 0`, on
`/dev/ttyUSB0` and saved device port `11564`. An independently unbound legacy
destination at port `12289` required explicit takeover. A corrected direct
lease harness passed machine-observed expiry and a physically confirmed
full-brightness 12-second renew/release run. PlugData then passed dark/free
probe, explicit claim and renewal on callback `17782`, independent all-ring
and marker output, exact positive ring-`0` and negative ring-`3` encoder
deltas, orderly all-dark release, automatic dark/free expiry after abrupt
host death, fresh fail-closed restart, and active-lease hotplug with
same-ID/same-port dark/free recovery before explicit reclaim. A fresh
ephemeral monitor recorded exactly one remove and one add; SerialOSC remained
active with zero restarts.

## SteamOS safety boundary

This project does not:

- run `steamos-readonly disable`;
- install or upgrade host packages;
- write application files into `/usr`, `/usr/local`, or `/etc`;
- install udev rules or persistent kernel-module configuration;
- create one system service per serial port;
- silently replace an active legacy system service.

Known legacy services must be inactive and disabled. The installer changes only the current user's files and user service.

## Documentation

- [Installation, build/install split, and migration](docs/INSTALLATION.md)
- [Troubleshooting and support evidence](docs/TROUBLESHOOTING.md)
- [Architecture, exact source custody, and validation boundary](docs/ARCHITECTURE.md)
- [Physical hardware test workbench](docs/HARDWARE_TESTS.md)
- [Third-party source and license notice](docs/THIRD_PARTY_LICENSES.md)
- [Candidate release notes](docs/RELEASE_NOTES.md)

## Optional PlugData object

[`monome-object.pd`](monome-object.pd) is retained only as a historical optional integration. The current PlugData workbench lives in [PlugData-Monome-Devices](https://github.com/kasselvania/PlugData-Monome-Devices) and is not installed automatically by this service package.
