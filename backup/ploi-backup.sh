#!/usr/bin/env bash
# =====================================================================
#  ploi-backup: dagelijkse restic-backups van Ploi-servers naar een
#  Hetzner Storage Box. Zie https://github.com/tobiashesselink/ploi-backups
#
#  Je draait dit script niet zelf: het kleine Ploi-script (ploi-script.sh)
#  haalt een vaste versie op, controleert de checksum en start het.
#  Het installeert zich als /usr/local/sbin/ploi-backup-<org>.
# =====================================================================

# Ploi of cron kan dit met sh starten: dan opnieuw met bash (alleen mogelijk vanuit een bestand)
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -f "$0" ]; then exec bash "$0" "$@"; fi
  echo "ploi-backup: dit script moet met bash draaien" >&2; exit 1
fi

# Config komt uit het Ploi-script (PB_*). De geïnstalleerde kopie bewaart de waarden.
ORG="${PB_ORG:-}"                          # korte naam, bv. acme: label, paden, meldingen
STORAGEBOX_ID="${PB_STORAGEBOX_ID:-}"      # Hetzner Console > Storage Box > ID
DISCORD_WEBHOOK="${PB_DISCORD_WEBHOOK:-}"  # optioneel
HC_PING_KEY="${PB_HC_PING_KEY:-}"          # optioneel: Healthchecks.io ping key

RESTIC_VERSION="0.19.1"
RESTIC_SHA256_AMD64="f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c"
RESTIC_SHA256_ARM64="a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465"
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=6
REPORT_WEEKDAY=7             # 1=ma .. 7=zo: prune, integriteitscheck en weekrapport
CHECK_SUBSET="5%"            # deel van de data dat wekelijks echt wordt gelezen
MIN_GUARD_BYTES=1000000000   # lege-server-check pas vanaf 1 GB vorige backup
KEEP_DB_HOURLY=48            # alleen voor de optionele 'db'-modus (bv. elk uur via een tweede schedule)
KEEP_DB_DAILY=7

CONFIG_VARS=(ORG STORAGEBOX_ID DISCORD_WEBHOOK HC_PING_KEY RESTIC_VERSION
  RESTIC_SHA256_AMD64 RESTIC_SHA256_ARM64 KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY
  REPORT_WEEKDAY CHECK_SUBSET MIN_GUARD_BYTES KEEP_DB_HOURLY KEEP_DB_DAILY CONFIG_VARS)

# ======================================================================
#  Algemeen
# ======================================================================

init_vars() {
  STATE="/root/.ploi-backup-$ORG"
  ENV_FILE="$STATE/env"
  KEY="$STATE/id_ed25519"
  SSH_CFG="$STATE/ssh_config"
  SSH_ALIAS="ploi-backup-$ORG"
  BIN="/usr/local/sbin/ploi-backup-$ORG"
  UNIT="ploi-backup-$ORG"
  LOGDIR="/var/log/ploi-backup-$ORG"
  LOG="$LOGDIR/last.log"
  LOCK="/run/lock/ploi-backup-$ORG.lock"
  DUMP_DIR="/var/backups/ploi-backup-$ORG"
  MYSQL_CNF="/root/.backup-mysql.cnf"
  DB_UNIT=""
  IS_MARIADB=0
  API="https://api.hetzner.com/v1"
  STEP="start"
  WARNINGS=()
  BLOCK_DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
  BLOCK_HC_PING_KEY="$HC_PING_KEY"
  SERVER_NAME=""
}

say()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { say "WAARSCHUWING: $*"; WARNINGS+=("$*"); }
die()  { say "FOUT: $*"; return 1; }   # met set -e + ERR-trap: stopt en meldt
# Lage CPU- en IO-prioriteit voor dit proces en alles wat het start (ook bash-functies zoals r)
lowprio_self() { renice -n 19 -p $$ >/dev/null 2>&1 || true; ionice -c2 -n7 -p $$ 2>/dev/null || true; }

load_env() {
  # shellcheck source=/dev/null
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  [ -n "$BLOCK_DISCORD_WEBHOOK" ] && DISCORD_WEBHOOK="$BLOCK_DISCORD_WEBHOOK"
  [ -n "$BLOCK_HC_PING_KEY" ] && HC_PING_KEY="$BLOCK_HC_PING_KEY"
  SERVER_NAME="${SERVER_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
  export RESTIC_REPOSITORY="sftp:$SSH_ALIAS:restic"
  export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
}

# JSON-string zonder jq (meldingen moeten ook werken als jq ontbreekt)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

discord() {
  [ -n "${DISCORD_WEBHOOK:-}" ] || return 0
  local msg="$1"
  [ "${#msg}" -gt 1900 ] && msg="${msg:0:1900}…"
  curl -sS -m 15 -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"content\":$(json_str "$msg")}" \
    -K <(printf 'url = "%s"\n' "$DISCORD_WEBHOOK") || true
}

hc() {
  [ -n "${HC_PING_KEY:-}" ] || return 0
  curl -sS -m 10 --retry 3 -o /dev/null \
    "https://hc-ping.com/$HC_PING_KEY/$ORG-$SERVER_NAME${HC_SUFFIX:-}${1:-}?create=1" || true
}

r() { restic -o sftp.command="ssh -F $SSH_CFG $SSH_ALIAS -s sftp" "$@"; }

# Log naar bestand én naar de originele stdout (journal of terminal).
# fd 3/4 = originele stdout/stderr, fd 5 = de pipe naar tee (ook bruikbaar waar stdout omgeleid is).
start_log() { # start_log BESTAND [append]
  if [ "${2:-}" = append ] && [ -f "$1" ]; then tail -n 2000 "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"; fi
  exec 3>&1 4>&2
  if [ "${2:-}" = append ]; then exec > >(tee -a "$1" >&3) 2>&1; else exec > >(tee "$1" >&3) 2>&1; fi
  TEE_PID=$!
  exec 5>&1
  LOG_FILE="$1"; LOG_ACTIVE=1
  trap stop_log EXIT
}
# Bij afsluiten: pipe sluiten en wachten tot tee alles heeft weggeschreven (systemd kan tee anders afschieten)
stop_log() {
  [ -n "${TEE_PID:-}" ] || return 0
  exec 1>&3 2>&4 5>&-
  local i
  for i in $(seq 1 50); do kill -0 "$TEE_PID" 2>/dev/null || break; sleep 0.1; done
  TEE_PID=""
}

tail_log() { if [ "${LOG_ACTIVE:-0}" = 1 ] && [ -f "$LOG_FILE" ]; then tail -n "${1:-15}" "$LOG_FILE" | cut -c1-200; fi; }

# Afgebroken (TERM/HUP/INT): tee is dan mogelijk al gestopt, dus direct naar het logbestand en de originele uitvoer
on_signal() { # on_signal FOUTAFHANDELING
  trap '' PIPE TERM HUP INT
  if [ -n "${TEE_PID:-}" ]; then exec 1>&3 2>&4; TEE_PID=""; fi
  [ "${LOG_ACTIVE:-0}" = 1 ] && echo "[$(date -u +%H:%M:%S)] afgebroken in stap: $STEP" >> "$LOG_FILE"
  STEP="$STEP (afgebroken)"
  "$1" 143
}

