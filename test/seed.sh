#!/usr/bin/env bash
# Zet alle testdata + MySQL-gebruikers op in de 'server'-container en draait de setup.
# Gebruik: docker compose up -d --build && ./seed.sh
set -euo pipefail
cd "$(dirname "$0")"

C=ploi-test-server

docker cp ploi-backup-test.sh "$C:/root/run-ploi-backup.sh"

docker exec "$C" bash -c '
set -e
id ploi   >/dev/null 2>&1 || useradd -m -s /bin/bash ploi
id site-b >/dev/null 2>&1 || useradd -m -s /bin/bash site-b

SITE=/home/ploi/site-a.nl
mkdir -p "$SITE/content/pages" "$SITE/public/assets" "$SITE/storage/framework/cache/data" \
         "$SITE/node_modules/pkg" "$SITE/public/static" "$SITE/storage/statamic/static-urls-cache" "$SITE/.git"
echo "# Home" > "$SITE/content/pages/home.md"
head -c 1048576 /dev/urandom > "$SITE/public/assets/foto.jpg"
echo "APP_KEY=base64:test" > "$SITE/.env"
echo "cached-data-should-be-excluded" > "$SITE/storage/framework/cache/data/x"
echo "module.exports = {};" > "$SITE/node_modules/pkg/index.js"
echo "<html>static</html>" > "$SITE/public/static/index.html"
echo "static-url-cache" > "$SITE/storage/statamic/static-urls-cache/a"
echo "ref: refs/heads/main" > "$SITE/.git/HEAD"
chown -R ploi:ploi "$SITE"
mkdir -p /home/ploi/.ploi/backup-1-abc && head -c 1000 /dev/urandom > /home/ploi/.ploi/backup-1-abc/site.zip && head -c 1000 /dev/urandom > /home/ploi/.ploi/db-1.zip && echo log > /home/ploi/.ploi/cron.log

WP=/home/ploi/wp.nl
mkdir -p "$WP/public/wp-content/uploads/2026" "$WP/public/wp-content/cache" "$WP/public/wp-content/ai1wm-backups"
head -c 204800 /dev/urandom > "$WP/public/wp-content/uploads/2026/a.jpg"
echo "cache-should-be-excluded" > "$WP/public/wp-content/cache/x"
echo "wpress-backup-should-be-excluded" > "$WP/public/wp-content/ai1wm-backups/b.wpress"
chown -R ploi:ploi "$WP"

mkdir -p /home/site-b/site-b.nl/database
sqlite3 /home/site-b/site-b.nl/database/database.sqlite "PRAGMA journal_mode=WAL; CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, val INTEGER);"
python3 - <<PY
import sqlite3
con = sqlite3.connect("/home/site-b/site-b.nl/database/database.sqlite")
con.execute("PRAGMA journal_mode=WAL;")
con.executemany("INSERT INTO items (name, val) VALUES (?, ?)", [(f"item{i}", i) for i in range(1000)])
con.commit(); con.close()
PY
chown -R site-b:site-b /home/site-b
'

# Tweede WordPress-site: database en alle objecten van de site-user zelf (zoals op Ploi)
docker exec -i "$C" bash -c 'set -e
mkdir -p /home/ploi/wp2.nl/public/wp-content/uploads/2026
head -c 100000 /dev/urandom > /home/ploi/wp2.nl/public/wp-content/uploads/2026/b.jpg
cat > /home/ploi/wp2.nl/public/wp-config.php
chown -R ploi:ploi /home/ploi/wp2.nl
mysql -e "SET GLOBAL log_bin_trust_function_creators = 1; CREATE DATABASE IF NOT EXISTS wp_two; CREATE USER IF NOT EXISTS wp_two_user@localhost IDENTIFIED BY \"Two-Pass-123!\"; GRANT ALL ON wp_two.* TO wp_two_user@localhost"
mysql -uwp_two_user -pTwo-Pass-123! wp_two -e "CREATE TABLE IF NOT EXISTS opts (id INT PRIMARY KEY AUTO_INCREMENT, v VARCHAR(50)); CREATE TABLE IF NOT EXISTS log (id INT); INSERT INTO opts (v) SELECT CONCAT(\"v\", seq) FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq < 300) SELECT seq FROM s) x; CREATE OR REPLACE VIEW opts_view AS SELECT id, v FROM opts; CREATE TRIGGER opts_ai AFTER INSERT ON opts FOR EACH ROW INSERT INTO log VALUES (NEW.id)" 2>/dev/null
' <<'WPC'
<?php
define( 'DB_NAME', 'wp_two' );
define( 'DB_USER', 'wp_two_user' );
define( 'DB_PASSWORD', 'Two-Pass-123!' );
define( 'DB_HOST', 'localhost' );
WPC

