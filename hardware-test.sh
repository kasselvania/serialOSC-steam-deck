#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly INSTALL_DIR="$HOME/.local/libexec/serialosc"
readonly TEST_INSTALL_DIR="$HOME/.local/libexec/serialosc-tests"
readonly CONFIG_DIR="$HOME/.config/serialosc"
readonly SERVICE_TARGET="$HOME/.config/systemd/user/serialoscd.service"
readonly INSTALLED_DOCTOR="$HOME/.local/bin/serialosc-doctor"
readonly BUILD_CONTAINER="${SERIALOSC_BUILD_CONTAINER:-serialosc-build}"
readonly STATE_ROOT="${SERIALOSC_TEST_STATE_ROOT:-$HOME/.local/state/serialosc-steamos/hardware-tests}"
readonly ACTIVE_FILE="$STATE_ROOT/.active-session"
readonly EXPECTED_VERSION='serialoscd 1.4.7 (94d457f)'
readonly EXPECTED_SERVICE_SHA256='e5b105c2833007d12f277a7abd47e07b2d1fbf9816fddbbba1f960455c529b4a'
readonly EXPECTED_SERIALOSCD_SHA256='a97adf0fc430ddbd98bae7f1562408e5b5c048cd1b7a3a5efa07677d7c2dadea'
readonly EXPECTED_DETECTOR_SHA256='5d7e47954bc1a40c06350f14c07b9d96a9b7b96357e24b9e15ba4c48c6541db3'
readonly EXPECTED_DEVICE_SHA256='5d2f0373541d3a182ef9c77484d6cd823047d0f9056f4d5209ce5f8b09dd5af4'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: serialosc-hardware-test COMMAND [ARGUMENTS]

Host-side commands:
  begin [label]       Capture a no-device baseline and open an evidence session
  status              Show service status and current OSC discovery
  snapshot LABEL      Capture a labeled state snapshot in the active session
  note TEXT...         Append a physical observation to the active session
  session             Run the interactive OSC event/light workbench
  discover            List SerialOSC-managed devices as JSON
  info PORT           Query one device server's /sys/info
  port-status PORT    Report whether a UDP port can be bound
  hold-port PORT      Hold a UDP port until Ctrl-C (controlled conflict test)
  tty-open PATH       Attempt a second, non-I/O tty open (controlled test only)
  finish              Capture the final state and close the evidence session

Run this command on the SteamOS host, never inside a Distrobox.
EOF
}

require_host() {
    [[ "$(uname -s)" == "Linux" ]] || fail 'this workbench requires Linux'
    [[ "$(uname -m)" == "x86_64" ]] || fail 'this workbench currently targets x86_64'
    [[ -r /etc/os-release ]] || fail 'cannot identify the host OS'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "steamos" ]] \
        || fail "run on the SteamOS host, not ${PRETTY_NAME:-an unidentified container}"
}

safe_label() {
    local value="${1:-snapshot}"
    value="${value//[^A-Za-z0-9._-]/_}"
    [[ -n "$value" ]] || value='snapshot'
    printf '%s\n' "$value"
}

current_hostname() {
    if command -v hostname >/dev/null 2>&1; then
        hostname
    elif [[ -r /proc/sys/kernel/hostname ]]; then
        cat /proc/sys/kernel/hostname
    else
        printf 'unknown\n'
    fi
}

