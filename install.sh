#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly PACKAGE_ENV="$ROOT_DIR/package.env"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -r "$PACKAGE_ENV" ]] || fail "missing package identity: $PACKAGE_ENV"
# shellcheck disable=SC1090
source "$PACKAGE_ENV"

readonly PACKAGE_NAME="$SERIALOSC_PACKAGE_NAME"
readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly TEST_INSTALL_DIR="$HOME/.local/libexec/serialosc-tests"
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly SERVICE_DIR="$HOME/.config/systemd/user"
readonly SERVICE_TARGET="$SERVICE_DIR/serialoscd.service"
readonly LEGACY_USER_SERVICE="$SERVICE_DIR/serialosc.service"
readonly STATE_DIR="$HOME/.local/state/serialosc-steamos"

transaction_started=false
transaction_committed=false
install_swap_started=false
transaction_dir=''
rollback_dir=''
previous_service_active=false
previous_service_enabled=false

usage() {
    printf 'Usage: %s [--verify-bundle|--noninteractive]\n' "$0"
}

verify_packaged_bundle() {
    local bundle_root="$1"
    local manifest="$bundle_root/SHA256SUMS"

    [[ -d "$bundle_root/bin" ]] \
        || fail "$bundle_root is not a built release bundle"
    [[ -r "$manifest" ]] \
        || fail "built release is missing SHA256SUMS: $bundle_root"
    command -v sha256sum >/dev/null 2>&1 \
        || fail 'sha256sum is required to verify the built release'

    (
        cd "$bundle_root"
        sha256sum --check --strict --quiet SHA256SUMS
    ) || fail 'built release checksum verification failed; do not install this copy'

    printf 'Verified built release checksums.\n'
}

find_payload_root() {
    if [[ -x "$ROOT_DIR/bin/serialoscd" ]]; then
        printf '%s\n' "$ROOT_DIR"
        return
    fi
    if [[ -x "$ROOT_DIR/build/$PACKAGE_NAME/bin/serialoscd" ]]; then
        printf '%s\n' "$ROOT_DIR/build/$PACKAGE_NAME"
        return
    fi

    fail "no built payload found; install.sh installs only. Run ./build.sh or ./build.sh --install first"
}

verify_binary() {
    local binary="$1"
    local ldd_output

    [[ -x "$binary" ]] || fail "missing executable: $binary"
    ldd_output="$(ldd "$binary" 2>&1)" \
        || fail "could not inspect runtime dependencies for $binary"
    if [[ "$ldd_output" == *'not found'* ]]; then
        printf '%s\n' "$ldd_output" >&2
        fail "runtime dependency is missing for $binary"
    fi
}

verify_payload() {
    local payload_root="$1"

    verify_packaged_bundle "$payload_root"
    [[ -r "$payload_root/BINARY-SHA256SUMS" ]] \
        || fail 'built release is missing BINARY-SHA256SUMS'
    [[ -r "$payload_root/BUILD-RECEIPT.txt" ]] \
        || fail 'built release is missing BUILD-RECEIPT.txt'
    [[ -r "$payload_root/systemd/serialoscd.service" ]] \
        || fail 'built release is missing the user service'

    grep -Fqx "package=$PACKAGE_NAME" "$payload_root/BUILD-RECEIPT.txt" \
        || fail 'build receipt package does not match the installer'
    grep -Fqx "channel=$SERIALOSC_PACKAGE_CHANNEL" "$payload_root/BUILD-RECEIPT.txt" \
        || fail 'build receipt channel does not match the installer'
    grep -Fqx "serialosc_revision=$SERIALOSC_REVISION" "$payload_root/BUILD-RECEIPT.txt" \
        || fail 'build receipt revision does not match the installer'

    (
        cd "$payload_root/bin"
        sha256sum --check --strict --quiet "$payload_root/BINARY-SHA256SUMS"
    ) || fail 'built binary checksums do not match the receipt'

    verify_binary "$payload_root/bin/serialoscd"
    verify_binary "$payload_root/bin/serialosc-detector"
    verify_binary "$payload_root/bin/serialosc-device"
    [[ "$("$payload_root/bin/serialoscd" -v)" == "$SERIALOSC_EXPECTED_VERSION" ]] \
        || fail "payload does not report $SERIALOSC_EXPECTED_VERSION"
}

backup_file() {
    local source="$1"
    local key="$2"

    if [[ -e "$source" || -L "$source" ]]; then
        cp -p -- "$source" "$rollback_dir/$key"
        : >"$rollback_dir/$key.present"
    fi
}

