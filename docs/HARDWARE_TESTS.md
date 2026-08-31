# Physical hardware test workbench

This protocol validates the installed, rootless SerialOSC service without changing SteamOS system files. Run every command on the **SteamOS host** in Desktop Mode or over SSH. Do not enter an application or build Distrobox first.

The current target is the `lease-candidate` build at SerialOSC revision `7187832`. The older 1.4.7 package remains the accepted rollback baseline. Evidence from that older build is useful regression context but is not acceptance of the candidate's x86-64 bytes.

The workbench records machine evidence automatically. Physical facts such as LEDs, key presses, encoder motion, cable removal, dock use, and audio cues still require a human observation; record them with `~/.local/bin/serialosc-hardware-test note`. The explicit path also works in SSH shells where `~/.local/bin` is not on `PATH`.

## What the resources actually are

The pinned SerialOSC source establishes four separate resources:

1. `serialoscd` owns the supervisor discovery socket on UDP/12002.
2. Each detected device gets one `serialosc-device` worker and one device-server UDP port. Its clean exit saves that port under `~/.config/serialosc`; a later connection tries to reuse it.
3. A client supplies its own OSC callback UDP port through `/sys/host` and `/sys/port`.
4. The device worker opens the serial tty with `O_RDWR | O_NOCTTY | O_NONBLOCK`.

SerialOSC does **not** request `TIOCEXCL`, `flock`, or a lockfile for the tty. A second tty open is therefore a characterization test, not an assertion that the kernel must reject it. The workbench's `tty-open` command performs no reads, writes, or termios changes.

The per-device UDP port has a different contract. If its saved port is already bound, that worker exits before it is ready. The supervisor does not automatically respawn that failed worker while the same USB add remains current. Recovery requires a fresh remove/add event (unplug/replug) or a supervisor restart. The conflict test below verifies that behavior without altering the OS.

## Start and evidence

Start with every Monome device unplugged:

```bash
~/.local/bin/serialosc-hardware-test begin post-update-matrix
```

`begin` fails closed unless all of these are true:

- SteamOS read-only mode is enabled;
- the user service is active and enabled;
- the installed version matches its exact build receipt;
- all installed binaries match that built package's checksum manifest;
- the active user service matches the packaged unit;
- UDP/12002 is listening;
- known legacy services are inactive and disabled;
- no device worker or OSC-managed device is already present.

Evidence is stored under:

```text
~/.local/state/serialosc-steamos/hardware-tests/<UTC-session>/
```

Each snapshot includes OS and boot identity, installed hashes, service state, process and socket state, USB topology, tty identity/properties/ACL/owners, saved device configuration, Zeroconf advertisements, recent journal entries, doctor output, and `/serialosc/list` results.

Useful commands during a session are:

```bash
~/.local/bin/serialosc-hardware-test status
~/.local/bin/serialosc-hardware-test snapshot LABEL
~/.local/bin/serialosc-hardware-test note TEXT...
~/.local/bin/serialosc-hardware-test discover
~/.local/bin/serialosc-hardware-test info DEVICE_UDP_PORT
~/.local/bin/serialosc-hardware-test session
~/.local/bin/serialosc-hardware-test finish
```

The interactive OSC session discovers all SerialOSC-managed devices, saves each device's original callback and prefix, gives it a session-specific prefix, and prints key/encoder events. This is the traditional-client compatibility lane: it deliberately uses existing `/sys/*` messages, not leases. Its commands are:

```text
devices
grid <index-or-serial> <on|off>
ring <index-or-serial> <ring-number> <on|off>
all-off
quit
```

The session classifies a device as a grid only when `/sys/size` reports two positive dimensions, or as an arc when SerialOSC's advertised device name contains `arc`. An ambiguous device stops configuration. `grid` refuses arc targets, `ring` refuses grid targets, and `all-off` sends only the output family valid for each device. For arcs, cleanup turns off only ring numbers explicitly addressed during that session; it does not assume two-ring or four-ring hardware. This boundary is safety-critical: during physical testing, sending arc ring commands to a legacy grid left key input working while LED output stopped until subsequent restoration traffic recovered it. Cross-capability serial output is therefore never a valid probe.

Normal exit, EOF, Ctrl-C, and partial configuration failure all run cleanup. Cleanup turns test lights off and restores every device's original OSC host, port, and prefix.

## Lease-specific acceptance lanes

The traditional OSC session above cannot prove lease behavior. Candidate acceptance adds three distinct lanes after ordinary discovery and compatibility pass:

1. **Protocol lane:** query `/sys/lease/info`, acquire or explicitly take over with a unique token, verify the exact grant/state readback, renew beyond the initial TTL, darken and release, and independently verify `free` with port `0`.
2. **Standalone PlugData lane:** use the lease-enabled workbench, verify device-specific output and input, orderly release, hot-unplug/reselect/reclaim, and abrupt PlugData process death followed by automatic darkness and free state.
3. **Bitwig host lane:** run the same workbench inside PlugData CLAP, verify isolation from a standalone owner, then kill the exact plug-in host while devices are leased. SerialOSC must expire each abandoned lease without being restarted.

