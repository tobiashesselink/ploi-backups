FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd

RUN useradd -m -s /bin/bash u100000 \
    && echo 'u100000:Test-Pass-123!' | chpasswd \
    && mkdir -p /home/u100000/.ssh \
    && chmod 700 /home/u100000/.ssh \
    && chown -R u100000:u100000 /home/u100000

# sshd config: port 23, password auth aan, sftp subsystem, geen chroot
RUN sed -i 's/^#\?Port .*/Port 23/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's#^Subsystem\s\+sftp.*#Subsystem sftp internal-sftp#' /etc/ssh/sshd_config \
    && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config \
    && ssh-keygen -A

EXPOSE 23
CMD ["/usr/sbin/sshd", "-D", "-e"]
