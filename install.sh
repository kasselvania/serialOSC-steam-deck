#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly PACKAGE_NAME="serialosc-steamos-v1.4.7-x86_64"
readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly TEST_INSTALL_DIR="$HOME/.local/libexec/serialosc-tests"
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly SERVICE_DIR="$HOME/.config/systemd/user"
readonly SERVICE_TARGET="$SERVICE_DIR/serialoscd.service"
readonly LEGACY_USER_SERVICE="$SERVICE_DIR/serialosc.service"
readonly STATE_DIR="$HOME/.local/state/serialosc-steamos"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

verify_packaged_bundle() {
    local manifest="$ROOT_DIR/SHA256SUMS"

    [[ -d "$ROOT_DIR/bin" ]] \
        || fail "this is a source checkout, not a packaged release bundle"
    [[ -r "$manifest" ]] \
        || fail "packaged release is missing SHA256SUMS"
    command -v sha256sum >/dev/null 2>&1 \
        || fail "sha256sum is required to verify the packaged release"

    (
        cd "$ROOT_DIR"
        sha256sum --check --strict --quiet SHA256SUMS
    ) || fail "packaged release checksum verification failed; do not install this copy"

    printf 'Verified packaged release checksums.\n'
}

find_payload() {
    if [[ -x "$ROOT_DIR/bin/serialoscd" ]]; then
        printf '%s\n' "$ROOT_DIR/bin"
        return
    fi
    if [[ -x "$ROOT_DIR/build/$PACKAGE_NAME/bin/serialoscd" ]]; then
        printf '%s\n' "$ROOT_DIR/build/$PACKAGE_NAME/bin"
        return
    fi

    printf 'No packaged binaries found; starting the rootless Debian 12 build.\n' >&2
    "$ROOT_DIR/build.sh" >&2
    [[ -x "$ROOT_DIR/build/$PACKAGE_NAME/bin/serialoscd" ]] \
        || fail "build completed without the expected payload"
    printf '%s\n' "$ROOT_DIR/build/$PACKAGE_NAME/bin"
}

verify_binary() {
    local binary="$1"
    local ldd_output

    [[ -x "$binary" ]] || fail "missing executable: $binary"
    ldd_output="$(ldd "$binary" 2>&1)" || fail "could not inspect runtime dependencies for $binary"
    if [[ "$ldd_output" == *'not found'* ]]; then
        printf '%s\n' "$ldd_output" >&2
        fail "runtime dependency is missing for $binary"
    fi
}

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [--verify-bundle|--noninteractive]\n' "$0" >&2
    exit 2
fi

