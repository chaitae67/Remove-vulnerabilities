#!/bin/bash
set -x
exec > >(tee /var/log/bootstrap.log) 2>&1

setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/*.conf
echo 'UsePAM yes' >> /etc/ssh/sshd_config
echo 'root:${server_password}' | chpasswd
systemctl restart sshd

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

dnf install -y python3
dnf install -y java-21-openjdk 2>/dev/null || dnf install -y java-17-openjdk

cat > /opt/placeholder.py <<'PYEOF'
import http.server, socketserver, socket
NAME = socket.gethostname()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"{NAME} :: Host={self.headers.get('Host')} :: {self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("0.0.0.0", 8080), H).serve_forever()
PYEOF

cat > /etc/systemd/system/placeholder.service <<'SVCEOF'
[Unit]
Description=WAS placeholder
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/placeholder.py
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now placeholder
