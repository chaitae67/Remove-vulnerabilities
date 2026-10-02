# 운영 프록시 및 잔여 취약점 조치 절차

대상 구조:

```text
인터넷 ALB -> WEB(Nginx 또는 IIS/ARR) -> 내부 ALB -> Spring Boot WAS
```

핵심 원칙은 인터넷 사용자가 보낸 `X-Forwarded-For`와 `Forwarded`를 애플리케이션이
직접 신뢰하지 않게 하는 것이다. 인터넷 ALB는 `append`, WEB은 신뢰 체인을 역방향으로
검증한 뒤 하나의 정규화된 클라이언트 IP만 내부 ALB로 전달한다.

## 1. ALB 속성 확인 및 적용

먼저 인터넷 ALB와 내부 ALB의 ARN을 확인한다.

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,DNSName,LoadBalancerArn]' \
  --output table
```

현재 값을 백업한다.

```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn '<INTERNET_ALB_ARN>' \
  --output json > internet-alb-attributes.before.json

aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn '<INTERNAL_ALB_ARN>' \
  --output json > internal-alb-attributes.before.json
```

두 ALB 모두 `append`를 사용하고 비정상 헤더를 제거한다. `preserve`는 외부의 위조 헤더를
그대로 전달하므로 사용하지 않는다. `remove`는 실제 클라이언트 IP도 제거하므로 IP 기반
접근 제한 및 속도 제한과 함께 사용할 수 없다.

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn '<INTERNET_ALB_ARN>' \
  --attributes \
    Key=routing.http.xff_header_processing.mode,Value=append \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true

aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn '<INTERNAL_ALB_ARN>' \
  --attributes \
    Key=routing.http.xff_header_processing.mode,Value=append \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true
```

인터넷 ALB가 사용하는 서브넷 CIDR을 확인한다. 아래 결과만 Nginx의 `set_real_ip_from`에
사용한다.

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns '<INTERNET_ALB_ARN>' \
  --query 'LoadBalancers[0].AvailabilityZones[].SubnetId' \
  --output text

aws ec2 describe-subnets \
  --subnet-ids '<SUBNET_ID_1>' '<SUBNET_ID_2>' \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' \
  --output table
