#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck disable=SC1091
source "$ROOT_DIR/package.env"

temporary_dir="$(mktemp -d)"
readonly temporary_dir
trap 'rm -rf -- "$temporary_dir"' EXIT

bundle="$temporary_dir/$SERIALOSC_PACKAGE_NAME"
mkdir -p "$bundle/bin" "$bundle/systemd" "$bundle/test"
for path in \
    install.sh \
    install-click.sh \
    'Install SerialOSC.sh' \
    doctor.sh \
    uninstall.sh \
    hardware-test.sh \
    package.env; do
    cp -p "$ROOT_DIR/$path" "$bundle/$path"
done
cp -p "$ROOT_DIR/systemd/serialoscd.service" "$bundle/systemd/serialoscd.service"
cp -p "$ROOT_DIR/test/osc_workbench.py" "$bundle/test/osc_workbench.py"

for binary in serialoscd serialosc-detector serialosc-device; do
    if [[ "$binary" == serialoscd ]]; then
        cat >"$bundle/bin/$binary" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == '-v' ]]; then
    printf '%s\n' '$SERIALOSC_EXPECTED_VERSION'
fi
exit 0
EOF
    else
        printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/bin/$binary"
    fi
    chmod 0755 "$bundle/bin/$binary"
done

(
    cd "$bundle/bin"
    sha256sum serialoscd serialosc-detector serialosc-device \
        >"$bundle/BINARY-SHA256SUMS"
)
cat >"$bundle/BUILD-RECEIPT.txt" <<EOF
package=$SERIALOSC_PACKAGE_NAME
channel=$SERIALOSC_PACKAGE_CHANNEL
packaging_repository=https://github.com/kasselvania/serialOSC-steam-deck.git
packaging_revision=0000000000000000000000000000000000000000
serialosc_repository=$SERIALOSC_REPOSITORY
serialosc_version=$SERIALOSC_VERSION
serialosc_revision=$SERIALOSC_REVISION
lease_protocol=opt-in,v1
EOF
(
    cd "$bundle"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        >SHA256SUMS
)

verification_output="$($bundle/install.sh --verify-bundle)"
[[ "$verification_output" == 'Verified built release checksums.' ]]

build_help="$($ROOT_DIR/build.sh --help)"
[[ "$build_help" == *'Usage: ./build.sh [--install]'* ]]
[[ "$build_help" == *'default is build-only'* ]]

fake_path="$temporary_dir/fake-path"
terminal_record="$temporary_dir/terminal-record"
mkdir -p "$fake_path"
cat >"$fake_path/konsole" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SERIALOSC_TEST_TERMINAL_RECORD:?}"
EOF
cat >"$fake_path/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
chmod 0755 "$fake_path/konsole" "$fake_path/uname"

if ! PATH="$fake_path:$PATH" \
    WAYLAND_DISPLAY='wayland-test' \
    SERIALOSC_TEST_TERMINAL_RECORD="$terminal_record" \
        "$bundle/install.sh" </dev/null >"$temporary_dir/click.out" 2>&1; then
    cat "$temporary_dir/click.out" >&2
    printf 'packaged install did not delegate its no-terminal launch to Konsole\n' >&2
    exit 1
fi

expected_terminal_args="$(printf '%s\n' -e "$bundle/install-click.sh")"
actual_terminal_args="$(cat "$terminal_record")"
[[ "$actual_terminal_args" == "$expected_terminal_args" ]]

rm -f "$terminal_record"
PATH="$fake_path:$PATH" \
WAYLAND_DISPLAY='wayland-test' \
SERIALOSC_TEST_TERMINAL_RECORD="$terminal_record" \
    "$bundle/Install SerialOSC.sh" </dev/null \
    >"$temporary_dir/friendly-click.out" 2>&1
actual_terminal_args="$(cat "$terminal_record")"
[[ "$actual_terminal_args" == "$expected_terminal_args" ]]

