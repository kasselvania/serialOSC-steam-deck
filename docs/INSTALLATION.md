# Installation and migration

## Requirements

- An x86-64 Steam Deck running SteamOS.
- Desktop Mode with KDE Plasma, Dolphin, and Konsole for clickable installation.
- A normal `deck` user session with systemd user services.
- SteamOS read-only mode left enabled.

A published archive contains all three SerialOSC executables. Git, Distrobox, compilers, CMake, and development headers are required only to build from source.

## Build and install are separate jobs

The command names have one meaning each:

```text
build.sh             build, test, and package; never install
install.sh           verify and install built bytes; never build
build.sh --install   build and test, then install only after success
```

`Install SerialOSC.sh` is a compatibility-friendly click wrapper retained in archives. It delegates to the same `install.sh`; it is not a second installer.

## Build the lease candidate from source

Run on the SteamOS host in Desktop Mode:

```bash
git clone https://github.com/kasselvania/serialOSC-steam-deck.git
cd serialOSC-steam-deck
git switch codex/lease-candidate-packaging
./build.sh
```

The build creates or reuses the dedicated rootless `serialosc-build` Debian 12 Distrobox. It installs build-only dependencies inside that container, checks out the exact fork and submodule revisions from `package.env`, runs the SerialOSC lease tests in an assertion-enabled Debug build, creates the distributable binaries in a separate Release build, enforces the glibc compatibility ceiling, and produces:

```text
dist/serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz
dist/serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz.sha256
```

The build does not alter the running service. After it succeeds, install from the source checkout with:

```bash
./install.sh
```

The installer finds only the exact staged package for the pinned identity. Running `./install.sh` before a successful build fails with an instruction to build; it never starts a build itself.

To request both explicit jobs in one command:

```bash
./build.sh --install
```

`--install` is reached only after checkout verification, compilation, native lease tests, runtime-link inspection, package checksum generation, and internal bundle verification succeed.

## Install a published release archive

Download the archive and its matching `.sha256` file from the [latest accepted GitHub Release](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest). Place both in the same directory and verify the exact downloaded filename:

```bash
cd ~/Downloads
sha256sum --check serialosc-steamos-*.tar.gz.sha256
```

Then:

1. Extract the archive in Dolphin.
2. Open the extracted folder.
3. Double-click `install.sh`.
4. Choose **Launch** when Dolphin offers **Launch** or **Open with Kate**.
5. Read the Konsole summary and press Enter to continue.
6. Wait for `INSTALLATION PASSED`, then press Enter to close the window.

Users following the first release's instructions may instead double-click `Install SerialOSC.sh`. It is retained for compatibility and reaches the same verified path.

For command-line installation from an extracted archive:

```bash
./install.sh
```

A launch without a terminal is redirected to Konsole. Deliberate headless automation must opt in:

```bash
./install.sh --noninteractive
```

## Verification and rollback behavior

Before stopping the existing service, the installer:

1. verifies the complete archive manifest;
2. verifies the three executable checksums a second time;
3. checks the exact SerialOSC version and revision receipt;
4. resolves every host runtime library;
5. refuses conflicting legacy services; and
6. stages the complete new installation in the user's state directory.

It then preserves the old installation and managed files under:

```text
~/.local/state/serialosc-steamos/rollback-<UTC>-<PID>/
```

If replacement, service activation, or installed-byte verification fails, the installer automatically restores the old installation and its previous enabled/running state. A successful candidate install retains the rollback snapshot while physical acceptance is pending.

The full click-install log is retained at:

```text
~/.local/state/serialosc-steamos/install-YYYYMMDDTHHMMSSZ.log
```

## Verify the installed service

Run this on the SteamOS host, not inside a Distrobox container:

```bash
~/.local/bin/serialosc-doctor
```

The doctor verifies the installed binaries against their build receipt, compares the active user service to the packaged unit, reports the exact source revision and package channel, and checks UDP/12002. A `lease-candidate` warning is expected until the exact SteamOS build completes acceptance.

With no Monome connected, a no-device warning is expected. With a device connected, the report should show its stable `/dev/serial/by-id/...` identity, read/write access, and a running device worker.

## Existing legacy installation

The installer does not overwrite or silently adopt older services.

If this former user service exists:

```text
~/.config/systemd/user/serialosc.service
```

preserve and disable it with:

```bash
./migrate-legacy-user-service.sh
```

If either known system-level service is active or enabled, the installer stops. Preserve any customized unit files, then disable only their obsolete boot entries:

```bash
sudo systemctl disable --now serialosc.service serialoscd@ttyUSB0.service
sudo systemctl reset-failed serialosc.service
```

These commands do not delete the old unit files. The installer itself never writes to `/etc`.

## Remove

```bash
~/.local/bin/serialosc-uninstall
```

Device preferences under `~/.config/serialosc` are preserved by default. Remove them only when intentional:

```bash
~/.local/bin/serialosc-uninstall --purge-config
```

Hardware evidence, installer logs, and rollback snapshots remain under the user state directory so removal does not erase diagnostic or recovery evidence.
