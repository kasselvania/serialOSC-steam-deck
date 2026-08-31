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

readonly BUILD_CONTAINER="${SERIALOSC_BUILD_CONTAINER:-serialosc-build}"
readonly BUILD_IMAGE="$SERIALOSC_BUILD_IMAGE"
readonly PACKAGE_NAME="$SERIALOSC_PACKAGE_NAME"
readonly WORK_DIR="$ROOT_DIR/build"
readonly SOURCE_DIR="$WORK_DIR/serialosc-$SERIALOSC_SHORT_REVISION"
readonly COMPILE_DIR="$WORK_DIR/compile-debian12-$SERIALOSC_SHORT_REVISION"
readonly TEST_COMPILE_DIR="$WORK_DIR/test-debian12-$SERIALOSC_SHORT_REVISION"
readonly TOOLS_DIR="$WORK_DIR/tools-debian12"
readonly STAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
readonly DIST_DIR="$ROOT_DIR/dist"

usage() {
    cat <<EOF
Usage: ./build.sh [--install]

Build the pinned $SERIALOSC_PACKAGE_CHANNEL SerialOSC revision in a rootless
Debian 12 Distrobox. The default is build-only. --install runs the packaged
installer only after the build and all build-time tests succeed.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

verify_checkout() {
    local actual

    actual="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    [[ "$actual" == "$SERIALOSC_REVISION" ]] \
        || fail "SerialOSC checkout is $actual, expected $SERIALOSC_REVISION"

    while read -r expected path; do
        actual="$(git -C "$SOURCE_DIR/$path" rev-parse HEAD)"
        [[ "$actual" == "$expected" ]] \
            || fail "$path is $actual, expected $expected"
    done <<EOF
$SERIALOSC_LIBLO_REVISION third-party/liblo
$SERIALOSC_LIBMONOME_REVISION third-party/libmonome
$SERIALOSC_LIBUV_REVISION third-party/libuv
$SERIALOSC_OPTPARSE_REVISION third-party/optparse
EOF

    if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ]]; then
        fail "the pinned SerialOSC checkout has tracked modifications"
    fi
}

check_binary() {
    local binary="$1"
    local ldd_output
    local max_glibc

    [[ -x "$binary" ]] || fail "missing executable: $binary"
    ldd_output="$(ldd "$binary" 2>&1)" \
        || fail "could not inspect runtime dependencies for $binary"
    if [[ "$ldd_output" == *'not found'* ]]; then
        printf '%s\n' "$ldd_output" >&2
        fail "runtime dependency is missing for $binary"
    fi

    max_glibc="$(readelf --version-info "$binary" \
        | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
        | sed 's/^GLIBC_//' \
        | sort -Vu \
        | tail -n 1)"
    [[ -n "$max_glibc" ]] \
        || fail "could not determine glibc requirement for $binary"
    if dpkg --compare-versions "$max_glibc" gt "$SERIALOSC_MAXIMUM_GLIBC"; then
        fail "$binary requires glibc $max_glibc; package ceiling is $SERIALOSC_MAXIMUM_GLIBC"
    fi
}

prepare_source() {
    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        [[ ! -e "$SOURCE_DIR" ]] \
            || fail "$SOURCE_DIR exists but is not a Git checkout"
        git clone --quiet --no-checkout "$SERIALOSC_REPOSITORY" "$SOURCE_DIR"
        git -C "$SOURCE_DIR" checkout --quiet --detach "$SERIALOSC_REVISION"
        git -C "$SOURCE_DIR" submodule update --quiet --init --recursive
    fi
    verify_checkout
}

