# v5 잔여 취약점 조치 배포 순서

이 버전은 약한 기존 비밀번호도 로그인 단계에서 거부한다. 따라서 아래 순서를 지켜 기존
`admin`/`user` 계정의 비밀번호를 먼저 강한 값으로 교체한 후 고객 JAR을 올린다.

## 1. 관리자 WEB Nginx

현재 설정을 백업한다.

```bash
sudo nginx -T > "$HOME/nginx-before-v5.txt"
sudo cp -a /etc/nginx "/etc/nginx.backup-v5-$(date +%Y%m%d-%H%M%S)"
```

오픈소스 Nginx의 `server_tokens off`는 버전만 숨기고 `Server: nginx`는 남긴다. 헤더 자체를
제거하려면 headers-more 모듈을 사용한다.

```bash
sudo apt-get update
sudo apt-get install -y libnginx-mod-http-headers-more-filter
ls -l /etc/nginx/modules-enabled | grep headers-more
```

`admin-web-nginx-v5.conf.example`의 네 자리표시자를 실제 값으로 바꾸고 현재 관리자 프록시
설정 파일에 반영한다.

```text
<INTERNET_ALB_SUBNET_CIDR_1>
<INTERNET_ALB_SUBNET_CIDR_2>
<ADMIN_PUBLIC_IP>/32
<ADMIN_VPN_CIDR>
```

검사 후 반영한다.

```bash
sudo nginx -t
sudo systemctl reload nginx
curl -skI https://admin.zerodayclinic.p-e.kr/login | grep -iE '^(server|x-powered-by):' || true
```

마지막 명령이 아무것도 출력하지 않아야 한다.

## 2. 관리자 JAR과 기존 계정 비밀번호 일회 교체

관리자 JAR을 `/opt/clinic/admin-app.jar`에 교체한 다음, systemd 환경 파일에 한 번만 다음
값을 추가한다. 두 비밀번호는 서로 달라야 하고 10~128자, 영문·숫자·특수문자를 포함하며
아이디를 포함하면 안 된다.

```text
ROTATE_PASSWORDS_ON_STARTUP=true
ROTATE_ADMIN_PASSWORD=<NEW_UNIQUE_ADMIN_PASSWORD>
ROTATE_USER_PASSWORD=<NEW_UNIQUE_CUSTOMER_PASSWORD>
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart clinic-admin.service
sudo systemctl status clinic-admin.service --no-pager -l
```

새 비밀번호로 관리자 로그인이 성공하는지 확인한 직후, 위 세 환경변수를 환경 파일에서
삭제하고 다시 시작한다. 비밀번호를 셸 명령행이나 `ExecStart` 인자로 넣지 않는다.

```bash
sudo systemctl restart clinic-admin.service
```

## 3. 고객 JAR

비밀번호 교체가 끝난 뒤 고객 WAS의 다음 파일을 v5 고객 JAR로 교체한다.

```text
C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar
```

```powershell
Stop-Service -Name 'clinic-customer'
Copy-Item -LiteralPath 'C:\Users\Administrator\customer-app.jar' `
  -Destination 'C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar' -Force
Start-Service -Name 'clinic-customer'
Get-Service -Name 'clinic-customer'
```

## 4. 고객 WEB IIS/ARR

이 작업은 고객 WAS가 아니라 IIS/ARR가 설치된 고객 WEB 서버에서 실행한다. 먼저 IIS 설정을
백업한다.

```powershell
$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
& $appcmd add backup "before-v5-security"
& $appcmd list site
```

대상 사이트의 기존 `web.config`에 `customer-web.config.v5.example`의 항목을 병합한다.
기존 `<rewrite><rules>`와 reverse-proxy 규칙은 삭제하지 않는다. IIS URL Rewrite의
**View Server Variables**에 다음 세 변수를 허용한다.

```text
HTTP_X_FORWARDED_FOR
HTTP_X_REAL_IP
HTTP_FORWARDED
```

설정 확인 및 재적용:

```powershell
& $appcmd list config '<IIS_SITE_NAME>' /section:system.webServer/httpProtocol
& $appcmd list config '<IIS_SITE_NAME>' /section:system.webServer/security/requestFiltering
& $appcmd list config '<IIS_SITE_NAME>' /section:system.webServer/rewrite
& $appcmd recycle apppool /apppool.name:'<APP_POOL_NAME>'
```

검증:

```powershell
curl.exe -k -sS -I https://www.zerodayclinic.p-e.kr/login
```

`X-Powered-By`와 `Server`가 없어야 한다.

## 5. 최종 확인

```bash
curl -skI https://www.zerodayclinic.p-e.kr/login | grep -iE '^(server|x-powered-by):' || true
curl -skI https://admin.zerodayclinic.p-e.kr/login | grep -iE '^(server|x-powered-by):' || true
```

이전의 약한 비밀번호 두 개는 두 사이트 모두에서 로그인 실패해야 하고, 새 강한 비밀번호만
각 역할에 맞는 사이트에서 성공해야 한다.
