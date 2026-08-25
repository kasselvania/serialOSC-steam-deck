# Installation and migration

## Requirements

- An x86-64 Steam Deck running SteamOS.
- Desktop Mode with KDE Plasma, Dolphin, and Konsole.
- A normal `deck` user session with systemd user services.
- SteamOS read-only mode left enabled.

The downloaded release already contains the three required SerialOSC executables. Git, Distrobox, compilers, CMake, and development headers are not needed for a normal install.

## Install a release

Download these two files from the [latest GitHub Release](https://github.com/kasselvania/serialOSC-steam-deck/releases/latest):

```text
serialosc-steamos-v1.4.7-x86_64.tar.gz
serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256
```

To verify the outer download in Konsole, place both files in the same directory and run:

```bash
cd ~/Downloads
sha256sum --check serialosc-steamos-v1.4.7-x86_64.tar.gz.sha256
```

The expected result is:

```text
serialosc-steamos-v1.4.7-x86_64.tar.gz: OK
```

Then:

1. Open the archive in Dolphin and extract `serialosc-steamos-v1.4.7-x86_64`.
2. Open the extracted folder.
3. Double-click **Install SerialOSC.sh**.
4. Choose **Launch** when Dolphin offers **Launch** or **Open with Kate**.
5. Read the Konsole summary and press Enter to continue.
6. Wait for `INSTALLATION PASSED`, then press Enter to close the window.

The click path verifies the archive's internal `SHA256SUMS` before installation. Its full log is retained under:

```text
~/.local/state/serialosc-steamos/install-YYYYMMDDTHHMMSSZ.log
```

Re-running the same installer is supported and replaces the installed user-owned files with the verified release copies.

## Verify the installed service

Run this on the SteamOS host, not inside a Distrobox container:

```bash
serialosc-doctor
```

With no Monome connected, a no-device warning is expected. With a device connected, the report should show its stable `/dev/serial/by-id/...` identity, read/write access, and a running device worker.

The user service can be inspected directly with:

```bash
systemctl --user status serialoscd.service
```

## Existing legacy installation

The installer does not overwrite or silently adopt older services.

If this former user service exists:

```text
~/.config/systemd/user/serialosc.service
```

preserve and disable it with the included helper:

```bash
./migrate-legacy-user-service.sh
```

If either known system-level service is active or enabled, the installer stops. Preserve any customized unit files, then disable only their obsolete boot entries:

```bash
sudo systemctl disable --now serialosc.service serialoscd@ttyUSB0.service
sudo systemctl reset-failed serialosc.service
```

These commands do not delete the old unit files. The doctor continues to report preserved, disabled files as warnings so they cannot be mistaken for the rootless installation.

## Command-line and automated installation

From an interactive Konsole in an extracted release:

```bash
./install.sh
```

A no-terminal launch is redirected to the same click installer. Deliberate automation must state its intent:

```bash
./install.sh --noninteractive
```

Both paths enforce the same package checksum and legacy-service preflights.

## Build and install from source

Run all commands on the SteamOS host in Desktop Mode:

```bash
git clone https://github.com/kasselvania/serialOSC-steam-deck.git
cd serialOSC-steam-deck
./install.sh
```

The source path creates or reuses a dedicated `serialosc-build` Debian 12 Distrobox. Build-only packages and output remain in that container and the repository's ignored `build/` directory.

## Remove

```bash
serialosc-uninstall
```

Device preferences under `~/.config/serialosc` are preserved by default. Remove them only when intentional:

```bash
serialosc-uninstall --purge-config
```

The uninstaller removes the rootless user service and installed user-owned tools. It does not delete preserved legacy system unit files.