case "${1:-}" in
    "")
        interactive_install=true
        ;;
    --noninteractive)
        [[ $# -eq 1 ]] || { printf 'Usage: %s [--verify-bundle|--noninteractive]\n' "$0" >&2; exit 2; }
        interactive_install=false
        ;;
    --verify-bundle)
        [[ $# -eq 1 ]] || { printf 'Usage: %s [--verify-bundle|--noninteractive]\n' "$0" >&2; exit 2; }
        verify_packaged_bundle
        exit 0
        ;;
    *)
        printf 'Usage: %s [--verify-bundle|--noninteractive]\n' "$0" >&2
        exit 2
        ;;
esac

if [[ "$interactive_install" == true && ! -t 0 ]]; then
    [[ -x "$ROOT_DIR/install-click.sh" ]] \
        || fail "install-click.sh is required for a no-terminal launch"
    if [[ -d "$ROOT_DIR/bin" ]]; then
        verify_packaged_bundle
    fi
    exec "$ROOT_DIR/install-click.sh"
fi

[[ "$(uname -s)" == "Linux" ]] || fail "this installer requires Linux"
[[ "$(uname -m)" == "x86_64" ]] || fail "this package currently supports x86_64 only"
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"
command -v ldd >/dev/null 2>&1 || fail "ldd is required"
command -v ldconfig >/dev/null 2>&1 || fail "ldconfig is required"

if [[ -d "$ROOT_DIR/bin" ]]; then
    verify_packaged_bundle
fi

if ! ldconfig -p 2>/dev/null | grep -F 'libdns_sd.so.1 ' >/dev/null; then
    fail "host runtime library libdns_sd.so.1 is required for Zeroconf"
fi

if [[ -e "$LEGACY_USER_SERVICE" ]]; then
    fail "legacy user service found at $LEGACY_USER_SERVICE; run ./migrate-legacy-user-service.sh first"
fi

for legacy_system_service in serialosc.service serialoscd@ttyUSB0.service; do
    if systemctl is-active --quiet "$legacy_system_service" 2>/dev/null; then
        fail "system-level $legacy_system_service is active; stop and preserve it before installing the user service"
    fi
    if systemctl is-enabled --quiet "$legacy_system_service" 2>/dev/null; then
        fail "system-level $legacy_system_service is enabled; preserve its unit file and disable the obsolete boot entry before installing"
    fi
done

payload_dir="$(find_payload)"
verify_binary "$payload_dir/serialoscd"
verify_binary "$payload_dir/serialosc-detector"
verify_binary "$payload_dir/serialosc-device"
[[ "$("$payload_dir/serialoscd" -v)" == 'serialoscd 1.4.7 (94d457f)' ]] \
    || fail "payload version does not match SerialOSC 1.4.7 commit 94d457f"
[[ -r "$ROOT_DIR/test/osc_workbench.py" ]] || fail "missing OSC workbench helper"
[[ -r "$ROOT_DIR/hardware-test.sh" ]] || fail "missing host hardware-test command"

mkdir -p "$INSTALL_DIR" "$TEST_INSTALL_DIR" "$USER_BIN_DIR" "$SERVICE_DIR" "$STATE_DIR"
systemctl --user stop serialoscd.service 2>/dev/null || true

if [[ -e "$SERVICE_TARGET" ]] && ! cmp -s "$ROOT_DIR/systemd/serialoscd.service" "$SERVICE_TARGET"; then
    backup="$STATE_DIR/serialoscd.service.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$SERVICE_TARGET" "$backup"
    printf 'Preserved previous user service as %s\n' "$backup"
fi

install -m 0755 "$payload_dir/serialoscd" "$INSTALL_DIR/serialoscd"
install -m 0755 "$payload_dir/serialosc-detector" "$INSTALL_DIR/serialosc-detector"
install -m 0755 "$payload_dir/serialosc-device" "$INSTALL_DIR/serialosc-device"
install -m 0644 "$ROOT_DIR/systemd/serialoscd.service" "$SERVICE_TARGET"
install -m 0755 "$ROOT_DIR/doctor.sh" "$USER_BIN_DIR/serialosc-doctor"
install -m 0755 "$ROOT_DIR/uninstall.sh" "$USER_BIN_DIR/serialosc-uninstall"
install -m 0755 "$ROOT_DIR/hardware-test.sh" "$USER_BIN_DIR/serialosc-hardware-test"
install -m 0755 "$ROOT_DIR/test/osc_workbench.py" "$TEST_INSTALL_DIR/osc_workbench.py"

systemctl --user daemon-reload
systemctl --user enable --now serialoscd.service

sleep 1
systemctl --user is-active --quiet serialoscd.service \
    || fail "serialoscd.service did not become active; run journalctl --user -u serialoscd.service"

printf '\nInstalled %s\n' "$("$INSTALL_DIR/serialoscd" -v)"
printf 'SteamOS system files were not modified.\n'
printf 'Run %s for a full status report.\n' "$USER_BIN_DIR/serialosc-doctor"
printf 'Run %s begin with all devices unplugged to start a physical test.\n' \
    "$USER_BIN_DIR/serialosc-hardware-test"