```

## 2. 관리자 WEB Nginx

현재 적용 파일을 먼저 찾는다.

```bash
sudo nginx -T 2>&1 | grep '^# configuration file'
sudo nginx -T 2>&1 | grep -n -B10 -A40 'internal-in-alb-1262980660.ap-northeast-2.elb.amazonaws.com'
```

`nginx -T`에서 `/etc/nginx/conf.d/*.conf`가 `http` 블록 안에 포함되는 것을 확인한 뒤
다음 파일을 연다.

```bash
sudo vim /etc/nginx/conf.d/00-real-ip.conf
```

내용은 실제 인터넷 ALB 서브넷 CIDR로 작성한다.

```nginx
set_real_ip_from <INTERNET_ALB_SUBNET_CIDR_1>;
set_real_ip_from <INTERNET_ALB_SUBNET_CIDR_2>;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

관리자 프록시 설정에서 아래의 취약한 설정을 제거한다.

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

대신 모든 프록시 `location`에 다음 설정을 적용한다.

```nginx
proxy_set_header Host admin.zerodayclinic.p-e.kr;
proxy_set_header X-Forwarded-Host admin.zerodayclinic.p-e.kr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-Port 443;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header Forwarded "";

proxy_hide_header Server;
proxy_hide_header X-Powered-By;
```

`server` 또는 `http` 블록에는 다음을 둔다.

```nginx
server_tokens off;
autoindex off;
```

관리자 페이지는 애플리케이션 필터와 별도로 Nginx에서도 실제 관리자 공인 IP 또는 VPN
대역만 허용한다. `0.0.0.0/0`, VPC 전체, ALB 서브넷을 관리자 허용 대역으로 넣지 않는다.

```nginx
allow <ADMIN_PUBLIC_IP>/32;
allow <ADMIN_VPN_CIDR>;
deny all;
```

적용 전 문법 검사 후 무중단 재적용한다.

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx --no-pager -l
```

## 3. 관리자 WAS와 systemd

새 JAR에는 `server.forward-headers-strategy=native`가 기본 적용된다. 운영 명령에서도 명시해
실수로 `framework`로 되돌아가지 않도록 한다.

```bash
sudo systemctl edit clinic-admin.service
```

예시:

```ini
[Service]
EnvironmentFile=/etc/clinic/admin.env
ExecStart=
ExecStart=/usr/bin/java -jar /opt/clinic/admin-app.jar --server.port=8080 --server.forward-headers-strategy=native --server.tomcat.use-relative-redirects=true
```

`/etc/clinic/admin.env`에는 DB 비밀번호, 관리자 허용 대역, 다운로드 서명 키를 넣고 서비스
계정만 읽게 한다. 비밀번호를 `ExecStart` 인자로 넣지 않는다.

```bash
sudo install -d -o root -g team -m 0750 /etc/clinic
sudo touch /etc/clinic/admin.env
sudo chown root:team /etc/clinic/admin.env
sudo chmod 0640 /etc/clinic/admin.env
sudo vim /etc/clinic/admin.env
```

필수 항목 예시:

```text
ORACLE_URL=jdbc:oracle:thin:@<DB_HOST>:1521/<SERVICE_NAME>
ORACLE_USERNAME=<DB_USER>
ORACLE_PASSWORD=<ROTATED_DB_PASSWORD>
ADMIN_ALLOWED_NETWORKS=<ADMIN_PUBLIC_IP>/32,<ADMIN_VPN_CIDR>
FORWARD_HEADERS_STRATEGY=native
APP_UPLOAD_DIR=/home/team/zeroday-clinic/uploads
APP_RECORDS_DIR=/home/team/zeroday-clinic/records
RECORD_DOWNLOAD_KEY=<32_BYTES_OR_LONGER_RANDOM_VALUE>
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart clinic-admin.service
sudo systemctl status clinic-admin.service --no-pager -l
```

## 4. 고객 WEB IIS/ARR

고객 WEB 서버의 보안 그룹은 인터넷 ALB의 보안 그룹에서 오는 요청만 허용해야 한다.
그 조건에서 인터넷 ALB가 추가한 `X-Forwarded-For`의 마지막 값을 실제 클라이언트로
간주하고, ARR가 내부 ALB로 전달하기 전에 기존 헤더를 정규화한다.

IIS URL Rewrite의 사이트 인바운드 규칙에서 다음 로직을 적용한다.

```xml
<rule name="Canonicalize X-Forwarded-For from ALB" stopProcessing="false">
  <match url=".*" />
  <conditions>
    <add input="{HTTP_X_FORWARDED_FOR}" pattern="(?:^|.*,)[ ]*([^, ]+)[ ]*$" />
  </conditions>
  <serverVariables>
    <set name="HTTP_X_FORWARDED_FOR" value="{C:1}" />
    <set name="HTTP_FORWARDED" value="" />
  </serverVariables>
  <action type="None" />
</rule>
```

사이트에 규칙을 넣기 전에 IIS 관리자 또는 URL Rewrite의 **View Server Variables**에서
`HTTP_X_FORWARDED_FOR`, `HTTP_FORWARDED`를 허용 변수로 등록한다. IIS가 인터넷에 직접
노출된 구조라면 위 규칙 대신 `HTTP_X_FORWARDED_FOR={REMOTE_ADDR}`로 덮어쓴다.

IIS/ARR의 버전 헤더도 제거한다.

```xml
<system.webServer>
  <httpProtocol>
    <customHeaders>
      <remove name="X-Powered-By" />
    </customHeaders>
  </httpProtocol>
  <security>
    <requestFiltering removeServerHeader="true" />
  </security>
</system.webServer>
```

`WebAdministration` 모듈이 없어도 다음 명령으로 사이트 이름과 구성을 확인할 수 있다.

```powershell
$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
& $appcmd list site
& $appcmd list config "<IIS_SITE_NAME>" /section:system.webServer/httpProtocol
& $appcmd list config "<IIS_SITE_NAME>" /section:system.webServer/security/requestFiltering
```

고객 WAS의 NSSM 인자에서도 DB 비밀번호를 제거하고 환경변수로 옮긴다.

```powershell
$nssm = 'C:\nssm\nssm-2.24\win64\nssm.exe'
$service = 'clinic-customer'
$jar = 'C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar'

& $nssm set $service AppParameters "-jar `"$jar`" --server.port=8080 --server.forward-headers-strategy=native"
& $nssm set $service AppEnvironmentExtra `
  'ORACLE_URL=jdbc:oracle:thin:@<DB_HOST>:1521/<SERVICE_NAME>' `
  'ORACLE_USERNAME=<DB_USER>' `
  'ORACLE_PASSWORD=<ROTATED_DB_PASSWORD>' `
  'FORWARD_HEADERS_STRATEGY=native'

Restart-Service -Name $service
```

## 5. 적용 후 검증

허용되지 않은 외부망에서 다음 세 요청이 모두 동일하게 관리자 페이지 접근을 거부해야 한다.

```bash
curl -k -i https://admin.zerodayclinic.p-e.kr/login
curl -k -i -H 'X-Forwarded-For: 127.0.0.1' https://admin.zerodayclinic.p-e.kr/login
curl -k -i -H 'Forwarded: for=127.0.0.1' https://admin.zerodayclinic.p-e.kr/login
```

허용된 관리자망에서는 첫 요청만 로그인 페이지를 반환하며, 임의 XFF를 넣어도 실제 접속자
IP 기준 판정이 유지되어야 한다. 두 사이트 응답에서 다음 헤더가 없어야 한다.

```text
X-Powered-By: ARR/3.0
Server: nginx/1.18.0 (Ubuntu)
```

로그인 자동화 검증은 같은 무효 아이디에 대해 IP 헤더를 바꾸더라도 6번째 요청이 `429`인지
확인한다. 실제 운영 계정은 사용하지 않는다.

현재 애플리케이션 속도 제한 카운터는 WAS 프로세스별 메모리에 저장된다. WAS가 2대 이상이면
AWS WAF의 rate-based rule 또는 Redis 같은 공유 저장소를 추가해 전체 인스턴스 기준으로도
동일 한도가 적용되게 한다.

## 6. 롤백

- Nginx: 변경 전 백업 설정을 복구하고 `nginx -t` 성공 후 reload한다.
- ALB: `*.before.json`에 기록한 이전 속성값만 다시 적용한다.
- WAS: 이전 JAR로 되돌리고 서비스 재시작 후 헬스 체크한다.
- IIS: 변경 전 `applicationHost.config` 백업 또는 IIS Configuration History로 복원한다.
