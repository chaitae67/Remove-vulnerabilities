-- 기존 Oracle DB를 유지하면서 회원 탈퇴 기능을 추가할 때 한 번 실행합니다.
ALTER TABLE app_user ADD (
    withdrawn NUMBER(1) DEFAULT 0 NOT NULL,
    withdrawn_at TIMESTAMP
);

ALTER TABLE app_user ADD CONSTRAINT ck_app_user_withdrawn
    CHECK (withdrawn IN (0, 1));

COMMIT;
