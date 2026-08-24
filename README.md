# 탑라인 성형외과 홈페이지 샘플

Java Spring Boot 기반의 성형외과 홈페이지 샘플입니다. 기본 실행은 Oracle DB에 직접 연결하고, H2 로컬 테스트가 필요할 때만 `local` 프로필을 사용합니다.

## 포함 기능

- 회원가입 / 로그인 / 로그아웃
- 관리자 권한
- 시술 상담 패키지 목록
- 모의 결제와 결제 완료 저장
- 포인트 적립/사용과 쿠폰 할인 (취약점 진단 실습용)
- 빠른 비용 문의
- 파일 업로드 가능한 온라인 Q&A
- 관리자 Q&A 답변
- 관리자만 작성/수정/삭제 가능한 공지사항
- 관리자 대시보드

## 3-Tier 구조

- Web: Thymeleaf 템플릿, 정적 CSS
- WAS: Spring MVC Controller, Service, Security
- DBMS: JPA Repository, Oracle 기본 연결, H2 로컬 프로필

## Oracle 직접 연결 실행

Oracle DB를 준비한 뒤 환경변수를 지정하고 실행합니다.

```bash
export ORACLE_URL='jdbc:oracle:thin:@localhost:1521/FREEPDB1'
export ORACLE_USERNAME='clinic'
export ORACLE_PASSWORD='clinic'
mvn -Dmaven.repo.local=work/.m2 spring-boot:run
```

브라우저에서 `http://localhost:8080` 접속

테이블을 SQL로 직접 만들고 싶으면 아래 순서로 실행하면 됩니다.

1. `src/main/resources/db/oracle-drop.sql`
2. `src/main/resources/db/oracle-schema.sql`
3. `src/main/resources/db/oracle-data.sql`

이미 8080 포트를 쓰는 프로그램이 있으면 아래처럼 다른 포트로 실행할 수 있습니다.

```bash
mvn -Dmaven.repo.local=work/.m2 spring-boot:run -Dspring-boot.run.arguments=--server.port=8081
```

테스트 계정:

- 관리자: `admin` / `admin1234`
- 일반회원: `user` / `user1234`

## H2 로컬 테스트 실행

Oracle 없이 화면만 확인하고 싶을 때 사용합니다.

```bash
mvn -Dmaven.repo.local=work/.m2 spring-boot:run -Dspring-boot.run.profiles=local
```

H2 콘솔:

- URL: `http://localhost:8080/h2-console`
- JDBC URL: `jdbc:h2:file:./work/clinic-local;MODE=Oracle;DATABASE_TO_UPPER=false;NON_KEYWORDS=USER`
- User: `sa`

## 주요 경로

- 메인: `/`
- 시술 패키지: `/procedures`
- 결제: `/payments/checkout/{procedureId}`
- 온라인 상담: `/qna`
- 공지사항: `/notices`
- 관리자: `/admin`

첨부파일은 기본적으로 `uploads/qna` 폴더에 저장됩니다.

## 포인트/쿠폰 취약점 실습

결제 요청의 `usePoints`, `couponCode` 값을 변조해 비즈니스 로직 취약점을 확인할 수 있습니다.

- 보유량보다 많은 포인트 사용
- 음수 포인트 입력에 의한 포인트 잔액 증가
- 사용자에게 발급되지 않은 쿠폰 사용
- 동일 쿠폰 반복 사용

이 동작은 취약점 진단 교육을 위해 의도적으로 포함된 것이므로 실제 운영 환경에 사용하면 안 됩니다.