# Configbestanden via stdin (quotes blijven heel)
docker exec -i "$C" bash -c 'cat > /home/ploi/wp.nl/public/wp-config.php && chown ploi:ploi /home/ploi/wp.nl/public/wp-config.php' <<'WPC'
<?php
define( 'DB_NAME', 'wp_test' );
define( 'DB_USER', 'wp_test_user' );
define( 'DB_PASSWORD', 'Wp-Pass-123!' );
define( 'DB_HOST', 'localhost' );
$table_prefix = 'wp_';
WPC
docker exec -i "$C" bash -c 'cat > /home/site-b/site-b.nl/.env && chown site-b:site-b /home/site-b/site-b.nl/.env' <<'ENV'
APP_NAME=siteb
DB_CONNECTION=sqlite
ENV

docker exec "$C" bash -c "
set -e
mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS wp_test CHARACTER SET utf8mb4;
USE wp_test;
CREATE TABLE IF NOT EXISTS posts (id INT PRIMARY KEY AUTO_INCREMENT, title VARCHAR(191), body TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;
SQL
n=\$(mysql -N -e 'SELECT COUNT(*) FROM wp_test.posts;')
if [ \"\$n\" = 0 ]; then
mysql wp_test <<'SQL'
DELIMITER \$\$
CREATE PROCEDURE seed_posts(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < n DO
    INSERT INTO posts (title, body) VALUES (CONCAT('Post ', i), CONCAT('Body text for post ', i));
    SET i = i + 1;
  END WHILE;
END\$\$
DELIMITER ;
CALL seed_posts(5000);
CREATE VIEW recent_posts AS SELECT id, title FROM posts ORDER BY id DESC LIMIT 100;
CREATE TABLE post_log (id INT PRIMARY KEY AUTO_INCREMENT, post_id INT, action VARCHAR(50), logged_at DATETIME DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;
DELIMITER \$\$
CREATE TRIGGER trg_posts_ai AFTER INSERT ON posts
FOR EACH ROW
BEGIN
  INSERT INTO post_log (post_id, action) VALUES (NEW.id, 'insert');
END\$\$
DELIMITER ;
SET GLOBAL event_scheduler = ON;
DELIMITER \$\$
CREATE EVENT ev_cleanup_log
ON SCHEDULE EVERY 1 DAY
DO
BEGIN
  DELETE FROM post_log WHERE logged_at < NOW() - INTERVAL 30 DAY;
END\$\$
DELIMITER ;
CREATE USER IF NOT EXISTS 'wp_test_user'@'localhost' IDENTIFIED BY 'Wp-Pass-123!';
GRANT ALL PRIVILEGES ON wp_test.* TO 'wp_test_user'@'localhost';
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY 'Bk-Pass-123!';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS, SHOW_ROUTINE ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
SQL
fi
umask 077
printf '[client]\nuser = backup\npassword = \"Bk-Pass-123!\"\n' > /root/.backup-mysql.cnf
chmod 600 /root/.backup-mysql.cnf
mysql --defaults-extra-file=/root/.backup-mysql.cnf -N -e 'SELECT CURRENT_USER();'
"

docker exec -i "$C" bash -c "
SB_USER=u100000 SB_HOST=storagebox SB_PASSWORD='Test-Pass-123!' RESTIC_PASSWORD=testpw123 bash /root/run-ploi-backup.sh setup </dev/null
"

echo "Klaar. Draai nu bv.: docker exec -i $C bash -c 'bash /root/run-ploi-backup.sh backup'"
