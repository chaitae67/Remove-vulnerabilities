-- 기존 Oracle DB를 유지하면서 회원 탈퇴 기능을 추가할 때 한 번 실행합니다.
-- 데이터가 들어 있는 테이블에서도 안전하도록 기본값 적용 후 NOT NULL로 변경합니다.
DECLARE
    column_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO column_count
      FROM user_tab_columns
     WHERE table_name = 'APP_USER' AND column_name = 'WITHDRAWN';

    IF column_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE app_user ADD withdrawn NUMBER(1) DEFAULT 0';
    END IF;
END;
/

UPDATE app_user SET withdrawn = 0 WHERE withdrawn IS NULL;

DECLARE
    column_nullable VARCHAR2(1);
BEGIN
    SELECT nullable INTO column_nullable
      FROM user_tab_columns
     WHERE table_name = 'APP_USER' AND column_name = 'WITHDRAWN';

    IF column_nullable = 'Y' THEN
        EXECUTE IMMEDIATE 'ALTER TABLE app_user MODIFY withdrawn DEFAULT 0 NOT NULL';
    ELSE
        EXECUTE IMMEDIATE 'ALTER TABLE app_user MODIFY withdrawn DEFAULT 0';
    END IF;
END;
/

DECLARE
    column_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO column_count
      FROM user_tab_columns
     WHERE table_name = 'APP_USER' AND column_name = 'WITHDRAWN_AT';

    IF column_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE app_user ADD withdrawn_at TIMESTAMP';
    END IF;
END;
/

DECLARE
    constraint_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO constraint_count
      FROM user_constraints
     WHERE table_name = 'APP_USER' AND constraint_name = 'CK_APP_USER_WITHDRAWN';

    IF constraint_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE app_user ADD CONSTRAINT ck_app_user_withdrawn CHECK (withdrawn IN (0, 1))';
    END IF;
END;
/

COMMIT;
