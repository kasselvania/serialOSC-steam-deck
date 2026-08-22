#!/usr/bin/env bash
set -euo pipefail

readonly LEGACY_SERVICE="$HOME/.config/systemd/user/serialosc.service"
readonly STATE_ROOT="$HOME/.local/state/serialosc-steamos/legacy-user"

if [[ ! -e "$LEGACY_SERVICE" ]]; then
    printf 'No legacy user service exists at %s\n' "$LEGACY_SERVICE"
    exit 0
fi

backup_dir="$STATE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"

systemctl --user disable --now serialosc.service 2>/dev/null || true
mv -- "$LEGACY_SERVICE" "$backup_dir/serialosc.service"
systemctl --user daemon-reload

printf 'Preserved the disabled legacy user service at:\n  %s\n' "$backup_dir/serialosc.service"

for system_unit in /etc/systemd/system/serialosc.service /etc/systemd/system/serialoscd@.service; do
    if [[ -e "$system_unit" ]]; then
        printf 'WARNING: legacy system unit still exists and was not changed: %s\n' "$system_unit" >&2
    fi
done
