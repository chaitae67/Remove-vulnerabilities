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

apt-get install -y nginx

cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
  log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
  access_log /var/log/nginx/access.log main;

  sendfile on;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  server_tokens on;

  server {
    listen 80 default_server;
    server_name _;
    root /usr/share/nginx/html;

    location = /health {
      access_log off;
      add_header Content-Type text/plain;
      return 200 'ok';
    }
    location = /who.html {
      add_header Content-Type text/plain;
    }
    location / {
      proxy_pass http://internal-in-alb-1262980660.ap-northeast-2.elb.amazonaws.com:8080;
      proxy_http_version 1.1;
      proxy_set_header Host              admin.zerodayclinic.p-e.kr;
      proxy_set_header X-Real-IP         $remote_addr;
      proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_connect_timeout 5s;
      proxy_read_timeout    30s;
      proxy_redirect ~^https?://[^/]+/(.*)$ https://$host/$1;
    }
  }
}
NGINXCONF

rm -f /etc/nginx/conf.d/*.conf
mkdir -p /usr/share/nginx/html
nginx -t && systemctl enable --now nginx

echo 'WEB-ADMIN01 (admin/ubuntu) -> admin.zerodayclinic.p-e.kr' > /usr/share/nginx/html/who.html