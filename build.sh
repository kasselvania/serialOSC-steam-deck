#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly BUILD_CONTAINER="${SERIALOSC_BUILD_CONTAINER:-serialosc-build}"
readonly BUILD_IMAGE="${SERIALOSC_BUILD_IMAGE:-docker.io/library/debian:12}"
readonly UPSTREAM_URL="https://github.com/monome/serialosc.git"
readonly UPSTREAM_TAG="v1.4.7"
readonly UPSTREAM_COMMIT="94d457f80fe3721d21df5190c99bd522c711185a"
readonly LIBLO_COMMIT="983785466ad1ddad58e21f5fcc12fac32780f586"
readonly LIBMONOME_COMMIT="dfff2bec1ce7655a21a5f3fdae1b14c5cd786f17"
readonly LIBUV_COMMIT="b00c5d1a09c094020044e79e19f478a25b8e1431"
readonly OPTPARSE_COMMIT="a86877ed301d89a4eb64feb08f23af395aede2ed"
readonly CMAKE_VERSION="3.31.6"
readonly VALIDATED_SERIALOSCD_SHA256="a97adf0fc430ddbd98bae7f1562408e5b5c048cd1b7a3a5efa07677d7c2dadea"
readonly VALIDATED_DETECTOR_SHA256="5d7e47954bc1a40c06350f14c07b9d96a9b7b96357e24b9e15ba4c48c6541db3"
readonly VALIDATED_DEVICE_SHA256="5d2f0373541d3a182ef9c77484d6cd823047d0f9056f4d5209ce5f8b09dd5af4"
readonly PACKAGE_NAME="serialosc-steamos-v1.4.7-x86_64"
readonly WORK_DIR="$ROOT_DIR/build"
readonly SOURCE_DIR="$WORK_DIR/upstream"
readonly COMPILE_DIR="$WORK_DIR/compile-debian12"
readonly TOOLS_DIR="$WORK_DIR/tools-debian12"
readonly STAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
readonly DIST_DIR="$ROOT_DIR/dist"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

verify_checkout() {
    local actual

    actual="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    [[ "$actual" == "$UPSTREAM_COMMIT" ]] || fail "upstream checkout is $actual, expected $UPSTREAM_COMMIT"

    while read -r expected path; do
        actual="$(git -C "$SOURCE_DIR/$path" rev-parse HEAD)"
        [[ "$actual" == "$expected" ]] || fail "$path is $actual, expected $expected"
    done <<EOF
$LIBLO_COMMIT third-party/liblo
$LIBMONOME_COMMIT third-party/libmonome
$LIBUV_COMMIT third-party/libuv
$OPTPARSE_COMMIT third-party/optparse
EOF

    if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ]]; then
        fail "the pinned upstream checkout has tracked modifications"
    fi
}

check_binary() {
    local binary="$1"
    local ldd_output
    local max_glibc

    [[ -x "$binary" ]] || fail "missing executable: $binary"
    ldd_output="$(ldd "$binary" 2>&1)" || fail "could not inspect runtime dependencies for $binary"
    if [[ "$ldd_output" == *'not found'* ]]; then
        printf '%s\n' "$ldd_output" >&2
        fail "runtime dependency is missing for $binary"
    fi

    max_glibc="$(readelf --version-info "$binary" \
        | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
        | sed 's/^GLIBC_//' \
        | sort -Vu \
        | tail -n 1)"
    [[ -n "$max_glibc" ]] || fail "could not determine glibc requirement for $binary"
    if dpkg --compare-versions "$max_glibc" gt 2.34; then
        fail "$binary requires glibc $max_glibc; the package ceiling is 2.34"
    fi
}

require_validated_sha256() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(sha256sum "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || fail "$path has SHA-256 $actual, not physically validated $expected"
}

