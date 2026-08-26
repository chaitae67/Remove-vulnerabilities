INSERT INTO app_user (username, password, name, email, phone, role, point_balance, withdrawn, created_at)
VALUES (
  'admin',
  '$2a$10$sem8oIPJ4v.cKjqvLrimceXFRluuk0mXNFfqZusBxMMBLZ8/cxmv.',
  '관리자',
  'admin@clinic.local',
  '02-0000-0000',
  'ADMIN',
  10000,
  0,
  SYSTIMESTAMP
);

INSERT INTO app_user (username, password, name, email, phone, role, point_balance, withdrawn, created_at)
VALUES (
  'user',
  '$2a$10$gS3FTadAfVWW4gKHvlUW8.8V9.M95tf.gNEuy58UT40fcZe75XNNq',
  '테스트회원',
  'user@clinic.local',
  '010-1234-5678',
  'USER',
  5000,
  0,
  SYSTIMESTAMP
);

INSERT INTO procedure_product (name, category, summary, description, price, active)
VALUES (
  '바디라인 컨설팅 패키지',
  '지방흡입',
  '부위별 라인 분석과 수술 전 검사를 포함한 기본 상담 패키지',
  '상담, 체형 분석, 수술 가능성 안내를 묶은 입문 패키지입니다. 실제 수술 여부와 비용은 의료진 상담 후 확정됩니다.',
  50000,
  1
);

INSERT INTO procedure_product (name, category, summary, description, price, active)
VALUES (
  '얼굴 윤곽 상담 패키지',
  '윤곽/리프팅',
  '얼굴 비율 진단과 맞춤 시술 제안을 제공하는 상담 패키지',
  '정면/측면 밸런스를 확인하고 비수술/수술 선택지를 안내합니다.',
  70000,
  1
);

INSERT INTO procedure_product (name, category, summary, description, price, active)
VALUES (
  '수술 후 케어 패키지',
  '사후관리',
  '붓기, 흉터, 회복 경과 확인을 위한 관리 예약 상품',
  '수술 후 회복 상태를 체크하고 개인별 케어 일정을 제안합니다.',
  120000,
  1
);

INSERT INTO notice (title, content, author_id, created_at)
VALUES (
  '8월 진료 일정 안내',
  '광복절 및 병원 내부 교육 일정에 따라 일부 진료 시간이 조정됩니다. 예약 전 전화 확인을 부탁드립니다.',
  1,
  SYSTIMESTAMP
);

INSERT INTO notice (title, content, author_id, created_at)
VALUES (
  '상담 전 안내사항',
  '온라인 상담은 참고용이며 정확한 진단과 치료 계획은 내원 후 의료진 상담을 통해 결정됩니다.',
  1,
  SYSTIMESTAMP
);

INSERT INTO qna_post (
  title, content, writer_id, phone, private_post, answered, answer, answered_at, created_at
)
VALUES (
  '허벅지 라인 상담 가능할까요?',
  '회복 기간과 대략적인 상담 절차가 궁금합니다.',
  2,
  '010-1234-5678',
  0,
  1,
  '개인 상태에 따라 다르므로 사진 상담 또는 내원 상담을 권장드립니다. 기본 회복 안내는 상담 시 자세히 설명드릴게요.',
  SYSTIMESTAMP,
  SYSTIMESTAMP
);

INSERT INTO review (title, content, rating, writer_id, procedure_product_id, created_at)
VALUES (
  '상담부터 관리까지 꼼꼼하게 챙겨주셨어요',
  '체형 분석부터 회복 케어 일정까지 자세히 안내해 주셔서 만족스러웠습니다.',
  5,
  2,
  1,
  SYSTIMESTAMP
);

INSERT INTO coupon (code, name, discount_amount, active, expires_at)
VALUES ('WELCOME10000', '신규 회원 1만원 할인', 10000, 1, SYSDATE + 365);

INSERT INTO quick_consultation (
  name, phone, area, preferred_contact, message, privacy_agreed, created_at
)
VALUES (
  '김테스트',
  '010-1111-2222',
  '지방흡입',
  '전화 상담',
  '팔과 허벅지 상담 비용이 궁금합니다.',
  1,
  SYSTIMESTAMP
);

INSERT INTO payment_order (
  order_number, buyer_id, procedure_product_id, amount, original_amount,
  coupon_discount, points_used, earned_points, coupon_id, status, method, created_at, paid_at
)
VALUES (
  'CLINIC-SAMPLE01',
  2,
  1,
  50000,
  50000,
  0,
  0,
  500,
  NULL,
  'PAID',
  'CARD',
  SYSTIMESTAMP,
  SYSTIMESTAMP
);

COMMIT;