if DISPLAY= WAYLAND_DISPLAY= "$bundle/install.sh" </dev/null \
    >"$temporary_dir/headless.out" 2>&1; then
    printf 'packaged install ran without a terminal or explicit --noninteractive flag\n' >&2
    exit 1
fi
grep -F 'run install.sh --noninteractive for deliberate automation' \
    "$temporary_dir/headless.out" >/dev/null

cat >"$fake_path/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) exit 2 ;;
esac
EOF
cat >"$fake_path/ldconfig" <<'EOF'
#!/usr/bin/env bash
printf 'libdns_sd.so.1 (libc6,x86-64) => /usr/lib/libdns_sd.so.1\n'
EOF
cat >"$fake_path/ldd" <<'EOF'
#!/usr/bin/env bash
printf 'libc.so.6 => /usr/lib/libc.so.6\n'
EOF
cat >"$fake_path/ss" <<'EOF'
#!/usr/bin/env bash
printf 'UNCONN 0 0 0.0.0.0:12002 0.0.0.0:*\n'
EOF
chmod 0755 "$fake_path/uname" "$fake_path/ldconfig" "$fake_path/ldd" "$fake_path/ss"

source_checkout="$temporary_dir/source-checkout"
mkdir -p "$source_checkout"
cp -p "$ROOT_DIR/install.sh" "$ROOT_DIR/install-click.sh" \
    "$ROOT_DIR/package.env" "$source_checkout/"
cat >"$fake_path/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "$fake_path/systemctl"
if HOME="$temporary_dir/source-home" PATH="$fake_path:$PATH" \
    "$source_checkout/install.sh" --noninteractive \
    >"$temporary_dir/install-only.out" 2>&1; then
    printf 'source install succeeded without a built payload\n' >&2
    exit 1
fi
grep -F 'install.sh installs only. Run ./build.sh or ./build.sh --install first' \
    "$temporary_dir/install-only.out" >/dev/null

cat >"$fake_path/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    'is-active --quiet '*) exit 1 ;;
    'is-enabled --quiet '*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$fake_path/systemctl"
if HOME="$temporary_dir/legacy-home" PATH="$fake_path:$PATH" \
    "$bundle/install.sh" --noninteractive \
    >"$temporary_dir/enabled-legacy.out" 2>&1; then
    printf 'packaged install accepted an enabled legacy system service\n' >&2
    exit 1
fi
grep -F 'system-level serialosc.service is enabled' \
    "$temporary_dir/enabled-legacy.out" >/dev/null

cat >"$fake_path/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    '--user is-active --quiet serialoscd.service') exit 0 ;;
    '--user is-enabled --quiet serialoscd.service') exit 0 ;;
    'is-active --quiet serialosc.service') exit 1 ;;
    'is-enabled --quiet serialosc.service') exit 1 ;;
    'is-active --quiet serialoscd@ttyUSB0.service') exit 1 ;;
    'is-enabled --quiet serialoscd@ttyUSB0.service') exit 1 ;;
    '--user stop serialoscd.service') exit 0 ;;
    '--user daemon-reload') exit 0 ;;
    '--user enable serialoscd.service') exit 0 ;;
    '--user restart serialoscd.service') exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$fake_path/systemctl"

fake_home="$temporary_dir/install-home"
mkdir -p "$fake_home"
HOME="$fake_home" PATH="$fake_path:$PATH" \
    "$bundle/install.sh" --noninteractive \
    >"$temporary_dir/install.out" 2>&1
grep -F "Installed $SERIALOSC_EXPECTED_VERSION" "$temporary_dir/install.out" >/dev/null
grep -F "Package channel: $SERIALOSC_PACKAGE_CHANNEL" "$temporary_dir/install.out" >/dev/null
[[ -x "$fake_home/.local/libexec/serialosc/serialoscd" ]]
[[ -r "$fake_home/.local/libexec/serialosc/BUILD-RECEIPT.txt" ]]
[[ -r "$fake_home/.local/libexec/serialosc/BINARY-SHA256SUMS" ]]
[[ -r "$fake_home/.config/systemd/user/serialoscd.service" ]]
find "$fake_home/.local/state/serialosc-steamos" -maxdepth 1 \
    -type d -name 'rollback-*' -print -quit | grep -q .