build_inside_container() {
    local -a elevate=()
    local cmake_bin="$TOOLS_DIR/bin/cmake"
    local source_date_epoch
    local jobs

    [[ "$(uname -m)" == "x86_64" ]] || fail "this package currently targets x86_64 only"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == 12* ]] \
        || fail "the build container must be Debian 12; found ${PRETTY_NAME:-unknown}"

    if [[ "$EUID" -ne 0 ]]; then
        require_command sudo
        elevate=(sudo)
    fi

    "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update
    "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        git \
        libavahi-compat-libdnssd-dev \
        libudev-dev \
        pkg-config \
        python3-venv

    mkdir -p "$WORK_DIR"
    if [[ ! -x "$cmake_bin" ]]; then
        python3 -m venv "$TOOLS_DIR"
        "$TOOLS_DIR/bin/pip" install "cmake==$CMAKE_VERSION"
    fi
    [[ "$("$cmake_bin" --version | sed -n '1p')" == "cmake version $CMAKE_VERSION" ]] \
        || fail "expected CMake $CMAKE_VERSION in $TOOLS_DIR"

    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        [[ ! -e "$SOURCE_DIR" ]] || fail "$SOURCE_DIR exists but is not a Git checkout"
        git clone --quiet --recurse-submodules --branch "$UPSTREAM_TAG" --depth 1 \
            "$UPSTREAM_URL" "$SOURCE_DIR"
    fi
    verify_checkout

    source_date_epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct "$UPSTREAM_COMMIT")"
    export SOURCE_DATE_EPOCH="$source_date_epoch"
    export CFLAGS="-ffile-prefix-map=$ROOT_DIR=/usr/src/serialosc-steamos"
    export CXXFLAGS="$CFLAGS"

    (
        cd "$SOURCE_DIR"
        "$cmake_bin" --fresh -S . -B "$COMPILE_DIR" -DCMAKE_BUILD_TYPE=Release
    )
    grep -q '^build_with_zeroconf:BOOL=ON$' "$COMPILE_DIR/CMakeCache.txt" \
        || fail "CMake did not enable Zeroconf"

    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
    "$cmake_bin" --build "$COMPILE_DIR" --clean-first --parallel "$jobs"

    [[ "$("$COMPILE_DIR/bin/serialoscd" -v)" == 'serialoscd 1.4.7 (94d457f)' ]] \
        || fail "serialoscd does not contain the expected version receipt"
    check_binary "$COMPILE_DIR/bin/serialoscd"
    check_binary "$COMPILE_DIR/bin/serialosc-detector"
    check_binary "$COMPILE_DIR/bin/serialosc-device"

    [[ "$STAGE_DIR" == "$WORK_DIR"/serialosc-steamos-* ]] || fail "unsafe staging path"
    rm -rf -- "$STAGE_DIR"
    mkdir -p \
        "$STAGE_DIR/bin" \
        "$STAGE_DIR/docs" \
        "$STAGE_DIR/licenses" \
        "$STAGE_DIR/source" \
        "$STAGE_DIR/systemd" \
        "$STAGE_DIR/test"

    install -m 0755 "$COMPILE_DIR/bin/serialoscd" "$STAGE_DIR/bin/serialoscd"
    install -m 0755 "$COMPILE_DIR/bin/serialosc-detector" "$STAGE_DIR/bin/serialosc-detector"
    install -m 0755 "$COMPILE_DIR/bin/serialosc-device" "$STAGE_DIR/bin/serialosc-device"
    strip --strip-unneeded "$STAGE_DIR/bin/serialoscd" "$STAGE_DIR/bin/serialosc-detector" "$STAGE_DIR/bin/serialosc-device"
    require_validated_sha256 "$STAGE_DIR/bin/serialoscd" "$VALIDATED_SERIALOSCD_SHA256"
    require_validated_sha256 "$STAGE_DIR/bin/serialosc-detector" "$VALIDATED_DETECTOR_SHA256"
    require_validated_sha256 "$STAGE_DIR/bin/serialosc-device" "$VALIDATED_DEVICE_SHA256"

    install -m 0755 "$ROOT_DIR/Install SerialOSC.sh" "$STAGE_DIR/Install SerialOSC.sh"
    install -m 0755 "$ROOT_DIR/install.sh" "$STAGE_DIR/install.sh"
    install -m 0755 "$ROOT_DIR/install-click.sh" "$STAGE_DIR/install-click.sh"
    install -m 0755 "$ROOT_DIR/uninstall.sh" "$STAGE_DIR/uninstall.sh"
    install -m 0755 "$ROOT_DIR/doctor.sh" "$STAGE_DIR/doctor.sh"
    install -m 0755 "$ROOT_DIR/migrate-legacy-user-service.sh" "$STAGE_DIR/migrate-legacy-user-service.sh"
    install -m 0755 "$ROOT_DIR/hardware-test.sh" "$STAGE_DIR/hardware-test.sh"
    install -m 0755 "$ROOT_DIR/build.sh" "$STAGE_DIR/build.sh"
    install -m 0644 "$ROOT_DIR/README.md" "$STAGE_DIR/README.md"
    for documentation in \
        ARCHITECTURE.md \
        HARDWARE_TESTS.md \
        INSTALLATION.md \
        THIRD_PARTY_LICENSES.md \
        TROUBLESHOOTING.md; do
        install -m 0644 "$ROOT_DIR/docs/$documentation" "$STAGE_DIR/docs/$documentation"
    done
    install -m 0644 "$ROOT_DIR/systemd/serialoscd.service" "$STAGE_DIR/systemd/serialoscd.service"
    install -m 0755 "$ROOT_DIR/test/osc_workbench.py" "$STAGE_DIR/test/osc_workbench.py"
    install -m 0644 "$ROOT_DIR/test/test_osc_workbench.py" "$STAGE_DIR/test/test_osc_workbench.py"
    install -m 0755 "$ROOT_DIR/test/test_install_bundle.sh" "$STAGE_DIR/test/test_install_bundle.sh"

    install -m 0644 "$SOURCE_DIR/COPYRIGHT" "$STAGE_DIR/licenses/serialosc-COPYRIGHT"
    install -m 0644 "$SOURCE_DIR/third-party/liblo/COPYING" "$STAGE_DIR/licenses/liblo-COPYING"
    install -m 0644 "$SOURCE_DIR/third-party/libmonome/COPYRIGHT" "$STAGE_DIR/licenses/libmonome-COPYRIGHT"
    install -m 0644 "$SOURCE_DIR/third-party/libuv/LICENSE" "$STAGE_DIR/licenses/libuv-LICENSE"
    install -m 0644 "$SOURCE_DIR/third-party/libuv/LICENSE-extra" "$STAGE_DIR/licenses/libuv-LICENSE-extra"
    install -m 0644 "$SOURCE_DIR/third-party/libuv/LICENSE-docs" "$STAGE_DIR/licenses/libuv-LICENSE-docs"
    install -m 0644 "$ROOT_DIR/docs/THIRD_PARTY_LICENSES.md" "$STAGE_DIR/licenses/THIRD_PARTY_LICENSES.md"

    tar --exclude-vcs --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
        -C "$SOURCE_DIR" -czf "$STAGE_DIR/source/serialosc-v1.4.7-with-submodules.tar.gz" .

    cat >"$STAGE_DIR/BUILD-RECEIPT.txt" <<EOF
