#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly PACKAGE_NAME="serialosc-steamos-v1.4.7-x86_64"
readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly SERVICE_DIR="$HOME/.config/systemd/user"
readonly SERVICE_TARGET="$SERVICE_DIR/serialoscd.service"
readonly LEGACY_USER_SERVICE="$SERVICE_DIR/serialosc.service"
readonly STATE_DIR="$HOME/.local/state/serialosc-steamos"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
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

[[ "$(uname -s)" == "Linux" ]] || fail "this installer requires Linux"
[[ "$(uname -m)" == "x86_64" ]] || fail "this package currently supports x86_64 only"
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"
command -v ldd >/dev/null 2>&1 || fail "ldd is required"
command -v ldconfig >/dev/null 2>&1 || fail "ldconfig is required"

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
done

payload_dir="$(find_payload)"
verify_binary "$payload_dir/serialoscd"
verify_binary "$payload_dir/serialosc-detector"
verify_binary "$payload_dir/serialosc-device"
[[ "$("$payload_dir/serialoscd" -v)" == 'serialoscd 1.4.7 (94d457f)' ]] \
    || fail "payload version does not match SerialOSC 1.4.7 commit 94d457f"

mkdir -p "$INSTALL_DIR" "$USER_BIN_DIR" "$SERVICE_DIR" "$STATE_DIR"
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

systemctl --user daemon-reload
systemctl --user enable --now serialoscd.service

sleep 1
systemctl --user is-active --quiet serialoscd.service \
    || fail "serialoscd.service did not become active; run journalctl --user -u serialoscd.service"

printf '\nInstalled %s\n' "$("$INSTALL_DIR/serialoscd" -v)"
printf 'SteamOS system files were not modified.\n'
printf 'Run %s for a full status report.\n' "$USER_BIN_DIR/serialosc-doctor"