stage_package() {
    local source_date_epoch="$1"

    [[ "$STAGE_DIR" == "$WORK_DIR"/serialosc-steamos-* ]] \
        || fail "unsafe staging path: $STAGE_DIR"
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
    strip --strip-unneeded \
        "$STAGE_DIR/bin/serialoscd" \
        "$STAGE_DIR/bin/serialosc-detector" \
        "$STAGE_DIR/bin/serialosc-device"

    (
        cd "$STAGE_DIR/bin"
        sha256sum serialoscd serialosc-detector serialosc-device \
            >"$STAGE_DIR/BINARY-SHA256SUMS"
    )

    install -m 0644 "$ROOT_DIR/package.env" "$STAGE_DIR/package.env"
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
        RELEASE_NOTES.md \
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

    tar --exclude-vcs --sort=name --mtime="@$source_date_epoch" \
        --owner=0 --group=0 --numeric-owner \
        -C "$SOURCE_DIR" -czf \
        "$STAGE_DIR/source/serialosc-$SERIALOSC_SHORT_REVISION-with-submodules.tar.gz" .

    cat >"$STAGE_DIR/BUILD-RECEIPT.txt" <<EOF
package=$PACKAGE_NAME
channel=$SERIALOSC_PACKAGE_CHANNEL
serialosc_repository=$SERIALOSC_REPOSITORY
serialosc_version=$SERIALOSC_VERSION
serialosc_revision=$SERIALOSC_REVISION
liblo_revision=$SERIALOSC_LIBLO_REVISION
libmonome_revision=$SERIALOSC_LIBMONOME_REVISION
libuv_revision=$SERIALOSC_LIBUV_REVISION
optparse_revision=$SERIALOSC_OPTPARSE_REVISION
build_image=$BUILD_IMAGE
builder_os=$PRETTY_NAME
cmake_version=$SERIALOSC_CMAKE_VERSION
compiler=$(cc --version | sed -n '1p')
test_build_type=Debug
production_build_type=Release
zeroconf=ON
maximum_required_glibc=$SERIALOSC_MAXIMUM_GLIBC
direct_runtime_libraries=libc.so.6,libm.so.6,libudev.so.1
dynamically_loaded_runtime_library=libdns_sd.so.1
lease_protocol=opt-in,v1
hardware_acceptance=macos-complete,steamos-pending
hardware_workbench=host-side,evidence-preserving,no-system-writes
installer=install-only,transactional,user-service
EOF

    (
        cd "$STAGE_DIR"
        find . -type f ! -name SHA256SUMS -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            >SHA256SUMS
    )
    "$STAGE_DIR/install.sh" --verify-bundle

    mkdir -p "$DIST_DIR"
    tar --sort=name --mtime="@$source_date_epoch" \
        --owner=0 --group=0 --numeric-owner \
        -C "$WORK_DIR" -czf "$DIST_DIR/$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"
    (
        cd "$DIST_DIR"
        sha256sum "$PACKAGE_NAME.tar.gz" >"$PACKAGE_NAME.tar.gz.sha256"
    )

    printf '\nBuilt package:\n  %s\n  %s\n' \
        "$DIST_DIR/$PACKAGE_NAME.tar.gz" \
        "$DIST_DIR/$PACKAGE_NAME.tar.gz.sha256"
}

build_inside_container() {
    local -a elevate=()
    local cmake_bin="$TOOLS_DIR/bin/cmake"
    local source_date_epoch
    local jobs

    [[ "$(uname -m)" == 'x86_64' ]] \
        || fail 'this package currently targets x86_64 only'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == 'debian' && "${VERSION_ID:-}" == 12* ]] \
        || fail "build container must be Debian 12; found ${PRETTY_NAME:-unknown}"

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
        "$TOOLS_DIR/bin/pip" install "cmake==$SERIALOSC_CMAKE_VERSION"
    fi
    [[ "$("$cmake_bin" --version | sed -n '1p')" == \
        "cmake version $SERIALOSC_CMAKE_VERSION" ]] \
        || fail "expected CMake $SERIALOSC_CMAKE_VERSION in $TOOLS_DIR"

    prepare_source
    source_date_epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct "$SERIALOSC_REVISION")"
    export SOURCE_DATE_EPOCH="$source_date_epoch"
    export CFLAGS="-ffile-prefix-map=$ROOT_DIR=/usr/src/serialosc-steamos"
    export CXXFLAGS="$CFLAGS"

    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
    (
        cd "$SOURCE_DIR"
        "$cmake_bin" --fresh -S . -B "$TEST_COMPILE_DIR" \
            -DCMAKE_BUILD_TYPE=Debug \
            -DBUILD_TESTING=ON
    )
    "$cmake_bin" --build "$TEST_COMPILE_DIR" --clean-first --parallel "$jobs"
    "$TOOLS_DIR/bin/ctest" --test-dir "$TEST_COMPILE_DIR" --output-on-failure

    (
        cd "$SOURCE_DIR"
        "$cmake_bin" --fresh -S . -B "$COMPILE_DIR" \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_TESTING=OFF
    )
    grep -q '^build_with_zeroconf:BOOL=ON$' "$COMPILE_DIR/CMakeCache.txt" \
        || fail 'CMake did not enable Zeroconf'

    "$cmake_bin" --build "$COMPILE_DIR" --clean-first --parallel "$jobs"

    [[ "$("$COMPILE_DIR/bin/serialoscd" -v)" == "$SERIALOSC_EXPECTED_VERSION" ]] \
        || fail "serialoscd does not report $SERIALOSC_EXPECTED_VERSION"
    check_binary "$COMPILE_DIR/bin/serialoscd"
    check_binary "$COMPILE_DIR/bin/serialosc-detector"
    check_binary "$COMPILE_DIR/bin/serialosc-device"

    stage_package "$source_date_epoch"
}

run_host_build() {
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

    distrobox enter "$BUILD_CONTAINER" -- \
        /usr/bin/env bash "$ROOT_DIR/build.sh" --inside-container
}

mode='build'
case "${1:-}" in
    '')
        ;;
    --install)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        mode='build-and-install'
        ;;
    --inside-container)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        build_inside_container
        exit 0
        ;;
    -h|--help)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

[[ "$(uname -s)" == 'Linux' ]] || fail 'run this build on a Linux host'
run_host_build

if [[ "$mode" == 'build-and-install' ]]; then
    [[ -x "$STAGE_DIR/install.sh" ]] \
        || fail "build succeeded without packaged installer: $STAGE_DIR/install.sh"
    "$STAGE_DIR/install.sh" --noninteractive
fi
