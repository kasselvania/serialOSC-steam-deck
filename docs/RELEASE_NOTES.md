# SerialOSC for Steam Deck lease candidate 7187832

Status: development candidate. Do not publish this archive as the latest accepted release until the exact x86-64 binaries complete the SteamOS acceptance matrix.

## Candidate assets

- `serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz`
- `serialosc-steamos-v1.4.8-lease.7187832-x86_64.tar.gz.sha256`

Pinned Debian 12 x86-64 candidate executable hashes:

```text
cb43323035fbf7098fa3caa8a0f46ab191dac3925586478e653b7a63b40d969a  serialoscd
5d7e47954bc1a40c06350f14c07b9d96a9b7b96357e24b9e15ba4c48c6541db3  serialosc-detector
59ec189e4ed2573ffa7c44d7b06538a2a1bab87e61db0d7b5bda487a86e124b1  serialosc-device
```

These hashes establish candidate byte identity, not physical acceptance. The build refuses a different executable under the same package name. The final archive checksum is emitted beside each archive and is not embedded inside the archive itself.

## Source custody

- Fork: `https://github.com/kasselvania/serialosc.git`
- Exact revision: `7187832c349202b1a94a9b10080ae57d40069946`
- Reported version: `serialoscd 1.4.8 (7187832)`
- Base: upstream SerialOSC 1.4.7 commit `94d457f80fe3721d21df5190c99bd522c711185a`
- Full corresponding source and populated submodules included in the archive.

## Functional change

The fork adds an opt-in version-1 leased-destination protocol. A lease-aware client can acquire or explicitly take over a device callback, renew it for a bounded TTL, and release it. A killed client or plug-in host stops renewing; SerialOSC then expires that one lease, darkens the supported Grid or Arc surface, and clears the callback. Legacy clients that send no `/sys/lease/*` messages retain traditional behavior.

## Packaging change

- `build.sh` is build-only by default.
- `install.sh` is install-only and refuses a source checkout without built bytes.
- `build.sh --install` composes both jobs after the build and native tests pass.
- `Install SerialOSC.sh` remains a compatibility click wrapper.
- The installer stages and verifies the entire replacement before stopping the old service.
- A failed replacement automatically restores the previous installation and service state.
- A successful candidate install retains the previous installation in a timestamped rollback snapshot.
- Build receipt, package channel, exact source revision, and binary checksums remain installed for diagnostics and evidence capture.
- Source builds require a clean packaging Git checkout and record that exact packaging commit in the build receipt.

## Acceptance already completed

Revision `7187832` completed macOS Apple-silicon acceptance with a legacy 128 Grid, a Pico Zero/256 Grid, and a four-ring Arc. It covered standalone PlugData, simultaneous renewable leases, explicit release, hotplug, abrupt PlugData death, and abrupt Bitwig PlugData-CLAP host death. Every abandoned lease expired, every surface darkened, and every destination became free.

That macOS evidence did not transfer automatically to SteamOS. On 2026-08-31,
the separately built pinned x86-64 bytes passed their first bounded Deck slices
with legacy Grid `m1000853`: direct protocol expiry and renew/release, followed
by PlugData standalone fail-closed startup, renewal, exact input/output,
orderly dark release, automatic dark/free expiry after abrupt PlugData death,
fresh fail-closed restart plus explicit reclaim, and active-lease
unplug/reconnect with same-ID/same-port return as dark/free before explicit
reclaim. SteamOS remained read-only and SerialOSC did not restart.

The isolated Pico Zero/256 then passed the same bounded lanes as USB
`cafe:1110`, SerialOSC ID `m2321590`, `monome zero`, 16 by 16, on saved port
`19536`. Evidence covered explicit stale-legacy takeover, direct expiry and
renew/release, PlugData fail-closed probe, renewable claim, full-surface
output, exact bottom-right press/release input, orderly release, automatic
dark/free expiry after abrupt PlugData death, fresh fail-closed restart, and
active-lease unplug/reconnect with same-ID/same-port recovery before explicit
reclaim. SerialOSC remained active with zero restarts.

