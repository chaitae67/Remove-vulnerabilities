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
└── admin-app/               관리자용 애플리케이션 (기본 포트 8081)
    ├── pom.xml              관리자 앱 모듈 설정
    ├── .env.example         관리자 앱 환경변수 예시
    └── src/
```

- `customer-app`: 고객 화면과 회원, 시술, 결제, 상담, Q&A 기능을 제공합니다.
- `admin-app`: 관리자 로그인, 대시보드, 회원 API, Q&A 관리 기능을 제공합니다.
- 두 앱은 동일한 Oracle 데이터베이스를 사용합니다.

## 배포 구조

```text
고객 도메인 -> WEB01(Nginx) -> WAS01(customer-app:8081) --┐
                                                          ├-> DB01 / Oracle :1521
관리 도메인 -> WEB-ADMIN01 -> WAS-ADMIN01(admin-app:8081) ┘
```

## 환경변수

각 앱의 `.env.example`을 참고하여 실행 환경에 값을 지정합니다.

```bash
export ORACLE_URL='jdbc:oracle:thin:@10.0.20.56:1521/FREEPDB1'
export ORACLE_USERNAME='clinic'
export ORACLE_PASSWORD='실제비밀번호'
```

관리자 앱은 `APP_BASE_URL`, `APP_UPLOAD_DIR`, `MAIL_USERNAME`, `MAIL_PASSWORD`를 추가로 사용하고, 고객 앱은 관리자 화면 연결을 위해 `ADMIN_APP_URL`을 사용합니다.

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

## 기본 실습 계정

- 관리자: `admin / admin1234`
- 고객 테스트: `user / user1234`

실습 환경 이외에서는 반드시 비밀번호를 변경하십시오.

## 주의

이 프로젝트에는 취약점 진단 실습을 위한 의도적인 취약 설정과 코드가 남아 있습니다. 공개 운영 서비스에 그대로 사용하지 마십시오.
