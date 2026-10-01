FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      mysql-server sqlite3 curl jq bzip2 openssh-client sshpass \
      util-linux procps ca-certificates openssl python3 \
      iproute2 less vim-tiny cron \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/discord-mock /var/run/mysqld \
    && chown mysql:mysql /var/run/mysqld

COPY discord_mock.py /usr/local/bin/discord_mock.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
