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
  exec 3>&1 4>&2
  if [ "${2:-}" = append ]; then exec > >(tee -a "$1" >&3) 2>&1; else exec > >(tee "$1" >&3) 2>&1; fi
  TEE_PID=$!
  exec 5>&1
  LOG_ACTIVE=1
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

tail_log() { if [ "${LOG_ACTIVE:-0}" = 1 ] && [ -f "$LOG" ]; then tail -n "${1:-15}" "$LOG" | cut -c1-200; fi; }

on_error() {
  local rc=$?
  # set -E erft de trap in $(...): daar alleen doorgeven, de buitenste shell meldt
  if [ "$BASH_SUBSHELL" -gt 0 ]; then return "$rc"; fi
  trap - ERR
  # De trap kan afgaan binnen een functie met >/dev/null (bv. r cat config): terug naar de log
  if [ "${LOG_ACTIVE:-0}" = 1 ]; then exec 1>&5 2>&5; fi
  say "Gestopt met exitcode $rc in stap: $STEP"
  sleep 1
  hc /fail
  discord "🔴 **Backup mislukt op \`$SERVER_NAME\`** ($ORG, stap: $STEP)
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
    printf 'SB_USER=%q\nSB_HOST=%q\nSB_SUBACCOUNT_ID=%q\n' "$SB_USER" "$SB_HOST" "${SB_SUBACCOUNT_ID:-}"
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
      [ "${ADOPT:-}" = 1 ] || die "bestaand sub-account niet gekoppeld (zet ADOPT=1 als dit de bedoeling is)"
    fi
    say "bestaand sub-account $sub_id koppelen: wachtwoord resetten"
    resp="$(api POST "/storage_boxes/$STORAGEBOX_ID/subaccounts/$sub_id/actions/reset_subaccount_password" \
      "$(jq -nc --arg p "$SB_PASSWORD" '{password:$p}')")"
    wait_action "$(jq -r '.action.id' <<<"$resp")"
    SETUP_NOTE="♻️ Bestaande backup-opslag gekoppeld aan \`$SERVER_NAME\` ($ORG, herbouwde server?)"
  fi
  resp="$(api GET "/storage_boxes/$STORAGEBOX_ID/subaccounts/$sub_id")"
  SB_SUBACCOUNT_ID="$sub_id"
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
  printf '[client]\nuser = backup\npassword = "%s"\n' "$pw" > "$MYSQL_CNF"
  chmod 600 "$MYSQL_CNF"
  mysql --defaults-extra-file="$MYSQL_CNF" -N -e "SELECT CURRENT_USER()" \
    || die "MySQL draait weer, maar de backup-user werkt niet. Zie /var/log/mysql/error.log (init_file)"
}