restore_file() {
    local target="$1"
    local key="$2"

    if [[ -e "$rollback_dir/$key.present" ]]; then
        mkdir -p -- "$(dirname -- "$target")"
        cp -p -- "$rollback_dir/$key" "$target"
    else
        rm -f -- "$target"
    fi
}

rollback_transaction() {
    set +e
    printf 'Install did not complete; restoring the previous user installation.\n' >&2
    systemctl --user stop serialoscd.service >/dev/null 2>&1

    if [[ "$install_swap_started" == true ]]; then
        if [[ -e "$INSTALL_DIR" ]]; then
            mv -- "$INSTALL_DIR" "$rollback_dir/failed-serialosc"
        fi
        if [[ -d "$rollback_dir/serialosc" ]]; then
            mkdir -p -- "$(dirname -- "$INSTALL_DIR")"
            mv -- "$rollback_dir/serialosc" "$INSTALL_DIR"
        fi
    fi

    restore_file "$SERVICE_TARGET" serialoscd.service
    restore_file "$USER_BIN_DIR/serialosc-doctor" serialosc-doctor
    restore_file "$USER_BIN_DIR/serialosc-uninstall" serialosc-uninstall
    restore_file "$USER_BIN_DIR/serialosc-hardware-test" serialosc-hardware-test
    restore_file "$TEST_INSTALL_DIR/osc_workbench.py" osc_workbench.py

    systemctl --user daemon-reload >/dev/null 2>&1
    if [[ "$previous_service_enabled" == true ]]; then
        systemctl --user enable serialoscd.service >/dev/null 2>&1
    else
        systemctl --user disable serialoscd.service >/dev/null 2>&1
    fi
    if [[ "$previous_service_active" == true ]]; then
        systemctl --user start serialoscd.service >/dev/null 2>&1
    fi
    printf 'Previous installation and service state restored.\n' >&2
    if [[ -d "$rollback_dir/failed-serialosc" ]]; then
        printf 'Failed candidate retained at %s\n' \
            "$rollback_dir/failed-serialosc" >&2
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$transaction_started" == true && "$transaction_committed" != true ]]; then
        rollback_transaction
    fi
    if [[ -n "$transaction_dir" && "$transaction_dir" == "$STATE_DIR"/install-stage.* ]]; then
        rm -rf -- "$transaction_dir"
    fi
    exit "$status"
}
trap cleanup EXIT

prepare_transaction() {
    local payload_root="$1"
    local new_install

    mkdir -p "$STATE_DIR"
    transaction_dir="$(mktemp -d "$STATE_DIR/install-stage.XXXXXX")"
    new_install="$transaction_dir/serialosc"
    mkdir -p "$new_install"

    install -m 0755 "$payload_root/bin/serialoscd" "$new_install/serialoscd"
    install -m 0755 "$payload_root/bin/serialosc-detector" "$new_install/serialosc-detector"
    install -m 0755 "$payload_root/bin/serialosc-device" "$new_install/serialosc-device"
    install -m 0644 "$payload_root/BINARY-SHA256SUMS" "$new_install/BINARY-SHA256SUMS"
    install -m 0644 "$payload_root/BUILD-RECEIPT.txt" "$new_install/BUILD-RECEIPT.txt"
    install -m 0644 "$payload_root/package.env" "$new_install/package.env"
    install -m 0644 "$payload_root/systemd/serialoscd.service" \
        "$new_install/serialoscd.service"

    (
        cd "$new_install"
        sha256sum --check --strict --quiet BINARY-SHA256SUMS
    ) || fail 'staged installation failed its binary checksum'
}