osc_helper() {
    local candidate
    for candidate in \
        "$ROOT_DIR/test/osc_workbench.py" \
        "$HOME/.local/libexec/serialosc-tests/osc_workbench.py"; do
        if [[ -r "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

run_osc() {
    local helper
    helper="$(osc_helper)" || {
        printf 'OSC helper is not installed\n' >&2
        return 127
    }
    if command -v python3 >/dev/null 2>&1; then
        python3 "$helper" "$@"
    elif command -v distrobox >/dev/null 2>&1; then
        distrobox enter "$BUILD_CONTAINER" -- python3 "$helper" "$@"
    else
        printf 'Python 3 is unavailable on the host and no Distrobox fallback exists\n' >&2
        return 127
    fi
}

active_session() {
    local session
    [[ -f "$ACTIVE_FILE" ]] || return 1
    IFS= read -r session <"$ACTIVE_FILE"
    [[ "$session" == "$STATE_ROOT/"* && -d "$session" ]] || return 1
    printf '%s\n' "$session"
}

require_active_session() {
    local session
    session="$(active_session)" \
        || fail "no active test session; run 'serialosc-hardware-test begin' first"
    printf '%s\n' "$session"
}

capture() {
    local output="$1"
    local command_status
    shift
    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
        command_status=$?
        printf '\nexit_status=%d\n' "$command_status"
    } >"$output" 2>&1
    return 0
}

host_report() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
    id
    uname -a
    printf '\n/etc/os-release\n'
    cat /etc/os-release
    printf '\nSteamOS read-only status\n'
    if command -v steamos-readonly >/dev/null 2>&1; then
        steamos-readonly status
    else
        printf 'steamos-readonly command unavailable\n'
    fi
    printf '\nboot id\n'
    cat /proc/sys/kernel/random/boot_id
    printf '\nuptime\n'
    uptime
}

install_report() {
    local path
    for path in \
        "$INSTALL_DIR/serialoscd" \
        "$INSTALL_DIR/serialosc-detector" \
        "$INSTALL_DIR/serialosc-device" \
        "$SERVICE_TARGET" \
        "$HOME/.local/bin/serialosc-hardware-test" \
        "$TEST_INSTALL_DIR/osc_workbench.py"; do
        printf '\n[%s]\n' "$path"
        if [[ ! -e "$path" ]]; then
            printf 'missing\n'
            continue
        fi
        ls -l -- "$path"
        sha256sum -- "$path"
        if [[ -x "$path" && "$path" == "$INSTALL_DIR/"* ]]; then
            ldd "$path"
        fi
    done
    printf '\nversion\n'
    "$INSTALL_DIR/serialoscd" -v
}

service_report() {
    systemctl --user is-enabled serialoscd.service
    systemctl --user is-active serialoscd.service
    systemctl --user status --no-pager --full serialoscd.service
    systemctl --user show serialoscd.service \
        -p ActiveState -p SubState -p MainPID -p NRestarts -p ExecMainStartTimestamp
    printf '\nLegacy services (read-only inspection)\n'
    systemctl --user is-active serialosc.service 2>/dev/null || true
    systemctl is-active serialosc.service 2>/dev/null || true
    systemctl is-active 'serialoscd@ttyUSB0.service' 2>/dev/null || true
}

process_report() {
    pgrep -a -f "$INSTALL_DIR/serialosc" || true
    printf '\nUDP sockets\n'
    ss -lunp
    if command -v fuser >/dev/null 2>&1; then
        printf '\nUDP/12002 owner\n'
        fuser -v -n udp 12002 || true
    fi
}

usb_report() {
    local path target
    local -a device_paths=()
    if command -v lsusb >/dev/null 2>&1; then
        lsusb
        printf '\nUSB topology\n'
        lsusb -t
    else
        printf 'lsusb unavailable\n'
    fi

    printf '\nSerial device paths\n'
    shopt -s nullglob
    device_paths=(/dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*)
    if (( ${#device_paths[@]} == 0 )); then
        printf 'none\n'
        return
    fi
    for path in "${device_paths[@]}"; do
        target="$(readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")"
        printf '\n[%s -> %s]\n' "$path" "$target"
        ls -l -- "$path" "$target" 2>&1 || true
        if command -v udevadm >/dev/null 2>&1; then
            udevadm info --query=property --name="$target" 2>&1 || true
        fi
        if command -v getfacl >/dev/null 2>&1; then
            getfacl --absolute-names "$target" 2>&1 || true
        fi
        if command -v fuser >/dev/null 2>&1; then
            fuser -v "$target" 2>&1 || true
        fi
    done
}

config_report() {
    local path
    local -a config_paths=()
    shopt -s nullglob
    config_paths=("$CONFIG_DIR"/*.conf)
    if (( ${#config_paths[@]} == 0 )); then
        printf 'no device configuration files\n'
        return
    fi
    for path in "${config_paths[@]}"; do
        printf '\n[%s]\n' "$path"
        sha256sum -- "$path"
        cat -- "$path"
    done
}

zeroconf_report() {
    if ! command -v avahi-browse >/dev/null 2>&1; then
        printf 'avahi-browse unavailable\n'
        return
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 4 avahi-browse -rt _monome-osc._udp || true
    else
        printf 'timeout unavailable; skipping potentially blocking browse\n'
    fi
}

snapshot_into() {
    local session="$1"
    local label="$2"
    local timestamp snapshot_dir osc_status
    timestamp="$(date -u +%Y%m%dT%H%M%S%NZ)"
    label="$(safe_label "$label")"
    snapshot_dir="$session/snapshots/$timestamp-$label"
    mkdir -p "$snapshot_dir"

    {
        printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'label=%s\n' "$label"
        printf 'session=%s\n' "$session"
    } >"$snapshot_dir/METADATA.txt"

    capture "$snapshot_dir/host.txt" host_report
    capture "$snapshot_dir/install.txt" install_report
    capture "$snapshot_dir/service.txt" service_report
    capture "$snapshot_dir/processes-and-sockets.txt" process_report
    capture "$snapshot_dir/usb-and-tty.txt" usb_report
    capture "$snapshot_dir/device-config.txt" config_report
    capture "$snapshot_dir/zeroconf.txt" zeroconf_report
    capture "$snapshot_dir/journal.txt" \
        journalctl --user -u serialoscd.service --no-pager -n 300 -o short-precise
    if [[ -x "$INSTALLED_DOCTOR" ]]; then
        capture "$snapshot_dir/doctor.txt" "$INSTALLED_DOCTOR"
    elif [[ -x "$ROOT_DIR/doctor.sh" ]]; then
        capture "$snapshot_dir/doctor.txt" "$ROOT_DIR/doctor.sh"
    else
        printf 'serialosc-doctor unavailable\n' >"$snapshot_dir/doctor.txt"
    fi
    run_osc discover --format json >"$snapshot_dir/osc-discovery.json" \
        2>"$snapshot_dir/osc-discovery.stderr"
    osc_status=$?
    printf '%d\n' "$osc_status" >"$snapshot_dir/osc-discovery.status"

    printf '%s\n' "$snapshot_dir"
}

preflight() {
    local failures=0 actual expected name count readonly_status

    preflight_fail() {
        printf 'FAIL  %s\n' "$*" >&2
        failures=$((failures + 1))
    }
    preflight_pass() {
        printf 'PASS  %s\n' "$*"
    }

    readonly_status="$(steamos-readonly status 2>/dev/null || true)"
    if [[ "$readonly_status" == 'enabled' ]]; then
        preflight_pass 'SteamOS read-only mode is enabled'
    else
        preflight_fail "SteamOS read-only mode is ${readonly_status:-unavailable}"
    fi

    if systemctl --user is-enabled --quiet serialoscd.service 2>/dev/null; then
        preflight_pass 'serialoscd.service is enabled'
    else
        preflight_fail 'serialoscd.service is not enabled'
    fi
    if systemctl --user is-active --quiet serialoscd.service 2>/dev/null; then
        preflight_pass 'serialoscd.service is active'
    else
        preflight_fail 'serialoscd.service is not active'
    fi

    if [[ -x "$INSTALL_DIR/serialoscd" \
        && "$("$INSTALL_DIR/serialoscd" -v 2>/dev/null)" == "$EXPECTED_VERSION" ]]; then
        preflight_pass "$EXPECTED_VERSION"
    else
        preflight_fail 'installed SerialOSC version is not the pinned build'
    fi

    while read -r expected name; do
        if [[ ! -f "$INSTALL_DIR/$name" ]]; then
            preflight_fail "missing $INSTALL_DIR/$name"
            continue
        fi
        actual="$(sha256sum "$INSTALL_DIR/$name" | awk '{print $1}')"
        if [[ "$actual" == "$expected" ]]; then
            preflight_pass "$name matches the validated packaged bytes"
        else
            preflight_fail "$name hash is $actual, expected $expected"
        fi
    done <<EOF
$EXPECTED_SERIALOSCD_SHA256 serialoscd
$EXPECTED_DETECTOR_SHA256 serialosc-detector
$EXPECTED_DEVICE_SHA256 serialosc-device
EOF

    if [[ -f "$SERVICE_TARGET" ]]; then
        actual="$(sha256sum "$SERVICE_TARGET" | awk '{print $1}')"
        if [[ "$actual" == "$EXPECTED_SERVICE_SHA256" ]]; then
            preflight_pass 'user service matches the packaged unit'
        else
            preflight_fail "user service hash is $actual, expected $EXPECTED_SERVICE_SHA256"
        fi
    else
        preflight_fail "missing $SERVICE_TARGET"
    fi

    if ss -lun 2>/dev/null \
        | grep -E '(^|[[:space:]])[^[:space:]]*:12002[[:space:]]' >/dev/null; then
        preflight_pass 'UDP/12002 is listening'
    else
        preflight_fail 'UDP/12002 is not listening'
    fi

    if [[ -e "$HOME/.config/systemd/user/serialosc.service" ]]; then
        preflight_fail 'legacy user service still exists'
    else
        preflight_pass 'legacy user service is absent'
    fi
    for name in serialosc.service 'serialoscd@ttyUSB0.service'; do
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            preflight_fail "legacy system service $name is active"
        else
            preflight_pass "legacy system service $name is not active"
        fi
    done

    if pgrep -f '/serialosc-devic(e)?([[:space:]]|$)' >/dev/null 2>&1; then
        preflight_fail 'a SerialOSC device worker is already running; begin requires no devices'
    else
        preflight_pass 'no SerialOSC device worker is running'
    fi

    count="$(run_osc discover --format count 2>/dev/null)"
    if [[ "$count" == '0' ]]; then
        preflight_pass 'OSC discovery reports zero managed devices'
    else
        preflight_fail "OSC discovery count is ${count:-unavailable}; begin requires zero"
    fi

    (( failures == 0 ))
}

begin_session() {
    local label="${1:-hardware-matrix}"
    local session timestamp
    if active_session >/dev/null 2>&1; then
        fail "a test session is already active at $(active_session)"
    fi
    umask 077
    mkdir -p "$STATE_ROOT"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    label="$(safe_label "$label")"
    session="$STATE_ROOT/$timestamp-$label-$$"
    mkdir -p "$session/snapshots"
    {
        printf 'started_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'label=%s\n' "$label"
        printf 'user=%s\n' "$(id -un)"
        printf 'host=%s\n' "$(current_hostname)"
    } >"$session/SESSION.txt"

    printf 'Capturing preflight baseline...\n'
    snapshot_into "$session" baseline-no-devices >/dev/null
    if ! preflight; then
        printf 'Preflight failed; evidence was preserved at %s\n' "$session" >&2
        return 1
    fi
    printf '%s\n' "$session" >"$ACTIVE_FILE"
    printf 'READY\nEvidence session: %s\n' "$session"
}

show_status() {
    local session
    if session="$(active_session)"; then
        printf 'Active evidence session: %s\n' "$session"
    else
        printf 'Active evidence session: none\n'
    fi
    printf 'serialoscd.service: '
    systemctl --user is-active serialoscd.service 2>/dev/null || true
    printf 'SteamOS read-only: '
    steamos-readonly status 2>/dev/null || printf 'unavailable\n'
    printf '\nSerialOSC discovery:\n'
    run_osc discover --format json
}

run_interactive_session() {
    local session evidence status
    session="$(require_active_session)"
    snapshot_into "$session" before-osc-session >/dev/null
    evidence="$session/osc-events-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
    run_osc session --evidence "$evidence"
    status=$?
    snapshot_into "$session" after-osc-session >/dev/null
    return "$status"
}

finish_session() {
    local session
    session="$(require_active_session)"
    snapshot_into "$session" final >/dev/null
    printf 'finished_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        >"$session/FINISHED.txt"
    rm -f -- "$ACTIVE_FILE"
    printf 'Closed evidence session: %s\n' "$session"
}

require_host
command="${1:-}"
shift || true

case "$command" in
    begin)
        (( $# <= 1 )) || fail 'begin accepts at most one label'
        begin_session "${1:-hardware-matrix}"
        ;;
    status)
        (( $# == 0 )) || fail 'status accepts no arguments'
        show_status
        ;;
    snapshot)
        (( $# == 1 )) || fail 'snapshot requires one label'
        session="$(require_active_session)"
        snapshot_into "$session" "$1"
        ;;
    note)
        (( $# > 0 )) || fail 'note requires text'
        session="$(require_active_session)"
        printf '%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" \
            >>"$session/physical-observations.tsv"
        ;;
    session)
        (( $# == 0 )) || fail 'session accepts no arguments'
        run_interactive_session
        ;;
    discover)
        (( $# == 0 )) || fail 'discover accepts no arguments'
        run_osc discover --format json
        ;;
    info)
        (( $# == 1 )) || fail 'info requires a device UDP port'
        run_osc info --device-port "$1"
        ;;
    port-status)
        (( $# == 1 )) || fail 'port-status requires a UDP port'
        run_osc port-status --port "$1"
        ;;
    hold-port)
        (( $# == 1 )) || fail 'hold-port requires a UDP port'
        require_active_session >/dev/null
        run_osc hold-port --port "$1"
        ;;
    tty-open)
        (( $# == 1 )) || fail 'tty-open requires an exact tty path'
        require_active_session >/dev/null
        run_osc tty-open --path "$1"
        ;;
    finish)
        (( $# == 0 )) || fail 'finish accepts no arguments'
        finish_session
        ;;
    help|-h|--help)
        usage
        ;;
    '')
        usage >&2
        exit 2
        ;;
    *)
        usage >&2
        fail "unknown command: $command"
        ;;
esac