cmd_setup() {
  need_root
  mkdir -p "$STATE" "$LOGDIR"
  chmod 700 "$STATE" "$LOGDIR"
  start_log "$LOGDIR/setup.log" append
  trap 'trap - ERR; exec 1>&5 2>&5; say "setup gestopt in stap: $STEP"' ERR
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
  local dbs=()
  mapfile -t dbs < <("${my[@]}" -e 'SHOW DATABASES' | { grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true; })
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
  local u out="$DUMP_DIR/mysql/_users_and_grants.sql"
  : > "$out"
  while IFS=$'\t' read -r u; do
    [ -n "$u" ] || continue
    { if [ "$IS_MARIADB" = 1 ]; then "${my[@]}" -e "SHOW CREATE USER $u"
      else "${my[@]}" -e "SET print_identified_with_as_hex=ON; SHOW CREATE USER $u"; fi | sed 's/$/;/'
      "${my[@]}" -e "SHOW GRANTS FOR $u" | sed 's/$/;/'; } >> "$out" 2>/dev/null \
      || warn "rechten van $u niet geëxporteerd"
  done < <("${my[@]}" -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
            WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','debian-sys-maint','backup','')")
}

dump_sqlite() {
  STEP="SQLite-dumps"
  local f owner name n=0 need avail
  mkdir -p "$DUMP_DIR/sqlite"
  need="$( { find /home -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' \) -printf '%s\n' 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')"
  avail="$(df -B1 --output=avail "$DUMP_DIR" | tail -1)"
  if [ "$((need * 3))" -gt "$avail" ]; then
    warn "te weinig schijfruimte voor SQLite-dumps ($((avail/1048576)) MB vrij): SQLite NIET apart gedumpt (de bestanden zelf gaan wel mee)"
    return 0
  fi
  while IFS= read -r -d '' f; do
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
  done < <(find /home -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' \) \
             -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -print0 2>/dev/null)
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
    --exclude '**/node_modules'
    # Laravel / Statamic: alles wat vanzelf opnieuw wordt opgebouwd
    --exclude '/home/*/*/storage/framework/cache' --exclude '/home/*/*/storage/framework/views'
    --exclude '/home/*/*/storage/framework/sessions' --exclude '/home/*/*/storage/framework/testing'
    --exclude '/home/*/*/storage/statamic/static-urls-cache' --exclude '/home/*/*/storage/statamic/glide'
    --exclude '/home/*/*/storage/statamic/stache-locks' --exclude '/home/*/*/storage/statamic/static'
    --exclude '/home/*/*/storage/debugbar' --exclude '/home/*/*/public/static'
    # WordPress: caches en backups van backup-plugins (uploads gaan wél mee)
    --exclude '**/wp-content/cache' --exclude '**/wp-content/et-cache' --exclude '**/wp-content/upgrade'
    --exclude '**/wp-content/ai1wm-backups' --exclude '**/wp-content/updraft'
    --exclude '**/wp-content/backups-dup-pro' --exclude '**/wp-content/backups-dup-lite'
    --exclude '**/wp-content/uploads/backwpup-*' --exclude '**/wp-content/litespeed'
    --exclude '**/*.sqlite-shm' --exclude '**/*.sqlite-wal'
  )
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
  trap - ERR
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    hc /fail
    discord "🟠 **DB-backup op \`$SERVER_NAME\` klaar met waarschuwingen** ($ORG)
$(printf -- '- %s\n' "${WARNINGS[@]}")"
  else
    hc
  fi
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
  local t0; t0="$(date +%s)"

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

  local snaps
  snaps="$(r snapshots --host "$SERVER_NAME" --tag ploi-backup --json)"
  if [ "$(date +%u)" = "$REPORT_WEEKDAY" ]; then
    STEP="wekelijks prunen"
    r prune --retry-lock 10m
    STEP="integriteitscheck"
    r check --read-data-subset="$CHECK_SUBSET"
    local size
    size="$(r stats --mode raw-data --json | jq -r '.total_size')"
    discord "🟢 Weekrapport \`$SERVER_NAME\` ($ORG): $(jq length <<<"$snaps") snapshots, repo $((size/1048576)) MB, laatste backup $(jq -r '.[-1].summary | ((.total_bytes_processed/1048576|floor|tostring) + " MB verwerkt, " + (.data_added/1048576|floor|tostring) + " MB nieuw")' <<<"$snaps"), integriteitscheck ($CHECK_SUBSET) ok."
  elif [ "$(jq length <<<"$snaps")" = 1 ]; then
    discord "🟢 Eerste backup van \`$SERVER_NAME\` ($ORG) klaar in $(( ($(date +%s) - t0) / 60 )) min: $(jq -r '.[-1].summary | (.total_bytes_processed/1048576|floor|tostring) + " MB"' <<<"$snaps")."
  fi

  trap - ERR
  local dur=$(( $(date +%s) - t0 ))
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    hc /fail
    local w; w="$(printf -- '- %s\n' "${WARNINGS[@]}")"
    discord "🟠 **Backup op \`$SERVER_NAME\` klaar met waarschuwingen** ($ORG)
$w"
  else
    hc
  fi
  say "===== klaar in $((dur/60))m$((dur%60))s ====="
}

# ======================================================================
#  Ingangen
# ======================================================================

# cmd_run [full|db]: start vanuit Ploi op de achtergrond
cmd_run() {
  local mode="${1:-full}" unit="$UNIT"
  [ "$mode" = db ] && unit="$UNIT-db"
  need_root
  STEP="starten vanuit Ploi"
  load_env
  trap on_error ERR
  install_self
  if [ ! -f "$ENV_FILE" ]; then
    say "Deze server is nog niet ingericht. Eenmalig als root: $BIN setup"
    discord "🔧 \`$(hostname -s)\` ($ORG): backup nog niet ingericht. Eenmalig als root: \`$BIN setup\`"
    exit 1
  fi
  if ! command -v systemd-run >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then trap - ERR; exec "$BIN" backup "$mode"; fi
  if systemctl is-active -q "$unit" 2>/dev/null; then
    say "backup draait al (journalctl -u $unit -f)"
    exit 0
  fi
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --unit="$unit" --description="ploi-backup $ORG $mode" --collect --quiet --setenv=HOME=/root \
    -p Nice=10 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=7 \
    -p CPUWeight=20 -p IOWeight=20 "$BIN" backup "$mode"
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
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
