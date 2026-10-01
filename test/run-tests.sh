#!/usr/bin/env bash
# Integratietest in Docker: nep-Storage Box (sftp op poort 23), MySQL, SQLite, nep-Discord.
# Gebruik: test/run-tests.sh   (duurt een paar minuten, ruimt zelf op)
set -uo pipefail
cd "$(dirname "$0")" || exit 1
C=ploi-test-server; B=/usr/local/sbin/ploi-backup-test; FAIL=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; FAIL=1; }
x()    { docker exec "$C" bash -c "$1"; }
check() { if x "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

./make-test-copy.sh
# Statisch: alles wat buiten functies staat moet in CONFIG_VARS, anders mist het in de geïnstalleerde kopie
missing="$(awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/{f=1} f&&/^\}/{f=0;next} !f && /^[A-Za-z_][A-Za-z0-9_]*=/{sub(/=.*/,""); print}' ../backup/ploi-backup.sh \
  | while read -r v; do grep -q "CONFIG_VARS=(.*\b$v\b" <(tr '\n' ' ' < ../backup/ploi-backup.sh) || echo "$v"; done)"
if [ -z "$missing" ]; then ok "alle variabelen buiten functies staan in CONFIG_VARS"; else bad "niet in CONFIG_VARS: $missing"; fi
docker compose down -v >/dev/null 2>&1
docker compose up -d --build >/dev/null 2>&1 || { echo "docker compose up mislukt"; exit 1; }
sleep 8
./seed.sh >/dev/null 2>&1 || { echo "seed mislukt"; docker compose down -v >/dev/null 2>&1; exit 1; }

check "setup: env 600, zonder sub-account-wachtwoord" "[ \$(stat -c %a /root/.ploi-backup-test/env) = 600 ] && ! grep -q SB_PASSWORD /root/.ploi-backup-test/env"
check "setup opnieuw: verandert niets" "printf 'RESTIC_PASSWORD=testpw123\n' | bash /root/run-ploi-backup.sh setup | grep -q 'werkt al'"
check "setup met fout wachtwoord: env blijft goed" "! printf 'RESTIC_PASSWORD=fout\n' | bash /root/run-ploi-backup.sh setup >/dev/null 2>&1 && grep -q testpw123 /root/.ploi-backup-test/env"
check "korte naam /usr/local/sbin/ploi-backup bestaat" "[ -L /usr/local/sbin/ploi-backup ] && /usr/local/sbin/ploi-backup status >/dev/null"
check "setup via export-regels + </dev/null (README)" "export RESTIC_PASSWORD=testpw123 SETUP_SERVER_NAME=server; /usr/local/sbin/ploi-backup setup </dev/null | grep -q 'setup klaar'"
check "setup via ingesprongen invoer met export en quotes" "printf '   export RESTIC_PASSWORD=\"testpw123\"  \n\tSETUP_SERVER_NAME=server\n' | /usr/local/sbin/ploi-backup setup | grep -q 'setup klaar'"
check "setup met stdin die nooit sluit: klaar binnen 60s" "sleep 120 | RESTIC_PASSWORD=testpw123 timeout 60 /usr/local/sbin/ploi-backup setup | grep -q 'setup klaar'"
check "backup (zonder HOME, zoals systemd)" "env -i PATH=/usr/bin:/bin bash /root/run-ploi-backup.sh backup"
check "excludes: caches en plugin-backups niet in snapshot" "! $B restic ls latest | grep -qE 'node_modules|framework/cache|public/static|static-urls-cache|wp-content/cache|ai1wm'"
check "excludes: tijdelijke Ploi-backups niet, Ploi-logs wel" "L=\$($B restic ls latest); ! grep -qE '\.ploi/backup-|\.ploi/db-1\.zip' <<<\"\$L\" && grep -q '\.ploi/cron.log' <<<\"\$L\""
check "includes: content, uploads, .git, dumps" "L=\$($B restic ls latest); for p in content/pages/home.md uploads/2026/a.jpg .git/HEAD mysql/wp_test.sql mysql/_users_and_grants.sql sqlite/; do grep -q \"\$p\" <<<\"\$L\" || exit 1; done"
check "geen root-owned sqlite -wal/-shm" "! find /home/site-b -user root | grep -q ."
check "dumpmap na afloop weg" "[ ! -e /var/backups/ploi-backup-test ]"
check "tweede backup incrementeel" "$B backup | grep -q 'Files: .* 0 new'"
check "run (zonder systemd valt terug op voorgrond)" "$B run"
check "db-modus" "$B run-db && $B restic snapshots --tag db --json | jq -e 'length >= 1'"
check "restore MySQL-dump: 5000 rijen" "$B restic dump latest /var/backups/ploi-backup-test/mysql/wp_test.sql > /tmp/r.sql && mysql -e 'DROP DATABASE IF EXISTS r; CREATE DATABASE r' && mysql r < /tmp/r.sql && [ \$(mysql -N -e 'SELECT COUNT(*) FROM r.posts') = 5000 ]"
check "restore SQLite-dump: integrity ok, 1000 rijen" "$B restic dump latest /var/backups/ploi-backup-test/sqlite/site-b_site-b.nl_database_database.sqlite.sql > /tmp/s.sql && rm -f /tmp/s.db && sqlite3 /tmp/s.db < /tmp/s.sql && [ \"\$(sqlite3 /tmp/s.db 'PRAGMA integrity_check')\" = ok ] && [ \$(sqlite3 /tmp/s.db 'SELECT COUNT(*) FROM items') = 1000 ]"
check "restore site: bestanden gelijk" "rm -rf /tmp/rt && $B restic restore latest --tag ploi-backup --target /tmp/rt --include /home/ploi/site-a.nl >/dev/null && diff -rq /tmp/rt/home/ploi/site-a.nl/content /home/ploi/site-a.nl/content"
check "zonder MySQL-toegang: exit 0 + oranje melding" "mv /root/.backup-mysql.cnf /root/.bk; $B backup >/dev/null 2>&1; rc=\$?; mv /root/.bk /root/.backup-mysql.cnf; [ \$rc = 0 ] && tail -n1 /var/log/discord-mock/requests.log | jq -r .content | grep -q '🟠'"
check "fout restic-wachtwoord: exit 12 + rode melding met log" "cp /root/.ploi-backup-test/env /root/e; sed -i 's/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=x/' /root/.ploi-backup-test/env; env -i PATH=/usr/bin:/bin timeout 60 $B backup >/dev/null 2>&1; rc=\$?; cp /root/e /root/.ploi-backup-test/env; [ \$rc = 12 ] && tail -n1 /var/log/discord-mock/requests.log | jq -r .content | grep -q 'wrong password'"
check "db-run wijkt voor lopende backup" "(exec 9>/run/lock/ploi-backup-test.lock; flock 9; sleep 15) & sleep 1; $B backup db | grep -q 'draait al'; wait"
check "lege server: overslaan + melding, FORCE=1 draait wel" "head -c 20000000 /dev/urandom > /home/ploi/site-a.nl/public/assets/groot.bin; $B backup >/dev/null 2>&1; mv /home/ploi /var/tmp/ploi.bak; $B backup >/dev/null 2>&1; s=\$(tail -n1 /var/log/discord-mock/requests.log | jq -r .content); FORCE=1 $B backup >/dev/null 2>&1; rc=\$?; mv /var/tmp/ploi.bak /home/ploi; grep -q overgeslagen <<<\"\$s\" && [ \$rc = 0 ]"
# ---- terugzetten (site + database samen) ----
x "$B backup" >/dev/null 2>&1   # verse backup na de lege-server-test
check "restore zonder site: lijst met backups" "$B restore | grep -q 'Beschikbare backups'"
check "restore proef wp.nl: bestanden + database.sql, live onveranderd" "$B restore wp.nl | grep -q 'PROEF klaar' && ls /root/restore-test/wp.nl-*/database.sql && ls /root/restore-test/wp.nl-*/home/ploi/wp.nl/public/wp-config.php"
check "restore onbekende site: duidelijke fout" "! $B restore bestaat-niet.nl >/dev/null 2>&1"
check "restore ongeldige datum/ID: fout" "! $B restore wp.nl --when gisteren >/dev/null 2>&1"
check "restore --apply weigert database met objecten van een andere user, verandert niets" "mysql -e 'DELETE FROM wp_test.posts WHERE id > 10'; ! $B restore wp.nl --apply >/tmp/o 2>&1 && grep -q 'andere MySQL-user' /tmp/o && [ \$(mysql -N -e 'SELECT COUNT(*) FROM wp_test.posts') = 10 ]"
check "restore --apply wp2.nl: upload, rijen, extra tabel, view en trigger" "rm /home/ploi/wp2.nl/public/wp-content/uploads/2026/b.jpg; mkdir -p /home/ploi/wp2.nl/node_modules/x; mysql -e 'DELETE FROM wp_two.opts WHERE id > 5; CREATE TABLE wp_two.stray (id INT)'; $B restore wp2.nl --apply >/dev/null && [ -f /home/ploi/wp2.nl/public/wp-content/uploads/2026/b.jpg ] && [ \$(mysql -N -e 'SELECT COUNT(*) FROM wp_two.opts') = 300 ] && ! mysql -N -e 'SHOW TABLES FROM wp_two' | grep -q stray && mysql -N -e 'SHOW TRIGGERS FROM wp_two' | grep -q opts_ai && mysql -N -e 'SELECT COUNT(*) FROM wp_two.opts_view' | grep -q 300 && [ -d /home/ploi/wp2.nl/node_modules/x ]"
check "restore --apply maakte een veiligheidsbackup (pre-restore)" "$B restic snapshots --tag pre-restore --json | jq -e 'length >= 1'"
check "restore --apply SQLite-site: rijen terug, eigenaar klopt" "runuser -u site-b -- sqlite3 /home/site-b/site-b.nl/database/database.sqlite 'DELETE FROM items WHERE id > 5'; $B restore site-b.nl --apply >/dev/null && [ \$(sqlite3 /home/site-b/site-b.nl/database/database.sqlite 'SELECT COUNT(*) FROM items') = 1000 ] && [ \$(stat -c %U /home/site-b/site-b.nl/database/database.sqlite) = site-b ] && ! find /home/site-b -user root | grep -q ."
check "restore --db-only met datum van vandaag" "mysql -e 'DELETE FROM wp_two.opts WHERE id > 100'; $B restore wp2.nl --db-only --when \$(date -u +%F) --apply >/dev/null && [ \$(mysql -N -e 'SELECT COUNT(*) FROM wp_two.opts') = 300 ]"
check "restore via omgeving (Ploi-script)" "RESTORE_SITE=wp2.nl RESTORE_WHEN=latest RESTORE_APPLY=0 $B restore | grep -q 'PROEF klaar'"
check "veiligheidsbackup zelf terugzetten (ongedaan maken)" "id=\$($B restic snapshots --tag pre-restore --json | jq -r 'sort_by(.time) | .[-1].short_id'); mysql -e 'DELETE FROM wp_two.opts WHERE id > 50'; $B restore wp2.nl --when \$id --apply >/dev/null && [ \$(mysql -N -e 'SELECT COUNT(*) FROM wp_two.opts') = 100 ]"
# ---- automatisch inrichten (nieuwe server) ----
check "nieuwe server zonder token: melding en exit 1" "mv /root/.ploi-backup-test /root/state.bak; ! env PB_RESTIC_PASSWORD=testpw123 bash /root/run-ploi-backup.sh run >/dev/null 2>&1; rc=\$?; tail -n1 /var/log/discord-mock/requests.log | jq -r .content | grep -q 'nog niet gekoppeld'"
check "nieuwe server met gegevens: richt zichzelf in en backupt" "env PB_RESTIC_PASSWORD=testpw123 SB_USER=u100000 SB_HOST=storagebox SB_PASSWORD='Test-Pass-123!' PB_SERVER_NAME=server bash /root/run-ploi-backup.sh run >/dev/null 2>&1 && [ -f /root/.ploi-backup-test/env ] && ! grep -q 'Test-Pass' /root/.ploi-backup-test/env"
x "rm -rf /root/state.bak" >/dev/null 2>&1
docker cp ../backup/ploi-script.sh "$C:/root/ploi-script.sh" >/dev/null
check "Ploi-script: download van GitHub + checksum + backup" "sed 's/^export PB_ORG=\"\"/export PB_ORG=\"test\"/' /root/ploi-script.sh > /root/w.sh && bash /root/w.sh"
check "Ploi-script: foute checksum valt terug op geïnstalleerde versie" "sed -e 's/^export PB_ORG=\"\"/export PB_ORG=\"test\"/' -e 's/^SHA256=.*/SHA256=\"0000\"/' /root/ploi-script.sh > /root/w2.sh && bash /root/w2.sh 2>&1 | grep -q 'geïnstalleerde versie'"
docker compose stop storagebox >/dev/null 2>&1
check "storage box onbereikbaar: exit != 0 binnen 90s" "! timeout 90 $B backup >/dev/null 2>&1 && tail -n1 /var/log/discord-mock/requests.log | jq -r .content | grep -q '🔴'"
check "alle Discord-berichten geldige JSON" "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e .content >/dev/null || exit 1; done < /var/log/discord-mock/requests.log"
docker compose down -v >/dev/null 2>&1
[ "$FAIL" = 0 ] && echo "ALLES GESLAAGD" || { echo "ER ZIJN FOUTEN"; exit 1; }