HOME="$fake_home" PATH="$fake_path:$PATH" \
    "$fake_home/.local/bin/serialosc-doctor" \
    >"$temporary_dir/doctor.out"
grep -F "build receipt: $SERIALOSC_PACKAGE_NAME at $SERIALOSC_REVISION" \
    "$temporary_dir/doctor.out" >/dev/null
grep -F 'packaging revision: 0000000000000000000000000000000000000000' \
    "$temporary_dir/doctor.out" >/dev/null
grep -F 'lease candidate is installed' "$temporary_dir/doctor.out" >/dev/null

cat >"$fake_path/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    '--user is-active --quiet serialoscd.service')
        count=0
        if [[ -r "${SERIALOSC_TEST_SYSTEMCTL_COUNT:?}" ]]; then
            IFS= read -r count <"$SERIALOSC_TEST_SYSTEMCTL_COUNT"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$SERIALOSC_TEST_SYSTEMCTL_COUNT"
        [[ "$count" -eq 1 ]]
        ;;
    '--user is-enabled --quiet serialoscd.service') exit 0 ;;
    'is-active --quiet serialosc.service') exit 1 ;;
    'is-enabled --quiet serialosc.service') exit 1 ;;
    'is-active --quiet serialoscd@ttyUSB0.service') exit 1 ;;
    'is-enabled --quiet serialoscd@ttyUSB0.service') exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$fake_path/systemctl"

rollback_home="$temporary_dir/rollback-home"
mkdir -p \
    "$rollback_home/.local/libexec/serialosc" \
    "$rollback_home/.local/bin" \
    "$rollback_home/.config/systemd/user"
printf 'accepted-old-install\n' \
    >"$rollback_home/.local/libexec/serialosc/accepted-marker"
printf 'old-service\n' \
    >"$rollback_home/.config/systemd/user/serialoscd.service"
printf '#!/usr/bin/env bash\nprintf old-doctor\\n\n' \
    >"$rollback_home/.local/bin/serialosc-doctor"
chmod 0755 "$rollback_home/.local/bin/serialosc-doctor"

systemctl_count="$temporary_dir/systemctl-count"
if HOME="$rollback_home" PATH="$fake_path:$PATH" \
    SERIALOSC_TEST_SYSTEMCTL_COUNT="$systemctl_count" \
    "$bundle/install.sh" --noninteractive \
    >"$temporary_dir/rollback.out" 2>&1; then
    printf 'installer reported success after candidate service verification failed\n' >&2
    exit 1
fi
grep -F 'Previous installation and service state restored.' \
    "$temporary_dir/rollback.out" >/dev/null
grep -Fqx 'accepted-old-install' \
    "$rollback_home/.local/libexec/serialosc/accepted-marker"
grep -Fqx 'old-service' \
    "$rollback_home/.config/systemd/user/serialoscd.service"
grep -Fq 'old-doctor' "$rollback_home/.local/bin/serialosc-doctor"
find "$rollback_home/.local/state/serialosc-steamos" -path '*/failed-serialosc/serialoscd' \
    -type f -print -quit | grep -q .

printf 'corruption\n' >>"$bundle/bin/serialoscd"
if "$bundle/install.sh" --verify-bundle >"$temporary_dir/corrupt.out" 2>&1; then
    printf 'corrupt built payload was accepted\n' >&2
    exit 1
fi
grep -F 'built release checksum verification failed' "$temporary_dir/corrupt.out" >/dev/null

printf 'PASS build/install split, verified click path, transactional install, and corruption rejection\n'
