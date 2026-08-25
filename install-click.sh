#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly STATE_DIR="$HOME/.local/state/serialosc-steamos"

pause_before_close() {
    if [[ -t 0 ]]; then
        printf '\nPress Enter to close this window.'
        read -r _ || true
    fi
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    pause_before_close
    exit 1
}

open_terminal_if_needed() {
    local konsole_bin

    [[ -t 0 ]] && return 0

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        konsole_bin="$(command -v konsole || true)"
        [[ -n "$konsole_bin" ]] \
            || fail "Konsole is required for click installation on SteamOS"
        exec "$konsole_bin" -e "$ROOT_DIR/install-click.sh"
    fi

    fail "no interactive terminal is available; run install.sh --noninteractive for deliberate automation"
}

run_install_and_doctor() {
    "$ROOT_DIR/install.sh" || return $?
    printf '\nRunning installed-system verification...\n\n'
    "$HOME/.local/bin/serialosc-doctor"
}

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

open_terminal_if_needed
[[ -x "$ROOT_DIR/install.sh" ]] || fail "install.sh is missing or not executable"
command -v tee >/dev/null 2>&1 || fail "tee is required to retain the installation log"

mkdir -p "$STATE_DIR"
log_file="$STATE_DIR/install-$(date -u +%Y%m%dT%H%M%SZ).log"

printf '\033]0;Install SerialOSC for Steam Deck\007'
printf '%s\n' \
    'SerialOSC for Steam Deck' \
    '========================' \
    '' \
    'This installs only user-owned files and a user-level service.' \
    'It does not use sudo, disable SteamOS read-only mode, or modify /usr or /etc.' \
    '' \
    "A complete log will be saved to:" \
    "  $log_file" \
    ''

printf 'Press Enter to install, or close this window to cancel.'
read -r _ || exit 130
printf '\n'

set +e
run_install_and_doctor 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
    printf '\nINSTALLATION PASSED\n'
    printf 'SerialOSC is installed, enabled, active, and verified.\n'
    printf 'You can now connect a Monome device.\n'
else
    printf '\nINSTALLATION FAILED\n' >&2
    printf 'Nothing above this line should be treated as a successful install.\n' >&2
    printf 'Read the error and retain this log for support:\n  %s\n' "$log_file" >&2
fi

pause_before_close
exit "$status"
