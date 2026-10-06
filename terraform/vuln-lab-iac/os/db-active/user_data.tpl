#!/bin/bash
set -x
exec > >(tee /var/log/bootstrap.log) 2>&1

# ---- SELinux / 방화벽 [취약점] ----
# AL2023 은 firewalld 가 기본 미설치지만 진단 재현성을 위해 명시적으로 끈다
systemctl disable --now firewalld 2>/dev/null || true
setenforce 0 2>/dev/null || true

dnf -y update
dnf -y install docker tar

# ---- SSH 하드닝 해제 [취약점] ----
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/*.conf
echo 'root:${server_password}' | chpasswd
systemctl restart sshd

id team >/dev/null 2>&1 || useradd -m -s /bin/bash team
echo 'team:${server_password}' | chpasswd
mkdir -p /home/team/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnULWloBYXMlrDnuXfT29sTrKInAAnYxspJFqCcNo6M team' > /home/team/.ssh/authorized_keys
chown -R team:team /home/team/.ssh
chmod 700 /home/team/.ssh
chmod 600 /home/team/.ssh/authorized_keys
echo 'team ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/team
chmod 440 /etc/sudoers.d/team

# ---- 도커 기동 ----
systemctl enable --now docker
usermod -aG docker ec2-user

# [취약점] Docker 원격 API 를 인증/TLS 없이 2375 로 개방
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/override.conf <<'CONF'
[Service]
ExecStart=
CONF
systemctl daemon-reload
systemctl restart docker

# ---- 데이터 볼륨 마운트 ----
# t3 는 Nitro 라 /dev/sdf 가 /dev/nvme1n1 으로 보인다.
# 20GB 짜리 미포맷 디스크를 찾아 /oradata 로 마운트한다.
DATA_DEV=""
for i in 1 2 3 4 5 6; do
  DATA_DEV=$(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" && $2=="20G" {print $1; exit}')
  [ -n "$DATA_DEV" ] && break
  sleep 5
done

mkdir -p /oradata
if [ -n "$DATA_DEV" ]; then
  blkid "$DATA_DEV" >/dev/null 2>&1 || mkfs -t xfs "$DATA_DEV"
  mount "$DATA_DEV" /oradata
  echo "$DATA_DEV /oradata xfs defaults,nofail 0 2" >> /etc/fstab
fi

# 컨테이너 내부 oracle 유저 UID 가 54321 이라 소유권을 맞춰야 한다
chown -R 54321:54321 /oradata

# ---- Oracle Database XE 21c 컨테이너 기동 ----
# [취약점] --privileged, host 네트워크, 약한 SYS 패스워드, 볼륨 미암호화
docker run -d --name oracle-xe \
  --restart always \
  --privileged \
  --network host \
  -e ORACLE_PASSWORD='${db_password}' \
  -e APP_USER='oraadmin' \
  -e APP_USER_PASSWORD='${db_password}' \
  -v /oradata:/opt/oracle/oradata \
  gvenzl/oracle-xe:21-slim

# [취약점] 접속 정보를 전역 환경변수로 평문 기록 + 644 권한
echo "ORACLE_SID=XE"                  >> /etc/environment
echo "ORACLE_USER=oraadmin" >> /etc/environment
echo "ORACLE_PWD=${db_password}"  >> /etc/environment
chmod 644 /etc/environment
