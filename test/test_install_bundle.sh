#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR

temporary_dir="$(mktemp -d)"
readonly temporary_dir
trap 'rm -rf -- "$temporary_dir"' EXIT

bundle="$temporary_dir/serialosc-steamos-test"
mkdir -p "$bundle/bin"
cp -p "$ROOT_DIR/install.sh" "$bundle/install.sh"
cp -p "$ROOT_DIR/install-click.sh" "$bundle/install-click.sh"
cp -p "$ROOT_DIR/Install SerialOSC.sh" "$bundle/Install SerialOSC.sh"

for binary in serialoscd serialosc-detector serialosc-device; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/bin/$binary"
    chmod 0755 "$bundle/bin/$binary"
done

(
    cd "$bundle"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        > SHA256SUMS
)

verification_output="$($bundle/install.sh --verify-bundle)"
[[ "$verification_output" == 'Verified packaged release checksums.' ]]

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
    WAYLAND_DISPLAY="wayland-test" \
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
WAYLAND_DISPLAY="wayland-test" \
SERIALOSC_TEST_TERMINAL_RECORD="$terminal_record" \
    "$bundle/Install SerialOSC.sh" </dev/null >"$temporary_dir/friendly-click.out" 2>&1
actual_terminal_args="$(cat "$terminal_record")"
[[ "$actual_terminal_args" == "$expected_terminal_args" ]]

if DISPLAY= WAYLAND_DISPLAY= "$bundle/install.sh" </dev/null >"$temporary_dir/headless.out" 2>&1; then
    printf 'packaged install ran without a terminal or explicit --noninteractive flag\n' >&2
    exit 1
fi
grep -F 'run install.sh --noninteractive for deliberate automation' "$temporary_dir/headless.out" >/dev/null

cat >"$fake_path/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) exit 2 ;;
esac
EOF
cat >"$fake_path/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    'is-active --quiet '*) exit 1 ;;
    'is-enabled --quiet '*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
cat >"$fake_path/ldconfig" <<'EOF'
#!/usr/bin/env bash
printf 'libdns_sd.so.1 (libc6,x86-64) => /usr/lib/libdns_sd.so.1\n'
EOF
cat >"$fake_path/ldd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "$fake_path/uname" "$fake_path/systemctl" "$fake_path/ldconfig" "$fake_path/ldd"

if PATH="$fake_path:$PATH" "$bundle/install.sh" --noninteractive \
    >"$temporary_dir/enabled-legacy.out" 2>&1; then
    printf 'packaged install accepted an enabled legacy system service\n' >&2
    exit 1
fi
if ! grep -F 'system-level serialosc.service is enabled' \
    "$temporary_dir/enabled-legacy.out" >/dev/null; then
    cat "$temporary_dir/enabled-legacy.out" >&2
    printf 'packaged install did not identify the enabled legacy system service\n' >&2
    exit 1
fi

printf 'corruption\n' >>"$bundle/bin/serialoscd"
if "$bundle/install.sh" --verify-bundle >"$temporary_dir/corrupt.out" 2>&1; then
    printf 'corrupt packaged payload was accepted\n' >&2
    exit 1
fi
grep -F 'packaged release checksum verification failed' "$temporary_dir/corrupt.out" >/dev/null

printf 'PASS packaged release verification, click delegation, and corruption rejection\n'
