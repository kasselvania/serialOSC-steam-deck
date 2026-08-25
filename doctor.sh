#!/usr/bin/env bash
set -uo pipefail

readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly SERVICE_TARGET="$HOME/.config/systemd/user/serialoscd.service"
readonly CURRENT_USER="${USER:-$(id -un)}"

failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

printf 'SerialOSC Steam Deck doctor\n\n'

if [[ "$(uname -m)" == "x86_64" ]]; then
    pass 'architecture is x86_64'
else
    fail "unsupported architecture: $(uname -m)"
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "steamos" ]]; then
        pass "host is ${PRETTY_NAME:-SteamOS}"
    else
        warn "host is ${PRETTY_NAME:-unknown}, not SteamOS"
    fi
fi

if command -v steamos-readonly >/dev/null 2>&1; then
    readonly_status="$(steamos-readonly status 2>/dev/null)"
    if [[ "$readonly_status" == "enabled" ]]; then
        pass 'SteamOS read-only mode is enabled'
    else
        warn "SteamOS read-only mode is $readonly_status"
    fi
fi

for name in serialoscd serialosc-detector serialosc-device; do
    binary="$INSTALL_DIR/$name"
    if [[ ! -x "$binary" ]]; then
        fail "missing executable $binary"
        continue
    fi
    ldd_output="$(ldd "$binary" 2>&1)"
    if [[ "$ldd_output" == *'not found'* ]]; then
        fail "$name has a missing runtime library"
        printf '%s\n' "$ldd_output"
    else
        pass "$name runtime libraries resolve"
    fi
done

if command -v ldconfig >/dev/null 2>&1 \
    && ldconfig -p 2>/dev/null | grep -F 'libdns_sd.so.1 ' >/dev/null; then
    pass 'Zeroconf runtime library libdns_sd.so.1 is available'
else
    fail 'Zeroconf runtime library libdns_sd.so.1 is unavailable'
fi

if [[ -x "$INSTALL_DIR/serialoscd" ]]; then
    version="$("$INSTALL_DIR/serialoscd" -v 2>&1)"
    if [[ "$version" == 'serialoscd 1.4.7 (94d457f)' ]]; then
        pass "$version"
    else
        fail "unexpected version: $version"
    fi
fi

if [[ -f "$SERVICE_TARGET" ]]; then
    pass "user service file exists at $SERVICE_TARGET"
else
    fail "user service file is missing: $SERVICE_TARGET"
fi

if systemctl --user is-enabled --quiet serialoscd.service 2>/dev/null; then
    pass 'serialoscd.service is enabled'
else
    fail 'serialoscd.service is not enabled'
fi

if systemctl --user is-active --quiet serialoscd.service 2>/dev/null; then
    pass 'serialoscd.service is active'
else
    fail 'serialoscd.service is not active'
fi

if ss -lun 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:12002[[:space:]]' >/dev/null; then
    pass 'SerialOSC discovery port UDP/12002 is listening'
else
    fail 'SerialOSC discovery port UDP/12002 is not listening'
fi

device_link=''
if [[ -d /dev/serial/by-id ]]; then
    device_link="$(find /dev/serial/by-id -maxdepth 1 -type l -name 'usb-monome_*' -print -quit 2>/dev/null)"
fi

if [[ -n "$device_link" ]]; then
    device_node="$(readlink -f "$device_link")"
    pass "Monome device found: $device_link -> $device_node"
    if [[ -r "$device_node" && -w "$device_node" ]]; then
        pass "$CURRENT_USER has read/write access to $device_node"
    else
        fail "$CURRENT_USER lacks read/write access to $device_node"
    fi
    # The worker's visible Linux process title may end in either serialosc-device or serialosc-devic.
    if pgrep -f '/serialosc-devic(e)?([[:space:]]|$)' >/dev/null 2>&1; then
        pass 'a SerialOSC device worker is running'
    else
        fail 'Monome is connected but no SerialOSC device worker is running'
    fi
else
    warn 'no Monome device is currently connected; hotplug readiness can still be valid'
fi

if [[ -e "$HOME/.config/systemd/user/serialosc.service" ]]; then
    fail 'legacy user service still exists at ~/.config/systemd/user/serialosc.service'
fi

for system_service in serialosc.service serialoscd@ttyUSB0.service; do
    case "$system_service" in
        serialosc.service)
            system_unit=/etc/systemd/system/serialosc.service
            ;;
        serialoscd@ttyUSB0.service)
            system_unit=/etc/systemd/system/serialoscd@.service
            ;;
    esac

    if systemctl is-active --quiet "$system_service" 2>/dev/null; then
        fail "legacy system service is active: $system_service"
    elif systemctl is-enabled --quiet "$system_service" 2>/dev/null; then
        fail "legacy system service is enabled: $system_service"
    elif [[ -e "$system_unit" ]]; then
        warn "disabled legacy system unit is preserved: $system_unit"
    else
        pass "legacy system service is absent: $system_service"
    fi
done

printf '\nResult: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
(( failures == 0 ))
