# Zero Day Clinic - 고객/관리자 서버 분리

기존 단일 Spring Boot 프로젝트를 고객용과 관리자용 애플리케이션으로 분리한 Maven 멀티 모듈 프로젝트입니다.

## 프로젝트 구조

```text
clinic-split/
├── pom.xml                  공통 의존성과 플러그인 설정
├── run-local.sh             로컬 실행 스크립트
├── customer-app/            고객용 애플리케이션 (기본 포트 8081)
│   ├── pom.xml              고객 앱 모듈 설정
│   ├── .env.example         고객 앱 환경변수 예시
│   └── src/
├── admin-app/               관리자용 애플리케이션 (기본 포트 8081)
│   ├── pom.xml              관리자 앱 모듈 설정
│   ├── .env.example         관리자 앱 환경변수 예시
│   └── src/
├── deploy/                  웹앱 배포 설정 예시와 보안 점검 문서
└── infra_auto_diag/         기존 인프라 진단 도구
```

- `customer-app`: 고객 화면과 회원, 시술, 결제, 상담, Q&A 기능을 제공합니다.
- `admin-app`: 관리자 로그인, 대시보드, 회원 API, Q&A 관리 기능을 제공합니다.
- 두 앱은 동일한 Oracle 데이터베이스를 사용합니다.

- `deploy`: 웹앱 배포 설정 예시와 보안 점검 문서를 제공합니다.
- `infra_auto_diag`: 별도의 인프라 진단 도구입니다.

제공된 실행 JAR 두 개와 `SHA256SUMS.txt`는 로컬 `release-assets/`에 보관합니다.
이 폴더는 Git 추적에서 제외되며, JAR 배포가 필요하면 별도 Release 자산으로 올립니다.

## 배포 구조

```text
고객 도메인 -> WEB01(Nginx) -> WAS01(customer-app:8081) --┐
                                                          ├-> DB01 / Oracle :1521
관리 도메인 -> WEB-ADMIN01 -> WAS-ADMIN01(admin-app:8081) ┘
```

## 환경변수

각 앱의 `.env.example`을 참고하여 실행 환경에 값을 지정합니다.

```bash
export ORACLE_URL='jdbc:oracle:thin:@db.example.internal:1521/FREEPDB1'
export ORACLE_USERNAME='clinic'
export ORACLE_PASSWORD='실제비밀번호'
```

관리자 앱은 별도 도메인/WAS에 배포하고 `ADMIN_ALLOWED_NETWORKS`로 사내망/VPN 대역을 제한합니다.
비밀값은 저장소나 `.env.example`에 넣지 말고 운영 비밀관리 시스템에서 주입해야 합니다.
업로드와 의무기록은 웹 루트 밖의 `APP_UPLOAD_DIR`, `APP_RECORDS_DIR`에 저장하고,
의무기록 다운로드 식별자 서명에는 `RECORD_DOWNLOAD_KEY`를 충분히 긴 난수로 지정합니다.
WEB 계층 제한은 `deploy/nginx-security.conf.example`을 운영 환경에 맞게 적용합니다.
운영 ALB/Nginx/IIS의 전달 IP 헤더 정규화와 버전 헤더 제거 절차는
`deploy/PRODUCTION_SECURITY_HARDENING.md`를 따릅니다. 인증 계정이 필요한 최종 점검은
`deploy/AUTHENTICATED_E2E_CHECKLIST.md`를 사용합니다.
실운영 재점검에서 확인된 헤더 노출과 기존 약한 계정까지 포함한 배포 순서는
`deploy/V5_DEPLOYMENT.md`를 사용합니다.

고객 앱의 `/notices`는 GET/HEAD 전용이며 일반 사용자의 POST 요청은 보안 필터와 WEB 계층에서 거부됩니다.
공지 작성·수정·삭제는 관리자 앱의 `/admin/notices`에서만 가능하고, 각 변경 작업마다 관리자 비밀번호를 재확인합니다.
세션 쿠키는 SameSite=Strict를 사용하며 상태 변경 요청은 CSRF 토큰과 동일 출처 검사도 함께 통과해야 합니다.
로그인과 민감 요청의 애플리케이션 요청 제한에 더해 운영 Nginx/WAF에서도 요청 제한을 반드시 적용합니다.

## 빌드

프로젝트 루트에서 두 앱을 함께 빌드합니다.

```bash
mvn clean package
```

앱 하나만 빌드할 수도 있습니다.

```bash
mvn -pl customer-app clean package
mvn -pl admin-app clean package
```

## 로컬 실행

```bash
./run-local.sh customer
./run-local.sh admin
```

또는 Maven으로 직접 실행합니다.

```bash
mvn -pl customer-app -Dspring-boot.run.profiles=local spring-boot:run
mvn -pl admin-app -Dspring-boot.run.profiles=local spring-boot:run
```

## 로컬 테스트 계정

기본 비밀번호는 소스에 포함하지 않습니다. `local` 프로필을 사용할 때만
`SEED_ADMIN_PASSWORD`, `SEED_USER_PASSWORD`를 강한 임시값으로 지정하면 테스트 계정이 생성됩니다.
운영 프로필에서는 샘플 계정과 샘플 데이터가 생성되지 않습니다.

## 주의

이 프로젝트는 교육과 검증 목적의 샘플 애플리케이션입니다. 공개 운영 서비스에 그대로 사용하지 마십시오.
