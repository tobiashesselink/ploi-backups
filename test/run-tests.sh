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
docker compose down -v >/dev/null 2>&1
docker compose up -d --build >/dev/null 2>&1 || { echo "docker compose up mislukt"; exit 1; }
sleep 8
./seed.sh >/dev/null 2>&1 || { echo "seed mislukt"; docker compose down -v >/dev/null 2>&1; exit 1; }

check "setup: env 600, zonder sub-account-wachtwoord" "[ \$(stat -c %a /root/.ploi-backup-test/env) = 600 ] && ! grep -q SB_PASSWORD /root/.ploi-backup-test/env"
check "setup opnieuw: verandert niets" "printf 'RESTIC_PASSWORD=testpw123\n' | bash /root/run-ploi-backup.sh setup | grep -q 'werkt al'"
check "setup met fout wachtwoord: env blijft goed" "! printf 'RESTIC_PASSWORD=fout\n' | bash /root/run-ploi-backup.sh setup >/dev/null 2>&1 && grep -q testpw123 /root/.ploi-backup-test/env"
check "backup (zonder HOME, zoals systemd)" "env -i PATH=/usr/bin:/bin bash /root/run-ploi-backup.sh backup"
check "excludes: caches en plugin-backups niet in snapshot" "! $B restic ls latest | grep -qE 'node_modules|framework/cache|public/static|static-urls-cache|wp-content/cache|ai1wm'"
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
docker compose stop storagebox >/dev/null 2>&1
check "storage box onbereikbaar: exit != 0 binnen 90s" "! timeout 90 $B backup >/dev/null 2>&1 && tail -n1 /var/log/discord-mock/requests.log | jq -r .content | grep -q '🔴'"
check "alle Discord-berichten geldige JSON" "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e .content >/dev/null || exit 1; done < /var/log/discord-mock/requests.log"
docker compose down -v >/dev/null 2>&1
[ "$FAIL" = 0 ] && echo "ALLES GESLAAGD" || { echo "ER ZIJN FOUTEN"; exit 1; }
