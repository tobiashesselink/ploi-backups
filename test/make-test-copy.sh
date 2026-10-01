#!/usr/bin/env bash
# Maakt ploi-backup-test.sh uit het echte script; alleen de standaardwaarden verschillen.
set -euo pipefail
cd "$(dirname "$0")"
sed -e 's|^ORG="${PB_ORG:-}"|ORG="${PB_ORG:-test}"|' \
    -e 's|^DISCORD_WEBHOOK="${PB_DISCORD_WEBHOOK:-}"|DISCORD_WEBHOOK="${PB_DISCORD_WEBHOOK:-http://127.0.0.1:8080/hook}"|' \
    -e 's|^MIN_GUARD_BYTES=1000000000|MIN_GUARD_BYTES=1000|' \
    ../backup/ploi-backup.sh > ploi-backup-test.sh
[ "$(grep -c 'PB_ORG:-test\|127.0.0.1:8080\|MIN_GUARD_BYTES=1000 ' ploi-backup-test.sh)" = 3 ] || { echo "sed paste niet meer op het script"; exit 1; }