The isolated classic four-ring Arc then passed as USB `0403:6001`, SerialOSC
ID `m1001113`, padded model `monome arc`, valid Arc size `0 0`, on saved port
`11564`. Evidence covered explicit takeover of independently unbound legacy
port `12289`, corrected direct expiry plus full-brightness renew/release,
PlugData fail-closed probe, renewable claim on `17782`, all-ring and marker
output, exact signed ring-`0`/ring-`3` delta input, orderly release, automatic
dark/free expiry after abrupt PlugData death, fresh fail-closed restart, and
active-lease unplug/reconnect with same-ID/same-port recovery before explicit
reclaim. A fresh monitor recorded exactly one remove and one add; SerialOSC
remained active with zero restarts.

The legacy-128 plus Zero/256 pair then passed the first candidate
simultaneous-device row. Separate `17780` and `17781` leases, distinguishable
output, and exact A/B key input stayed isolated. Hotplug in both directions
preserved the survivor and returned the reconnected device dark/free before
explicit reclaim. Each device released independently. Shared PlugData host
death expired and visibly darkened both leases; a fresh host started
fail-closed, explicitly recovered both, and released both to free port `0`.
SteamOS remained read-only and SerialOSC retained zero restarts.

The legacy-128 plus four-ring Arc pair then passed the second candidate
simultaneous-device row. Separate `17780` and `17782` leases, distinguishable
Grid/ring output, exact Grid key input, and signed Arc delta input stayed
isolated. Hotplug in both directions preserved the survivor and returned the
reconnected device dark/free before explicit reclaim. Each device released
independently. Because the Grid and Arc patches ran in separate PlugData
processes, reciprocal process death proved isolation rather than shared-host
death: only the dead process's device expired and darkened, and each fresh
process started fail-closed. Final release returned both devices to free port
`0`. SteamOS remained read-only and SerialOSC retained zero restarts.

The Zero/256 plus four-ring Arc pair then completed bounded M3 functional
acceptance. Separate `17780` and `17782` leases, distinguishable output, exact
Zero key input, and signed Arc delta input stayed isolated. Zero removal
preserved Arc; Arc removal/reconnect preserved Zero. Independent release and
reciprocal separate-process expiry/recovery passed. Zero boot insertion,
however, physically reset and re-enumerated Arc through the dock in both tested
port orientations. Both devices returned under their stable IDs and saved
ports as dark/free, rejected preselection output, and recovered only after
explicit action. The kernel recorded the Arc USB disconnect and no
over-current warning. This accepts fail-closed recovery, not uninterrupted Arc
continuity during Zero insertion. Connect Zero first and Arc afterward on this
dock. Final release left both dark/free; SteamOS remained read-only and
SerialOSC retained zero restarts.

This is partial candidate evidence, not SteamOS release acceptance.

## Required SteamOS acceptance

- Build from the pinned Debian 12 container with all fork-native tests passing.
- Verify glibc ceiling, host runtime linkage, checksums, receipt, rootless service, and SteamOS read-only state.
- Verify non-lease discovery and device operation remain compatible.
- Verify lease capability, claim/takeover, renewal, orderly dark/release, and automatic expiry.
- Verify all three devices, using the documented Zero-first connection order
  and preserving the Zero-boot dock-reset boundary in the result.
- Verify standalone PlugData and PlugData CLAP hosted in Bitwig.
- Kill the exact host process while all three devices are leased; require automatic darkness and free-state recovery.
- Verify unplug/replug, dock behavior, and survivor isolation.

Only after the machine evidence and the user's physical observations agree should the package channel change from `lease-candidate` to an accepted release.

## Safety boundary

- No `pacman`, AUR helper, host package upgrade, or SteamOS read-only disable.
- No application installation into `/usr`, `/usr/local`, or `/etc`.
- No udev rule or persistent kernel configuration.
- Active or enabled legacy system services remain a hard preflight failure.
- Headless installation requires explicit `--noninteractive` intent.
