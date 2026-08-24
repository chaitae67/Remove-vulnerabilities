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

화면 요청은 기본적으로 다음 순서로 처리됩니다.

```text
화면 요청 → Controller → Service → Repository → DB
```

## 프로젝트 폴더 구조

```text
src/main/
├─ java/com/example/clinic/
│  ├─ controller/    URL 요청 처리와 화면 연결
│  ├─ service/       유효성 검사와 업무 로직
│  ├─ repository/    데이터베이스 조회 및 저장
│  ├─ domain/        데이터베이스 테이블에 대응하는 엔티티
│  └─ config/        보안, 파일 업로드, 초기 데이터 설정
│
└─ resources/
   ├─ templates/     Thymeleaf HTML 화면
   ├─ static/        CSS, JavaScript, 이미지 등 정적 파일
   ├─ db/            Oracle 테이블 및 초기 데이터 SQL
   └─ application.yml
```

## 기능별 구현 위치

| 기능 | Controller | Service | Repository | 화면 |
| --- | --- | --- | --- | --- |
| 메인 페이지 | `HomeController` | 여러 Service 사용 | 각 Repository | `templates/home.html` |
| 회원가입·로그인 | `AuthController` | `UserService` | `AppUserRepository` | `templates/auth/` |
| 시술·패키지 | `ProcedureController` | `ProcedureService` | `ProcedureProductRepository` | `templates/procedures/` |
| 시술 검색 | `SearchController` | - | `ProcedureSearchRepository` | `templates/procedures/list.html` |
| 결제 | `PaymentController` | `PaymentService` | `PaymentOrderRepository` | `templates/payments/` |
| 빠른 상담 | `HomeController` | `QuickConsultationService` | `QuickConsultationRepository` | `templates/home.html` |
| 온라인 Q&A | `QnaController` | `QnaService` | `QnaPostRepository` | `templates/qna/` |
| Q&A 파일 첨부 | `QnaController` | `QnaService` | Q&A와 함께 저장 | `templates/qna/form.html` |
| 공지사항 | `NoticeController` | `NoticeService` | `NoticeRepository` | `templates/notices/` |
| 공지 검색 | `SearchController` | - | `NoticeSearchRepository` | `templates/notices/list.html` |
| 마이페이지 | `MyPageController` | - | 회원·결제·Q&A Repository | `templates/mypage/` |
| 관리자 페이지 | `AdminController` | 상담·결제·Q&A Service | 각 Repository | `templates/admin/` |

### 백엔드 패키지

- `controller`: 브라우저 요청을 받고 사용할 Service와 반환할 화면을 결정합니다.
- `service`: 회원가입, 결제 생성, 상담 등록, 파일 저장 등 핵심 로직을 처리합니다.
- `repository`: JPA를 이용해 데이터를 저장하고 조회합니다. 별도 검색 쿼리는 `*SearchRepository`에 있습니다.
- `domain`: 회원, 시술, 결제, Q&A, 공지, 빠른 상담 데이터 구조가 있습니다.
- `config`: 로그인 권한은 `SecurityConfig`, 업로드 파일 제공은 `WebConfig`, 샘플 데이터는 `DataSeeder`가 담당합니다.

### 화면 및 정적 파일

- `templates/fragments/`: 공통 헤더와 푸터
- `templates/auth/`: 로그인과 회원가입
- `templates/procedures/`: 시술 목록과 검색
- `templates/payments/`: 결제 입력과 완료 화면
- `templates/qna/`: Q&A 목록, 작성, 상세, 관리자 답변
- `templates/notices/`: 공지 목록, 작성, 상세, 수정
- `templates/mypage/`: 회원 정보, 결제 내역, 작성한 Q&A
- `templates/admin/`: 최근 상담, 결제, Q&A 관리
- `static/css/style.css`: 전체 화면의 공통 스타일

현재 별도의 JavaScript 파일은 없습니다.

## 새 기능 추가 방법

예를 들어 예약 관리 기능을 추가한다면 다음 구조로 작성합니다.

```text
domain/Reservation.java
repository/ReservationRepository.java
service/ReservationService.java
controller/ReservationController.java
templates/reservations/list.html
templates/reservations/form.html
```

필요에 따라 다음 파일도 함께 수정합니다.

- `SecurityConfig`: 예약 주소의 접근 권한 설정
- `templates/fragments/header.html`: 메뉴 링크 추가
- `static/css/style.css`: 예약 화면 스타일 추가
- `db/*.sql`: Oracle 테이블과 초기 데이터 정의
- `src/test/`: 예약 기능 테스트 작성

`MyPageController`와 `SearchController`는 현재 Service 없이 Repository를 직접 사용합니다. 관련 기능이 커지면 별도 Service로 분리하는 것을 권장합니다.

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

## 로컬 AI 챗봇 실행

챗봇은 API 키가 필요 없는 로컬 Ollama API를 사용합니다. 각 PC에 Ollama와 모델을 한 번씩 설치해야 합니다.

1. `https://ollama.com/download`에서 Ollama를 설치합니다.
2. 터미널에서 기본 모델을 내려받습니다.

```bash
ollama pull gemma3:1b
```

3. Ollama가 실행 중인 상태에서 Spring Boot 애플리케이션을 실행합니다.

```bash
mvn -Dmaven.repo.local=work/.m2 spring-boot:run -Dspring-boot.run.profiles=local
```

기본 모델은 `gemma3:1b`, 기본 API 주소는 `http://localhost:11434/api/chat`입니다. 각각 `OLLAMA_MODEL`, `OLLAMA_CHAT_URL` 환경변수로 변경할 수 있습니다. Ollama가 꺼져 있거나 모델이 설치되지 않았으면 기존 규칙 기반 안내로 자동 전환됩니다.

이 챗봇에는 보안 교육을 위해 다음 취약점이 의도적으로 포함되어 있습니다.

- 사용자 입력을 운영 지시와 같은 프롬프트 문자열에 결합하는 프롬프트 인젝션
- AI 응답을 HTML 정화 없이 `innerHTML`로 출력하는 XSS
- 인증 없이 누구나 사용할 수 있어 로컬 CPU·메모리 자원을 소모시키는 무제한 호출

실제 운영 환경에서는 역할이 분리된 메시지, 출력 HTML 정화, 인증·호출 제한·자원 사용량 제한을 적용해야 합니다.