on_error() {
  local rc=$?
  [ -z "${1:-}" ] || rc="$1"
  # set -E erft de trap in $(...): daar alleen doorgeven, de buitenste shell meldt
  if [ "$BASH_SUBSHELL" -gt 0 ]; then return "$rc"; fi
  trap - ERR
  # De trap kan afgaan binnen een functie met >/dev/null (bv. r cat config): terug naar de log
  if [ -n "${TEE_PID:-}" ]; then exec 1>&5 2>&5; fi
  say "Gestopt met exitcode $rc in stap: $STEP"
  sleep 1
  hc /fail
  discord "🔴 **${ACTION:-Backup} mislukt op \`$SERVER_NAME\`** ($ORG, stap: $STEP)${PRE_SNAPSHOT:+ Veiligheidsbackup van vóór het terugzetten: \`$PRE_SNAPSHOT\`.}
\`\`\`
$(tail_log 15)
\`\`\`"
  exit "$rc"
}

need_root() { [ "$(id -u)" = 0 ] || die "dit moet als root draaien"; }

# Schrijft het script (config + functies) naar $BIN, ook als Ploi het via stdin uitvoert
install_self() {
  local tmp
  tmp="$(mktemp "$BIN.XXXXXX")"
  local cur_dw="${DISCORD_WEBHOOK:-}" cur_hc="${HC_PING_KEY:-}"
  DISCORD_WEBHOOK="$BLOCK_DISCORD_WEBHOOK"; HC_PING_KEY="$BLOCK_HC_PING_KEY"
  {
    echo '#!/usr/bin/env bash'
    echo "# Gegenereerd door ploi-backup ($ORG). Bron: github.com/tobiashesselink/ploi-backups"
    declare -p "${CONFIG_VARS[@]}"
    declare -f
    echo 'main "$@"'
  } > "$tmp"
  DISCORD_WEBHOOK="$cur_dw"; HC_PING_KEY="$cur_hc"
  chmod 700 "$tmp"
  mv -f "$tmp" "$BIN"
  # Korte naam zonder org, zodat commando's in de README altijd gelijk zijn
  ln -sfn "$BIN" /usr/local/sbin/ploi-backup
}

# ======================================================================
#  Tools
# ======================================================================

apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ "${#missing[@]}" -eq 0 ] && return 0
  say "apt install ${missing[*]}"
  # Geen tty, geen prompts en needrestart overslaan: nooit services herstarten vanuit de backup
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l \
    apt-get -o DPkg::Lock::Timeout=600 update -qq </dev/null
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l \
    apt-get -o DPkg::Lock::Timeout=600 install -y -qq "${missing[@]}" </dev/null >/dev/null
}

install_restic() {
  if restic version 2>/dev/null | grep -q "restic $RESTIC_VERSION "; then return 0; fi
  local arch sha tmp
  case "$(uname -m)" in
    x86_64)  arch=amd64; sha="$RESTIC_SHA256_AMD64" ;;
    aarch64) arch=arm64; sha="$RESTIC_SHA256_ARM64" ;;
    *) die "onbekende architectuur $(uname -m)" ;;
  esac
  say "restic $RESTIC_VERSION installeren ($arch)"
  tmp="$(mktemp -d)"
  curl -fsSL -m 300 --retry 3 -o "$tmp/restic.bz2" \
    "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${arch}.bz2"
  echo "$sha  $tmp/restic.bz2" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "checksum restic klopt niet"; }
  bunzip2 -c "$tmp/restic.bz2" > "$tmp/restic"
  install -m 755 "$tmp/restic" /usr/local/bin/restic
  rm -rf "$tmp"
  restic version
}

tools() {
  STEP="tools"
  local pk=(curl bzip2 openssh-client)
  command -v jq >/dev/null || pk+=(jq)
  [ "${1:-}" = setup ] && pk+=(sshpass)
  local hit
  hit="$(find /home -maxdepth 6 -name '*.sqlite' -print -quit 2>/dev/null || true)"
  [ -z "$hit" ] || pk+=(sqlite3)
  apt_install "${pk[@]}"
  install_restic
}

# ======================================================================
#  Hetzner Storage Box API (alleen in setup)
# ======================================================================

# api METHOD PATH [JSON]: geeft body terug; bij fout HTTP-code en body in de log (zonder token)
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  local data=()
  [ -n "$body" ] && data=(--data-binary @-)
  code="$(printf '%s' "$body" | curl -sS -m 30 -o "$out" -w '%{http_code}' -X "$method" \
    -H 'Content-Type: application/json' "${data[@]}" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$HETZNER_TOKEN") "$API$path")" || code="000"
  if [[ "$code" != 2* ]]; then
    say "Hetzner API $method $path: HTTP $code: $(head -c 800 "$out")"
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

wait_action() {
  local id="$1" i st
  [ -n "$id" ] && [ "$id" != null ] || return 0
  for i in $(seq 1 60); do
    st="$(api GET "/storage_boxes/actions/$id" | jq -r '.action.status')"
    case "$st" in
      success) return 0 ;;
      error) api GET "/storage_boxes/actions/$id" | jq -c '.action.error'; return 1 ;;
    esac
    sleep 3
  done
  say "Hetzner action $id niet klaar na 3 minuten"
  return 1
}

gen_password() {
  # 32 hex + verplichte hoofdletter, kleine letter, cijfer en speciaal teken (Hetzner-beleid)
  printf '%sAa1-' "$(openssl rand -hex 16)"
}

# ======================================================================
#  Storage Box verbinding
# ======================================================================

write_ssh_cfg() {
  cat > "$SSH_CFG" <<CFG
Host $SSH_ALIAS
  HostName $SB_HOST
  User $SB_USER
  Port 23
  IdentityFile $KEY
  IdentitiesOnly yes
  UserKnownHostsFile $STATE/known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
  ServerAliveCountMax 10
  ConnectTimeout 30
CFG
  chmod 600 "$SSH_CFG"
}

key_works() {
  [ -f "$SSH_CFG" ] && [ -f "$KEY" ] || return 1
  echo "ls" | timeout 60 sftp -F "$SSH_CFG" -b - -o BatchMode=yes "$SSH_ALIAS" >/dev/null 2>&1
}

# Voegt de publieke key toe aan .ssh/authorized_keys van het sub-account (wachtwoord-login)
upload_key() {
  local tmp i
  tmp="$(mktemp -d)"
  for i in $(seq 1 12); do
    rm -f "$tmp/ak"
    SSHPASS="$SB_PASSWORD" timeout 60 sshpass -e sftp -F "$SSH_CFG" \
      -o PubkeyAuthentication=no -o PreferredAuthentications=password -o BatchMode=no \
      "$SSH_ALIAS" >/dev/null 2>&1 <<SFTP || true
-mkdir .ssh
-get .ssh/authorized_keys $tmp/ak
SFTP
    touch "$tmp/ak"
    grep -qxF "$(cat "$KEY.pub")" "$tmp/ak" || cat "$KEY.pub" >> "$tmp/ak"
    SSHPASS="$SB_PASSWORD" timeout 60 sshpass -e sftp -F "$SSH_CFG" \
      -o PubkeyAuthentication=no -o PreferredAuthentications=password -o BatchMode=no \
      "$SSH_ALIAS" >/dev/null 2>&1 <<SFTP || true
put $tmp/ak .ssh/authorized_keys
chmod 600 .ssh/authorized_keys
chmod 700 .ssh
SFTP
    if key_works; then rm -rf "$tmp"; return 0; fi
    say "wachten tot Hetzner het sub-account activeert (duurt meestal 1-2 min, poging $i/12)"
    sleep 10
  done
  rm -rf "$tmp"
  return 1
}

# ======================================================================
#  Setup (eenmalig per server, als root)
# ======================================================================

ask() { # ask VAR "vraag" [secret]
  local var="$1" q="$2" secret="${3:-}" val=""
  [ -n "${!var:-}" ] && return 0
  # Alleen vragen als setup interactief draait (stdin is een terminal)
  [ "${SETUP_INTERACTIVE:-0}" = 1 ] && [ -r /dev/tty ] || return 0
  if [ -n "$secret" ]; then read -rsp "$q: " val </dev/tty; echo >&2
  else read -rp "$q: " val </dev/tty; fi
  printf -v "$var" '%s' "$val"
}

write_env() {
  umask 077
  {
    echo "# ploi-backup $ORG, aangemaakt door setup op $(date -u -Is)"
    printf 'SERVER_NAME=%q\n' "$SERVER_NAME"
    printf 'SB_USER=%q\nSB_HOST=%q\n' "$SB_USER" "$SB_HOST"
    printf 'RESTIC_PASSWORD=%q\n' "$RESTIC_PASSWORD"
    printf 'DISCORD_WEBHOOK=%q\nHC_PING_KEY=%q\n' "${DISCORD_WEBHOOK:-}" "${HC_PING_KEY:-}"
  } > "$ENV_FILE.tmp"
  chmod 600 "$ENV_FILE.tmp"
  mv -f "$ENV_FILE.tmp" "$ENV_FILE"
}

# Zoekt of maakt het sub-account voor deze server; zet SB_USER/SB_HOST/SB_PASSWORD
provision_subaccount() {
  STEP="Storage Box sub-account"
  local sel list n sub_id body resp action
  [[ "$STORAGEBOX_ID" =~ ^[0-9]+$ ]] || die "PB_STORAGEBOX_ID ontbreekt in het Ploi-script"
  sel="ploi-backup-org%3D$ORG%2Cploi-backup-server%3D$SERVER_NAME"
  list="$(api GET "/storage_boxes/$STORAGEBOX_ID/subaccounts?label_selector=$sel")"
  n="$(jq '.subaccounts | length' <<<"$list")"
  [ "$n" -le 1 ] || die "meer dan één sub-account met label server=$SERVER_NAME; ruim eerst op in de Hetzner Console"
  SB_PASSWORD="$(gen_password)"
  if [ "$n" = 0 ]; then
    say "nieuw sub-account aanmaken: servers/$SERVER_NAME"
    body="$(jq -nc --arg p "$SB_PASSWORD" --arg h "servers/$SERVER_NAME" --arg s "$SERVER_NAME" --arg o "$ORG" \
      '{password:$p, home_directory:$h, name:("backup-"+$s), description:("ploi-backup "+$o+" "+$s),
        labels:{"ploi-backup-org":$o, "ploi-backup-server":$s},
        access_settings:{ssh_enabled:true, reachable_externally:true, samba_enabled:false, webdav_enabled:false, readonly:false}}')"
    resp="$(api POST "/storage_boxes/$STORAGEBOX_ID/subaccounts" "$body")"
    sub_id="$(jq -r '.subaccount.id' <<<"$resp")"
    action="$(jq -r '.action.id' <<<"$resp")"
    wait_action "$action"
    SETUP_NOTE="🆕 Nieuwe backup-opslag aangemaakt voor \`$SERVER_NAME\` ($ORG)"
  else
    sub_id="$(jq -r '.subaccounts[0].id' <<<"$list")"
    if [ "${ADOPT:-}" != 1 ]; then
      ask ADOPT "Sub-account voor '$SERVER_NAME' bestaat al (herbouwde server?). Koppelen? Typ 1 als de oude server weg is"
      [ "${ADOPT:-}" = 1 ] || die "er bestaan al backups voor '$SERVER_NAME'. Herbouwde server? Zet dan eenmalig PB_ADOPT=1 in het Ploi-script (zie README). Anders: kies een andere PB_SERVER_NAME"
    fi
    say "bestaand sub-account $sub_id koppelen: wachtwoord resetten"
    resp="$(api POST "/storage_boxes/$STORAGEBOX_ID/subaccounts/$sub_id/actions/reset_subaccount_password" \
      "$(jq -nc --arg p "$SB_PASSWORD" '{password:$p}')")"
    wait_action "$(jq -r '.action.id' <<<"$resp")"
    SETUP_NOTE="♻️ Bestaande backup-opslag gekoppeld aan \`$SERVER_NAME\` ($ORG, herbouwde server?)"
  fi
  resp="$(api GET "/storage_boxes/$STORAGEBOX_ID/subaccounts/$sub_id")"
  SB_USER="$(jq -r '.subaccount.username // empty' <<<"$resp")"
  SB_HOST="$(jq -r '.subaccount.server // empty' <<<"$resp")"
  [ -n "$SB_USER" ] && [ -n "$SB_HOST" ] || die "sub-account $sub_id: username/server ontbreken in API-antwoord"
  say "sub-account: $SB_USER@$SB_HOST (home servers/$SERVER_NAME)"
}

# Maakt MySQL-user 'backup' (alleen leesrechten) zonder root-wachtwoord: init_file + 1 herstart
setup_mysql_user() {
  STEP="MySQL backup-user"
  detect_db || die "geen draaiende MySQL/MariaDB gevonden"
  local sql=/etc/mysql/ploi-backup-init.sql dropin=/etc/mysql/mysql.conf.d/zz-ploi-backup-init.cnf pw grants
  [ -d /etc/mysql/mysql.conf.d ] || dropin=/etc/mysql/conf.d/zz-ploi-backup-init.cnf
  grants="SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS"
  [ "$IS_MARIADB" = 1 ] || grants="$grants, SHOW_ROUTINE"
  pw="$(gen_password)"
  umask 077
  cat > "$sql" <<SQL
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '$pw';
ALTER USER 'backup'@'localhost' IDENTIFIED BY '$pw';
GRANT $grants ON *.* TO 'backup'@'localhost';
SQL
  chown mysql:mysql "$sql"
  printf '[mysqld]\ninit_file = %s\n' "$sql" > "$dropin"
  chmod 644 "$dropin"
  if [ "$IS_MARIADB" = 0 ] && ! mysqld --validate-config; then rm -f "$sql" "$dropin"; die "MySQL-config ongeldig"; fi
  say "$DB_UNIT herstarten (eenmalig, enkele seconden)"
  if ! systemctl restart "$DB_UNIT"; then
    rm -f "$sql" "$dropin"
    systemctl restart "$DB_UNIT" || true
    die "MySQL-herstart met init_file mislukt; teruggezet. Zie /var/log/mysql/error.log"
  fi
  rm -f "$sql" "$dropin"
  write_client_cnf "$MYSQL_CNF" backup "$pw"
  mysql --defaults-extra-file="$MYSQL_CNF" -N -e "SELECT CURRENT_USER()" \
    || die "MySQL draait weer, maar de backup-user werkt niet. Zie /var/log/mysql/error.log (init_file)"
}

cmd_setup() {
  need_root
  mkdir -p "$STATE" "$LOGDIR"
  chmod 700 "$STATE" "$LOGDIR"
  start_log "$LOGDIR/setup.log" append
  trap 'trap - ERR; exec 1>&5 2>&5; say "setup gestopt in stap: $STEP"' ERR
  trap 'on_signal setup_abort' TERM HUP INT
  say "===== setup ploi-backup $ORG op $(hostname -s) ====="
  load_env
  # Secrets kunnen als KEY=waarde-regels via stdin komen (pipe of fifo), zodat ze nooit in argv of bestanden staan
  SETUP_INTERACTIVE=0
  if [ -t 0 ]; then SETUP_INTERACTIVE=1; else
    # Ongevoelig voor spaties, 'export ' en aanhalingstekens; stopt na 5 s stilte (stdin die nooit sluit)
    local line k v
    while IFS= read -r -t 5 line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      line="${line#export }"
      k="${line%%=*}"; v="${line#*=}"
      v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      case "$k" in
        HETZNER_TOKEN|RESTIC_PASSWORD|DISCORD_WEBHOOK|HC_PING_KEY|SB_USER|SB_HOST|SB_PASSWORD|SETUP_SERVER_NAME|SETUP_MYSQL|ADOPT)
          printf -v "$k" '%s' "$v" ;;
      esac
      line=""
    done
  fi
  [ -n "${SETUP_SERVER_NAME:-}" ] && SERVER_NAME="$SETUP_SERVER_NAME"
  STEP="servernaam"
  [[ "$SERVER_NAME" =~ ^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$ ]] \
    || die "ongeldige servernaam '$SERVER_NAME' (kleine letters, cijfers, - en .)"
  tools setup
  install_self

  STEP="SSH-key"
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY" -C "ploi-backup-$ORG@$SERVER_NAME"
  SETUP_NOTE=""
  if [ -n "${SB_USER:-}" ] && [ -n "${SB_HOST:-}" ] && { write_ssh_cfg; key_works; }; then
    say "Storage Box-verbinding werkt al ($SB_USER@$SB_HOST), API niet nodig"
  else
    if [ -z "${SB_PASSWORD:-}" ]; then
      ask HETZNER_TOKEN "Hetzner API-token (read/write, wordt niet opgeslagen)" secret
      [ -n "${HETZNER_TOKEN:-}" ] || die "HETZNER_TOKEN ontbreekt"
      provision_subaccount
    fi
    write_ssh_cfg
    STEP="SSH-key op Storage Box plaatsen"
    upload_key || die "SSH-key plaatsen op $SB_USER@$SB_HOST mislukt (wachtwoord-login of netwerk poort 23?)"
    say "SSH-key werkt"
  fi
  unset HETZNER_TOKEN SB_PASSWORD

  STEP="restic repo"
  ask RESTIC_PASSWORD "restic-wachtwoord (bewaar dit ook in je wachtwoordmanager)" secret
  [ -n "${RESTIC_PASSWORD:-}" ] || die "RESTIC_PASSWORD ontbreekt"
  export RESTIC_PASSWORD
  local rc=0
  r cat config >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) say "restic repo bestaat en wachtwoord klopt" ;;
    10) say "restic repo initialiseren"; r init ;;
    12) die "restic-wachtwoord klopt niet voor de bestaande repo (env niet aangepast)" ;;
    *) r cat config >/dev/null || die "restic repo niet bereikbaar (exitcode $rc)" ;;
  esac
  # Pas na een geslaagde repo-check opslaan, zodat een fout wachtwoord nooit een werkende setup overschrijft
  write_env

  if detect_db; then
    if [ -r "$MYSQL_CNF" ] && mysql --defaults-extra-file="$MYSQL_CNF" -e 'SELECT 1' >/dev/null 2>&1; then
      say "MySQL backup-user werkt"
    elif [ "${SETUP_MYSQL:-}" = 1 ]; then
      setup_mysql_user
    else
      ask SETUP_MYSQL "MySQL backup-user aanmaken? Dit herstart MySQL eenmalig (enkele seconden). Typ 1 voor ja"
      if [ "${SETUP_MYSQL:-}" = 1 ]; then setup_mysql_user
      else warn "geen MySQL backup-user: databases worden niet gebackupt tot je setup met SETUP_MYSQL=1 draait"; fi
    fi
  fi

  say "===== setup klaar: $SERVER_NAME -> $SB_USER@$SB_HOST ====="
  say "Volgende stap: zet de Ploi schedule aan, of start nu: $BIN run"
  discord "${SETUP_NOTE:-🔧 Backup-setup bijgewerkt voor \`$SERVER_NAME\` ($ORG)}"
}

# ======================================================================
#  Backup
# ======================================================================

# Zet DB_UNIT (mysql|mariadb) en IS_MARIADB; geeft 1 als er geen database-server draait
detect_db() {
  command -v mysql >/dev/null 2>&1 || return 1
  if systemctl is-active -q mariadb 2>/dev/null; then DB_UNIT=mariadb
  elif systemctl is-active -q mysql 2>/dev/null; then DB_UNIT=mysql
  elif mysqladmin --no-defaults ping >/dev/null 2>&1; then DB_UNIT=mysql
  else return 1; fi
  IS_MARIADB=0
  if mysqld --version 2>/dev/null | grep -qi mariadb; then IS_MARIADB=1; fi
  return 0
}

dump_mysql() {
  if ! detect_db; then
    if command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1; then
      warn "MySQL/MariaDB is geïnstalleerd maar draait niet: databases NIET gebackupt"
    fi
    return 0
  fi
  STEP="MySQL-dumps"
  if [ ! -r "$MYSQL_CNF" ] || ! mysql --defaults-extra-file="$MYSQL_CNF" -e 'SELECT 1' >/dev/null 2>&1; then
    warn "geen MySQL-toegang ($MYSQL_CNF ontbreekt of werkt niet): databases NIET gebackupt. Oplossing: als root \`SETUP_MYSQL=1 $BIN setup\` (herstart MySQL eenmalig)"
    return 0
  fi
  local my=(mysql --defaults-extra-file="$MYSQL_CNF" -N -B) db need avail extra=()
  need="$("${my[@]}" -e "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables
          WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')")"
  avail="$(df -B1 --output=avail "$DUMP_DIR" | tail -1)"
  if [ "$((need * 3 / 2))" -gt "$avail" ]; then
    warn "te weinig schijfruimte voor dumps ($((avail/1048576)) MB vrij, databases ~$((need/1048576)) MB): databases NIET gebackupt"
    return 0
  fi
  if mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then extra+=(--set-gtid-purged=OFF); fi
  mkdir -p "$DUMP_DIR/mysql"
  local dbs=() list
  list="$("${my[@]}" -e 'SHOW DATABASES' 2>&1)" || { warn "lijst met databases ophalen mislukt: ${list:0:200}"; return 0; }
  mapfile -t dbs < <(grep -Ev '^(information_schema|performance_schema|mysql|sys)$' <<<"$list" || true)
  for db in "${dbs[@]}"; do
    if mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick \
        --routines --triggers --events --hex-blob --no-tablespaces "${extra[@]}" \
        "$db" > "$DUMP_DIR/mysql/$db.sql.tmp" 2> "$DUMP_DIR/mysql/$db.err"; then
      mv -f "$DUMP_DIR/mysql/$db.sql.tmp" "$DUMP_DIR/mysql/$db.sql"
      rm -f "$DUMP_DIR/mysql/$db.err"
      say "dump $db: $(du -h "$DUMP_DIR/mysql/$db.sql" | cut -f1)"
    else
      warn "dump van database $db mislukt: $(head -c 300 "$DUMP_DIR/mysql/$db.err")"
      rm -f "$DUMP_DIR/mysql/$db.sql.tmp"
    fi
  done
  # Gebruikers en rechten (wachtwoorden als hash), zodat .env en wp-config na restore blijven kloppen
  local u out="$DUMP_DIR/mysql/_users_and_grants.sql" users
  : > "$out"
  users="$("${my[@]}" -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
            WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','debian-sys-maint','backup','')")" \
    || { warn "databasegebruikers niet geëxporteerd"; return 0; }
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    { if [ "$IS_MARIADB" = 1 ]; then "${my[@]}" -e "SHOW CREATE USER $u"
      else "${my[@]}" -e "SET print_identified_with_as_hex=ON; SHOW CREATE USER $u"; fi | sed 's/$/;/'
      "${my[@]}" -e "SHOW GRANTS FOR $u" | sed 's/$/;/'; } >> "$out" 2>/dev/null \
      || warn "rechten van $u niet geëxporteerd"
  done <<<"$users"
}

dump_sqlite() {
  STEP="SQLite-dumps"
  local f owner name n=0 need=0 avail files=()
  mkdir -p "$DUMP_DIR/sqlite"
  mapfile -d '' -t files < <(find /home -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' \) \
    -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -print0 2>/dev/null || true)
  for f in "${files[@]}"; do need=$((need + $(stat -c %s "$f" 2>/dev/null || echo 0))); done
  avail="$(df -B1 --output=avail "$DUMP_DIR" | tail -1)"
  if [ "$((need * 3))" -gt "$avail" ]; then
    warn "te weinig schijfruimte voor SQLite-dumps ($((avail/1048576)) MB vrij): SQLite NIET apart gedumpt (de bestanden zelf gaan wel mee)"
    return 0
  fi
  for f in "${files[@]}"; do
    [ "$(head -c 15 "$f" 2>/dev/null)" = "SQLite format 3" ] || continue
    owner="$(stat -c %U "$f")"
    name="$(printf '%s' "${f#/home/}" | tr '/' '_')"
    # Als eigenaar van het bestand, zodat er nooit root-owned -wal/-shm bestanden ontstaan
    if runuser -u "$owner" -- sqlite3 -readonly -bail -cmd '.timeout 20000' "$f" .dump \
        > "$DUMP_DIR/sqlite/$name.sql.tmp" 2> "$DUMP_DIR/sqlite/$name.err" \
        && tail -n 1 "$DUMP_DIR/sqlite/$name.sql.tmp" | grep -q '^COMMIT;'; then
      mv -f "$DUMP_DIR/sqlite/$name.sql.tmp" "$DUMP_DIR/sqlite/$name.sql"
      rm -f "$DUMP_DIR/sqlite/$name.err"
      n=$((n+1))
    else
      warn "SQLite-dump van $f mislukt: $(head -c 300 "$DUMP_DIR/sqlite/$name.err")"
      rm -f "$DUMP_DIR/sqlite/$name.sql.tmp"
    fi
  done
  say "SQLite: $n databases gedumpt"
}

backup_paths() {
  PATHS=(/home /etc /root "$DUMP_DIR")
  local p
  for p in /var/spool/cron /usr/local/sbin /opt; do [ -d "$p" ] && PATHS+=("$p"); done
  EXCLUDES=(
    --exclude-caches
    --exclude '/home/*/.cache' --exclude '/home/*/.npm' --exclude '/home/*/.composer/cache'
    --exclude '/home/*/.config/composer/cache' --exclude '/home/*/.yarn' --exclude '/home/*/.pm2/logs'
    --exclude '/root/.cache' --exclude '/root/.npm' --exclude '/root/snap' --exclude '/root/restore-test'
    --exclude '**/*.sqlite-shm' --exclude '**/*.sqlite-wal'
  )
  # Caches van sites (zelfde lijst als bij terugzetten)
  while IFS= read -r p; do
    case "$p" in /*) EXCLUDES+=(--exclude "/home/*/*$p") ;; *) EXCLUDES+=(--exclude "**/$p") ;; esac
  done < <(site_cache_paths)
}

# Einde van een run: oranje melding bij waarschuwingen, anders alleen Healthchecks
report_done() {
  trap - ERR
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    hc /fail
    discord "🟠 **$1 op \`$SERVER_NAME\` klaar met waarschuwingen** ($ORG)
$(printf -- '- %s\n' "${WARNINGS[@]}")"
  else
    hc
  fi
}

# Alleen de dumps naar een eigen snapshot-reeks (tag db) met eigen bewaartermijn
backup_db_only() {
  local t0="$1"
  STEP="database-dumps backuppen"
  if [ -z "$(find "$DUMP_DIR" -type f -name '*.sql' -print -quit)" ]; then
    warn "db-modus: geen databases gevonden om te backuppen"
  else
    r backup "$DUMP_DIR" --host "$SERVER_NAME" --tag db --retry-lock 10m
  fi
  rm -rf "$DUMP_DIR"
  STEP="retentie (db)"
  r forget --host "$SERVER_NAME" --tag db --group-by host --retry-lock 10m \
    --keep-hourly "$KEEP_DB_HOURLY" --keep-daily "$KEEP_DB_DAILY"
  report_done "DB-backup"
  say "===== db-backup klaar in $(( $(date +%s) - t0 ))s ====="
}

# cmd_backup [full|db]: full = alles (dagelijks); db = alleen database-dumps (optioneel, bv. elk uur)
cmd_backup() {
  local mode="${1:-full}"
  need_root
  mkdir -p "$LOGDIR" "$STATE"
  chmod 700 "$LOGDIR" "$STATE"
  if [ "$mode" = db ]; then LOG="$LOGDIR/last-db.log"; HC_SUFFIX="-db"; fi
  start_log "$LOG"
  trap on_error ERR
  trap 'on_signal on_error' TERM HUP INT
  load_env
  say "===== backup $SERVER_NAME ($ORG, $mode) ====="
  STEP="configuratie"
  [ -f "$ENV_FILE" ] || die "server is nog niet ingericht: draai eenmalig als root \`$BIN setup\`"
  [ -n "$RESTIC_PASSWORD" ] || die "RESTIC_PASSWORD ontbreekt in $ENV_FILE"

  STEP="lock"
  exec 9>"$LOCK"
  # db-run wijkt voor een lopende backup; de volledige backup wacht max 30 min op een lopende db-run
  local wait_s=0
  [ "$mode" = db ] || wait_s=1800
  if ! flock -w "$wait_s" 9; then
    [ "$mode" = full ] && die "kon na 30 min wachten geen lock krijgen (hangt er een db-run of handmatige restic?)"
    say "er draait al een backup, deze db-run stopt"; trap - ERR; exit 0
  fi
  hc /start
  lowprio_self
  local t0 weekday; t0="$(date +%s)"; weekday="$(date +%u)"

  tools
  STEP="restic repo openen"
  r unlock >/dev/null 2>&1 || true
  r cat config >/dev/null

  STEP="dumps voorbereiden"
  rm -rf "$DUMP_DIR"
  mkdir -p "$DUMP_DIR"
  chmod 700 "$DUMP_DIR"
  dump_mysql
  dump_sqlite
  if [ "$mode" = db ]; then
    backup_db_only "$t0"
    return 0
  fi
  backup_paths

  STEP="controle op lege server"
  local last now
  last="$(r snapshots --host "$SERVER_NAME" --tag ploi-backup --latest 1 --json | jq -r '[.[].summary.total_bytes_processed // 0] | max // 0')"
  now="$( { du -sbx "${PATHS[@]}" 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')"
  say "vorige backup $((last/1048576)) MB, nu op schijf $((now/1048576)) MB"
  if [ "$last" -gt "$MIN_GUARD_BYTES" ] && [ "$now" -lt $((last / 2)) ] && [ "${FORCE:-0}" != 1 ]; then
    discord "⚠️ **Backup overgeslagen op \`$SERVER_NAME\`** ($ORG): de server is veel kleiner dan de vorige backup ($((now/1048576)) MB nu, $((last/1048576)) MB toen). Herbouwde of leeggemaakte server? Eerst restoren, of eenmalig als root \`FORCE=1 $BIN backup\`."
    hc /fail
    rm -rf "$DUMP_DIR"
    trap - ERR
    exit 0
  fi

  STEP="bestanden backuppen"
  local rc=0
  r backup "${PATHS[@]}" --host "$SERVER_NAME" --tag ploi-backup --one-file-system \
    --retry-lock 10m "${EXCLUDES[@]}" || rc=$?
  case "$rc" in
    0) ;;
    3) warn "restic kon sommige bestanden niet lezen (zie log); de rest is wel gebackupt" ;;
    *) false ;;
  esac
  rm -rf "$DUMP_DIR"

  STEP="retentie"
  r forget --host "$SERVER_NAME" --tag ploi-backup --group-by host --retry-lock 10m \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
  r forget --host "$SERVER_NAME" --tag pre-restore --group-by host --retry-lock 10m --keep-within 30d >/dev/null

  local snaps
  snaps="$(r snapshots --host "$SERVER_NAME" --tag ploi-backup --json)"
  if [ "$weekday" = "$REPORT_WEEKDAY" ]; then
    STEP="wekelijks prunen"
    r prune --retry-lock 10m
    STEP="integriteitscheck"
    r check --read-data-subset="$CHECK_SUBSET"
    restic cache --cleanup >/dev/null 2>&1 || true
    local size
    size="$(r stats --mode raw-data --json | jq -r '.total_size')"
    discord "🟢 Weekrapport \`$SERVER_NAME\` ($ORG): $(jq length <<<"$snaps") snapshots, repo $((size/1048576)) MB, laatste backup $(jq -r '.[-1].summary | ((.total_bytes_processed/1048576|floor|tostring) + " MB verwerkt, " + (.data_added/1048576|floor|tostring) + " MB nieuw")' <<<"$snaps"), integriteitscheck ($CHECK_SUBSET) ok."
  elif [ "$(jq length <<<"$snaps")" = 1 ]; then
    discord "🟢 Eerste backup van \`$SERVER_NAME\` ($ORG) klaar in $(( ($(date +%s) - t0) / 60 )) min: $(jq -r '.[-1].summary | (.total_bytes_processed/1048576|floor|tostring) + " MB"' <<<"$snaps")."
  fi

  report_done "Backup"
  local dur=$(( $(date +%s) - t0 ))
  say "===== klaar in $((dur/60))m$((dur%60))s ====="
}

# ======================================================================
#  Terugzetten: een site en de database die erbij hoort, samen
# ======================================================================


# Caches en build-output in een site: niet in de backup, en bij terugzetten laat rsync ze staan.
# Met / ervoor: vanaf de root van de site. Zonder: op elke diepte.
site_cache_paths() {
  printf '%s\n' node_modules \
    /storage/framework/cache /storage/framework/views /storage/framework/sessions /storage/framework/testing \
    /storage/statamic/static-urls-cache /storage/statamic/glide /storage/statamic/stache-locks /storage/statamic/static \
    /storage/debugbar /public/static \
    wp-content/cache wp-content/et-cache wp-content/upgrade wp-content/litespeed \
    wp-content/ai1wm-backups wp-content/updraft wp-content/backups-dup-pro wp-content/backups-dup-lite \
    'wp-content/uploads/backwpup-*'
}

# write_client_cnf BESTAND USER WACHTWOORD [HOST PORT]: MySQL-optiebestand, alleen leesbaar voor root
write_client_cnf() {
  ( umask 077
    { echo "[client]"; echo "user = $(cnf_quote "$2")"; echo "password = $(cnf_quote "$3")"
      [ -z "${4:-}" ] || echo "host = $(cnf_quote "$4")"
      [ -z "${5:-}" ] || echo "port = $5"; } > "$1.tmp" && mv -f "$1.tmp" "$1" )
}

# Waarde veilig tussen aanhalingstekens voor een MySQL-optiebestand (backslash en " escapen)
cnf_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

# env_value BESTAND KEY: waarde uit een .env (met of zonder aanhalingstekens)
env_value() {
  { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || true; } | tail -n 1 | sed -E \
    -e "s/^[^=]*=[[:space:]]*//" -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\1/"
}
# wp_value BESTAND KEY: waarde uit define('KEY', 'waarde') in wp-config.php
wp_value() {
  { grep -E "define\([[:space:]]*['\"]$2['\"]" "$1" 2>/dev/null || true; } | head -n 1 | sed -E \
    "s/.*define\([[:space:]]*['\"]$2['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/"
}

# pick_snapshot WANNEER: latest, een datum (JJJJ-MM-DD: laatste backup van die dag) of een snapshot-ID
pick_snapshot() {
  local all; all="$(r snapshots --host "$SERVER_NAME" --tag ploi-backup --json)"
  case "${1:-latest}" in
    latest) jq -r 'sort_by(.time) | .[-1].short_id // empty' <<<"$all" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      jq -r --arg d "$1" '[.[] | select(.time[0:10] <= $d)] | sort_by(.time) | .[-1].short_id // empty' <<<"$all" ;;
    *) [[ "$1" =~ ^[0-9a-f]{8,64}$ ]] && echo "$1" ;;
  esac
}

# Bepaalt welke database bij de site hoort, uit de teruggezette .env of wp-config.php.
# Zet DB_KIND (mysql|sqlite|none), DB_NAME, DB_USER, DB_PASS, DB_HOST, DB_PORT, DB_FILE
detect_site_db() {
  local src="$1" live="$2" conn cfg=""
  DB_KIND=none; DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST=127.0.0.1; DB_PORT=3306; DB_FILE=""
  if [ -f "$src/.env" ]; then
    conn="$(env_value "$src/.env" DB_CONNECTION)"
    case "$conn" in
      mysql|mariadb)
        DB_KIND=mysql
        DB_NAME="$(env_value "$src/.env" DB_DATABASE)"; DB_USER="$(env_value "$src/.env" DB_USERNAME)"
        DB_PASS="$(env_value "$src/.env" DB_PASSWORD)"
        DB_HOST="$(env_value "$src/.env" DB_HOST)"; DB_PORT="$(env_value "$src/.env" DB_PORT)" ;;
      sqlite)
        DB_KIND=sqlite
        DB_FILE="$(env_value "$src/.env" DB_DATABASE)"
        case "$DB_FILE" in
          "") DB_FILE="$live/database/database.sqlite" ;;
          /*) ;;
          *) DB_FILE="$live/$DB_FILE" ;;
        esac ;;
    esac
  else
    for cfg in "$src/wp-config.php" "$src/public/wp-config.php"; do [ -f "$cfg" ] && break; cfg=""; done
    if [ -n "$cfg" ]; then
      DB_KIND=mysql
      DB_NAME="$(wp_value "$cfg" DB_NAME)"; DB_USER="$(wp_value "$cfg" DB_USER)"
      DB_PASS="$(wp_value "$cfg" DB_PASSWORD)"; DB_HOST="$(wp_value "$cfg" DB_HOST)"
    fi
  fi
  DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"
  if [[ "$DB_HOST" == *:* ]]; then DB_PORT="${DB_HOST##*:}"; DB_HOST="${DB_HOST%%:*}"; fi
  [ "$DB_HOST" = localhost ] && DB_HOST=127.0.0.1
  return 0
}

# Onderhoudsmodus tijdens terugzetten: Laravel/Statamic via artisan, WordPress via .maintenance.
# Alles als de eigenaar van de site, zodat root nooit schrijft naar iets wat de site-user kan klaarzetten.
site_down() { # site_down MAP EIGENAAR
  MAINT_DIR="$1"; MAINT_USER="$2"; MAINT_WP=""
  if [ -f "$1/artisan" ]; then
    runuser -u "$2" -- php "$1/artisan" down >/dev/null 2>&1 || true
    return 0
  fi
  local w
  for w in "$1/public" "$1"; do
    if [ -f "$w/wp-config.php" ] || [ -f "$w/wp-load.php" ]; then
      # shellcheck disable=SC2016
      runuser -u "$2" -- sh -c 'printf "<?php \$upgrading = time(); ?>" > "$1"' _ "$w/.maintenance" 2>/dev/null && MAINT_WP="$w/.maintenance"
      return 0
    fi
  done
}
site_up() {
  [ -n "${MAINT_DIR:-}" ] || return 0
  if [ -f "$MAINT_DIR/artisan" ]; then
    runuser -u "$MAINT_USER" -- php "$MAINT_DIR/artisan" optimize:clear >/dev/null 2>&1 || true
    [ ! -f "$MAINT_DIR/please" ] || runuser -u "$MAINT_USER" -- php "$MAINT_DIR/please" static:clear >/dev/null 2>&1 || true
    runuser -u "$MAINT_USER" -- php "$MAINT_DIR/artisan" up >/dev/null 2>&1 || true
  fi
  [ -z "${MAINT_WP:-}" ] || rm -f "$MAINT_WP"
  MAINT_DIR=""
}

# Bij een fout tijdens terugzetten: site uit onderhoud halen, dan de gewone foutmelding
restore_fail() {
  local rc="$1"
  if [ "$BASH_SUBSHELL" -gt 0 ]; then return "$rc"; fi
  rm -f "${RESTORE_CNF:-}"
  [ -z "${RESTORE_TARGET:-}" ] || rm -rf "$RESTORE_TARGET"
  site_up
  on_error "$rc"
}

# Zoekt de map van een site: op de server, of anders in een snapshot. Leeg als hij nergens is.
find_site_dir() {
  local site="$1" snap="${2:-}" d live=""
  for d in /home/*/"$site"; do
    [ -d "$d" ] || continue
    [ -z "$live" ] || die "site $site staat meerdere keren in /home"
    live="$d"
  done
  if [ -z "$live" ] && [ -n "$snap" ]; then
    live="$(r ls --json "$snap" /home 2>/dev/null | jq -r --arg s "$site" \
      'select(.type == "dir") | .path | select((split("/") | length) == 4 and (split("/") | .[3]) == $s)' | head -n 1)"
  fi
  printf '%s' "$live"
}

human() { numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
size_or_dash() { if [ "${1:-0}" = 0 ]; then echo -; else human "$1"; fi; }

# cmd_list [SITE]: overzicht van alle backups, of per backup de grootte van één site en zijn database
cmd_list() {
  local site="${1:-${LIST_SITE:-}}"
  need_root
  load_env
  [ -f "$ENV_FILE" ] || die "deze server is nog niet ingericht"
  local snaps; snaps="$(r snapshots --host "$SERVER_NAME" --json)"
  local rows
  rows="$(jq -r 'sort_by(.time) | reverse | .[] | [.short_id, (.time[0:16] | sub("T"; " ")),
      (if ((.tags // []) | index("db")) then "database" elif ((.tags // []) | index("pre-restore")) then "veiligheid" else "volledig" end),
      (.summary.total_bytes_processed // 0), (.summary.data_added // 0)] | @tsv' <<<"$snaps")"
  [ -n "$rows" ] || { say "Nog geen backups van $SERVER_NAME."; return 0; }

  if [ -z "$site" ]; then
    echo "Backups van $SERVER_NAME (tijden in UTC):"
    printf '  %-9s %-16s  %-10s %9s %9s\n' ID DATUM SOORT TOTAAL NIEUW
    local id t kind tot new
    while IFS=$'\t' read -r id t kind tot new; do
      printf '  %-9s %-16s  %-10s %9s %9s\n' "$id" "$t" "$kind" "$(human "$tot")" "$(human "$new")"
    done <<<"$rows"
    echo "Opslag op de Storage Box (versleuteld, ontdubbeld): $(human "$(r stats --mode raw-data --json | jq -r '.total_size')")"
    echo "Sites: $(find /home -mindepth 2 -maxdepth 2 -type d -name '*.*' -printf '%f ' 2>/dev/null)"
    echo "Details van één site: ploi-backup list SITE. Terugzetten: RESTORE_SITE=SITE RESTORE_WHEN=ID."
    return 0
  fi

  [[ "$site" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "ongeldige sitenaam '$site'"
  local latest live
  latest="$(jq -r '[.[] | select((.tags // []) | index("ploi-backup"))] | sort_by(.time) | .[-1].short_id // empty' <<<"$snaps")"
  live="$(find_site_dir "$site" "$latest")"
  [ -n "$live" ] || die "site $site staat niet op deze server en niet in de laatste backup"
  local dump=""
  if [ -d "$live" ]; then
    detect_site_db "$live" "$live"
    case "$DB_KIND" in
      mysql) dump="$DUMP_DIR/mysql/$DB_NAME.sql" ;;
      sqlite) dump="$DUMP_DIR/sqlite/$(printf '%s' "${DB_FILE#/home/}" | tr '/' '_').sql" ;;
    esac
  fi
  echo "Backups van $site ($live) op $SERVER_NAME (tijden in UTC):"
  printf '  %-9s %-16s  %-10s %9s %9s\n' ID DATUM SOORT BESTANDEN DATABASE
  local id t kind tot new files db
  while IFS=$'\t' read -r id t kind tot new; do
    files=0; db=0
    if [ "$kind" != database ]; then
      files="$(r ls --json --recursive "$id" "$live" 2>/dev/null | jq -s '[.[] | select(.type == "file") | .size] | add // 0')"
    fi
    [ -z "$dump" ] || db="$(r ls --json "$id" "$dump" 2>/dev/null | jq -s '[.[] | select(.type == "file") | .size] | add // 0')"
    [ "$files" != 0 ] || [ "$db" != 0 ] || continue
    printf '  %-9s %-16s  %-10s %9s %9s\n' "$id" "$t" "$kind" \
      "$(size_or_dash "$files")" "$(size_or_dash "$db")"
  done <<<"$rows"
  echo "Terugzetten: RESTORE_SITE=$site RESTORE_WHEN=ID (eerst met RESTORE_APPLY=0)."
}

# Controleert vóór er iets verandert of de site-user de database mag vervangen. Zet MY (mysql-commando).
restore_mysql_check() {
  local dump="$1"
  STEP="database controleren"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_$-]+$ ]] || die "ongeldige databasenaam '$DB_NAME' in de site-config"
  [[ "$DB_PORT" =~ ^[0-9]+$ ]] || DB_PORT=3306
  RESTORE_CNF="$STATE/restore-db.cnf"
  write_client_cnf "$RESTORE_CNF" "$DB_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT"
  MY=(mysql --defaults-file="$RESTORE_CNF" --database="$DB_NAME" -N -B)
  if ! "${MY[@]}" -e "SELECT 1" >/dev/null 2>&1; then
    # Lokaal via de socket (users die alleen @localhost mogen)
    write_client_cnf "$RESTORE_CNF" "$DB_USER" "$DB_PASS"
    "${MY[@]}" -e "SELECT 1" >/dev/null || die "inloggen op $DB_NAME met de gegevens uit de site lukt niet"
  fi
  local foreign
  foreign="$("${MY[@]}" -e "SELECT GROUP_CONCAT(CONCAT(t, ' ', n) SEPARATOR ', ') FROM (
      SELECT 'view' t, table_name n, definer d FROM information_schema.views WHERE table_schema = DATABASE()
      UNION ALL SELECT 'trigger', trigger_name, definer FROM information_schema.triggers WHERE trigger_schema = DATABASE()
      UNION ALL SELECT 'routine', routine_name, definer FROM information_schema.routines WHERE routine_schema = DATABASE()
      UNION ALL SELECT 'event', event_name, definer FROM information_schema.events WHERE event_schema = DATABASE()) x
      WHERE SUBSTRING_INDEX(d, '@', 1) <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1)")"
  if [ -n "$foreign" ] && [ "$foreign" != NULL ]; then
    die "$DB_NAME bevat objecten van een andere MySQL-user ($foreign); de site-user mag die niet vervangen. Er is niets veranderd. Zet de database terug als MySQL-root (zie README)"
  fi
  # Met binlog aan mag een gewone user alleen triggers/routines maken als log_bin_trust_function_creators=1
  if grep -qE '^/\*!50003 (CREATE\*/|TRIGGER)|^CREATE[^;]*(PROCEDURE|FUNCTION)' "$dump" \
     && [ "$("${MY[@]}" -e "SELECT @@log_bin AND NOT @@log_bin_trust_function_creators")" = 1 ]; then
    die "de backup van $DB_NAME bevat triggers of routines, en MySQL staat dat de site-user niet toe (binlog aan). Er is niets veranderd. Zet de database terug als MySQL-root (zie README)"
  fi
}

# Importeert de dump en haalt daarna weg wat er na de backup is bijgekomen, zodat de database gelijk is aan de backup
restore_mysql_import() {
  local dump="$1" pre="$2" want have obj
  STEP="database terugzetten"
  # De dump vervangt elke tabel zelf (DROP ... IF EXISTS). DEFINER weg: objecten komen op naam van de site-user.
  # shellcheck disable=SC2016
  sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$dump" | "${MY[@]}" \
    || die "importeren van $DB_NAME mislukt; zet zo nodig de veiligheidsbackup $pre terug"
  # shellcheck disable=SC2016
  want="$( { grep -oE '^CREATE TABLE `[^`]+`|^/\*!50001 (CREATE )?VIEW `[^`]+`' "$dump" || true; } | sed -E 's/.*`([^`]+)`$/TABLE \1/'
          { grep -oE '(PROCEDURE|FUNCTION|EVENT) `[^`]+`' "$dump" || true; } | tr -d '`' )"
  want="$(sort -u <<<"$want")"
  have="$("${MY[@]}" -e "SELECT CONCAT('TABLE ', table_name) FROM information_schema.tables WHERE table_schema = DATABASE()
      UNION SELECT CONCAT(routine_type, ' ', routine_name) FROM information_schema.routines WHERE routine_schema = DATABASE()
      UNION SELECT CONCAT('EVENT ', event_name) FROM information_schema.events WHERE event_schema = DATABASE()" | sort -u)"
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    local kind="${obj%% *}" name="${obj#* }"
    [[ "$name" == *'`'* ]] && { warn "$obj niet opgeruimd (vreemde naam)"; continue; }
    local sql="DROP $kind IF EXISTS \`$name\`"
    [ "$kind" = TABLE ] && sql="SET FOREIGN_KEY_CHECKS=0; DROP VIEW IF EXISTS \`$name\`; DROP TABLE IF EXISTS \`$name\`"
    if "${MY[@]}" -e "$sql" 2>/dev/null; then say "$obj (aangemaakt na de backup) verwijderd"
    else warn "$obj kon niet weg"; fi
  done < <(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
  rm -f "$RESTORE_CNF"
}

restore_sqlite_import() {
  local dump="$1" owner="$2" tmpdb="$DB_FILE.restore-$$"
  STEP="database terugzetten"
  runuser -u "$owner" -- sqlite3 "$tmpdb" < "$dump"
  [ "$(runuser -u "$owner" -- sqlite3 "$tmpdb" 'PRAGMA integrity_check')" = ok ] || { rm -f "$tmpdb"; die "SQLite-controle mislukt"; }
  rm -f "$DB_FILE-wal" "$DB_FILE-shm"
  mv -f "$tmpdb" "$DB_FILE"
}

# cmd_restore [SITE] [--when X] [--apply] [--files-only|--db-only]
# Of via omgeving (Ploi-script): RESTORE_SITE, RESTORE_WHEN, RESTORE_APPLY=1, RESTORE_PART=files|db
cmd_restore() {
  local site="${RESTORE_SITE:-}" when="${RESTORE_WHEN:-latest}" apply="${RESTORE_APPLY:-0}" part="${RESTORE_PART:-all}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --when) when="${2:-}"; shift ;;
      --when=*) when="${1#--when=}" ;;
      --files-only) part=files ;;
      --db-only) part=db ;;
      -*) die "onbekende optie $1" ;;
      *) site="$1" ;;
    esac
    shift
  done
  need_root
  mkdir -p "$LOGDIR"
  start_log "$LOGDIR/restore.log" append
  ACTION="Terugzetten"
  trap 'restore_fail $?' ERR
  trap 'on_signal restore_fail' TERM HUP INT
  load_env
  [ -f "$ENV_FILE" ] || die "deze server is nog niet ingericht"
  if [ -z "$site" ]; then trap - ERR; cmd_list; return 0; fi
  [[ "$site" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "ongeldige sitenaam '$site'"
  case "$part" in all|files|db) ;; *) die "RESTORE_PART moet all, files of db zijn" ;; esac
  STEP="tools"
  apt_install rsync
  STEP="lock"
  exec 9>"$LOCK"
  flock -w 900 9 || die "er draait al een backup; probeer het over een paar minuten opnieuw"

  STEP="snapshot kiezen"
  local snap; snap="$(pick_snapshot "$when")"
  [ -n "$snap" ] || die "geen backup gevonden voor '$when' (zie: ploi-backup restore zonder site)"
  local stime; stime="$(r snapshots "$snap" --json | jq -r '.[0].time[0:16] | sub("T"; " ")')"

  STEP="site zoeken"
  local live; live="$(find_site_dir "$site" "$snap")"
  [ -n "$live" ] || die "site $site staat niet op deze server en niet in backup $snap"
  [ -d "$live" ] || [ "$apply" != 1 ] || die "site $live bestaat nog niet op deze server: maak hem eerst aan in Ploi"
  say "Site: $live, backup: $snap ($stime UTC), deel: $part, $([ "$apply" = 1 ] && echo 'ECHT TERUGZETTEN' || echo 'proef')"

  STEP="uit backup halen"
  local target="/root/restore-test/$site-$snap"
  find /root/restore-test -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$target"; mkdir -p "$target"
  RESTORE_TARGET="$target"
  r restore "$snap" --target "$target" --include "$live" --include "$DUMP_DIR" >/dev/null
  local src="$target$live" dumps="$target$DUMP_DIR"
  [ -d "$src" ] || die "site $live zit niet in backup $snap"

  # Welke database: uit de config van de backup, of bij alleen-database uit de huidige site (actuele gegevens)
  local cfg="$src"
  if [ "$part" = db ] && { [ -f "$live/.env" ] || [ -f "$live/wp-config.php" ] || [ -f "$live/public/wp-config.php" ]; }; then cfg="$live"; fi
  detect_site_db "$cfg" "$live"
  local dump=""
  case "$DB_KIND" in
    mysql)  dump="$dumps/mysql/$DB_NAME.sql" ;;
    sqlite)
      # De .env is van de site-user: het SQLite-bestand moet binnen de site liggen
      case "$(realpath -m "$DB_FILE")/" in "$(realpath -m "$live")"/*) ;; *) die "SQLite-pad $DB_FILE ligt buiten de site" ;; esac
      dump="$dumps/sqlite/$(printf '%s' "${DB_FILE#/home/}" | tr '/' '_').sql" ;;
  esac
  if [ "$DB_KIND" = none ]; then say "Database: geen (geen .env met DB_CONNECTION en geen wp-config.php)"
  elif [ -f "$dump" ]; then say "Database: $DB_KIND ${DB_NAME:-$DB_FILE}, dump $(du -h "$dump" | cut -f1)"
  else
    [ "$part" = files ] || die "geen dump van ${DB_NAME:-$DB_FILE} in backup $snap"
    dump=""
  fi
  [ "$part" = files ] && dump=""

  if [ "$apply" != 1 ]; then
    [ -n "$dump" ] && cp "$dump" "$target/database.sql"
    rm -rf "${target:?}/var"
    RESTORE_TARGET=""
    say "PROEF klaar, er is niets live veranderd. Bestanden: $target${live}  Database-dump: ${dump:+$target/database.sql}"
    say "Echt terugzetten: zelfde opdracht met RESTORE_APPLY=1 (of --apply)."
    return 0
  fi

  local owner; owner="$(stat -c %U "$live")"
  [ -z "$dump" ] || [ "$DB_KIND" != mysql ] || restore_mysql_check "$dump"

  STEP="veiligheidsbackup van de huidige staat"
  rm -rf "$DUMP_DIR"; mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
  dump_mysql; dump_sqlite
  local pre
  pre="$(r backup "$live" "$DUMP_DIR" --host "$SERVER_NAME" --tag pre-restore --json --quiet \
    | jq -r 'select(.message_type == "summary") | .snapshot_id[0:8]')"
  rm -rf "$DUMP_DIR"
  [ -n "$pre" ] || die "veiligheidsbackup mislukt, er is niets veranderd"
  say "Veiligheidsbackup van vóór het terugzetten: $pre (terugdraaien: RESTORE_WHEN=$pre)"
  PRE_SNAPSHOT="$pre"

  site_down "$live" "$owner"
  if [ "$part" != db ]; then
    STEP="bestanden terugzetten"
    # Caches staan niet in de backup: die laat rsync staan; SQLite gaat apart via de dump
    local keep=() p
    while IFS= read -r p; do keep+=(--exclude "$p"); done < <(site_cache_paths)
    rsync -a --delete "${keep[@]}" --exclude '*.sqlite' --exclude '*.sqlite3' \
      --exclude '*.sqlite-wal' --exclude '*.sqlite-shm' --exclude .maintenance "$src/" "$live/"
    [ "$(stat -c %u:%g "$src")" = "$(stat -c %u:%g "$live")" ] || chown -R --reference="$live" "$live"
    say "Bestanden teruggezet"
  fi
  if [ -n "$dump" ]; then
    if [ "$DB_KIND" = mysql ]; then restore_mysql_import "$dump" "$pre"; else restore_sqlite_import "$dump" "$owner"; fi
    say "Database teruggezet"
  fi
  site_up
  trap - ERR
  rm -rf "$target"
  say "===== $site teruggezet naar $stime UTC ====="
  discord "♻️ \`$site\` op \`$SERVER_NAME\` teruggezet naar de backup van $stime UTC ($part). Veiligheidsbackup van daarvoor: \`$pre\`."
}

# ======================================================================
#  Ingangen
# ======================================================================

setup_abort() { say "setup gestopt in stap: $STEP"; exit "$1"; }

# Nieuwe server: richt zichzelf in met de waarden uit het Ploi-script (PB_*).
# Setup draait als apart proces; secrets gaan via de omgeving, nooit via argv of bestanden.
auto_setup() {
  STEP="automatisch inrichten"
  local host; host="$(hostname -s)"
  if [ -z "${PB_RESTIC_PASSWORD:-}" ] || { [ -z "${PB_HETZNER_TOKEN:-}" ] && [ -z "${SB_PASSWORD:-}" ]; }; then
    say "Nieuwe server: vul PB_HETZNER_TOKEN en PB_RESTIC_PASSWORD in het Ploi-script in en run het opnieuw."
    discord "🔧 \`$host\` ($ORG) is nog niet gekoppeld. Vul \`PB_HETZNER_TOKEN\` in het Ploi-script in, run het op deze server en maak het token daarna weer leeg."
    hc /fail
    exit 1
  fi
  say "Nieuwe server: automatisch inrichten (duurt 1-3 minuten)"
  if ! HETZNER_TOKEN="${PB_HETZNER_TOKEN:-}" RESTIC_PASSWORD="$PB_RESTIC_PASSWORD" \
       SETUP_MYSQL="${PB_SETUP_MYSQL:-1}" SETUP_SERVER_NAME="${PB_SERVER_NAME:-}" ADOPT="${PB_ADOPT:-}" \
       "$BIN" setup </dev/null; then
    discord "🔴 **Inrichten mislukt op \`$host\`** ($ORG)
\`\`\`
$(tail -n 12 "$LOGDIR/setup.log" 2>/dev/null | cut -c1-200)
\`\`\`"
    hc /fail
    exit 1
  fi
}

# cmd_run [full|db]: start vanuit Ploi op de achtergrond
cmd_run() {
  local mode="${1:-full}" unit="$UNIT"
  [ "$mode" = db ] && unit="$UNIT-db"
  need_root
  STEP="starten vanuit Ploi"
  load_env
  trap on_error ERR
  install_self
  if [ ! -f "$ENV_FILE" ]; then auto_setup; load_env; fi
  if [ -n "${PB_HETZNER_TOKEN:-}" ]; then
    say "Server is ingericht. Je kunt PB_HETZNER_TOKEN in het Ploi-script weer leegmaken."
  fi
  unset PB_HETZNER_TOKEN PB_RESTIC_PASSWORD
  if ! command -v systemd-run >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then trap - ERR; exec "$BIN" backup "$mode"; fi
  if systemctl is-active -q "$unit" 2>/dev/null; then
    say "backup draait al (journalctl -u $unit -f)"
    exit 0
  fi
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --unit="$unit" --description="ploi-backup $ORG $mode" --collect --quiet --setenv=HOME=/root \
    -p Nice=10 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 \
    -p CPUWeight=20 -p IOWeight=20 -p RuntimeMaxSec=12h "$BIN" backup "$mode"
  say "Backup ($mode) gestart op de achtergrond (unit $unit)."
  say "Volgen: journalctl -u $unit -f    Log: $LOGDIR/"
}

cmd_restic() {
  need_root
  load_env
  [ -f "$ENV_FILE" ] || die "nog niet ingericht"
  r "$@"
}

cmd_status() {
  need_root
  load_env
  echo "org=$ORG server=$SERVER_NAME repo=${SB_USER:-?}@${SB_HOST:-?}:restic"
  systemctl status "$UNIT" --no-pager 2>/dev/null | head -5 || true
  [ -f "$ENV_FILE" ] && r snapshots --host "$SERVER_NAME" --latest 5 || true
  if [ -f "$LOG" ]; then echo "--- laatste log"; tail -n 15 "$LOG"; fi
}

usage() {
  cat <<USAGE
Gebruik: $BIN [run|setup|backup|status|restic ...]
  run     (standaard, Ploi schedule) start de volledige backup op de achtergrond
  run-db  alleen databases (optioneel, aparte Ploi schedule, bv. elk uur)
  setup   eenmalig inrichten (vraagt Hetzner-token en restic-wachtwoord)
  backup  backup in de voorgrond: backup [full|db] (FORCE=1 negeert de lege-server-check)
  status  laatste snapshots en log
  list    overzicht van alle backups: list [SITE] (met site: grootte van bestanden en database per backup)
  restore site + database terugzetten: restore SITE [--when latest|JJJJ-MM-DD|ID] [--apply] [--files-only|--db-only]
          zonder --apply: proef naar /root/restore-test, er verandert niets live
  restic  restic met de juiste repo en wachtwoord, bv: $BIN restic snapshots
USAGE
}

main() {
  set -Eeuo pipefail
  export LC_ALL=C.UTF-8 PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  # systemd-run en Ploi geven niet altijd HOME mee; restic en ssh hebben het nodig
  export HOME="${HOME:-/root}"
  [ "$(id -u)" != 0 ] || export HOME=/root RESTIC_CACHE_DIR=/root/.cache/restic
  umask 077
  if ! [[ "$ORG" =~ ^[a-z0-9-]+$ ]]; then
    echo "ploi-backup: PB_ORG ontbreekt of is ongeldig (alleen a-z, 0-9 en -). Zie README." >&2; exit 2
  fi
  init_vars
  case "${1:-run}" in
    run) cmd_run full ;;
    run-db) cmd_run db ;;
    setup) cmd_setup ;;
    backup) cmd_backup "${2:-full}" ;;
    status) cmd_status ;;
    restic) shift; cmd_restic "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    list) shift; cmd_list "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