package=$PACKAGE_NAME
serialosc_version=1.4.7
serialosc_commit=$UPSTREAM_COMMIT
liblo_commit=$LIBLO_COMMIT
libmonome_commit=$LIBMONOME_COMMIT
libuv_commit=$LIBUV_COMMIT
optparse_commit=$OPTPARSE_COMMIT
build_image=$BUILD_IMAGE
builder_os=$PRETTY_NAME
cmake_version=$CMAKE_VERSION
compiler=$(cc --version | sed -n '1p')
zeroconf=ON
maximum_required_glibc=2.34
direct_runtime_libraries=libc.so.6,libm.so.6,libudev.so.1
dynamically_loaded_runtime_library=libdns_sd.so.1
hardware_workbench=host-side,evidence-preserving,no-system-writes
click_installer=executable-shell-entry,kde-konsole,manifest-verified
EOF

    (
        cd "$STAGE_DIR"
        find . -type f ! -name SHA256SUMS -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            > SHA256SUMS
    )
    "$STAGE_DIR/install.sh" --verify-bundle

    mkdir -p "$DIST_DIR"
    tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
        -C "$WORK_DIR" -czf "$DIST_DIR/$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"
    (
        cd "$DIST_DIR"
        sha256sum "$PACKAGE_NAME.tar.gz" > "$PACKAGE_NAME.tar.gz.sha256"
    )

    printf '\nBuilt package:\n  %s\n  %s\n' \
        "$DIST_DIR/$PACKAGE_NAME.tar.gz" \
        "$DIST_DIR/$PACKAGE_NAME.tar.gz.sha256"
}

if [[ "${1:-}" == "--inside-container" ]]; then
    build_inside_container
    exit 0
fi

[[ "$(uname -s)" == "Linux" ]] || fail "run this build on a Linux host"
require_command distrobox
require_command awk

if ! distrobox list --no-color 2>/dev/null \
    | awk -F '|' -v wanted="$BUILD_CONTAINER" '
        {
            name=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    '; then
    distrobox create --name "$BUILD_CONTAINER" --image "$BUILD_IMAGE" --yes
fi

distrobox enter "$BUILD_CONTAINER" -- /usr/bin/env bash "$ROOT_DIR/build.sh" --inside-container
