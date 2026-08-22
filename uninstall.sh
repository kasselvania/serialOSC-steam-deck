#!/usr/bin/env bash
set -euo pipefail

readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly SERVICE_TARGET="$HOME/.config/systemd/user/serialoscd.service"
readonly CONFIG_DIR="$HOME/.config/serialosc"

purge_config=false
if [[ "${1:-}" == "--purge-config" ]]; then
    purge_config=true
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--purge-config]\n' "$0" >&2
    exit 2
fi

systemctl --user disable --now serialoscd.service 2>/dev/null || true

rm -f -- "$SERVICE_TARGET"
rm -f -- "$INSTALL_DIR/serialoscd"
rm -f -- "$INSTALL_DIR/serialosc-detector"
rm -f -- "$INSTALL_DIR/serialosc-device"
rm -f -- "$USER_BIN_DIR/serialosc-doctor"
rm -f -- "$USER_BIN_DIR/serialosc-uninstall"
rmdir -- "$INSTALL_DIR" 2>/dev/null || true
systemctl --user daemon-reload

if [[ "$purge_config" == true ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
        find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.conf' -delete
        rmdir -- "$CONFIG_DIR" 2>/dev/null || true
    fi
    printf 'Removed SerialOSC binaries, service, tools, and device preferences.\n'
else
    printf 'Removed SerialOSC binaries, service, and tools.\n'
    printf 'Preserved device preferences under %s\n' "$CONFIG_DIR"
fi

printf 'The optional serialosc-build Distrobox was not removed.\n'
