-- VULNERABLE LAB - WEB-07/WEB-13: 웹 경로에 노출된 백업/DB 덤프 파일
CREATE TABLE app_user (
    id NUMBER PRIMARY KEY,
    username VARCHAR2(50) NOT NULL UNIQUE,
    password VARCHAR2(255) NOT NULL,
    name VARCHAR2(50) NOT NULL,
    email VARCHAR2(120) NOT NULL UNIQUE,
    phone VARCHAR2(30),
    role VARCHAR2(20) NOT NULL,
    point_balance NUMBER DEFAULT 0
);

INSERT INTO app_user (id, username, password, name, email, role, point_balance)
VALUES (1, 'admin', '$2a$10$examplebcrypthash', '관리자', 'admin@clinic.local', 'ADMIN', 10000);
