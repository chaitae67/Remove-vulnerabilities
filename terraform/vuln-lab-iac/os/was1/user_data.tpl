<powershell>
net user Administrator "${server_password}"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-Item -ItemType Directory -Force -Path C:\Users\Administrator\.ssh
Set-Content -Path C:\Users\Administrator\.ssh\authorized_keys -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnULWloBYXMlrDnuXfT29sTrKInAAnYxspJFqCcNo6M team"
icacls C:\Users\Administrator\.ssh\authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
</powershell>
<persist>true</persist>
