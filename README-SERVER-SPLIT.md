# Zero Day Clinic - 고객/관리자 서버 분리 소스

기존 단일 Spring Boot 프로젝트를 고객용과 관리자용 두 애플리케이션으로 분리한 전체 소스입니다.

## 배포 구조

```text
고객 도메인 -> WEB01(Nginx) -> WAS01(customer-app:8081) --┐
                                                          ├-> DB01 EC2 / Oracle :1521
관리 도메인 -> WEB-ADMIN01 -> WAS-ADMIN01(admin-app:8082) ┘
```

두 애플리케이션은 `ORACLE_URL`, `ORACLE_USERNAME`, `ORACLE_PASSWORD`를 동일하게 지정하여 하나의 Oracle DB를 공유합니다.

## 폴더

- `customer-app/`: 고객용 웹 애플리케이션. 기존 고객 기능을 유지하고 관리자 Controller/화면을 제거했습니다.
- `admin-app/`: 관리자 전용 웹 애플리케이션. 관리자 로그인, 대시보드, 회원 API, Q&A 관리만 외부 웹 경로로 노출합니다.

## DB 환경변수 예시

```bash
export ORACLE_URL='jdbc:oracle:thin:@10.0.20.56:1521/FREEPDB1'
export ORACLE_USERNAME='clinic'
export ORACLE_PASSWORD='실제비밀번호'
```

## 고객 WAS 빌드/실행

```bash
cd customer-app
mvn clean package -DskipTests
java -jar target/clinic-customer-app-0.0.1-SNAPSHOT.jar
```

기본 포트는 8081입니다.

## 관리자 WAS 빌드/실행

```bash
cd admin-app
mvn clean package -DskipTests
java -jar target/clinic-admin-app-0.0.1-SNAPSHOT.jar
```

기본 포트는 8082입니다.

## 기본 실습 계정

기존 `DataSeeder` 기준:

- 관리자: `admin / admin1234`
- 고객 테스트: `user / user1234`

실습 환경 이외에서는 반드시 비밀번호를 변경하십시오.

## Nginx 연결 예시

고객 WEB01은 WAS01의 8081로, 관리자 WEB-ADMIN01은 WAS-ADMIN01의 8082로 reverse proxy하면 됩니다.

## 주의

이 프로젝트에는 취약점 진단 실습 목적으로 기존 코드의 일부 의도적인 취약 설정/코드가 남아 있습니다. 공개 운영 서비스에 그대로 사용하지 마십시오.