install_transaction() {
    local payload_root="$1"
    local timestamp

    prepare_transaction "$payload_root"
    mkdir -p "$USER_BIN_DIR" "$SERVICE_DIR" "$TEST_INSTALL_DIR"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    rollback_dir="$STATE_DIR/rollback-$timestamp"
    mkdir -p "$rollback_dir"

    systemctl --user is-active --quiet serialoscd.service 2>/dev/null \
        && previous_service_active=true
    systemctl --user is-enabled --quiet serialoscd.service 2>/dev/null \
        && previous_service_enabled=true

    backup_file "$SERVICE_TARGET" serialoscd.service
    backup_file "$USER_BIN_DIR/serialosc-doctor" serialosc-doctor
    backup_file "$USER_BIN_DIR/serialosc-uninstall" serialosc-uninstall
    backup_file "$USER_BIN_DIR/serialosc-hardware-test" serialosc-hardware-test
    backup_file "$TEST_INSTALL_DIR/osc_workbench.py" osc_workbench.py
    if [[ -e "$INSTALL_DIR" ]]; then
        [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] \
            || fail "refusing to replace non-directory install path: $INSTALL_DIR"
    fi

    {
        printf 'created_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'replaced_with=%s\n' "$PACKAGE_NAME"
        printf 'previous_service_active=%s\n' "$previous_service_active"
        printf 'previous_service_enabled=%s\n' "$previous_service_enabled"
    } >"$rollback_dir/ROLLBACK-RECEIPT.txt"

    transaction_started=true
    systemctl --user stop serialoscd.service 2>/dev/null || true
    if [[ -d "$INSTALL_DIR" ]]; then
        mv -- "$INSTALL_DIR" "$rollback_dir/serialosc"
    fi
    install_swap_started=true
    mv -- "$transaction_dir/serialosc" "$INSTALL_DIR"

    install -m 0644 "$payload_root/systemd/serialoscd.service" "$SERVICE_TARGET"
    install -m 0755 "$payload_root/doctor.sh" "$USER_BIN_DIR/serialosc-doctor"
    install -m 0755 "$payload_root/uninstall.sh" "$USER_BIN_DIR/serialosc-uninstall"
    install -m 0755 "$payload_root/hardware-test.sh" "$USER_BIN_DIR/serialosc-hardware-test"
    install -m 0755 "$payload_root/test/osc_workbench.py" "$TEST_INSTALL_DIR/osc_workbench.py"

    systemctl --user daemon-reload
    systemctl --user enable serialoscd.service
    systemctl --user restart serialoscd.service
    sleep 1
    systemctl --user is-active --quiet serialoscd.service \
        || fail 'serialoscd.service did not become active'
    systemctl --user is-enabled --quiet serialoscd.service \
        || fail 'serialoscd.service did not remain enabled'
    if ! ss -lun 2>/dev/null \
        | grep -E '(^|[[:space:]])[^[:space:]]*:12002[[:space:]]' >/dev/null; then
        fail 'installed service is active but UDP/12002 is not listening'
    fi
    (
        cd "$INSTALL_DIR"
        sha256sum --check --strict --quiet BINARY-SHA256SUMS
    ) || fail 'installed binaries do not match their package checksums'
    [[ "$("$INSTALL_DIR/serialoscd" -v)" == "$SERIALOSC_EXPECTED_VERSION" ]] \
        || fail 'installed serialoscd version changed during installation'

    transaction_committed=true
    printf 'complete=true\n' >>"$rollback_dir/ROLLBACK-RECEIPT.txt"
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

case "${1:-}" in
    '')
        interactive_install=true
        ;;
    --noninteractive)
        interactive_install=false
        ;;
    --verify-bundle)
        verify_packaged_bundle "$ROOT_DIR"
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ "$interactive_install" == true && ! -t 0 ]]; then
    [[ -x "$ROOT_DIR/install-click.sh" ]] \
        || fail 'install-click.sh is required for a no-terminal launch'
    exec "$ROOT_DIR/install-click.sh"
fi

[[ "$(uname -s)" == 'Linux' ]] || fail 'this installer requires Linux'
[[ "$(uname -m)" == 'x86_64' ]] || fail 'this package currently supports x86_64 only'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required'
command -v ldd >/dev/null 2>&1 || fail 'ldd is required'
command -v ldconfig >/dev/null 2>&1 || fail 'ldconfig is required'
command -v ss >/dev/null 2>&1 || fail 'ss is required'

if ! ldconfig -p 2>/dev/null | grep -F 'libdns_sd.so.1 ' >/dev/null; then
    fail 'host runtime library libdns_sd.so.1 is required for Zeroconf'
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

payload_root="$(find_payload_root)"
verify_payload "$payload_root"
[[ -x "$payload_root/doctor.sh" ]] || fail 'built release is missing doctor.sh'
[[ -x "$payload_root/uninstall.sh" ]] || fail 'built release is missing uninstall.sh'
[[ -x "$payload_root/hardware-test.sh" ]] || fail 'built release is missing hardware-test.sh'
[[ -r "$payload_root/test/osc_workbench.py" ]] \
    || fail 'built release is missing the OSC workbench helper'

install_transaction "$payload_root"

printf '\nInstalled %s\n' "$("$INSTALL_DIR/serialoscd" -v)"
printf 'Package channel: %s\n' "$SERIALOSC_PACKAGE_CHANNEL"
printf 'SteamOS system files were not modified.\n'
printf 'Previous installation retained for rollback at %s\n' "$rollback_dir"
printf 'Run %s for a full status report.\n' "$USER_BIN_DIR/serialosc-doctor"
printf 'Run %s begin with all devices unplugged to start a physical test.\n' \
    "$USER_BIN_DIR/serialosc-hardware-test"
