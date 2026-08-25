#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

for required_script in install.sh install-click.sh; do
    if [[ ! -x "$ROOT_DIR/$required_script" ]]; then
        printf 'ERROR: %s is missing or not executable\n' "$required_script" >&2
        exit 1
    fi
done

if [[ -d "$ROOT_DIR/bin" ]]; then
    "$ROOT_DIR/install.sh" --verify-bundle
fi

exec "$ROOT_DIR/install-click.sh"
