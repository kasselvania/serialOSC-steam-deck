# Troubleshooting

Start with:

```bash
serialosc-doctor
```

The doctor distinguishes hard failures from warnings and does not change the machine.

## Dolphin offers Launch or Open with Kate

Choose **Launch** for `install.sh`. The script verifies the package, opens Konsole, and waits for confirmation before installing. `Install SerialOSC.sh` remains an equivalent compatibility launcher.

If no Konsole window opens:

1. Confirm the file is named `install.sh` or `Install SerialOSC.sh`.
2. Re-extract the archive with Ark so executable permissions are preserved.
3. From Konsole, run:

   ```bash
   cd "/path/to/extracted-serialosc-steamos-folder"
   ./install.sh
   ```

Do not bypass a checksum or permission warning by copying scripts out of the package.

## install.sh says no built payload was found

You are in a source checkout, not an extracted release. `install.sh` is intentionally install-only and will never download or compile SerialOSC. Build first:

```bash
./build.sh
./install.sh
```

Or explicitly compose both jobs:

```bash
./build.sh --install
```

If you downloaded a release archive, make sure you extracted the whole folder rather than copying out only one script.

## The doctor warns that a lease candidate is installed

That warning is expected while testing the pinned `7187832` SteamOS build. It means the installed bytes have a verified build receipt but have not yet been promoted to an accepted SteamOS release. It is not a service failure. Do not remove the warning or relabel the package until the exact candidate completes the hardware and host-death matrix.

## Candidate installation failed and restored the old build

The installer stages the replacement before stopping the old service. If activation or installed-byte verification fails, it automatically restores the previous installation and service state. Inspect the failed candidate and rollback receipt under:

```text
~/.local/state/serialosc-steamos/rollback-*/
```

Retain that directory and the newest installer log for diagnosis. Do not delete the working rollback baseline while candidate acceptance is in progress.

## Installation failed

The complete log is retained even when the window closes:

```bash
ls -1t ~/.local/state/serialosc-steamos/install-*.log | head -n 1
```

Open the returned file in Kate or include it with a support report. A failure banner means the installation must not be treated as successful.

## A legacy service is active or enabled

Inspect the known old services:

```bash
systemctl status serialosc.service serialoscd@ttyUSB0.service
systemctl is-enabled serialosc.service serialoscd@ttyUSB0.service
```

After preserving any custom unit contents, disable their boot entries:

```bash
sudo systemctl disable --now serialosc.service serialoscd@ttyUSB0.service
sudo systemctl reset-failed serialosc.service
```

The new installer deliberately does not alter `/etc` itself.

## No device appears

Check for a stable serial identity:

```bash
ls -l /dev/serial/by-id/
```

Then rerun:

```bash
serialosc-doctor
```

An audio cue or cable insertion alone does not prove that USB enumeration completed. During validation, one dock port produced USB descriptor errors `-32` and `-71`; moving the cable to another dock port allowed normal enumeration. If no `usb-monome_*` identity appears, try another physical port or a direct connection before changing SerialOSC.

## A Pico Zero appears as iii rather than SerialOSC

The tested Pico-based Zero exposes different USB personalities. In its iii personality it presents serial plus MIDI/audio-compatible interfaces and is not a SerialOSC grid. On the tested device, holding grid key `(0,0)` while connecting USB selected its SerialOSC compatibility personality.

This gesture is evidence for that tested Zero firmware, not a universal instruction for every Monome-derived device. Confirm the device's own firmware documentation when identities differ.

## Discovery works but Zeroconf publication does not

SerialOSC's local OSC discovery port is UDP/12002. DNS-SD/Zeroconf publication additionally depends on the host's Avahi policy. A SteamOS configuration can allow local SerialOSC operation while refusing service publication.

This project verifies that `libdns_sd.so.1` is available but does not rewrite `/etc` to override Avahi policy. Treat successful UDP discovery and successful DNS-SD publication as separate claims.

## A dock resets another device

A dock can remove and re-enumerate an entire USB branch when a second device is inserted. SerialOSC follows stable serial identities and saved UDP ports, but it cannot prevent a physical dock reset. Verify surviving devices by identity and discovery rather than relying on tty numbers such as `/dev/ttyUSB0`.

## Collect support evidence

Run:

```bash
serialosc-doctor
systemctl --user status serialoscd.service --no-pager
journalctl --user -b -u serialoscd.service --no-pager
steamos-readonly status
```

Also retain the newest installer log. Do not post passwords, SSH keys, or unrelated environment output.

For controlled physical testing, follow [HARDWARE_TESTS.md](HARDWARE_TESTS.md). The workbench records machine evidence without converting user observations into automatic claims.
