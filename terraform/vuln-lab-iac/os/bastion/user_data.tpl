#!/bin/bash
set -x
exec > >(tee /var/log/bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/*.conf
echo 'UsePAM yes' >> /etc/ssh/sshd_config
echo 'root:${server_password}' | chpasswd
systemctl restart ssh 2>/dev/null || systemctl restart sshd

echo "DB_HOST=10.0.20.184" >> /etc/environment
echo "DB_USER=oraadmin" >> /etc/environment
echo "DB_PASS=${db_password}" >> /etc/environment
chmod 644 /etc/environment
# ---- 공통 team 계정 (OS 무관 통일 접속) ----
id team >/dev/null 2>&1 || useradd -m -s /bin/bash team
echo 'team:${server_password}' | chpasswd
mkdir -p /home/team/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnULWloBYXMlrDnuXfT29sTrKInAAnYxspJFqCcNo6M team' > /home/team/.ssh/authorized_keys
chown -R team:team /home/team/.ssh
chmod 700 /home/team/.ssh
chmod 600 /home/team/.ssh/authorized_keys
# team 에 sudo 권한 [취약점: 광범위 sudo]
echo 'team ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/team
chmod 440 /etc/sudoers.d/team

apt-get install -y netcat-openbsd telnet dnsutils awscli