The authoritative PlugData workbench for this candidate is the exact `PlugData-Monome-Devices` bundle associated with commit `898885cbc05ca218f23a3ed8f74fe14b9f215f6f`. Do not substitute the historical `monome-object.pd` retained in this repository. Every lane must record the SerialOSC build receipt and the PlugData workbench commit together.

The candidate policy is a 6000 ms TTL renewed every 2000 ms. A successful renewal may be intentionally quiet in the PlugData console. Evidence comes from state readback, continued operation beyond the first TTL, daemon transition logs, orderly release, and expiry—not from console spam.

## Device matrix

Run the single-device rows before combinations. Do not infer support for a later row from an earlier one.

| Case | Connected hardware | Required functional observations |
|---|---|---|
| S1 | Legacy FTDI Monome 128 only | Stable serial identity; one worker and device port; independent grid light command; key press and release events; clean removal and replug |
| S2 | Pico-based 256 “Zero” in OSC mode only | First characterize USB, tty, OSC discovery, and Zeroconf path; if SerialOSC-managed, test grid light and key events; otherwise record the boundary and stop rather than claiming SerialOSC support |
| S3 | Arc only | Stable serial identity; one worker and device port; independent ring command; encoder delta; encoder key events only when the hardware has switches; clean removal and replug |
| M1 | Legacy 128 + Zero | Unique identities and ports; independent lights/events; removing either leaves the other functional |
| M2 | Legacy 128 + Arc | Unique identities and ports; grid and ring outputs remain isolated; removing either leaves the other functional |
| M3 | Zero + Arc | Unique identities and ports if both are SerialOSC-managed; independent events/removal |
| M4 | Legacy 128 + Zero + Arc | Three identities and ports if all are managed; independent output/input; each of three removal orders affects only the removed device |

The Zero's path is intentionally empirical. “Pico-based” and “OSC mode” do not by themselves prove that it should appear as a SerialOSC serial device. The baseline snapshot captures both USB/udev and Zeroconf evidence so its real boundary can be classified before changing software.

For each matrix row:

1. Capture a pre-plug snapshot.
2. Plug only the listed devices and wait for enumeration.
3. Capture a post-plug snapshot and inspect `discover` plus each device's `info`.
4. Run one interactive OSC session. Address each device separately; verify its output and at least one physical input event. Enter `quit` and wait for verified settings restoration **before unplugging anything**.
5. Unplug one device. Capture a snapshot and verify only that worker, advertisement, and device port disappear while every remaining device still responds.
6. Verify the removed worker's UDP port is free, then replug it and verify normal recovery. A cleanly saved port should be reused when available.
7. Turn all test output off and record the human observations.

A row passes only when the machine evidence and the physical observations agree. USB enumeration alone, LEDs alone, a Steam audio cue, or a process alone is not a functional pass.

## UDP bind and release test

Perform this only after one device has completed its normal single-device row. Let `P` be its reported device-server UDP port.

With the device connected:

```bash
~/.local/bin/serialosc-hardware-test port-status P
```

Expected: `in-use`. Unplug the device, wait for removal, snapshot, and repeat. Expected: `free`.

In a second host terminal, deliberately occupy the saved port:

```bash
~/.local/bin/serialosc-hardware-test hold-port P
```

While the holder is running, replug that one device and capture a snapshot. Expected source-derived behavior is:

- the detector observes the add;
- the worker cannot bind `P` and exits before advertising readiness;
- `/serialosc/list` does not falsely claim that worker is available;
- it does not silently choose a different port or retry in a loop.

Unplug the device, press Ctrl-C in the holder terminal, and verify `port-status P` reports `free`. Replug once more. The fresh add should start the worker normally on `P`.

## Serial tty second-open characterization

After the normal functional test, resolve the exact stable path from the snapshot, for example `/dev/serial/by-id/...`. With the worker active, run:

```bash
~/.local/bin/serialosc-hardware-test tty-open /dev/serial/by-id/EXACT_DEVICE
```

The command opens and immediately closes the tty without I/O or settings changes. Record whether it succeeds or fails. Success matches the current source's non-exclusive open behavior; failure requires inspecting ACL, driver, and owner evidence before drawing a conclusion. This command does not prove concurrent protocol use is safe.

## Update, dock, sleep, and reboot passes

These are separate lifecycle cases, not substitutes for the device matrix:

- **SteamOS update:** boot the updated OS, begin with no devices, and verify exact installed bytes plus service readiness before hotplug.
- **Dock routing:** repeat the relevant row through the dock and compare stable identity against the changed physical USB path.
- **Suspend/resume:** snapshot before suspend and after resume; verify service restart count, workers, ports, advertisements, and fresh physical events.
- **Cold reboot:** reboot with a declared device attachment state, then verify the enabled user service and enumerate from that exact state.

Finish only after the intended cases are complete:

```bash
~/.local/bin/serialosc-hardware-test finish
```

Finishing retains all evidence and removes only the active-session pointer.
