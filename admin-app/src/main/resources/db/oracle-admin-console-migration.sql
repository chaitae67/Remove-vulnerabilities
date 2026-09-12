-- 기존 Oracle DB를 유지하면서 관리자 페이지(상담 특이사항 / 결제 환불) 기능을 추가할 때 한 번 실행합니다.

-- 상담 신청 특이사항(관리자 메모) 컬럼
DECLARE
    column_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO column_count
      FROM user_tab_columns
     WHERE table_name = 'QUICK_CONSULTATION' AND column_name = 'ADMIN_NOTE';

    IF column_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE quick_consultation ADD admin_note VARCHAR2(1000 CHAR)';
    END IF;
END;
/

COMMIT;

-- 결제 환불 시각 기록 컬럼
DECLARE
    column_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO column_count
      FROM user_tab_columns
     WHERE table_name = 'PAYMENT_ORDER' AND column_name = 'REFUNDED_AT';

    IF column_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE payment_order ADD refunded_at TIMESTAMP';
    END IF;
END;
/

COMMIT;
