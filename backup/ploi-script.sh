#!/usr/bin/env bash
# Ploi > Scripts > "ploi-backup" (user: root). Uitleg: https://github.com/tobiashesselink/ploi-backups
# Ploi schrijft dit script met secrets naar de server: meteen weghalen (bash leest gewoon door).
case "$0" in /root/ploi-script-*.sh) rm -f -- "$0" ;; esac
# ---- Invullen -------------------------------------------------------
export PB_ORG=""                 # korte naam, kleine letters, bv. acme
export PB_STORAGEBOX_ID=""       # Hetzner Console > Storage Box > ID (getal)
export PB_RESTIC_PASSWORD=""     # uit je wachtwoordmanager; nooit wijzigen
export PB_DISCORD_WEBHOOK=""     # Discord-kanaal > Integraties > Webhook-URL
export PB_HC_PING_KEY=""         # optioneel: Healthchecks.io ping key
export PB_HETZNER_TOKEN=""       # alleen invullen om een nieuwe server te koppelen, daarna weer leeg
# ---- Versie (alleen aanpassen bij een update, zie README) -----------
VERSION="v1.1.0"
SHA256="vul-in-bij-release"
# ---------------------------------------------------------------------
set -euo pipefail
URL="https://raw.githubusercontent.com/tobiashesselink/ploi-backups/$VERSION/backup/ploi-backup.sh"
BIN="/usr/local/sbin/ploi-backup-$PB_ORG"
MODE="${1:-run}"
tmp="$(mktemp)"
if curl -fsSL -m 60 --retry 3 -o "$tmp" "$URL" && echo "$SHA256  $tmp" | sha256sum -c --quiet -; then
  rc=0; bash "$tmp" "$MODE" || rc=$?
  rm -f "$tmp"; exit "$rc"
fi
rm -f "$tmp"
echo "ploi-backup: downloaden of checksum van $VERSION mislukt." >&2
if [ -x "$BIN" ]; then
  echo "ploi-backup: de al geïnstalleerde versie wordt gebruikt." >&2
  exec "$BIN" "$MODE"
fi
exit 1
