#!/usr/bin/env bash
set -e

mkdir -p /var/log/discord-mock /var/run/mysqld /var/lib/mysql
chown -R mysql:mysql /var/run/mysqld /var/lib/mysql
: > /var/log/discord-mock/requests.log

if [ ! -d /var/lib/mysql/mysql ]; then
  mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql
fi

mysqld_safe --user=mysql --datadir=/var/lib/mysql &

for i in $(seq 1 60); do
  mysqladmin --silent ping >/dev/null 2>&1 && break
  sleep 1
done

python3 /usr/local/bin/discord_mock.py &

exec sleep infinity
